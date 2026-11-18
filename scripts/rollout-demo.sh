#!/usr/bin/env bash
# Progressive delivery demo: a good release is promoted by the analysis, a bad one is aborted by it, under steady load.
# Predictions: docs/progressive-delivery.md (written before the first run). Needs the GitOps install (make up-gitops).
#   scripts/rollout-demo.sh          results in docs/rollout-results/<today>/
#   ROLLOUT_DATE=2026-11-18 scripts/rollout-demo.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

NS=shop
DATE=${ROLLOUT_DATE:-$(date +%F)}
DIR=docs/rollout-results/$DATE
ROLLOUTS_CHART=2.43.12
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
for tool in kubectl helm jq git python3 curl; do command -v $tool >/dev/null || { echo "missing: $tool" >&2; exit 2; }; done
kubectl -n argocd get application shop >/dev/null 2>&1 || { echo "needs the GitOps install: make up-gitops" >&2; exit 1; }
mkdir -p "$DIR"; : > "$DIR/events.txt"; rm -f "$DIR/STOP"
WORK=$(mktemp -d)

ro() { kubectl -n $NS get rollout shop-api -o jsonpath="$1" 2>/dev/null; }
wait_for() {
  local limit=$1 what=$2; shift 2
  for i in $(seq 1 "$limit"); do "$@" >/dev/null 2>&1 && { printf '  %s after ~%ss\n' "$what" "$i"; return 0; }; sleep 1; done
  printf '  TIMED OUT after %ss: %s\n' "$limit" "$what"; return 1
}
rollout_healthy() { [[ $(ro '{.status.phase}') == Healthy && $(ro '{.status.currentPodHash}') == "$(ro '{.status.stableRS}')" && $(ro '{.status.availableReplicas}') -ge 2 ]]; }
set_rollouts() { kubectl -n argocd patch application shop --type merge -p "{\"spec\":{\"source\":{\"helm\":{\"valuesObject\":{\"rollout\":{\"enabled\":$1}}}}}}" >/dev/null; }
event() { echo "$1 $(now)" >> "$DIR/events.txt"; }

PF=""
cleanup() {
  touch "$DIR/STOP"; [[ -n $PF ]] && kill $PF 2>/dev/null
  say "putting the cluster back to the normal Deployment"
  set_rollouts false
  rm -rf "$WORK"
}
trap cleanup EXIT

say "installing Argo Rollouts $ROLLOUTS_CHART"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argo-rollouts argo/argo-rollouts --version "$ROLLOUTS_CHART" -n argo-rollouts --create-namespace \
  --set dashboard.enabled=false --set controller.resources.requests.cpu=25m --set controller.resources.requests.memory=64Mi \
  --set controller.resources.limits.memory=192Mi --wait --timeout 5m >/dev/null || { echo "Argo Rollouts install failed" >&2; exit 1; }

say "seeding the in-cluster Git with this checkout (so Argo sees the Rollout chart) and switching the app to canary mode"
git bundle create - HEAD 2>/dev/null | kubectl -n gitops exec -i deploy/git-server -- sh -c \
  'cat > /repos/seed.bundle && git -C /repos/shop.git fetch -q --force /repos/seed.bundle HEAD:refs/heads/main'
set_rollouts true
wait_for 300 "Rollout exists and is Healthy" rollout_healthy || exit 1
wait_for 120 "Argo CD Synced and Healthy" bash -c "[[ \$(kubectl -n argocd get application shop -o jsonpath='{.status.sync.status}/{.status.health.status}') == Synced/Healthy ]]" || exit 1
echo "  Deployment still there? $(kubectl -n $NS get deploy shop-api 2>&1 | head -1 | cut -c1-60)"

kubectl -n gitops port-forward svc/git-server 19418:9418 >/dev/null 2>&1 & PF=$!
wait_for 20 "Git server reachable" git ls-remote git://localhost:19418/shop.git || exit 1
git clone -q git://localhost:19418/shop.git "$WORK/shop"
G=(git -C "$WORK/shop" -c user.name=demo -c user.email=demo@example.com)
set_rate() { sed -i.bak "s/^  paymentFailureRate: .*/  paymentFailureRate: \"$1\"/" "$WORK/shop/charts/shop/values.yaml"; }
grep -q '^  paymentFailureRate: "0.03"' "$WORK/shop/charts/shop/values.yaml" || { echo "unexpected values.yaml" >&2; exit 1; }

python3 scripts/chaos-load.py run --out "$DIR/requests.csv" --stop-file "$DIR/STOP" --rate 20 &
CLIENT=$!
say "20 s of baseline traffic"
sleep 20

