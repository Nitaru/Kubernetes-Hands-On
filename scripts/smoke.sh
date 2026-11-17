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
retry_long() { for _ in $(seq 1 40); do "$@" && return 0; sleep 3; done; return 1; }
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
echo "monitoring"
PROM=/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1
# promq <query>: instant query through the API server proxy; fails unless Prometheus says "success"
promq() { kubectl get --raw "$PROM/query?query=$(jq -rn --arg q "$1" '$q|@uri')" | jq -e 'select(.status == "success")'; }
prom_ready()     { kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus --timeout=120s \
                   && kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=alertmanager --timeout=120s; }
targets_up()     { promq 'count(up{namespace="shop", service="shop-api"} == 1)' | jq -e '.data.result[0].value[1] | tonumber >= 2'; }
rules_loaded()   { kubectl get --raw "$PROM/rules" | jq -e '[.data.groups[].rules[].name] | index("ShopAvailabilityFastBurn")'; }
sli_has_data()   { promq 'shop:http_requests:rate5m' | jq -e '.data.result | length == 1'; }
nothing_firing() { promq 'ALERTS{alertname=~"Shop.*", alertstate="firing"}' | jq -e '.data.result | length == 0'; }
dashboard_up()   { local pw; pw=$(kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
                   curl -s -m 8 -u "admin:$pw" 'http://grafana.localtest.me:8080/api/search?query=Shop' | jq -e 'type == "array" and any(.[]; .uid == "shop-api-slo")'; }
check "Prometheus and Alertmanager are Ready"   prom_ready
check "Prometheus scrapes every shop-api pod (network policy allows it)" retry_long targets_up
check "SLO rules are loaded"                    rules_loaded
check "SLI recording rule returns data"         retry_long sli_has_data
check "no SLO alert is firing under normal traffic" nothing_firing
check "Grafana serves the shop dashboard"       retry_long dashboard_up

echo "admission policies (Kyverno)"
# denied <manifest>: the API server must refuse it, and the refusal must come from an admission policy
denied() { local out; out=$(kubectl apply --dry-run=server -f "$1" 2>&1) && return 1; grep -q "denied the request" <<<"$out"; }
check "Kyverno admission controller is Ready" kubectl -n kyverno wait --for=condition=Ready pod -l app.kubernetes.io/component=admission-controller --timeout=120s
check "3 policies are Ready"                  bash -c '[[ $(kubectl get validatingpolicy -o jsonpath="{.items[*].status.conditionStatus.ready}") == "true true true" ]]'
check "a hardened pod is admitted"            kubectl apply --dry-run=server -f tests/policies/good-pod.yaml
check "a root, unhardened pod is rejected"    denied tests/policies/bad-root-pod.yaml
check "a :latest image is rejected"           denied tests/policies/bad-latest-tag.yaml
check "an unhardened Deployment is rejected at apply time" denied tests/policies/bad-deployment.yaml

if kubectl -n argocd get application shop >/dev/null 2>&1; then
  echo "gitops (Argo CD)"
  app() { kubectl -n argocd get application shop -o jsonpath="$1"; }
  restored() { kubectl -n shop delete pdb shop-api >/dev/null && retry_long kubectl -n shop get pdb shop-api; }
  check "Argo CD server, repo-server and controller are Ready" bash -c 'kubectl -n argocd wait --for=condition=Ready pod -l "app.kubernetes.io/name in (argocd-server,argocd-repo-server,argocd-application-controller)" --timeout=120s'
  check "shop is Synced with Git"               retry_long bash -c '[[ $(kubectl -n argocd get application shop -o jsonpath={.status.sync.status}) == Synced ]]'
  check "shop is Healthy"                       retry_long bash -c '[[ $(kubectl -n argocd get application shop -o jsonpath={.status.health.status}) == Healthy ]]'
  check "automated sync with prune and self-heal is on" bash -c '[[ $(kubectl -n argocd get application shop -o jsonpath="{.spec.syncPolicy.automated.prune}{.spec.syncPolicy.automated.selfHeal}") == truetrue ]]'
  check "a PodDisruptionBudget deleted by hand is restored by Argo" restored
  check "Argo CD UI answers through the ingress" http 200 "http://argocd.localtest.me:8080/"
else
  echo "gitops (Argo CD): skipped, the app was installed directly with Helm (make up-gitops to use Argo CD)"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
