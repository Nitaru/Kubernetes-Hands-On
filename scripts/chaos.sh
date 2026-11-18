#!/usr/bin/env bash
# Chaos experiments against the running platform (GitOps install: `make up-gitops`).
# The hypotheses are in docs/chaos-experiments.md, written before the first run.
#
#   scripts/chaos.sh podkill|drain|redis|redisdown|baddeploy|netpol|all
#   CHAOS_DATE=2026-11-18 scripts/chaos.sh redis      # where the raw results go (default: today)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

NS=shop
DATE=${CHAOS_DATE:-$(date +%F)}
OUT_ROOT=docs/chaos-results/$DATE
PROM=/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1
API_SEL=app.kubernetes.io/name=shop-api
REDIS_SEL=app.kubernetes.io/name=shop-redis
BASELINE_S=30
AFTER_S=30

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 2; }; }
need kubectl; need python3; need jq; need git

prom_q() {   # prom_q <promql>: first value, or "no data"
  kubectl get --raw "$PROM/query?query=$(jq -rn --arg q "$1" '$q|@uri')" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "no data"' 2>/dev/null || echo "no data"
}
firing() {
  kubectl get --raw "$PROM/query?query=ALERTS%7Balertname%3D~%22Shop.*%22%2Calertstate%3D%22firing%22%7D" 2>/dev/null \
    | jq -r '[.data.result[].metric.alertname] | unique | join(", ") | if . == "" then "none" else . end' 2>/dev/null || echo "unknown"
}
# Count pods, not the Deployment's status: right after a forced delete the status still shows the old numbers.
pods_ready() {   # pods_ready <label selector>: pods that are Ready and not terminating
  kubectl -n $NS get pods -l "$1" -o json 2>/dev/null \
    | jq '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' 2>/dev/null || echo 0
}
pods_total() {   # pods_total <label selector>: pods that are not terminating
  kubectl -n $NS get pods -l "$1" -o json 2>/dev/null | jq '[.items[] | select(.metadata.deletionTimestamp == null)] | length' 2>/dev/null || echo 0
}
api_ready()  { pods_ready $API_SEL; }
api_wanted() { kubectl -n $NS get deploy shop-api -o jsonpath='{.spec.replicas}' 2>/dev/null; }
redis_ready() { [[ $(pods_ready $REDIS_SEL) == 1 && $(pods_total $REDIS_SEL) == 1 ]] && echo true || echo false; }
products_ok() { [[ $(curl -s -m 2 -o /dev/null -w '%{http_code}' -H 'Host: shop.localtest.me' http://127.0.0.1:8080/api/products) == 200 ]]; }
steady() {   # everything is up and serving, three answers in a row
  local want ready total
  want=$(api_wanted); ready=$(pods_ready $API_SEL); total=$(pods_total $API_SEL)
  [[ -n $want && $want -ge 2 && $ready == "$want" && $total == "$want" && $(redis_ready) == true ]] || return 1
  products_ok && products_ok && products_ok
}
wait_until() {   # wait_until <seconds> <description> <command...>: poll once a second, print how long it took
  local limit=$1 what=$2; shift 2
  for i in $(seq 1 "$limit"); do "$@" >/dev/null 2>&1 && { printf '  %s after ~%ss\n' "$what" "$i"; return 0; }; sleep 1; done
  printf '  TIMED OUT after %ss waiting for: %s\n' "$limit" "$what"; return 1
}

# ---------- one experiment: load, fault, recovery, report ----------
DIR="" LOAD_PID=""
begin() {   # begin <name>
  DIR=$OUT_ROOT/$1; mkdir -p "$DIR"; : > "$DIR/events.txt"; rm -f "$DIR/STOP"
  say "$1: waiting for a steady system"
  wait_until 180 "system steady" steady || { echo "  not steady, aborting $1" >&2; return 1; }
  python3 scripts/chaos-load.py run --out "$DIR/requests.csv" --stop-file "$DIR/STOP" --rate 20 &
  LOAD_PID=$!
  say "$1: ${BASELINE_S}s of baseline load"
  sleep $BASELINE_S
}
event() { echo "$1 $(now)" >> "$DIR/events.txt"; }
finish() {   # finish <name>
  say "$1: ${AFTER_S}s of load after recovery, then the report"
  sleep $AFTER_S
  touch "$DIR/STOP"; wait "$LOAD_PID" 2>/dev/null
  sleep 20   # let Prometheus scrape the last requests
  {
    echo "5-minute error ratio now:        $(prom_q shop:http_errors:ratio_rate5m)"
    echo "worst 5-minute error ratio seen: $(prom_q 'max_over_time(shop:http_errors:ratio_rate5m[15m])')"
    echo "5xx responses the app counted:   $(prom_q 'sum(increase(http_request_duration_seconds_count{app="shop-api",status=~"5.."}[15m]))')"
    echo "SLO alerts firing:               $(firing)"
  } | tee "$DIR/prometheus.txt"
  python3 scripts/chaos-load.py report --requests "$DIR/requests.csv" --events "$DIR/events.txt" --json "$DIR/summary.json"
}

# ---------- 1. podkill ----------
podkill() {
  begin podkill || return 1
  local victim; victim=$(kubectl -n $NS get pod -l $API_SEL -o name | head -1)
  say "podkill: kill $victim with no grace period"
  event fault
  kubectl -n $NS delete "$victim" --grace-period=0 --force --wait=false 2>&1 | tail -1
  wait_until 120 "all API pods Ready again" steady
  event recovered
  finish podkill
}

# ---------- 2. drain ----------
drain() {
  begin drain || return 1
  local redis_node node
  redis_node=$(kubectl -n $NS get pod -l $REDIS_SEL -o jsonpath='{.items[0].spec.nodeName}')
  node=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -vx "$redis_node" | head -1)
  say "drain: Redis runs on $redis_node, so drain $node"
  event fault
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=180s 2>&1 | tail -2
  wait_until 120 "all API pods Ready again" steady
  event recovered
  finish drain
  kubectl uncordon "$node" >/dev/null
}

# ---------- 3. redis ----------
redis() {
  begin redis || return 1
  say "redis: delete the Redis pod"
  event fault
  kubectl -n $NS delete pod -l $REDIS_SEL --wait=false 2>&1 | tail -1
  # Poll once a second what each part is doing, so the timeline is in the results.
  ( for i in $(seq 1 90); do
      printf '%s api_ready=%s/%s redis_ready=%s products_http=%s\n' "$(now)" "$(api_ready)" "$(api_wanted)" "$(redis_ready)" \
        "$(curl -s -m 2 -o /dev/null -w '%{http_code}' -H 'Host: shop.localtest.me' http://127.0.0.1:8080/api/products)"
      sleep 1; done > "$DIR/timeline.txt" ) &
  local tl=$!
  wait_until 180 "system steady again" steady
  event recovered
  wait $tl 2>/dev/null
  finish redis
}

# ---------- 3b. redisdown (Redis gone for long enough to matter) ----------
set_selfheal() {   # set_selfheal true|false: Argo CD's automatic drift correction on the shop app
  kubectl -n argocd patch application shop --type merge \
    -p "$(printf '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":%s}}}}' "$1")" >/dev/null
}
redisdown() {
  begin redisdown || return 1
  # Argo CD's self-heal would put the replica back within seconds (see experiment 5), so switch it off for the
  # duration, as an on-call engineer would, and always switch it back on.
  trap 'set_selfheal true; kubectl -n $NS scale statefulset shop-redis --replicas=1 >/dev/null' RETURN
  set_selfheal false
  say "redisdown: self-heal is off; scale Redis to 0 for 45 s"
  event fault
  kubectl -n $NS scale statefulset shop-redis --replicas=0 2>&1 | tail -1
  ( for i in $(seq 1 150); do
      printf '%s api_ready=%s/%s redis_ready=%s products_http=%s\n' "$(now)" "$(api_ready)" "$(api_wanted)" "$(redis_ready)" \
        "$(curl -s -m 2 -o /dev/null -w '%{http_code}' -H 'Host: shop.localtest.me' http://127.0.0.1:8080/api/products)"
      sleep 1; done > "$DIR/timeline.txt" ) &
  local tl=$!
  sleep 45
  event redis_restored
  kubectl -n $NS scale statefulset shop-redis --replicas=1 2>&1 | tail -1
  set_selfheal true
  wait_until 240 "system steady again" steady
  event recovered
  wait $tl 2>/dev/null
  finish redisdown
}

