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
