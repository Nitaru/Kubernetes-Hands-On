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
