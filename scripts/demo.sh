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

gitops() {
  app() { kubectl -n argocd get application shop -o jsonpath="$1"; }
  hpa_max() { kubectl -n shop get hpa shop-api -o jsonpath='{.spec.maxReplicas}'; }
  redis_pw() { kubectl -n shop get secret shop-redis -o jsonpath='{.data.password}' | shasum | cut -c1-12; }
  wait_for() {   # wait_for <description> <seconds> <shell condition>, re-evaluated every second
    local what=$1 limit=$2 cond=$3
    for i in $(seq 1 "$limit"); do eval "$cond" >/dev/null 2>&1 && { printf '  %s after ~%ss\n' "$what" "$i"; return 0; }; sleep 1; done
    printf '  TIMED OUT waiting for: %s\n' "$what"; return 1
  }
  say "Argo CD keeps the cluster equal to Git"
  printf '  app shop: %s / %s, revision %.8s, source %s\n' "$(app '{.status.sync.status}')" "$(app '{.status.health.status}')" \
    "$(app '{.status.sync.revision}')" "$(app '{.spec.source.repoURL}')"

  say "1. Drift: delete the default-deny NetworkPolicy by hand (a security control disappears)"
  run kubectl -n shop delete networkpolicy default-deny
  wait_for "Argo restored default-deny" 60 "kubectl -n shop get networkpolicy default-deny"

  say "2. Drift: scale the HPA's ceiling by hand, then watch Argo put it back"
  run kubectl -n shop patch hpa shop-api --type merge -p '{"spec":{"maxReplicas":3}}'
  wait_for "Argo restored maxReplicas to 8" 60 '[[ $(hpa_max) == 8 ]]'

  if [[ $(app '{.spec.source.repoURL}') != git://git-server.gitops.svc* ]]; then
    echo "  (the change-through-Git step needs the built-in Git server, so it is skipped for $(app '{.spec.source.repoURL}'))"
    return
  fi
  say "3. The real workflow: change Git, not the cluster (maxReplicas 8 -> 6)"
  local work; work=$(mktemp -d)
  kubectl -n gitops port-forward svc/git-server 19418:9418 >/dev/null 2>&1 &
  local pf=$!
  trap 'kill $pf 2>/dev/null; rm -rf "$work"' RETURN
  wait_for "Git server reachable" 20 "git ls-remote git://localhost:19418/shop.git"
  git clone -q git://localhost:19418/shop.git "$work/shop"
  local gitc=(git -C "$work/shop" -c user.name=demo -c user.email=demo@example.com)
  grep -q '^  maxReplicas: 8' "$work/shop/charts/shop/values.yaml" || { echo "  Git does not have maxReplicas: 8 (a previous run was interrupted); re-seed with scripts/up.sh"; return 1; }
  pw_before=$(redis_pw)
  sed -i.bak 's/^  maxReplicas: 8/  maxReplicas: 6/' "$work/shop/charts/shop/values.yaml"
  "${gitc[@]}" commit -qam "Lower the autoscaling ceiling to 6"
  run "${gitc[@]}" push -q origin HEAD:main
  wait_for "HPA maxReplicas is now 6 (Argo polled Git and synced)" 120 '[[ $(hpa_max) == 6 ]]'
  printf '  Argo: %s / %s, revision %.8s\n' "$(app '{.status.sync.status}')" "$(app '{.status.health.status}')" "$(app '{.status.sync.revision}')"

  say "4. Roll it back the GitOps way: revert the commit"
  "${gitc[@]}" revert --no-edit HEAD >/dev/null
  run "${gitc[@]}" push -q origin HEAD:main
  wait_for "HPA maxReplicas is back to 8" 120 '[[ $(hpa_max) == 8 ]]'
  printf '  Redis password unchanged across both syncs: %s\n' "$([[ $(redis_pw) == "$pw_before" ]] && echo yes || echo "NO (before $pw_before, after $(redis_pw))")"
  printf '  Argo: %s / %s\n' "$(app '{.status.sync.status}')" "$(app '{.status.health.status}')"
  kill $pf 2>/dev/null; wait $pf 2>/dev/null || true   # wait reports 143 for the process we just killed
}

case "${1:-}" in
  selfheal) selfheal ;; rollout) rollout ;; autoscale) autoscale ;; netpol) netpol ;; drain) drain ;; slo) slo ;; policy) policy ;; gitops) gitops ;;
  *) echo "usage: $0 selfheal|rollout|autoscale|netpol|drain|slo|policy|gitops" >&2; exit 2 ;;
esac