# ---------- 4. baddeploy (through Argo CD and the in-cluster Git server) ----------
argo() { kubectl -n argocd get application shop -o jsonpath="$1" 2>/dev/null; }
baddeploy() {
  [[ $(argo '{.spec.source.repoURL}') == git://git-server.gitops.svc* ]] || { echo "needs the GitOps install with the built-in Git server (make up-gitops)"; return 1; }
  begin baddeploy || return 1
  local work pf; work=$(mktemp -d)
  kubectl -n gitops port-forward svc/git-server 19418:9418 >/dev/null 2>&1 & pf=$!
  trap 'kill $pf 2>/dev/null; rm -rf "$work"' RETURN
  wait_until 20 "Git server reachable" git ls-remote git://localhost:19418/shop.git
  git clone -q git://localhost:19418/shop.git "$work/shop"
  local g=(git -C "$work/shop" -c user.name=chaos -c user.email=chaos@example.com)
  grep -q '^  tag: dev' "$work/shop/charts/shop/values.yaml" || { echo "unexpected values.yaml, re-seed with scripts/up.sh"; return 1; }
  ( for i in $(seq 1 400); do
      printf '%s argo=%s/%s api_ready=%s/%s pods=%s\n' "$(now)" "$(argo '{.status.sync.status}')" "$(argo '{.status.health.status}')" \
        "$(api_ready)" "$(api_wanted)" "$(kubectl -n $NS get pod -l $API_SEL -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{","}{end}' 2>/dev/null)"
      sleep 3; done > "$DIR/timeline.txt" ) &
  local tl=$!
  say "baddeploy: commit an image tag that does not exist"
  sed -i.bak 's/^  tag: dev/  tag: does-not-exist/' "$work/shop/charts/shop/values.yaml"
  "${g[@]}" commit -qam "Release a broken image tag (chaos experiment)"
  "${g[@]}" push -q origin HEAD:main
  event fault
  wait_until 240 "Argo CD noticed (app no longer Healthy)" bash -c "[[ \$(kubectl -n argocd get application shop -o jsonpath='{.status.health.status}') != Healthy ]]"
  event detected
  say "baddeploy: hold the broken release for 90 s with users still sending traffic"
  sleep 90
  say "baddeploy: roll back the GitOps way, git revert"
  "${g[@]}" revert --no-edit HEAD >/dev/null
  "${g[@]}" push -q origin HEAD:main
  event rollback_pushed
  wait_until 300 "Argo Healthy and Synced, all pods Ready" bash -c "[[ \$(kubectl -n argocd get application shop -o jsonpath='{.status.health.status}/{.status.sync.status}') == Healthy/Synced ]]" && wait_until 120 "system steady" steady
  event recovered
  kill $tl 2>/dev/null
  finish baddeploy
  echo "  timeline (first lines): $DIR/timeline.txt"
}

# ---------- 5. netpol ----------
netpol() {
  begin netpol || return 1
  kubectl delete ns intruder --ignore-not-found --wait=true >/dev/null
  kubectl create ns intruder >/dev/null
  # shellcheck disable=SC2016  # the single-quoted scripts run inside the pods, so $a and $(date) must not expand here
  # The probe in another namespace: can it reach the API or Redis? curl exit 7 or 28 means the connection was dropped.
  kubectl -n intruder run probe --restart=Never --image=curlimages/curl:8.11.1 --command -- sh -c \
    'while true; do a=$(curl -s -m 1 -o /dev/null -w "%{exitcode}" http://shop-api.shop.svc/health); r=$(curl -s -m 1 -o /dev/null -w "%{exitcode}" http://shop-redis.shop.svc:6379/); echo "$(date +%s) api_exit=$a redis_exit=$r"; sleep 1; done' >/dev/null
  kubectl -n intruder wait --for=condition=Ready pod/probe --timeout=90s >/dev/null
  # shellcheck disable=SC2016
  # The probe inside the Redis pod: can Redis open a connection OUT to Traefik? (the `redis` policy covers ingress only)
  ( kubectl -n $NS exec shop-redis-0 -- sh -c 'while true; do if nc -w 1 traefik.traefik.svc.cluster.local 80 </dev/null >/dev/null 2>&1; then echo "$(date +%s) redis_egress=open"; else echo "$(date +%s) redis_egress=blocked"; fi; sleep 1; done' > "$DIR/redis-egress.txt" 2>&1 ) &
  local ep=$!
  sleep 8
  say "netpol: delete the default-deny NetworkPolicy by hand"
  event fault
  kubectl -n $NS delete networkpolicy default-deny 2>&1 | tail -1
  wait_until 180 "Argo CD restored default-deny" kubectl -n $NS get networkpolicy default-deny
  event recovered
  sleep 10
  kill $ep 2>/dev/null
  kubectl -n intruder logs probe > "$DIR/intruder-probe.txt" 2>&1
  kubectl delete ns intruder --wait=false >/dev/null
  finish netpol
  say "netpol: what the probes saw"
  echo "  intruder -> API and Redis: $(awk '{print $2" "$3}' "$DIR/intruder-probe.txt" | sort | uniq -c | tr '\n' ';')"
  echo "  Redis -> Traefik (egress):  $(awk '{print $2}' "$DIR/redis-egress.txt" | sort | uniq -c | tr '\n' ';')"
  local first last
  first=$(awk '/redis_egress=open/{print $1; exit}' "$DIR/redis-egress.txt"); last=$(awk '/redis_egress=open/{t=$1} END{print t}' "$DIR/redis-egress.txt")
  [[ -n $first ]] && echo "  Redis egress was open for about $((last - first + 1)) s" || echo "  Redis egress never opened"
}

case "${1:-}" in
  podkill) podkill ;; drain) drain ;; redis) redis ;; redisdown) redisdown ;; baddeploy) baddeploy ;; netpol) netpol ;;
  all) for e in podkill drain redis redisdown baddeploy netpol; do $e || echo "experiment $e did not complete"; done ;;
  *) echo "usage: $0 podkill|drain|redis|redisdown|baddeploy|netpol|all" >&2; exit 2 ;;
esac
