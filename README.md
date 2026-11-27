# Kubernetes Hands-On

[![ci](https://github.com/Nitaru/Kubernetes-Hands-On/actions/workflows/ci.yml/badge.svg)](https://github.com/Nitaru/Kubernetes-Hands-On/actions/workflows/ci.yml)

A small production-style platform on a local multi-node Kubernetes cluster: ingress, autoscaling,
zero-downtime rollouts, default-deny network policies, hardened pods, a stateful backend, and
observability with SLO-based alerting, security scanning in CI, admission policies and GitOps with Argo CD.
Everything is built from scratch by one script; the smoke tests run against it in CI in both install modes. The experiments further down
(chaos, load test, canary releases, restore drill) are one-off runs on a laptop, with their raw data committed in `docs/`.

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
 │   Kyverno ──▶ admission policies: unhardened pods are refused at apply time  │
 │   Argo CD ──▶ keeps the shop namespace equal to Git (prune, self-heal)       │
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
make up        # cluster + Calico + Traefik + metrics-server + Prometheus/Grafana + app (about 9 minutes)
make test      # 30 assertions against the live cluster
make up-gitops # same platform, but Argo CD deploys the app from Git (see GitOps below); `make test` then runs 39
make scan      # Trivy: image CVEs, Dockerfile and chart misconfigurations, secrets
make grafana-password   # login for http://grafana.localtest.me:8080 (user: admin)
make argocd-password    # login for http://argocd.localtest.me:8080 (GitOps mode only)
curl http://shop.localtest.me:8080/api/products    # localtest.me resolves to 127.0.0.1
make down
```

## What it demonstrates

| Topic | How |
|---|---|
| **Helm chart from scratch** | [`charts/shop`](charts/shop): Deployment, StatefulSet, Services, Ingress, HPA, PDB, Secret, NetworkPolicies, ServiceAccount. Linted and schema-validated in CI. |
| **Health checks done right** | Separate `startup`, `readiness` and `liveness` probes. Neither liveness nor readiness depends on Redis: a Redis outage must not restart healthy pods, and (found by a chaos experiment) it must not take read-only endpoints out of the Service either. `/api/orders` answers 503 on its own when Redis is down. |
| **Zero-downtime rollouts** | `maxUnavailable: 0`, a `preStop` sleep, and SIGTERM handling in the app that fails readiness and drains in-flight requests. |
| **Autoscaling** | HPA on CPU with tuned scale-up/scale-down behaviour, driven by an in-cluster load generator. Measured (`make loadtest`, [docs/loadtest.md](docs/loadtest.md)): 2 to 8 replicas in 68 s, back to 2 in 299 s after the load stopped, 0 failed requests. That load was far beyond what 8 pods can serve (CPU about 950% of the request), so p95 latency rose from 62 ms to over a second: it shows the speed of the scaling, not that latency stays within the SLO. |
| **High availability** | Topology spread over nodes, a PodDisruptionBudget, and a node drain that keeps serving. |
| **Network security** | Default-deny ingress and egress, then explicit allows: ingress controller to API, API to Redis, DNS. Enforced by Calico. |
| **Pod hardening** | Non-root, read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`, no service-account token mounted. |
| **Secrets** | Under Argo CD the [External Secrets Operator](https://external-secrets.io) generates the Redis password once (an `ExternalSecret` with a `Password` generator, `refreshPolicy: CreatedOnce`) and owns the Secret, so the chart ships no password in any form (`redisPassword.source: externalSecrets`). A plain `helm install` still generates it with `lookup` (`source: helm`, the default). Either way it is injected from a Secret and never written in a manifest. |
| **Stateful workload** | Redis as a StatefulSet with a PersistentVolumeClaim and append-only persistence. |
| **Observability** | kube-prometheus-stack (pinned chart). The chart ships a `ServiceMonitor`, a `PrometheusRule` and a Grafana dashboard as code ([`dashboard.json`](charts/shop/files/dashboard.json), picked up by the Grafana sidecar). The default-deny policy has one explicit allow so only the `monitoring` namespace can scrape `/metrics`. |
| **SLOs and alerting** | Two SLOs on the user-facing routes: 99% of requests are not 5xx, 95% finish within 500 ms. Alerts use multiwindow burn rates (page at 14.4x, ticket at 6x), written in [`slo-rules.yaml`](charts/shop/files/slo-rules.yaml) and unit-tested with `promtool` ([`tests`](tests/slo-rules.test.yaml), run in CI with no cluster). Availability is measured twice: by the app, and at the ingress from Traefik's per-router metrics, because the app cannot count requests that never reach a pod. `ShopRedisDown` names a Redis outage directly. |
| **Supply-chain scanning** | [`scripts/scan.sh`](scripts/scan.sh) runs Trivy on the image (HIGH/CRITICAL CVEs that have a fix), the Dockerfile and chart (misconfigurations) and the repo (secrets), and CI fails the build on any finding. It also produces a CycloneDX SBOM, uploaded as a CI artifact. The image is built in two stages so npm never reaches the runtime image. |
| **Admission policies** | Kyverno `ValidatingPolicy` rules (CEL) enforce, in the `shop` namespace, what the chart already does: non-root, read-only filesystem, no privilege escalation, all capabilities dropped, seccomp, pinned image tags, requests and a memory limit. Bad pods and bad Deployments are rejected at `kubectl apply` with the rule that failed, and the chart's own pods are admitted. |
| **GitOps** | Argo CD watches a Git repository and keeps the cluster equal to it: automated sync with prune and self-heal. A hand-made change (deleting the default-deny NetworkPolicy, editing the HPA) is undone within seconds, and a commit is deployed without anyone running `helm` or `kubectl`. By default it watches a tiny Git server inside the cluster, so the whole loop works offline and in CI; pointing it at GitHub is one variable (below). |
| **Testing** | `scripts/smoke.sh` asserts cluster, workload, traffic and policy behaviour. CI runs lint, then builds the platform on a fresh kind cluster and runs it. |

## Prove it

```sh
make demo-rollout    # hammer the site while every pod is replaced; fails on any non-200 (2026-11-27: 62 of 62 were 200)
make demo-selfheal   # delete a pod; traffic keeps flowing and a replacement appears
make demo-autoscale  # load goes up, replicas follow, load stops, replicas come back down
make demo-netpol     # a pod in another namespace is blocked from the API and Redis
make demo-drain      # drain a worker node; the PDB keeps the service up
make demo-slo        # make every payment fail; watch the error budget burn and the page fire
make demo-policy     # apply good and bad manifests; the API server refuses the bad ones
make demo-gitops     # undo hand-made drift, then change the cluster the GitOps way: commit, push, sync, revert
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

### What the first scan found

The first Trivy run failed the build with 1 CRITICAL and 28 HIGH findings, none of them in the app's own
dependencies. Most were in `tar`, `glob`, `minimatch` and similar packages **bundled inside npm**, which
ships in the `node:20-alpine` base image although the app never runs npm. The rest were stale Alpine
packages (`libssl3`, `libcrypto3`, `zlib`, `musl`) with fixes already published. The Dockerfile now installs
dependencies in a build stage, drops npm and corepack from the runtime stage, and runs `apk upgrade`.
The rescan reports 0 HIGH and 0 CRITICAL, the app still passes every smoke test, and the SBOM lists 103
components. I also checked that the scanners can fail: a Dockerfile without `USER` fails the config scan
(`DS-0002`), and a fake GitHub token fails the secret scan.

## GitOps

`make up-gitops` builds the same platform, but instead of `helm install shop` it creates one Argo CD
`Application` ([`platform/gitops/application.yaml`](platform/gitops/application.yaml)) that points at
`charts/shop` in a Git repository. From then on Git is the source of truth.

- **Default:** a small Git server runs inside the cluster and is seeded with this checkout's commits
  (uncommitted changes are not deployed, because GitOps only sees commits). Nothing leaves your machine, and
  CI does not depend on GitHub being reachable. `make demo-gitops` clones from it, commits, pushes, and
  watches Argo deploy the change, then reverts it.
- **Against GitHub:** after the repository is pushed, run
  `GITOPS_REPO=https://github.com/Nitaru/Kubernetes-Hands-On.git make up-gitops`. Then a merge to `main`
  is what deploys. The repository must be public, or Argo needs credentials (`argocd repo add` or a
  repository Secret). `GITOPS_REVISION` selects a branch, tag or commit other than `main`.
- **What this does not do yet:** the app image is built locally and loaded into kind (`shop-api:dev`), so
  Git changes configuration, not code. A real pipeline would have CI push an image to a registry and commit
  the new tag to this repository, and Argo would roll it out.
- `make up` and `make up-gitops` are alternatives for the same release name; switch with `make down` first.

## Chaos experiments

Six failures against the running platform, each with a hypothesis committed before the run: [docs/chaos-experiments.md](docs/chaos-experiments.md)
(`make chaos`, needs `make up-gitops`). Killing a pod, draining a node and shipping a broken release through Git cost zero failed requests;
deleting the default-deny policy was undone by Argo CD in about 1 s. One prediction was refuted and one found a real flaw: with Redis down for
45 s, readiness took the whole API out of the Service and product browsing returned 503 although it never touches Redis.
Postmortem, fix and re-measurement: [docs/postmortems](docs/postmortems/2026-11-18-redis-outage-takes-down-browsing.md).
Two of its follow-ups were then built and measured ([docs/alerting-followups.md](docs/alerting-followups.md)): with every API pod gone for
3 minutes, clients saw 99.3% errors while the app's own SLI counted **zero**, so availability is now also measured at the ingress;
and a `ShopRedisDown` alert, which fired about 115 s into a 3-minute Redis outage (I predicted 60 to 105 s) and, by design, not for a 45 s one.
Not covered: a multi-machine cluster, realistic network latency, load above about 20 requests a second, and most runs are a single run.

## Progressive delivery

[docs/progressive-delivery.md](docs/progressive-delivery.md), with predictions written first. With `rollout.enabled` the chart renders an Argo Rollouts canary
instead of the Deployment (off by default; the default render is byte-identical to before). `make rollout-demo` pushes two releases through Git under
steady load: a good one was promoted by the analysis in 175 s with no extra errors, a bad one (every order fails) was **aborted by the analysis after
92 s** with 21% of orders failed and no failed product request, without anyone running a command. Not covered: a comparison with a plain rolling update,
a real traffic router (a canary weight here is a replica ratio), or more than one run of each release.

## Backup and restore

[docs/backup-restore.md](docs/backup-restore.md), with predictions written first. `make redis-restore-drill` backs up Redis with `redis-cli --rdb`,
deletes its volume, restores the dump into a fresh one and compares: identical, 25 s from deleting the volume to verified, products kept
answering throughout. The first approach, Velero, did **not** work on kind: it reported `Completed` and backed up nothing that mattered, because it
cannot read the `hostPath` volumes kind's default storage creates (`make backup-drill` now fails loudly on that). Not covered: an off-cluster copy of the
dump, real data sizes, or anything other than Redis.

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
- **Trivy's secret scan ignored my fake AWS key.** `AKIAIOSFODNN7EXAMPLE` is AWS's documented example key
  and is allow-listed, so my first negative test "passed" for the wrong reason. A fake GitHub token
  triggered it. Worth remembering when testing any scanner: prove it can fail with realistic input.
- **Kyverno's `ClusterPolicy` is deprecated** in the version installed here (chart 3.10.0, Kyverno 1.20) in favour of
  the CEL-based `ValidatingPolicy`, so the policies use the new API. Matching only Pods is enough because
  Kyverno autogenerates the rules for Deployments and StatefulSets.
- **Enforcing policies has an availability cost.** With `failurePolicy: Fail`, if Kyverno is down, new pods
  in `shop` are refused. That is the secure choice and is noted in the policy file; a real cluster would
  run several controller replicas.
- **My first backup said it succeeded and contained no data.** Velero's file-level backup skips `hostPath` volumes, which is what kind's storage creates, and still
  reports `Completed`; the restore then restored an empty disk. A second silent failure: Redis with append-only mode on ignores an RDB file and starts empty. Both
  are written up in the backup doc, and the drill now checks the data instead of trusting a status.
- **Readiness depended on Redis, so a Redis outage took product browsing down too.** Found by experiment 3b, fixed and re-measured
  (602 failed product requests before, 0 after); see the postmortem. My first test of it, a 3-second Redis restart, showed nothing
  because it was shorter than the probe window.
- **Argo CD showed the app as `Progressing` forever.** Everything was synced and every pod was running; the
  cause was the Ingress, which Argo calls healthy only once it has a load-balancer address, and Traefik on
  kind (a NodePort) never gets one. A custom health check in the Argo values accepts the Ingress. A cluster
  with a real LoadBalancer would not need it.
- **Helm's `lookup` does not exist under Argo CD.** The chart keeps the Redis password across upgrades with
  `lookup`, but Argo renders with `helm template`, which cannot read the cluster, so every render invented a
  new password and the Secret would be rewritten on every sync. First fix: the Application ignored that one field
  (`ignoreDifferences` plus `RespectIgnoreDifferences`), checked by hashing the password before and after two
  real Git-driven syncs. That was a workaround for a design problem, so the GitOps install now uses the External Secrets
  Operator instead (the Secret is not in the chart, so there is nothing for Argo to ignore); the same hashing check still passes.
- **My first two GitOps tests were wrong.** I forced a sync with a patch that replaced the Application's sync
  options, so it silently dropped the setting I was testing, and the password changed. I also deleted a
  PodDisruptionBudget and a NetworkPolicy with one command that treated both names as PDBs, so "restored in
  3 seconds" was a lie. Both are now exercised through the demo with real commits and real deletes.
- **Kyverno needs a moment after its pod is Ready.** Applying the policies right after `helm --wait`
  sometimes failed with "failed calling webhook" because the webhooks were not registered yet. It passed
  once by luck and failed on the next clean build, so `up.sh` now retries the apply.
- **Seeding the Git server needs full history.** `git bundle` refuses a shallow clone, which is what
  `actions/checkout` makes by default, so the e2e job fetches with `fetch-depth: 0`.
- **`helm --wait` does not wait for the Prometheus StatefulSet.** The operator creates it after Helm
  returns, so the smoke test waits for the pods itself.

## Layout

```
app/              Node.js shop API (Prometheus metrics, /health, /ready, graceful shutdown)
charts/shop/      the Helm chart (files/: SLO rules and Grafana dashboard)
tests/            promtool unit tests for the SLO rules, manifests the admission policies must accept or reject
kind/cluster.yaml 3-node cluster, default CNI disabled
platform/         values for Traefik, metrics-server, kube-prometheus-stack, Kyverno and Argo CD; policies/; gitops/ (Application, in-cluster Git server); the load generator
scripts/          up.sh (build everything), demo.sh, smoke.sh, test-rules.sh, scan.sh; the experiments: chaos.sh (+ chaos-load.py,
                  chaos-chart.py), loadtest.sh, rollout-demo.sh, backup-drill.sh, redis-restore-drill.sh
.github/          CI: helm lint, kubeconform (incl. CRD schemas), promtool, hadolint, Trivy scans and SBOM, then an end-to-end run on kind in both install modes (Helm and Argo CD)
```

## Versions

Kubernetes v1.37.0 (kind v0.33), Calico v3.31.0, Traefik chart 42.4.0, metrics-server chart 3.14.0,
kube-prometheus-stack chart 93.3.1, Kyverno chart 3.10.0, Argo CD chart 10.18.0 (Argo CD v3.6), Trivy 0.76.2.

## License

MIT, see [LICENSE](LICENSE).
