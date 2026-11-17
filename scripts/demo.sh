#!/usr/bin/env bash
# Each demo makes a claim and then shows the evidence.
set -uo pipefail
cd "$(dirname "$0")/.."

NS=shop
URL=http://shop.localtest.me:8080
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
run() { printf '\033[2m$ %s\033[0m\n' "$*"; "$@"; }

selfheal() {
  say "Kill a pod: the Deployment recreates it and traffic keeps flowing"
  victim=$(kubectl -n $NS get pod -l app.kubernetes.io/name=shop-api -o name | head -1)
  run kubectl -n $NS delete "$victim" --wait=false
  for i in 1 2 3 4 5 6; do
    printf '  request %s -> HTTP %s\n' "$i" "$(curl -s -o /dev/null -w '%{http_code}' $URL/api/products)"
    sleep 1
  done
  run kubectl -n $NS rollout status deploy/shop-api --timeout=120s
  run kubectl -n $NS get pods -l app.kubernetes.io/name=shop-api
}

rollout() {
  say "Zero-downtime rolling update: hammer the site while every pod is replaced"
  codes=$(mktemp)
  ( while [[ ! -f $codes.stop ]]; do curl -s -o /dev/null -w '%{http_code}\n' $URL/api/products >> "$codes"; sleep 0.05; done ) &
  loop=$!
  run kubectl -n $NS rollout restart deploy/shop-api
  kubectl -n $NS rollout status deploy/shop-api --timeout=180s
  touch $codes.stop; wait $loop 2>/dev/null
  say "Status codes seen during the rollout"
  sort "$codes" | uniq -c
  rm -f "$codes" "$codes.stop"
}

autoscale() {
  say "Autoscaling: load goes up, the HPA adds replicas, load stops, it scales back"
  run kubectl apply -f platform/loadgen.yaml
  run kubectl -n loadtest scale deploy/loadgen --replicas=3
  for i in $(seq 1 16); do
    hpa() { kubectl -n $NS get hpa shop-api -o jsonpath="$1"; }
    printf '  t+%3ss  cpu %4s of %s%% target   replicas %s -> desired %s\n' $((i * 15)) \
      "$(hpa '{.status.currentMetrics[0].resource.current.averageUtilization}')%" \
      "$(hpa '{.spec.metrics[0].resource.target.averageUtilization}')" \
      "$(hpa '{.status.currentReplicas}')" "$(hpa '{.status.desiredReplicas}')"
    sleep 15
  done
  say "Stopping the load"
  run kubectl -n loadtest scale deploy/loadgen --replicas=0
  echo "  watch it scale down: kubectl -n $NS get hpa shop-api -w"
}

netpol() {
  say "NetworkPolicy: a pod in another namespace cannot reach the API or Redis"
  kubectl delete ns intruder --ignore-not-found --wait=true >/dev/null
  kubectl create ns intruder >/dev/null
  probe() {   # probe <url>: print "<http code> <curl exit code>"; exit 28 or 7 means the connection was dropped
    local name="probe-$RANDOM"
    kubectl -n intruder run "$name" --restart=Never --image=curlimages/curl:8.11.1 --command -- \
      sh -c "curl -s -m 4 -o /dev/null -w '%{http_code} %{exitcode}' '$1'; true" >/dev/null
    kubectl -n intruder wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=90s >/dev/null
    kubectl -n intruder logs "$name"
    kubectl -n intruder delete pod "$name" --wait=false >/dev/null
  }
  # Control: an unprotected service answers, so a "blocked" below is the policy, not a broken probe.
  read -r code _ <<< "$(probe http://traefik.traefik.svc/)"
  printf '  intruder -> traefik   (control, no policy)  HTTP %s\n' "${code:-none}"
  for target in "shop-api:http://shop-api.shop.svc/health" "redis:http://shop-redis.shop.svc:6379/"; do
    read -r code rc <<< "$(probe "${target#*:}")"
    if   [[ -z ${rc:-} ]]; then verdict="probe error (no result)"
    elif [[ $rc == 28 || $rc == 7 ]]; then verdict="blocked (connection dropped)"
    elif [[ $code != 000 ]]; then verdict="REACHABLE (HTTP $code)"
    else verdict="REACHABLE (TCP connected, not an HTTP service)"; fi
    printf '  intruder -> %-9s %s\n' "${target%%:*}" "$verdict"
  done
  say "Through the ingress it works, because that path is explicitly allowed"
  printf '  user -> traefik -> shop-api: HTTP %s\n' "$(curl -s -o /dev/null -w '%{http_code}' $URL/api/products)"
  kubectl delete ns intruder --wait=true >/dev/null
}

drain() {
  node=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | head -1)
  say "Drain a worker node: pods move, the PodDisruptionBudget keeps one replica up"
  run kubectl -n $NS get pods -l app.kubernetes.io/name=shop-api -o wide
  run kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=120s
  printf '  HTTP %s while drained\n' "$(curl -s -o /dev/null -w '%{http_code}' $URL/api/products)"
  run kubectl -n $NS get pods -l app.kubernetes.io/name=shop-api -o wide
  run kubectl uncordon "$node"
}

