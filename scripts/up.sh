#!/usr/bin/env bash
# Build the whole platform from nothing: cluster, CNI, ingress, metrics, monitoring, policies, app.
#
#   scripts/up.sh                      the app is installed directly with Helm
#   GITOPS=1 scripts/up.sh             Argo CD installs the app from a Git repository instead
#   GITOPS=1 GITOPS_REPO=<url> ...     ...using this repository (default: a small Git server inside the cluster,
#                                      seeded with the commits of this checkout, so nothing leaves your machine)
#   GITOPS_REVISION=<branch|tag|sha>   what Argo follows in that repository (default: main)
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=hands-on
CALICO=v3.31.0
TRAEFIK_CHART=42.4.0
METRICS_CHART=3.14.0
PROM_CHART=93.3.1
KYVERNO_CHART=3.10.0
ARGOCD_CHART=10.18.0
ESO_CHART=2.15.0
IMAGE=shop-api:dev
GITOPS=${GITOPS:-0}
GITOPS_REPO=${GITOPS_REPO:-}                  # empty = use the in-cluster Git server
GITOPS_REVISION=${GITOPS_REVISION:-main}
LOCAL_GIT=git://git-server.gitops.svc.cluster.local/shop.git

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  say "Cluster $CLUSTER already exists, reusing it"
else
  say "Creating the kind cluster (1 control plane + 2 workers)"
  kind create cluster --config kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

say "Installing Calico $CALICO (CNI with NetworkPolicy enforcement)"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/calico.yaml" >/dev/null
kubectl -n kube-system rollout status daemonset/calico-node --timeout=240s
kubectl wait --for=condition=Ready nodes --all --timeout=240s

say "Adding the Helm chart repositories"
helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
helm repo update traefik metrics-server prometheus-community kyverno argo external-secrets >/dev/null

say "Installing Traefik (ingress)"
helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_CHART" \
  -n traefik --create-namespace -f platform/traefik-values.yaml --wait --timeout 5m

say "Installing metrics-server (kubectl top, HPA)"
helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_CHART" \
  -n kube-system -f platform/metrics-server-values.yaml --wait --timeout 5m

say "Installing kube-prometheus-stack (Prometheus, Alertmanager, Grafana; must come before the app, which ships a ServiceMonitor)"
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version "$PROM_CHART" \
  -n monitoring --create-namespace -f platform/kube-prometheus-stack-values.yaml --wait --timeout 8m
kubectl apply -f platform/traefik-servicemonitor.yaml   # needs the CRD from kube-prometheus-stack, so not with Traefik

say "Installing Kyverno and the shop admission policies (before the app, so the chart itself is validated)"
helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART" \
  -n kyverno --create-namespace -f platform/kyverno-values.yaml --wait --timeout 5m
# The pod is Ready before Kyverno has registered its webhooks and issued their certificates, so the
# first apply can fail with "failed calling webhook". Retry until the webhook answers.
for attempt in $(seq 1 30); do
  kubectl apply -f platform/policies/ 2>/dev/null && break
  [[ $attempt == 30 ]] && { kubectl apply -f platform/policies/; exit 1; }
  sleep 5
done
kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true validatingpolicy --all --timeout=120s

say "Building the app image and loading it into the cluster"
docker build -q -t "$IMAGE" app
kind load docker-image "$IMAGE" --name "$CLUSTER"

if [[ $GITOPS == 1 ]]; then
  if helm status shop -n shop >/dev/null 2>&1; then
    echo "A direct Helm release named shop already exists, and Argo CD would fight it for ownership." >&2
    echo "Run 'make down' first (or 'helm uninstall shop -n shop')." >&2
    exit 1
  fi

  say "Installing the External Secrets Operator (it generates the Redis password, so the chart ships none)"
  helm upgrade --install external-secrets external-secrets/external-secrets --version "$ESO_CHART" \
    -n external-secrets --create-namespace -f platform/external-secrets-values.yaml --wait --timeout 6m
  kubectl wait --for=condition=Established crd/externalsecrets.external-secrets.io crd/passwords.generators.external-secrets.io --timeout=120s
  say "Installing Argo CD"
  helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART" \
    -n argocd --create-namespace -f platform/argocd-values.yaml --wait --timeout 8m

  if [[ -z $GITOPS_REPO ]]; then
    say "Starting the in-cluster Git server and seeding it with this checkout's commits"
    [[ -z $(git status --porcelain) ]] || echo "  note: uncommitted changes are not deployed, GitOps only sees commits"
    docker build -q -t git-server:dev platform/gitops
    kind load docker-image git-server:dev --name "$CLUSTER"
    kubectl apply -f platform/gitops/git-server.yaml
    kubectl -n gitops rollout status deploy/git-server --timeout=120s
    git bundle create - HEAD 2>/dev/null | kubectl -n gitops exec -i deploy/git-server -- sh -c \
      'cat > /repos/seed.bundle && git -C /repos/shop.git fetch -q --force /repos/seed.bundle HEAD:refs/heads/main'
    repo=$LOCAL_GIT
  else
    repo=$GITOPS_REPO
  fi

  say "Telling Argo CD to deploy charts/shop from $repo ($GITOPS_REVISION)"
  sed "s|__REPO_URL__|$repo|; s|__REVISION__|$GITOPS_REVISION|" platform/gitops/application.yaml | kubectl apply -f -
  kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/shop --timeout=300s
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/shop --timeout=300s
else
  say "Deploying the shop chart"
  helm upgrade --install shop charts/shop -n shop --create-namespace --reset-values --wait --timeout 5m
fi

say "Done"
echo "  shop:   curl -s http://shop.localtest.me:8080/api/products"
echo "  grafana: http://grafana.localtest.me:8080   (user admin, password: make grafana-password)"
if [[ $GITOPS == 1 ]]; then
  echo "  argocd:  http://argocd.localtest.me:8080    (user admin, password: make argocd-password)"
fi
echo "  nodes:  kubectl get nodes -o wide"
