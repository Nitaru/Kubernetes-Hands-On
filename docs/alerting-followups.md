# Postmortem follow-ups: a Redis alert and an ingress-level SLI

Two open action items from the [Redis postmortem](postmortems/2026-11-18-redis-outage-takes-down-browsing.md):

- **Item 2:** alert on `shop_redis_up == 0` for a minute. Since the fix, readiness no longer depends on Redis, so a Redis
  outage leaves every pod Ready and shows up only as failed orders. Nothing named the cause.
- **Item 3:** measure availability at the ingress too. The app's metrics only see requests that reach a pod, so a 503
  that Traefik generates itself (no endpoints left, as in the original outage) never counts against the SLO.

The predictions below were committed before any live run (see the commit history). Results are added underneath them.

## Item 2: `ShopRedisDown`

Rule in [`slo-rules.yaml`](../charts/shop/files/slo-rules.yaml): `count(shop_redis_up{app="shop-api"} == 0) > 0` for 1 minute.
Any one pod without Redis is enough, because orders that land on that pod fail. Unit tests in
[`slo-rules.test.yaml`](../tests/slo-rules.test.yaml): all pods down fires, one pod down fires, a 45 s blip does not.
Each test was checked by breaking the rule on purpose (requiring every pod to be down; `for: 0s`), which turned it red.

**Predictions for the live run** (scrape every 15 s, Prometheus evaluates rules every 30 s, `for: 1m`):

