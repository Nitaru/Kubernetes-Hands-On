#!/usr/bin/env bash
# Build the whole platform from nothing: cluster, CNI, ingress, metrics, app.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=hands-on
CALICO=v3.31.0
TRAEFIK_CHART=42.4.0
METRICS_CHART=3.14.0
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
helm repo update traefik metrics-server >/dev/null

say "Installing Traefik (ingress)"
helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_CHART" \
  -n traefik --create-namespace -f platform/traefik-values.yaml --wait --timeout 5m

say "Installing metrics-server (kubectl top, HPA)"
helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_CHART" \
  -n kube-system -f platform/metrics-server-values.yaml --wait --timeout 5m

say "Building the app image and loading it into the cluster"
docker build -q -t "$IMAGE" app
kind load docker-image "$IMAGE" --name "$CLUSTER"

say "Deploying the shop chart"
helm upgrade --install shop charts/shop -n shop --create-namespace --reset-values --wait --timeout 5m

say "Done"
echo "  shop:   curl -s http://shop.localtest.me:8080/api/products"
echo "  nodes:  kubectl get nodes -o wide"