slo() {
  say "SLO alerting: break payments, watch the error budget burn and the page fire, then recover"
  prom=/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1
  q() { kubectl get --raw "$prom/query?query=$(jq -rn --arg q "$1" '$q|@uri')" | jq -r '.data.result[0].value[1] // "no data"'; }
  firing() {
    kubectl get --raw "$prom/query?query=ALERTS%7Balertname%3D~%22Shop.*%22%2Calertstate%3D%22firing%22%7D" \
      | jq -r '[.data.result[].metric.alertname] | join(", ") | if . == "" then "none" else . end'
  }
  say "Every payment fails (PAYMENT_FAILURE_RATE=1) and clients keep ordering"
  run helm upgrade shop charts/shop -n shop --reuse-values --set api.paymentFailureRate=1 --wait --timeout 3m
  ( while [[ ! -f /tmp/slo-demo.stop ]]; do
      curl -s -o /dev/null -XPOST -H 'content-type: application/json' -d '{"product":"mouse"}' $URL/api/orders
      curl -s -o /dev/null $URL/api/products; sleep 0.1; done ) &
  loop=$!
  for i in $(seq 1 14); do
    printf '  t+%3ss  errors(5m) %-8s  errors(1h) %-8s  firing: %s\n' $((i * 20)) \
      "$(q shop:http_errors:ratio_rate5m | cut -c1-6)" "$(q shop:http_errors:ratio_rate1h | cut -c1-6)" "$(firing)"
    sleep 20
  done
  touch /tmp/slo-demo.stop; wait $loop 2>/dev/null; rm -f /tmp/slo-demo.stop
  say "Restore payments"
  run helm upgrade shop charts/shop -n shop --reuse-values --set api.paymentFailureRate=0.03 --wait --timeout 3m
  echo "  alerts resolve once the 5m window clears; Grafana: http://grafana.localtest.me:8080"
}

policy() {
  say "Admission policies: the API server refuses manifests that weaken the hardening"
  for f in good-pod bad-latest-tag bad-root-pod bad-deployment; do
    printf '\n  %s\n' "$(sed -n '1s/^# //p' tests/policies/$f.yaml)"
    printf '\033[2m  $ kubectl apply --dry-run=server -f tests/policies/%s.yaml\033[0m\n' "$f"
    kubectl apply --dry-run=server -f "tests/policies/$f.yaml" 2>&1 | sed 's/^/    /; s/; Policy/;\n    Policy/g'  || true
  done
}

case "${1:-}" in
  selfheal) selfheal ;; rollout) rollout ;; autoscale) autoscale ;; netpol) netpol ;; drain) drain ;; slo) slo ;; policy) policy ;;
  *) echo "usage: $0 selfheal|rollout|autoscale|netpol|drain|slo|policy" >&2; exit 2 ;;
esac