| Run | Prediction |
|---|---|
| Redis scaled to 0 for 3 minutes | Alert pending within 15 to 45 s, **firing 60 to 105 s** after the scale-down; resolved within 60 s of Redis being Ready again |
| Redis scaled to 0 for 45 s (the postmortem's outage) | **Does not fire** (pending at most). Meaning: an outage this short is not paged by this alert, only seen on the dashboard |
| API pods while Redis is down | Stay Ready, 2 of 2 (the postmortem fix, checked again) |

## Item 3: availability measured at the ingress

**Predictions for the live run** (API scaled to 0 for 3 minutes under the chaos load, Argo CD self-heal off for the run):

| Signal | Prediction |
|---|---|
| App SLI `shop:http_errors:ratio_rate5m` | Shows **no errors**: no pod exists to count them. The series has no data instead (division by zero), so the app-level SLO is blind to this outage |
| Ingress SLI (from Traefik's metrics) | Close to **100% errors** within 1 to 2 scrapes of the scale-down |
| Client side (the load generator) | Every request fails for the 3 minutes plus the pod start-up time |
| `ShopApiDown` | Fires? No: it has `for: 5m`, longer than the outage |

Risk to the prediction: Traefik may not attribute "no endpoints" 503s to the shop's service label at all (the service may vanish
from its config when it has no endpoints). If so the ingress SLI has to use entrypoint or router metrics instead, and this file
will say which one was used and why.

## Results, item 3 (2026-11-27, `scripts/chaos.sh apidown`)

Raw data: `docs/chaos-results/2026-11-27/apidown/` (`signals.txt` has the alert states and three error ratios every 5 s).
The API was scaled to 0 for 180 s under the usual load of about 20 requests a second.

| Signal | Prediction | Measured | Verdict |
|---|---|---|---|
| Client side | Every request fails for the outage | **3651 of 3676 requests failed (99.3%)**, all `503` from Traefik, from 0.2 s to 182.7 s after the scale-down | Confirmed |
| App SLI (`http_request_duration_seconds`) | No errors, then no data | **0** errors counted. The 1-minute ratio went from 0.4% (the simulated payment failures) to **no data** about 50 s in, and stayed there until the pods were back | Confirmed: the app-level SLO is blind to this outage |
| Ingress SLI | Close to 100% within 1 to 2 scrapes | Per-router ratio **0.39 at +21 s** (a 1-minute window filling up), **1.0 from about +50 s to +183 s** | Confirmed, with the window lag you would expect |
| `ShopApiDown` | Does not fire (`for: 5m`) | Pending from about +50 s, never fired | Confirmed. A 3-minute total outage pages nobody |

**The risk I wrote down happened.** A first run (kept in `apidown-run1-signals-garbled-no-router-metrics/`) used Traefik's
per-service metric, `traefik_service_requests_total`. It counted **none** of the 503s: with no endpoints left, Traefik no longer
attributes those requests to the shop's service. Only the entrypoint metric saw them (about 20 errors a second), and the
entrypoint mixes every host behind Traefik (Grafana and Argo CD too). So the SLI uses the **per-router** metric, which needed
`addRoutersLabels: true` in [`traefik-values.yaml`](../platform/traefik-values.yaml), and the second run shows it catches the outage.
That first run also had a bug of mine in the harness: one query string split into two arguments and shifted every column of
`signals.txt`. The numbers above come from the second run; the first run's useful finding was checked against Prometheus's history.

What was added: [`traefik-servicemonitor.yaml`](../platform/traefik-servicemonitor.yaml) (Prometheus did not scrape Traefik at all
before), the recording rules `shop:ingress_errors:ratio_rate5m` and `ratio_rate1h`, and `ShopIngressAvailabilityFastBurn` with the same
14.4x thresholds as the app's alert. Unit tests: Traefik answering 503 with no app series fires the ingress alert and not the app's;
503s on another host (Grafana) do not count against the shop. Each test was checked by breaking the rule on purpose (counting every
router; building the SLI from the per-service metric), which turned the matching test red.

**Not covered.** The ingress alert was not deployed during this run, so whether it pages for this outage was not observed. Whether
it would depends on traffic over the hour: with steady traffic all hour, 3 minutes of total failure is about 5% of the 1-hour window,
under the 14.4% line; on this lab cluster, where load only flows during experiments, the same outage dominates the window. The SLI
is for sustained burn, like the app's. Traefik has no path label, so the ingress SLI counts every path on the shop's host,
not only the two user-facing routes the app's SLI uses. Errors in front of Traefik (DNS, the host port) are invisible to both.

## Results, item 2 (2026-11-27, `REDIS_DOWN_S=180` and `REDIS_DOWN_S=45 scripts/chaos.sh redisalert`)

Raw data: `docs/chaos-results/2026-11-27/redisalert-180s/` and `redisalert-45s/`. Times are seconds after Redis was scaled to 0;
`signals.txt` is polled about every 5 s, so each time is good to about 5 s. Prometheus scrapes the app every 15 s and evaluates rules every 30 s.

| Run | Prediction | Measured | Verdict |
|---|---|---|---|
| 180 s outage: pending | 15 to 45 s | **about 52 s** (`shop_redis_up` was already 0 at +5 s) | **Missed** by a few seconds; I did not find where the extra delay comes from |
| 180 s outage: firing | 60 to 105 s | **about 115 s** (pending + the 1-minute `for`, as designed) | **Missed**, by the same delay carried forward |
| 180 s outage: resolved | within 60 s of Redis Ready | about **23 s** after Redis was back | Confirmed |
| 45 s outage | does not fire | pending at about +31 s, **never fired**, inactive again 28 s after Redis was back | Confirmed: a 45 s outage is not paged by this alert |
| API pods during both | stay Ready, 2 of 2 | **0 failed product requests** in both runs (and the longest gap between successful product responses was 0.3 s), so no pod left the Service | Confirmed (the postmortem fix, checked again) |
| Orders during both | fail with 503 | 724 of 3635 requests (19.9%) and 175 of 934 (18.7%), all `POST /api/orders` | As designed |

**Something I did not plan to see.** During the 180 s run the new ingress alert, `ShopIngressAvailabilityFastBurn`, fired (from about
+118 s to +253 s) and the app's `ShopAvailabilityFastBurn` did not, although both measured about 20% errors in the 5-minute window.
The difference is the 1-hour window: the ingress SLI still held the `apidown` outage from 20 minutes earlier, and the app's SLI had
never seen it (it had no data then). That is item 3's point in action, but it is a side effect of running the experiments back to
back, not a clean comparison, so I do not count it as a result.

**Not covered.** One run each. A Redis that is up but slow, or a single pod losing its connection while the others keep theirs
(only the unit test covers the one-pod case). The alert goes to Alertmanager, which has no receiver configured here, so nobody
would actually be paged.
