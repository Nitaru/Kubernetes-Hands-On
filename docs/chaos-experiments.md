# Chaos experiments

Five controlled failures against the running platform, each with a hypothesis written **before** the first run
(see the commit history: this file was committed before any result existed), plus a sixth (3b) added after experiment 3's
result and before its own run. A wrong hypothesis is a result too.

Run one with `make chaos-podkill`, `chaos-drain`, `chaos-redis`, `chaos-redisdown`, `chaos-baddeploy`, `chaos-netpol`, or all of them
with `make chaos`. They need the GitOps install (`make up-gitops`), because two of them go through Argo CD.
Raw numbers land in `docs/chaos-results/<date>/`.

## How every run works

1. A steady load generator (`scripts/chaos-load.py`) sends about 20 requests a second **through Traefik**, the path a
   real user takes: 80% `GET /api/products`, 20% `POST /api/orders`. Every request is logged with its time, route,
   status and latency.
2. 30 s of baseline, then the fault, then load continues until the system has recovered, plus 30 s.
3. The analysis counts **fault errors** only. A `502 payment failed` from the app is the simulated payment provider
   (3% of orders by design), not a fault, so it is counted separately. Connection errors, timeouts, Traefik's own
   502/503/504 and any other 5xx are fault errors.
4. It reports error ratio, the outage window (first to last fault error), latency percentiles before and during the
   fault, and, from Prometheus, the 5-minute error ratio and which alerts fired.
5. **Burn rate** below is the error ratio over the fault window divided by the 1% error budget of the availability SLO
   (99% of requests not 5xx). A burn rate of 14.4 over an hour is what pages; a short outage can be severe and still
   not page, because the alert needs both a 1 h and a 5 m window above the line.

Not claimed anywhere here: behaviour on a real multi-machine cluster (this is kind on one laptop), realistic network
latency, data durability of Redis, or load above about 20 requests a second.

## The experiments and what I expect

### 1. `podkill`: kill one API pod without warning

`kubectl delete pod --grace-period=0 --force` on one `shop-api` pod, under load.

**Hypothesis.** With two or more replicas the other pod keeps serving. Failures are limited to requests that were in
flight on the dead pod, before the load balancer notices. Fault errors **below 1%** of requests, the replacement pod
Ready in **under 30 s**, **no alert** fires, burn rate at most about 1.

### 2. `drain`: drain a worker node that does not host Redis

`kubectl drain` of the worker running API pods but not Redis. The PodDisruptionBudget and `maxUnavailable: 0` should
keep capacity up.

**Hypothesis.** A graceful eviction costs **zero fault errors**. All API pods are Ready again within **60 s**.
No alert fires.

### 3. `redis`: kill the Redis pod

`kubectl delete pod` on the Redis StatefulSet's pod, under load.

**Hypothesis.** My first instinct was that only ordering would break and browsing products would keep working,
because `GET /api/products` never touches Redis. **Reading the code says otherwise**: `/ready` returns 503 whenever
the Redis client is not ready, so within two failed probes (2 x 5 s) every API pod leaves the Service. Predicted
result: **product requests fail too**, for roughly the Redis restart time plus the probe delay, about **20 to 60 s**,
with a near-100% error ratio inside that window. The 5-minute error ratio spikes, but the fast-burn alert
**does not page** (its 1 h window stays below 14.4%). If this is right, it is a design flaw: a read-only endpoint is
taken down by a dependency it does not use.

### 3b. `redisdown`: Redis is down for 45 seconds

**Why this exists.** Added after the first run of experiment 3, while it was still running: the Redis pod came back in
about 3 seconds, which is shorter than the two failed readiness probes the API needs to leave the Service (up to 10 s).
So experiment 3 could not test the design question at all. This one can. The hypothesis below was written after I saw
experiment 3's timeline, but before I ran 3b.

`kubectl scale statefulset shop-redis --replicas=0`, wait 45 s under load, then scale back to 1. A real Redis incident
(a node loss, a volume that takes a minute to re-attach) lasts far longer than 3 seconds.

**Hypothesis.** After at most two failed readiness probes (about 10 s) every API pod leaves the Service, so **product
requests fail too, not only orders**: a near-100% error ratio from roughly 10 s after the fault until Redis is back and
the API pods pass readiness again, about **35 to 60 s of total outage** for a 45 s Redis outage, then recovery within
about 15 s of Redis returning (probe period 5 s plus the client reconnecting). The fast-burn alert does **not page**:
45 s of failures is about 1.25% of a 1-hour window against a 14.4% threshold. If this is right, readiness couples a
read-only endpoint to a dependency it does not use.

**Run 1 did not test this, and why.** I scaled the StatefulSet to 0, and Argo CD's self-heal put the replica back within
seconds, so Redis was down for about 7 s, shorter than the two failed readiness probes. That is a finding of its own:
under GitOps a manual `kubectl scale` is undone almost at once (see also experiment 5). The raw data is kept in
`docs/chaos-results/2026-11-18/redisdown-run1-selfheal-reverted-it/`. Run 2 turns self-heal off for the duration, which
is what an on-call engineer would do in a real incident to stop Argo fighting a manual change, and turns it back on
afterwards. The hypothesis above is unchanged.

