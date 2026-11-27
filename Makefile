.PHONY: rollout-demo redis-restore-drill backup-drill loadtest chaos chaos-podkill chaos-drain chaos-redis chaos-redisdown chaos-baddeploy chaos-netpol up-gitops argocd-password demo-gitops demo-policy scan sbom grafana-password test-rules demo-slo up down status lint test demo-selfheal demo-rollout demo-autoscale demo-netpol demo-drain load

up:                ## build the cluster, platform and app from scratch
	scripts/up.sh
down:
	kind delete cluster --name hands-on
status:
	kubectl get nodes -o wide
	kubectl get pods -A
lint:              ## offline checks, same as CI
	helm lint charts/shop
	helm template shop charts/shop -n shop | kubeconform -strict -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
	helm template shop charts/shop -n shop --set redisPassword.source=externalSecrets | kubeconform -ignore-missing-schemas -strict -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
	helm template shop charts/shop -n shop --set redisPassword.source=externalSecrets --set rollout.enabled=true | kubeconform -ignore-missing-schemas -strict -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
	scripts/test-rules.sh
test:              ## smoke test against the running cluster
	scripts/smoke.sh

demo-selfheal:
	scripts/demo.sh selfheal
demo-rollout:
	scripts/demo.sh rollout
demo-autoscale:
	scripts/demo.sh autoscale
demo-netpol:
	scripts/demo.sh netpol
demo-drain:
	scripts/demo.sh drain

demo-slo:
	scripts/demo.sh slo

grafana-password:  ## print the Grafana admin password (user: admin, http://grafana.localtest.me:8080)
	@kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo

scan:              ## Trivy: image CVEs, Dockerfile and chart misconfigurations, secrets (builds the image first)
	docker build -q -t shop-api:dev app
	scripts/scan.sh all
sbom:
	docker build -q -t shop-api:dev app
	scripts/scan.sh sbom

demo-policy:
	scripts/demo.sh policy

up-gitops:         ## like `make up`, but Argo CD deploys the app from Git (GITOPS_REPO=<url> to use GitHub)
	GITOPS=1 scripts/up.sh
argocd-password:   ## print the Argo CD admin password (user: admin, http://argocd.localtest.me:8080)
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
demo-gitops:
	scripts/demo.sh gitops

chaos:             ## all six chaos experiments, needs `make up-gitops` (hypotheses: docs/chaos-experiments.md)
	scripts/chaos.sh all
chaos-podkill:
	scripts/chaos.sh podkill
chaos-drain:
	scripts/chaos.sh drain
chaos-redis:
	scripts/chaos.sh redis
chaos-redisdown:
	scripts/chaos.sh redisdown
chaos-baddeploy:
	scripts/chaos.sh baddeploy
chaos-netpol:
	scripts/chaos.sh netpol

loadtest:          ## measure the autoscaling: predictions in docs/loadtest.md, needs a running cluster
	scripts/loadtest.sh

backup-drill:      ## back up Redis's volume with Velero and restore it into a second namespace (docs/backup-restore.md)
	scripts/backup-drill.sh

redis-restore-drill: ## back up Redis with redis-cli --rdb, delete its volume, restore, compare (docs/backup-restore.md part 2)
	scripts/redis-restore-drill.sh

rollout-demo:      ## canary releases with an automatic analysis: a good one is promoted, a bad one aborts itself (docs/progressive-delivery.md)
	scripts/rollout-demo.sh
