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
