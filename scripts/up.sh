#!/usr/bin/env bash
# Build the whole platform from nothing: cluster, CNI, ingress, metrics, app.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=hands-on
CALICO=v3.31.0
TRAEFIK_CHART=42.4.0
METRICS_CHART=3.14.0
PROM_CHART=93.3.1
KYVERNO_CHART=3.10.0
IMAGE=shop-api:dev

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
helm repo update traefik metrics-server prometheus-community kyverno >/dev/null

say "Installing Traefik (ingress)"
helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_CHART" \
  -n traefik --create-namespace -f platform/traefik-values.yaml --wait --timeout 5m

say "Installing metrics-server (kubectl top, HPA)"
helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_CHART" \
  -n kube-system -f platform/metrics-server-values.yaml --wait --timeout 5m

say "Installing kube-prometheus-stack (Prometheus, Alertmanager, Grafana; must come before the app, which ships a ServiceMonitor)"
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version "$PROM_CHART" \
  -n monitoring --create-namespace -f platform/kube-prometheus-stack-values.yaml --wait --timeout 8m

say "Installing Kyverno and the shop admission policies (before the app, so the chart itself is validated)"
helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART" \
  -n kyverno --create-namespace -f platform/kyverno-values.yaml --wait --timeout 5m
kubectl apply -f platform/policies/
kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true validatingpolicy --all --timeout=120s

say "Building the app image and loading it into the cluster"
docker build -q -t "$IMAGE" app
kind load docker-image "$IMAGE" --name "$CLUSTER"

say "Deploying the shop chart"
helm upgrade --install shop charts/shop -n shop --create-namespace --reset-values --wait --timeout 5m

say "Done"
echo "  shop:   curl -s http://shop.localtest.me:8080/api/products"
echo "  grafana: http://grafana.localtest.me:8080   (user admin, password: make grafana-password)"
echo "  nodes:  kubectl get nodes -o wide"