### 4. `baddeploy`: ship a broken release through Git and roll it back through Git

Commit a change pointing the image at a tag that does not exist to the in-cluster Git server, let Argo CD sync it, then
`git revert` it.

**Hypothesis.** The new pod cannot pull its image and never becomes Ready, and because `maxUnavailable` is 0 the old
pods keep serving, so users see **zero fault errors**. Argo CD notices within about a minute (it polls Git every 30 s
here, see `platform/argocd-values.yaml`) and reports the app as not Healthy. The revert restores Healthy within
**2 minutes**.

### 5. `netpol`: someone deletes the default-deny NetworkPolicy by hand

`kubectl delete networkpolicy default-deny -n shop`, while a probe pod in another namespace tries to reach the API and
Redis every second, and a probe inside the Redis pod tries to open a connection to Traefik every second.

**Hypothesis (revised before running).** My first draft said the probe pod would reach the API and Redis during the gap.
Reading `charts/shop/templates/networkpolicy.yaml` shows that is wrong: the `api` and `redis` policies still select
those pods, so they stay isolated even without `default-deny`. What `default-deny` really adds is (a) a lock on Redis's
**egress**, because the `redis` policy only covers ingress, and (b) a deny for any pod that no other policy selects.
So I expect: the other-namespace probe stays **blocked throughout**, the Redis pod's outbound connection to Traefik
**opens** while the policy is missing and closes again after, and Argo CD's self-heal restores the policy in
**under 60 s** (30 s polling plus a sync). The exposure window is the number to report.

## Re-measurement after the fix (written before the fix is deployed)

Experiment 3b showed the design flaw: with Redis down for 45 s, 602 product requests failed because readiness required
Redis. The fix (in `app/src/server.js`) takes Redis out of the readiness check, adds a `shop_redis_up` metric, and leaves
`/api/orders` to answer 503 on its own when Redis is down. Same experiment, same load, results in
`docs/chaos-results/2026-11-18-after-fix/`.

**Hypothesis.** No pod leaves the Service, so **product requests do not fail at all** (0 fault errors on products).
Orders still fail with 503 for as long as Redis is down, so the overall error ratio inside the 45 s window is close to
the share of orders in the load, **about 20%**, instead of 75%. Orders recover within about 5 s of Redis returning
(the client reconnecting). The fast-burn alert still does not page for a 45 s outage. Note the trade: the fix does not
make orders survive a Redis outage, it stops the outage from also taking down browsing.

## What counts as done

Each experiment: the hypothesis above, the measured result next to it, and whether I was right. At least one action
item from the results is fixed and the same experiment re-measured (see the postmortem in `docs/postmortems/`).

## Results (2026-11-18, one run each unless stated)

Each hypothesis above, next to what was measured. Raw requests, timelines and summaries are in `docs/chaos-results/2026-11-18/`.

| # | Hypothesis | Measured | Verdict |
|---|---|---|---|
| 1 `podkill` | Under 1% fault errors, replacement Ready in under 30 s, no alert | **0** fault errors (73 requests in a 3.7 s window), replacement Ready after about 4 s, no alert. One run, so a lucky gap with no request in flight is possible | Confirmed (n = 1) |
| 2 `drain` | Zero fault errors, all pods Ready within 60 s | **0** fault errors over 94 s (1881 requests), all API pods Ready **94 s** after the drain started (`events.txt`; the console said 79 s, but its counter only starts once `kubectl drain` returns) | Errors confirmed, time **missed**; I did not investigate why it took that long |
| 3 `redis` (pod delete) | Product requests fail for 20 to 60 s | **0** product failures, 4 failed orders in about 1 s. Redis was back in about 3 s, so readiness never flipped | **Refuted** (timing), which led to 3b |
| 3b `redisdown` | About 35 to 60 s outage including products, back within 15 s of Redis, no page | Products 503 from +9.4 s to +46.9 s (**602 failed product requests**), 75.3% errors in the window, all pods Ready 6.1 s after Redis, no alert | Confirmed. Run 1 was invalid (self-heal restored Redis), kept for the record |
| 4 `baddeploy` | Zero errors, Argo notices within about a minute, Healthy within 2 min of the revert | **0** fault errors over 151.5 s (3031 requests), Argo noticed after about 32 s, the new pod sat in `ErrImagePull`/`ImagePullBackOff`, the app showed Progressing (I did not wait the 10 minutes it takes to reach Degraded), Healthy and Synced **28 s** after the revert | Confirmed |
| 5 `netpol` | Probe from another namespace stays blocked, Redis egress opens in the gap, restored in under 60 s | Probe **blocked in 6 of 6** samples, policy restored after about **1 s** (1.1 s in `events.txt`), Redis egress **never seen open**: the gap was shorter than my 1 s probe | Partly confirmed, partly **inconclusive** |

**After the fix** (`docs/chaos-results/2026-11-18-after-fix/`): same experiment as 3b. Product requests failed: **0** (was 602).
Orders failed: 182 (was 198). Error ratio in the window: 19.5% (was 75.3%), as predicted. API pods stayed Ready 2 of 2.
Full write-up: [`postmortems/2026-11-18-redis-outage-takes-down-browsing.md`](postmortems/2026-11-18-redis-outage-takes-down-browsing.md).