watch_rollout() {   # watch_rollout <label> <seconds> <stop-condition...>: log the rollout's state every 5 s until the condition holds
  local label=$1 limit=$2; shift 2
  : > "$DIR/timeline-$label.txt"
  for i in $(seq 1 $((limit / 5))); do
    printf '%s phase=%s abort=%s step=%s canary_hash=%s stable=%s msg=%s\n' "$(now)" "$(ro '{.status.phase}')" "$(ro '{.status.abort}')" \
      "$(ro '{.status.currentStepIndex}')" "$(ro '{.status.currentPodHash}')" "$(ro '{.status.stableRS}')" "$(ro '{.status.message}' | cut -c1-70)" >> "$DIR/timeline-$label.txt"
    "$@" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
analysis_summary() {   # the measurements the analysis took, for the record
  kubectl -n $NS get analysisrun -o json | jq -r '.items[] | [.metadata.name, .status.phase, ([.status.metricResults[]?.measurements[]? | .value] | join(","))] | @tsv' | tail -4
}
aborted() { [[ $(ro '{.status.abort}') == true ]]; }
# Right after a push the Rollout still reports the OLD revision as Healthy until Argo CD has synced the new template, so wait until the
# new revision has registered before judging anything (an early version of this script did not, and "promoted in 0.4 s" was nonsense).
new_revision() { local before=$1; for _ in $(seq 1 120); do [[ $(ro '{.status.currentPodHash}') != "$before" ]] && return 0; sleep 1; done; return 1; }

say "release A (good): the simulated payment failure rate 3% -> 2%, pushed through Git"
BEFORE=$(ro '{.status.currentPodHash}')
set_rate 0.02; "${G[@]}" commit -qam "Release A: payment failure rate 2%"; "${G[@]}" push -q origin HEAD:main
event A_push
new_revision "$BEFORE" || echo "  WARNING: the new revision never registered"
if watch_rollout A 420 rollout_healthy; then A_OK=1; else A_OK=0; fi
event A_done
echo "  release A: promoted=$A_OK; analysis runs:"; analysis_summary | tee "$DIR/analysis-A.txt" | sed 's/^/    /'
sleep 10

say "release B (bad): payment failure rate 100%, pushed through Git; nobody runs a command from here on"
BEFORE=$(ro '{.status.currentPodHash}')
set_rate 1; "${G[@]}" commit -qam "Release B: payment failure rate 100% (bad)"; "${G[@]}" push -q origin HEAD:main
event B_push
new_revision "$BEFORE" || echo "  WARNING: the new revision never registered"
if watch_rollout B 300 aborted; then B_ABORTED=1; else B_ABORTED=0; fi
event B_aborted
echo "  release B: aborted by the analysis=$B_ABORTED; analysis runs:"; analysis_summary | tee "$DIR/analysis-B.txt" | sed 's/^/    /'
echo "  pods now: $(kubectl -n $NS get pods -l app.kubernetes.io/name=shop-api -o jsonpath='{range .items[*]}{.metadata.labels.rollouts-pod-template-hash}{" "}{end}')  (stable revision: $(ro '{.status.stableRS}'))"
sleep 20

say "putting the stable version back through Git (revert the bad release)"
"${G[@]}" revert --no-edit HEAD >/dev/null; "${G[@]}" push -q origin HEAD:main
wait_for 240 "Rollout Healthy again" rollout_healthy
event restored
sleep 10
touch "$DIR/STOP"; wait $CLIENT 2>/dev/null

say "what users saw"
python3 - "$DIR" <<'PY'
import csv, json, sys
d = sys.argv[1]
ev = {l.split()[0]: float(l.split()[1]) for l in open(f"{d}/events.txt") if len(l.split()) == 2}
rows = [(float(r["epoch"]), r["route"], r["kind"]) for r in csv.DictReader(open(f"{d}/requests.csv"))]
out = {}
for name, a, b in (("release_A_good", "A_push", "A_done"), ("release_B_bad", "B_push", "B_aborted")):
    w = [r for r in rows if ev[a] <= r[0] <= ev[b]]
    orders = [r for r in w if r[1] == "orders"]
    out[name] = {"seconds": round(ev[b] - ev[a], 1), "requests": len(w), "orders": len(orders),
                 "orders_payment_502": sum(1 for r in orders if r[2] == "payment"),
                 "orders_fault": sum(1 for r in orders if r[2] == "fault"),
                 "products_fault": sum(1 for r in w if r[1] == "products" and r[2] == "fault")}
    o = out[name]; o["order_failure_share_pct"] = round(100 * (o["orders_payment_502"] + o["orders_fault"]) / max(1, o["orders"]), 1)
json.dump(out, open(f"{d}/summary.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY
[[ $A_OK == 1 && $B_ABORTED == 1 ]]
