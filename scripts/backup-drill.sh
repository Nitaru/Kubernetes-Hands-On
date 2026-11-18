#!/usr/bin/env bash
# Backup and restore drill for Redis's volume. Predictions: docs/backup-restore.md (written before the first run).
#   scripts/backup-drill.sh              results in docs/backup-results/<today>/
#   BACKUP_DATE=2026-11-18 scripts/backup-drill.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

NS=shop
RESTORED=shop-restored
DATE=${BACKUP_DATE:-$(date +%F)}
DIR=docs/backup-results/$DATE
TS=$(date +%H%M%S)
VELERO_CHART=12.2.5
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
for tool in kubectl helm jq curl python3; do command -v $tool >/dev/null || { echo "missing: $tool" >&2; exit 2; }; done
mkdir -p "$DIR"

redis() {   # redis <namespace> <command...>: run redis-cli inside that namespace's Redis pod (the password comes from the pod's own env)
  local ns=$1; shift
  kubectl -n "$ns" exec shop-redis-0 -- sh -c "redis-cli -a \"\$REDIS_PASSWORD\" --no-auth-warning $*" 2>/dev/null
}
state() {   # the numbers that must survive: total orders created, per-product counts, revenue
  local ns=$1
  printf 'next_id=%s\n' "$(redis "$ns" GET orders:next_id)"
  redis "$ns" HGETALL orders:by_product | paste - - | sort | sed 's/\t/=/;s/^/by_product./'
  printf 'revenue=%s\n' "$(redis "$ns" GET orders:revenue)"
}
wait_for() {   # wait_for <seconds> <description> <command...>
  local limit=$1 what=$2; shift 2
  for i in $(seq 1 "$limit"); do "$@" >/dev/null 2>&1 && { printf '  %s after ~%ss\n' "$what" "$i"; return 0; }; sleep 1; done
  printf '  TIMED OUT after %ss: %s\n' "$limit" "$what"; return 1
}
phase() { kubectl -n velero get "$1" "$2" -o jsonpath='{.status.phase}' 2>/dev/null; }
finished() { case "$(phase "$1" "$2")" in Completed|Failed|PartiallyFailed|FailedValidation) return 0;; *) return 1;; esac; }

say "installing MinIO and Velero (if not already there)"
kubectl apply -f platform/minio.yaml >/dev/null
kubectl -n velero rollout status deploy/minio --timeout=180s
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update >/dev/null
helm upgrade --install velero vmware-tanzu/velero --version "$VELERO_CHART" -n velero -f platform/velero-values.yaml --wait --timeout 6m >/dev/null || { echo "velero install failed" >&2; exit 1; }
wait_for 120 "backup storage location Available" bash -c '[[ $(kubectl -n velero get backupstoragelocation default -o jsonpath="{.status.phase}") == Available ]]' || exit 1
wait_for 120 "node agent Ready on every node" bash -c '[[ $(kubectl -n velero get ds node-agent -o jsonpath="{.status.numberReady}") == $(kubectl -n velero get ds node-agent -o jsonpath="{.status.desiredNumberScheduled}") ]]' || exit 1

say "creating a known set of orders"
for i in $(seq 1 30); do
  curl -s -o /dev/null -m 5 -XPOST -H 'Host: shop.localtest.me' -H 'content-type: application/json' \
    -d "{\"product\":\"$([[ $((i % 3)) == 0 ]] && echo mouse || echo keyboard)\"}" http://127.0.0.1:8080/api/orders
done
wait_for 60 "order queue drained" bash -c "[[ \$(kubectl -n $NS exec shop-redis-0 -- sh -c 'redis-cli -a \"\$REDIS_PASSWORD\" --no-auth-warning LLEN orders:pending' 2>/dev/null) == 0 ]]"
sleep 5   # Redis fsyncs its append-only file once a second; let the last writes reach the disk
state $NS | tee "$DIR/before.txt"
[[ -s $DIR/before.txt && $(head -1 "$DIR/before.txt") != "next_id=" ]] || { echo "could not read Redis state, aborting" >&2; exit 1; }

