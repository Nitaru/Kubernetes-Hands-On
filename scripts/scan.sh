#!/usr/bin/env bash
# Security scans, the same ones CI runs: image CVEs, Dockerfile and chart misconfigurations, secrets.
# Uses a local trivy if there is one, otherwise the Trivy image (needs Docker).
# usage: scripts/scan.sh [image|config|secrets|all]   (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

TRIVY_IMAGE=aquasec/trivy:0.76.2
IMAGE=${IMAGE:-shop-api:dev}

run_trivy() {
  if command -v trivy >/dev/null; then trivy "$@"
  else docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD:/work" -w /work \
         -v trivy-cache:/root/.cache "$TRIVY_IMAGE" "$@"; fi
}
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

image() {
  say "CVEs in $IMAGE (HIGH and CRITICAL that have a fix; fails the build if any)"
  run_trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "$IMAGE"
}
config() {
  say "Misconfigurations in the Dockerfile and the rendered Helm chart"
  run_trivy config --severity HIGH,CRITICAL --exit-code 1 --skip-dirs node_modules app
  run_trivy config --severity HIGH,CRITICAL --exit-code 1 charts/shop
}
secrets() {
  say "Secrets committed to the repository"
  run_trivy fs --scanners secret --exit-code 1 --skip-dirs .git --skip-dirs node_modules .
}
sbom() {
  say "Software bill of materials for $IMAGE -> sbom.cdx.json (CycloneDX)"
  run_trivy image --format cyclonedx --output sbom.cdx.json "$IMAGE"
}

case "${1:-all}" in
  image) image ;; config) config ;; secrets) secrets ;; sbom) sbom ;;
  all) config; secrets; image ;;
  *) echo "usage: $0 image|config|secrets|sbom|all" >&2; exit 2 ;;
esac
