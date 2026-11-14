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

case "${1:-}" in
  selfheal) selfheal ;; rollout) rollout ;; autoscale) autoscale ;; netpol) netpol ;; drain) drain ;;
  *) echo "usage: $0 selfheal|rollout|autoscale|netpol|drain" >&2; exit 2 ;;
esac
