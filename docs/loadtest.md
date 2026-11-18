# Load test: numbers behind the autoscaling claims

The README says the HPA has "tuned scale-up/scale-down behaviour". This measures it. Run with `make loadtest` (needs the cluster:
`make up` or `make up-gitops`). Raw samples land in `docs/loadtest-results/<date>/`. Predictions below were written before the first run.

## What is measured

A steady "user" load of about 20 requests a second goes through Traefik the whole time (`scripts/chaos-load.py`), so errors and
latency are what a client sees. On top of it, the in-cluster load generator (`platform/loadgen.yaml`, 3 replicas, each looping 8
parallel calls to `/api/compute?ms=80`, a CPU-bound endpoint) is switched on, held until the HPA has reached its maximum plus
60 s, then switched off. Every 5 s the script records the HPA's current and desired replicas, its CPU reading and the number of
Ready pods.

The chart's settings (`charts/shop/values.yaml`, `templates/hpa.yaml`): 2 to 8 replicas, target 60% CPU, scale-up at most 2 pods
per 15 s with no stabilization, scale-down at most 1 pod per 30 s after a 60 s stabilization window.

## Predictions

1. **First scale-up** (desired replicas above 2) within **60 s** of the load starting. The CPU reading needs a metrics scrape and
   an HPA sync (about 15 s each), so I expect 30 to 60 s.
2. **Reaching the maximum of 8** takes three steps of +2 pods, 15 s apart at the fastest, so **about 90 to 150 s** after the load starts.
3. **Zero fault errors** for the user traffic during scale-up. New pods only receive traffic once Ready, so adding capacity should
   not hurt requests. Latency (p95) will rise while the existing pods are saturated, before the new pods arrive.
4. **Scale-down** back to 2 after the load stops: 60 s stabilization, then 6 pods at 1 per 30 s, so **about 4 to 6 minutes**.

What would make me wrong: the CPU reading lagging by more than a minute, new pods taking longer than 30 s to become Ready,
or the load generator itself being too weak to push CPU above 60%.

Not claimed: behaviour on a real cluster (kind on one laptop), other request mixes, or repeatability (one run).

## Results (2026-11-18, one run)

Raw samples: `docs/loadtest-results/2026-11-18/` (`timeline.csv`, `requests.csv`, `summary.json`, `client-summary.json`).

| Prediction | Measured | Verdict |
|---|---|---|
| 1. First scale-up within 60 s (I expected 30 to 60 s) | desired replicas went above 2 after **21.5 s** | Confirmed, and faster than I expected |
| 2. Reaching 8 replicas in about 90 to 150 s | 8 replicas after **68.5 s** (all 8 Ready after 67.9 s) | **Wrong, too pessimistic.** The first CPU reading arrived within 21 s, so the +2 pods per 15 s policy was the only limit |
| 3. Zero fault errors, latency rises before new pods arrive | **0** fault errors in 2560 requests during the load. p50/p95/p99 went from 29/62/82 ms to **188/1104/1981 ms** | Errors confirmed. The latency rise is large |
| 4. Scale-down about 4 to 6 minutes | **298.8 s** from load off to back at 2 replicas, one pod at a time, 30 to 40 s apart | Confirmed |

Replica timeline: 2 at the start; desired 4 at +21 s, 6 at +37 s, 8 at +53 s; 8 Ready at +68 s; after the load stopped, 7 at +236 s
(this includes the 60 s stabilization window), then one fewer roughly every 30 to 40 s until 2 at +426 s (times counted from the load starting).

**How to read this, honestly.** CPU peaked at about **950%** of the pods' CPU request (the target is 60%), and at the maximum of 8
replicas it still read 871%. The load generator is far stronger than 8 pods can serve, so this run shows that the autoscaler
reacts fast and that it reaches its ceiling quickly. It does **not** show that autoscaling keeps latency inside the 500 ms SLO:
p95 was over a second during the load, because even 8 pods were saturated. Two follow-ups this suggests, neither done: a gentler
load that 8 pods can absorb (to measure whether latency recovers as replicas arrive), and a higher maximum or a per-pod
requests/limits review.

Also not covered: one run only, a single laptop, one request mix (a CPU-bound endpoint).
