#!/usr/bin/env bash
# Assertions against the running cluster. Used by `make test` and by CI.
set -uo pipefail
cd "$(dirname "$0")/.."

URL=http://shop.localtest.me:8080
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
http() {  # http <expected code> <curl args...>
  local want=$1; shift
  [[ $(curl -s -m 8 -o /dev/null -w '%{http_code}' "$@") == "$want" ]]
}
retry() { for _ in $(seq 1 20); do "$@" && return 0; sleep 3; done; return 1; }

echo "cluster"
check "3 nodes Ready"                         bash -c '[[ $(kubectl get nodes --no-headers | grep -c " Ready") -eq 3 ]]'
check "Calico running on every node"          bash -c '[[ $(kubectl -n kube-system get ds calico-node -o jsonpath={.status.numberReady}) == 3 ]]'
check "metrics-server serves node metrics"    retry kubectl top nodes
echo "workloads"
check "shop-api rollout complete"             kubectl -n shop rollout status deploy/shop-api --timeout=120s
check "redis statefulset ready"               kubectl -n shop rollout status sts/shop-redis --timeout=120s
check "at least 2 shop-api replicas"          bash -c '[[ $(kubectl -n shop get deploy shop-api -o jsonpath={.status.readyReplicas}) -ge 2 ]]'
check "topology spread across nodes is configured" bash -c '[[ $(kubectl -n shop get deploy shop-api -o jsonpath={.spec.template.spec.topologySpreadConstraints[0].topologyKey}) == kubernetes.io/hostname ]]'
check "PodDisruptionBudget exists"            kubectl -n shop get pdb shop-api
check "HPA reads CPU metrics"                 retry bash -c '[[ $(kubectl -n shop get hpa shop-api -o jsonpath={.status.currentMetrics[0].resource.current.averageUtilization}) != "" ]]'
check "no container runs as root"             bash -c '! kubectl -n shop get pod -o jsonpath="{range .items[*]}{.spec.securityContext.runAsNonRoot}{\"\n\"}{end}" | grep -qv true'
check "redis password is not in the pod spec" bash -c '! kubectl -n shop get pod -o yaml | grep -q "requirepass [A-Za-z0-9]\{12,\}"'
echo "traffic (through the ingress)"
check "GET /api/products -> 200"              retry http 200 -H 'Host: shop.localtest.me' "$URL/api/products"
check "POST /api/orders -> 201 (writes Redis)" bash -c "for i in 1 2 3 4 5 6; do c=\$(curl -s -m 8 -o /dev/null -w '%{http_code}' -XPOST -H 'content-type: application/json' -d '{\"product\":\"mouse\"}' $URL/api/orders); [[ \$c == 201 ]] && exit 0; done; exit 1"
check "unknown host -> 404 from the ingress"  http 404 -H 'Host: nope.example' "$URL/"
check "bad product -> 400"                    http 400 -XPOST -H 'content-type: application/json' -d '{"product":"nope"}' "$URL/api/orders"
echo "network policies"
check "4 NetworkPolicies applied"             bash -c '[[ $(kubectl -n shop get netpol --no-headers | wc -l) -eq 4 ]]'
check "intruder namespace is blocked"         bash -c 'scripts/demo.sh netpol 2>&1 | grep -q "shop-api  blocked" && scripts/demo.sh netpol 2>&1 | grep -q "redis     blocked"'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
