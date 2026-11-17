#!/usr/bin/env bash
# Unit-test the SLO recording and alerting rules with promtool. No cluster needed.
# Uses a local promtool if there is one, otherwise the one inside the Prometheus image.
set -euo pipefail
cd "$(dirname "$0")/.."

PROM_IMAGE=prom/prometheus:v3.5.0

if command -v promtool >/dev/null; then
  promtool check rules charts/shop/files/slo-rules.yaml
  promtool test rules tests/slo-rules.test.yaml
else
  docker run --rm -v "$PWD:/work" -w /work --entrypoint promtool "$PROM_IMAGE" check rules charts/shop/files/slo-rules.yaml
  docker run --rm -v "$PWD:/work" -w /work --entrypoint promtool "$PROM_IMAGE" test rules tests/slo-rules.test.yaml
fi
