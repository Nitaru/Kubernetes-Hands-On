# Progressive delivery: a bad release that stops itself

A rolling update replaces pods until every one runs the new version, so a release that breaks something breaks it for everyone, and a human
has to notice and roll back. This adds [Argo Rollouts](https://argoproj.github.io/rollouts/): the new version goes to a small share of
the pods first, an analysis reads the canary's error ratio from Prometheus, and the rollout **aborts by itself** if the ratio is too high.
`make rollout-demo` runs it. Predictions were written before the first run.

## What it does

The chart can render a `Rollout` instead of the `Deployment` (`rollout.enabled`, off by default, so the normal install is unchanged).
Steps: 25% canary, a pause, an analysis, 50%, a pause, an analysis, then everything. The analysis (`AnalysisTemplate` `shop-canary-health`)
asks Prometheus for the 5xx ratio of the **canary pods only** (matched by the ReplicaSet's pod-template hash) and fails above 10%.
There is no traffic router on kind, so a "25% canary" is a replica ratio: roughly a quarter of the pods, so roughly a quarter of the requests.

Two releases are pushed through Git with Argo CD, under the steady load from the chaos experiments (about 20 requests a second, 20% of them orders):

- a **good** release (the simulated payment failure rate goes from 3% to 2%, a change to the pod template, so it is a new revision);
- a **bad** release (payment failure rate 100%, so every order the canary serves fails with a 502).

## Predictions

1. **The good release is promoted to 100%** by the analysis, with no human step, in **under 4 minutes**, and users see no extra errors.
2. **The bad release is aborted by the analysis** and the stable version keeps serving: the rollout ends `Degraded` (aborted) with the old
   revision still the stable one, **without anyone running a command**, within **3 minutes** of the push.
3. **The blast radius is bounded.** Failed orders during the bad release are a **minority** of all orders (I expect roughly 10 to 30%,
   the canary's share of the traffic for the time it was up), not all of them.
4. **Nothing else breaks:** no failed product requests (`GET /api/products`) during either release.

What would make me wrong: no analysis data for the canary (the series may not carry the label I match on), the ratio never crossing the
threshold because the canary gets too little traffic, or the HPA and the Rollout fighting over replicas.

Not claimed: a comparison with a plain rolling update of the same bad release (not run), behaviour with a real traffic router,
precise weights, or anything beyond this one cluster and one run each.

## Results (2026-11-18, one run of each release)

Raw output: `docs/rollout-results/2026-11-18/` (`timeline-A.txt`, `timeline-B.txt`, `analysis-*.txt`, `summary.json`).

| Prediction | Measured | Verdict |
|---|---|---|
| 1. Good release promoted by the analysis in under 4 min, no extra errors | **Promoted, 175 s** after the push. Two analysis runs, both Successful (canary error ratios 0 and about 0.22%). Orders failed: 20 of 730 (2.7%), which is the simulated payment failure rate and nothing more | Confirmed |
| 2. Bad release aborted by the analysis, stable keeps serving, within 3 min, no command run | **Aborted after 92 s**. The analysis measured a canary error ratio of **0.231** against the 0.10 limit and failed. The stable revision (the good release A) stayed stable. After the abort the cluster was healthy; putting the stable version back through Git took 45 s | Confirmed |
| 3. Failed orders a minority, roughly 10 to 30% | **79 of 381 orders (20.7%)** failed during the 92 s | Confirmed |
| 4. No failed product requests in either release | **0** failed product requests in both | Confirmed |

**A first run that did not count.** My script judged the good release "promoted" after 0.4 s: right after a push the Rollout still reports the old
revision as Healthy until Argo CD has synced the new template, so the check passed before anything had started. The bad release was then pushed
while the good one was still mid-rollout. The analysis still aborted it (error ratio 0.197), but release A was never measured, so that run is kept in
`docs/rollout-results/2026-11-18-run1-release-A-not-measured/` and the script now waits for the new revision to register first. This is the same
mistake as in the chaos script (a status that lags a change), made again, which is worth remembering.

**What this does not show.** There is no comparison run of a plain rolling update with the same bad release; I expect every order to fail until a
human reverts, but I did not measure it, so the claim here is only the absolute one: about a fifth of orders for 92 s, then stopped. The canary
share is a replica ratio (no traffic router on kind), one run each, and the analysis passes when the canary serves no requests at all (the query
falls back to 0), so it needs real traffic to mean anything.
