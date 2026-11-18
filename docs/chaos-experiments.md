# Chaos experiments

Five controlled failures against the running platform, each with a hypothesis written **before** the first run
(see the commit history: this file was committed before any result existed). A wrong hypothesis is a result too.

Run one with `make chaos-podkill`, `chaos-drain`, `chaos-redis`, `chaos-baddeploy`, `chaos-netpol`, or all of them
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

### 4. `baddeploy`: ship a broken release through Git and roll it back through Git

Commit a change pointing the image at a tag that does not exist to the in-cluster Git server, let Argo CD sync it, then
`git revert` it.

**Hypothesis.** The new pod cannot pull its image and never becomes Ready, and because `maxUnavailable` is 0 the old
pods keep serving, so users see **zero fault errors**. Argo CD reports the app as not Healthy (Progressing, then
Degraded). The revert restores Healthy within **3 minutes**, Argo's default polling interval.

### 5. `netpol`: someone deletes the default-deny NetworkPolicy by hand

`kubectl delete networkpolicy default-deny -n shop` while a probe pod in another namespace tries to reach the API
and Redis every second.

**Hypothesis.** Argo CD's self-heal puts the policy back in **under 30 s**. During that gap the probe **can** reach the
API and Redis (the security control really is gone), and after it is restored it cannot. The exposure window is the
number to report.

## What counts as done

Each experiment: the hypothesis above, the measured result next to it, and whether I was right. At least one action
item from the results is fixed and the same experiment re-measured (see the postmortem in `docs/postmortems/`).