say "backing up the $NS namespace, volumes included"
T0=$(date +%s)
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: velero.io/v1
kind: Backup
metadata: { name: drill-$TS, namespace: velero }
spec:
  includedNamespaces: [$NS]
  defaultVolumesToFsBackup: true
  ttl: 24h0m0s
YAML
wait_for 300 "backup finished" finished backup drill-$TS
BACKUP_S=$(( $(date +%s) - T0 ))
echo "  backup phase: $(phase backup drill-$TS) in ${BACKUP_S}s"
# A backup can say Completed and still contain no data: Velero's file-level backup skips hostPath volumes, which is
# what kind's default storage creates. So check that the Redis data volume itself was backed up, not just the status.
REDIS_PVB=$(kubectl -n velero get podvolumebackups -l velero.io/backup-name=drill-$TS -o json \
  | jq '[.items[] | select(.spec.pod.name == "shop-redis-0" and .status.phase == "Completed")] | length')
echo "  volumes of shop-redis-0 backed up: $REDIS_PVB"
if [[ $REDIS_PVB -lt 1 ]]; then
  pv_type=$(kubectl get pv "$(kubectl -n $NS get pvc data-shop-redis-0 -o jsonpath='{.spec.volumeName}')" -o json | jq -r 'if .spec.hostPath then "hostPath" elif .spec.local then "local" else "other" end')
  echo "  FAIL: the backup is Completed but Redis's data volume is NOT in it (its PV type is $pv_type)." >&2
  echo "        Velero's file-level backup cannot read hostPath volumes. Use a CSI or local-type volume, or a Redis-level backup (scripts/redis-restore-drill.sh)." >&2
  exit 1
fi
kubectl -n velero get backup drill-$TS -o json | jq '{phase:.status.phase, items:.status.progress, warnings:.status.warnings, errors:.status.errors}' > "$DIR/backup.json"

say "restoring into a second namespace ($RESTORED)"
kubectl delete ns $RESTORED --ignore-not-found --wait=true >/dev/null
T1=$(date +%s)
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: velero.io/v1
kind: Restore
metadata: { name: drill-$TS, namespace: velero }
spec:
  backupName: drill-$TS
  namespaceMapping: { $NS: $RESTORED }
  # only what the data needs: the copy must not take over the real ingress, scraping or scaling
  excludedResources: [ingresses.networking.k8s.io, horizontalpodautoscalers.autoscaling, servicemonitors.monitoring.coreos.com, prometheusrules.monitoring.coreos.com]
YAML
wait_for 300 "restore finished" finished restore drill-$TS
wait_for 240 "restored Redis pod Ready" bash -c "[[ \$(kubectl -n $RESTORED get pod shop-redis-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null) == true ]]"
RESTORE_S=$(( $(date +%s) - T1 ))
echo "  restore phase: $(phase restore drill-$TS) in ${RESTORE_S}s"
kubectl -n velero get restore drill-$TS -o json | jq '{phase:.status.phase, warnings:.status.warnings, errors:.status.errors}' > "$DIR/restore.json"

say "comparing the restored data with what was backed up"
sleep 3
state $RESTORED | tee "$DIR/after.txt"
if diff -u "$DIR/before.txt" "$DIR/after.txt" >/dev/null; then verdict="IDENTICAL"; else verdict="DIFFERENT"; diff -u "$DIR/before.txt" "$DIR/after.txt"; fi
echo "  restored data: $verdict"
jq -n --arg b "$(phase backup drill-$TS)" --arg r "$(phase restore drill-$TS)" --argjson bs "$BACKUP_S" --argjson rs "$RESTORE_S" --arg v "$verdict" \
  '{backup_phase:$b, backup_seconds:$bs, restore_phase:$r, restore_seconds:$rs, restored_data:$v}' > "$DIR/summary.json"
cat "$DIR/summary.json"

say "cleaning up the second namespace"
kubectl delete ns $RESTORED --wait=false >/dev/null
[[ $verdict == IDENTICAL ]]
