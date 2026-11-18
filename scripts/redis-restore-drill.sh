#!/usr/bin/env bash
# Redis-level backup and restore drill: back up with `redis-cli --rdb`, DELETE the volume, restore the dump into a fresh one.
# Predictions: docs/backup-restore.md, part 2 (written before the first run). Needs the GitOps or the direct install.
#   scripts/redis-restore-drill.sh            results in docs/backup-results/<today>-redis-rdb/
#   BACKUP_DATE=2026-11-18 scripts/redis-restore-drill.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

NS=shop
PVC=data-shop-redis-0
DATE=${BACKUP_DATE:-$(date +%F)}
DIR=docs/backup-results/$DATE-redis-rdb
WORK=$(mktemp -d)   # the dump stays on this machine only for the length of the drill
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }
for tool in kubectl jq curl python3; do command -v $tool >/dev/null || { echo "missing: $tool" >&2; exit 2; }; done
mkdir -p "$DIR"

redis() {   # redis <pod> <command...>: redis-cli inside that pod (the password comes from the pod's own env)
  local pod=$1; shift
  kubectl -n $NS exec "$pod" -- sh -c "redis-cli -a \"\$REDIS_PASSWORD\" --no-auth-warning $*" 2>/dev/null
}
state() {   # the numbers that must survive
  local pod=$1
  printf 'next_id=%s\n' "$(redis "$pod" GET orders:next_id)"
  redis "$pod" HGETALL orders:by_product | paste - - | sort | sed 's/\t/=/;s/^/by_product./'
  printf 'revenue=%s\n' "$(redis "$pod" GET orders:revenue)"
}
wait_for() {
  local limit=$1 what=$2; shift 2
  for i in $(seq 1 "$limit"); do "$@" >/dev/null 2>&1 && { printf '  %s after ~%ss\n' "$what" "$i"; return 0; }; sleep 1; done
  printf '  TIMED OUT after %ss: %s\n' "$limit" "$what"; return 1
}
code() { curl -s -m 3 -o /dev/null -w '%{http_code}' -H 'Host: shop.localtest.me' "$@" http://127.0.0.1:8080/api/${PATHSEG}; }
products() { PATHSEG=products code; }
order()    { PATHSEG=orders code -XPOST -H 'content-type: application/json' -d '{"product":"mouse"}'; }
redis_ready() { [[ $(kubectl -n $NS get pod shop-redis-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null) == true ]]; }

# Argo CD would put the replica count and anything else we change by hand back within seconds; switch that off while we work.
GITOPS=0; kubectl -n argocd get application shop >/dev/null 2>&1 && GITOPS=1
set_selfheal() {
  [[ $GITOPS == 1 ]] || return 0
  kubectl -n argocd patch application shop --type merge -p "$(printf '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":%s}}}}' "$1")" >/dev/null
}
cleanup() { set_selfheal true; kubectl -n $NS delete pod redis-restore --ignore-not-found --wait=false >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

say "a steady system and a known set of orders"
wait_for 120 "Redis Ready" redis_ready || exit 1
for i in $(seq 1 30); do
  curl -s -o /dev/null -m 5 -XPOST -H 'Host: shop.localtest.me' -H 'content-type: application/json' \
    -d "{\"product\":\"$([[ $((i % 3)) == 0 ]] && echo mouse || echo keyboard)\"}" http://127.0.0.1:8080/api/orders
done
wait_for 60 "order queue drained" bash -c "[[ \$(kubectl -n $NS exec shop-redis-0 -- sh -c 'redis-cli -a \"\$REDIS_PASSWORD\" --no-auth-warning LLEN orders:pending' 2>/dev/null) == 0 ]]"
sleep 3
state shop-redis-0 | tee "$DIR/before.txt"
[[ $(head -1 "$DIR/before.txt") != "next_id=" ]] || { echo "could not read Redis state, aborting" >&2; exit 1; }

say "backup: a point-in-time RDB dump with redis-cli --rdb"
B0=$(now)
kubectl -n $NS exec shop-redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --rdb /data/backup.rdb' 2>&1 | tail -1
kubectl -n $NS cp shop-redis-0:/data/backup.rdb "$WORK/dump.rdb" >/dev/null 2>&1
B1=$(now)
DUMP_BYTES=$(wc -c < "$WORK/dump.rdb" | tr -d ' ')
echo "  dump: $DUMP_BYTES bytes, sha256 $(shasum -a 256 "$WORK/dump.rdb" | cut -c1-16)..., took $(python3 -c "print(round($B1-$B0,1))") s"
[[ $DUMP_BYTES -gt 0 ]] || { echo "empty dump, aborting" >&2; exit 1; }

say "disaster: delete Redis's volume for good"
D0=$(now)
set_selfheal false
kubectl -n $NS scale statefulset shop-redis --replicas=0 >/dev/null
wait_for 90 "Redis pod gone" bash -c "! kubectl -n $NS get pod shop-redis-0 >/dev/null 2>&1"
kubectl -n $NS delete pvc $PVC --wait=true >/dev/null
echo "  volume deleted: $(kubectl -n $NS get pvc $PVC 2>&1 | head -1 | cut -c1-70)"
sleep 12   # let the API notice (readiness no longer depends on Redis, so it should stay up)
P_CODES=$(for _ in 1 2 3; do products; echo -n " "; done); O_CODES=$(for _ in 1 2 3; do order; echo -n " "; done)
echo "  while Redis is gone: GET /api/products -> $P_CODES| POST /api/orders -> $O_CODES"

say "restore: load the dump into a fresh volume, with append-only mode off, then convert to the append-only files production uses"
kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $PVC, namespace: $NS }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: redis-restore, namespace: $NS }
spec:
  restartPolicy: Never
  serviceAccountName: shop
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 999, runAsGroup: 999, fsGroup: 999, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: redis
      image: redis:7.4-alpine
      # waits for the dump to arrive, then loads it with append-only OFF (with it on, Redis ignores an RDB and starts empty)
      command: ["sh", "-c", "while [ ! -f /data/dump.rdb ]; do sleep 1; done; exec redis-server --requirepass \"\$REDIS_PASSWORD\" --appendonly no --dir /data --dbfilename dump.rdb"]
      env:
        - name: REDIS_PASSWORD
          valueFrom: { secretKeyRef: { name: shop-redis, key: password } }
      resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { memory: 128Mi } }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes: [{ name: data, persistentVolumeClaim: { claimName: $PVC } }]
