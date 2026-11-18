#!/usr/bin/env bash
# Load test for the autoscaling claims. Predictions: docs/loadtest.md (written before the first run).
#   scripts/loadtest.sh                       results in docs/loadtest-results/<today>/
#   LOADTEST_DATE=2026-11-18 scripts/loadtest.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

NS=shop
DATE=${LOADTEST_DATE:-$(date +%F)}
DIR=docs/loadtest-results/$DATE
LOADGEN_REPLICAS=3
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
hpa() { kubectl -n $NS get hpa shop-api -o jsonpath="$1" 2>/dev/null; }
ready_pods() {
  kubectl -n $NS get pods -l app.kubernetes.io/name=shop-api -o json 2>/dev/null \
    | jq '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' 2>/dev/null || echo 0
}
for tool in kubectl jq python3; do command -v $tool >/dev/null || { echo "missing: $tool" >&2; exit 2; }; done

mkdir -p "$DIR"; : > "$DIR/events.txt"; rm -f "$DIR/STOP"
MIN=$(hpa '{.spec.minReplicas}'); MAX=$(hpa '{.spec.maxReplicas}')
[[ -n $MIN && -n $MAX ]] || { echo "no HPA named shop-api in namespace $NS; is the cluster up?" >&2; exit 1; }

say "waiting for the HPA to sit at its minimum ($MIN) with every pod Ready"
for _ in $(seq 1 300); do [[ $(hpa '{.status.currentReplicas}') == "$MIN" && $(ready_pods) == "$MIN" ]] && break; sleep 2; done
[[ $(hpa '{.status.currentReplicas}') == "$MIN" ]] || { echo "HPA did not settle at $MIN" >&2; exit 1; }

kubectl apply -f platform/loadgen.yaml >/dev/null
python3 scripts/chaos-load.py run --out "$DIR/requests.csv" --stop-file "$DIR/STOP" --rate 20 &
CLIENT=$!
echo "epoch,hpa_current,hpa_desired,cpu_percent,ready_pods,phase" > "$DIR/timeline.csv"
sampler() {
  while [[ ! -f "$DIR/STOP" ]]; do
    printf '%s,%s,%s,%s,%s,%s\n' "$(now)" "$(hpa '{.status.currentReplicas}')" "$(hpa '{.status.desiredReplicas}')" \
      "$(hpa '{.status.currentMetrics[0].resource.current.averageUtilization}')" "$(ready_pods)" "$(cat "$DIR/phase" 2>/dev/null)" >> "$DIR/timeline.csv"
    sleep 5
  done
}
echo baseline > "$DIR/phase"; sampler & SAMPLER=$!

say "30 s of baseline user traffic"
sleep 30
say "load on: $LOADGEN_REPLICAS load generators"
echo load > "$DIR/phase"; echo "fault $(now)" >> "$DIR/events.txt"
kubectl -n loadtest scale deploy/loadgen --replicas=$LOADGEN_REPLICAS >/dev/null

for _ in $(seq 1 120); do [[ $(hpa '{.status.currentReplicas}') == "$MAX" && $(ready_pods) == "$MAX" ]] && break; sleep 2; done
echo "max_reached $(now)" >> "$DIR/events.txt"
say "at $(hpa '{.status.currentReplicas}') replicas; holding the load for another 60 s"
sleep 60
say "load off"
echo scaledown > "$DIR/phase"; echo "recovered $(now)" >> "$DIR/events.txt"
kubectl -n loadtest scale deploy/loadgen --replicas=0 >/dev/null

for _ in $(seq 1 400); do [[ $(hpa '{.status.currentReplicas}') == "$MIN" && $(ready_pods) == "$MIN" ]] && break; sleep 3; done
echo "back_to_min $(now)" >> "$DIR/events.txt"
say "back at $(hpa '{.status.currentReplicas}') replicas; 20 s more of user traffic, then the report"
sleep 20
touch "$DIR/STOP"; wait $CLIENT $SAMPLER 2>/dev/null

python3 - "$DIR" "$MIN" "$MAX" <<'PY'
import csv, json, sys
d, mn, mx = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ev = {l.split()[0]: float(l.split()[1]) for l in open(f"{d}/events.txt") if len(l.split()) == 2}
rows = [r for r in csv.DictReader(open(f"{d}/timeline.csv")) if r["hpa_current"] and r["hpa_desired"]]
t0 = ev["fault"]
def first(cond):
    for r in rows:
        if float(r["epoch"]) >= t0 and cond(r):
            return round(float(r["epoch"]) - t0, 1)
out = {
    "first_scale_up_s_after_load": first(lambda r: int(r["hpa_desired"]) > mn),
    "first_new_replica_s_after_load": first(lambda r: int(r["hpa_current"]) > mn),
    "max_replicas_s_after_load": first(lambda r: int(r["hpa_current"]) >= mx),
    "all_max_pods_ready_s_after_load": round(ev["max_reached"] - t0, 1),
    "scale_down_to_min_s_after_load_off": round(ev["back_to_min"] - ev["recovered"], 1),
    "peak_cpu_percent": max((int(r["cpu_percent"]) for r in rows if r["cpu_percent"].isdigit()), default=None),
}
json.dump(out, open(f"{d}/summary.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY
python3 scripts/chaos-load.py report --requests "$DIR/requests.csv" --events "$DIR/events.txt" --json "$DIR/client-summary.json"
rm -f "$DIR/phase"
