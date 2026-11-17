# Kubernetes Hands-On

A small production-style platform on a local multi-node Kubernetes cluster: ingress, autoscaling,
zero-downtime rollouts, default-deny network policies, hardened pods, a stateful backend, and
observability with SLO-based alerting.
Everything is built from scratch by one script and verified by tests that run in CI.

```
 browser / curl
      │  http://shop.localtest.me:8080
      ▼
 ┌─────────── kind cluster (1 control plane + 2 workers, Calico CNI) ───────────┐
 │   Traefik (ingress, 2 replicas)                                              │
 │      │  NetworkPolicy: only the ingress namespace may reach the API          │
 │      ▼                                                                       │
 │   shop-api  (Deployment, 2-8 replicas, HPA on CPU, PDB, spread across nodes) │
 │      │  NetworkPolicy: the API may only talk to Redis (and DNS)              │
 │      ▼                                                                       │
 │   shop-redis (StatefulSet, PVC, password from a Secret)                      │
 │                                                                              │
 │   metrics-server  ──▶  kubectl top, HPA                                      │
│                                                                              │
│   Prometheus ──scrapes──▶ shop-api /metrics   (ServiceMonitor, allowed by    │
│      │  SLO recording + burn-rate alert rules  the NetworkPolicy)            │
│      ├──▶ Alertmanager                                                       │
│      └──▶ Grafana  http://grafana.localtest.me:8080  (dashboard as code)     │
 └──────────────────────────────────────────────────────────────────────────────┘
```

## Run it