YAML
wait_for 120 "restore pod running" bash -c "[[ \$(kubectl -n $NS get pod redis-restore -o jsonpath='{.status.phase}') == Running ]]" || exit 1
kubectl -n $NS cp "$WORK/dump.rdb" redis-restore:/data/dump.rdb.part >/dev/null 2>&1
kubectl -n $NS exec redis-restore -- mv /data/dump.rdb.part /data/dump.rdb
wait_for 60 "dump loaded" bash -c "[[ -n \$(kubectl -n $NS exec redis-restore -- sh -c 'redis-cli -a \"\$REDIS_PASSWORD\" --no-auth-warning GET orders:next_id' 2>/dev/null) ]]" || exit 1
redis redis-restore CONFIG SET appendonly yes >/dev/null
wait_for 60 "append-only files written" bash -c "[[ \$(kubectl -n $NS exec redis-restore -- sh -c 'redis-cli -a \"\$REDIS_PASSWORD\" --no-auth-warning INFO persistence' 2>/dev/null | tr -d '\r' | awk -F: '/aof_rewrite_in_progress/{print \$2}') == 0 ]]" || exit 1
redis redis-restore SHUTDOWN NOSAVE >/dev/null
wait_for 60 "restore pod finished" bash -c "[[ \$(kubectl -n $NS get pod redis-restore -o jsonpath='{.status.phase}') != Running ]]"
kubectl -n $NS delete pod redis-restore --wait=true >/dev/null

say "bring Redis back the normal way and compare"
kubectl -n $NS scale statefulset shop-redis --replicas=1 >/dev/null
set_selfheal true
wait_for 180 "Redis Ready" redis_ready || exit 1
wait_for 60 "products answer 200" bash -c "[[ \$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H 'Host: shop.localtest.me' http://127.0.0.1:8080/api/products) == 200 ]]"
D1=$(now)
sleep 3
state shop-redis-0 | tee "$DIR/after.txt"
if diff -u "$DIR/before.txt" "$DIR/after.txt" >/dev/null; then verdict=IDENTICAL; else verdict=DIFFERENT; diff -u "$DIR/before.txt" "$DIR/after.txt"; fi
RESTORE_S=$(python3 -c "print(round($D1-$D0,1))")
echo "  restored data: $verdict; from deleting the volume to verified: ${RESTORE_S} s"
jq -n --arg v "$verdict" --argjson bytes "$DUMP_BYTES" --argjson dump_s "$(python3 -c "print(round($B1-$B0,1))")" --argjson total "$RESTORE_S" \
  --arg p "$P_CODES" --arg o "$O_CODES" \
  '{restored_data:$v, dump_bytes:$bytes, dump_seconds:$dump_s, delete_to_verified_seconds:$total, products_codes_while_redis_gone:$p, orders_codes_while_redis_gone:$o}' > "$DIR/summary.json"
cat "$DIR/summary.json"
[[ $verdict == IDENTICAL ]]
