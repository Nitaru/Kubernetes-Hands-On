.PHONY: up down status lint test demo-selfheal demo-rollout demo-autoscale demo-netpol demo-drain load

up:                ## build the cluster, platform and app from scratch
	scripts/up.sh
down:
	kind delete cluster --name hands-on
status:
	kubectl get nodes -o wide
	kubectl get pods -A
lint:              ## offline checks, same as CI
	helm lint charts/shop
	helm template shop charts/shop -n shop | kubeconform -strict -summary -ignore-missing-schemas
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