Needs Docker, [kind](https://kind.sigs.k8s.io), `kubectl` and `helm`.

```sh
make up        # cluster + Calico + Traefik + metrics-server + Prometheus/Grafana + app (a few minutes)
make test      # 23 assertions against the live cluster
make grafana-password   # login for http://grafana.localtest.me:8080 (user: admin)
curl http://shop.localtest.me:8080/api/products    # localtest.me resolves to 127.0.0.1
make down
```

## What it demonstrates

| Topic | How |
|---|---|
| **Helm chart from scratch** | [`charts/shop`](charts/shop): Deployment, StatefulSet, Services, Ingress, HPA, PDB, Secret, NetworkPolicies, ServiceAccount. Linted and schema-validated in CI. |
| **Health checks done right** | Separate `startup`, `readiness` and `liveness` probes. Liveness never depends on Redis (a Redis outage must not restart healthy pods); readiness does. |
| **Zero-downtime rollouts** | `maxUnavailable: 0`, a `preStop` sleep, and SIGTERM handling in the app that fails readiness and drains in-flight requests. |
| **Autoscaling** | HPA on CPU with tuned scale-up/scale-down behaviour, driven by an in-cluster load generator. |
| **High availability** | Topology spread over nodes, a PodDisruptionBudget, and a node drain that keeps serving. |
| **Network security** | Default-deny ingress and egress, then explicit allows: ingress controller to API, API to Redis, DNS. Enforced by Calico. |
| **Pod hardening** | Non-root, read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`, no service-account token mounted. |
| **Secrets** | Redis password generated once by Helm (`lookup` keeps it across upgrades) and injected from a Secret, never written in a manifest. |
| **Stateful workload** | Redis as a StatefulSet with a PersistentVolumeClaim and append-only persistence. |
| **Observability** | kube-prometheus-stack (pinned chart). The chart ships a `ServiceMonitor`, a `PrometheusRule` and a Grafana dashboard as code ([`dashboard.json`](charts/shop/files/dashboard.json), picked up by the Grafana sidecar). The default-deny policy has one explicit allow so only the `monitoring` namespace can scrape `/metrics`. |
| **SLOs and alerting** | Two SLOs on the user-facing routes: 99% of requests are not 5xx, 95% finish within 500 ms. Alerts use multiwindow burn rates (page at 14.4x, ticket at 6x), written in [`slo-rules.yaml`](charts/shop/files/slo-rules.yaml) and unit-tested with `promtool` ([`tests`](tests/slo-rules.test.yaml), run in CI with no cluster). |
| **Testing** | `scripts/smoke.sh` asserts cluster, workload, traffic and policy behaviour. CI runs lint, then builds the platform on a fresh kind cluster and runs it. |

## Prove it

```sh
make demo-rollout    # hammer the site while every pod is replaced: all responses are 200
make demo-selfheal   # delete a pod; traffic keeps flowing and a replacement appears
make demo-autoscale  # load goes up, replicas follow, load stops, replicas come back down
make demo-netpol     # a pod in another namespace is blocked from the API and Redis
make demo-drain      # drain a worker node; the PDB keeps the service up
make demo-slo        # make every payment fail; watch the error budget burn and the page fire
```

The network policy demo includes a control target (an unprotected service that must answer) so
"blocked" cannot be a broken probe, and was verified both ways: policies off means reachable,
policies on means blocked.

### What the SLO demo showed

With every payment failing and mixed order and product traffic, the 5-minute and 1-hour error ratios
both settled near 50% within about 80 seconds, and `ShopAvailabilityFastBurn` fired as `critical`
(`ShopAvailabilitySlowBurn` went `pending`, waiting out its 15-minute hold). After payments were
restored the alert resolved within minutes, once the 5-minute window cleared. That is the point of
the two windows: the long one filters blips, the short one stops the page soon after recovery.

## Things that went wrong, and what they taught me

- **kind's default CNI ignores NetworkPolicies.** Policies apply without error and do nothing.
  The cluster runs Calico instead, and the demo proves enforcement in both directions.
- **ingress-nginx is retired**, so the ingress controller is Traefik, installed from a pinned chart.
- **Ingress on kind with Docker Desktop:** a NodePort request that must hop to a pod on another node
  hangs when it enters through the published host port, while in-cluster and node-to-node traffic is
  fine. I narrowed it down by testing each hop (pod to pod, node to node, a non-node container to the
  NodePort) and pinned Traefik to the control-plane node, the standard kind recipe. I did not find the
  exact root cause; on a real cluster a LoadBalancer replaces all of this.
- **Helm 4 keeps old `--set` values on `helm upgrade`.** A leftover `networkPolicy.enabled=false` silently
  removed every policy. The scripts now pass `--reset-values`.
- **My first network policy "test" proved nothing.** The probe pod could exit before `kubectl` attached
  to it, and Redis does not speak HTTP, so a connected socket looked like a failure. Fixed by running the
  probe to completion, reading its logs, using curl's exit code, and adding the control target.
- **Topology spread is not a rebalancer.** After draining a node, both replicas ended up on the same
  worker and stayed there. The fix in a real cluster is the descheduler or an anti-affinity rule.
- **metrics-server needs `--kubelet-insecure-tls` on kind.** Fine locally, never on a real cluster.
  Prometheus has the same problem scraping the kubelet (`insecureSkipVerify` in the stack values).
- **Disabling the operator's admission webhook is not enough.** The operator still mounts a TLS secret
  that the webhook's patch job would have created, so the pod sat in `ContainerCreating` and Helm timed
  out. The fix is `prometheusOperator.tls.enabled: false` as well.
- **kind's control-plane targets would alert forever.** etcd, scheduler, controller-manager and kube-proxy
  bind to localhost on kind, so their scrape targets are permanently down. They and their default rules
  are switched off, and node-exporter is off because it needs host mounts Docker Desktop cannot share.
- **My first two monitoring checks passed without checking anything.** One queried Grafana with a wrong
  password and got a 401 JSON object, which `length >= 1` accepted. Another had a quoting bug that
  turned the Prometheus query into an error, which also "passed". The checks now require
  `status == "success"` and an actual dashboard uid, and I proved they can fail (the "no alert firing"
  check failed correctly while the demo alert was still active).
- **`helm --wait` does not wait for the Prometheus StatefulSet.** The operator creates it after Helm
  returns, so the smoke test waits for the pods itself.

## Layout

```
app/              Node.js shop API (Prometheus metrics, /health, /ready, graceful shutdown)
charts/shop/      the Helm chart (files/: SLO rules and Grafana dashboard)
tests/            promtool unit tests for the SLO alert rules
kind/cluster.yaml 3-node cluster, default CNI disabled
platform/         values for Traefik, metrics-server and kube-prometheus-stack, the load generator
scripts/          up.sh (build everything), demo.sh, smoke.sh, test-rules.sh
.github/          CI: helm lint, kubeconform (incl. CRD schemas), promtool, hadolint, then an end-to-end run on kind
```

## Versions

Kubernetes v1.37.0 (kind v0.33), Calico v3.31.0, Traefik chart 42.4.0, metrics-server chart 3.14.0,
kube-prometheus-stack chart 93.3.1.
