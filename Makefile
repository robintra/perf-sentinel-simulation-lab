# perf-sentinel simulation lab Makefile.
# Run `make help` to list targets.

CLUSTER_NAME := perf-sentinel-lab
DAEMON_URL   := http://localhost:14318
GRAFANA_URL  := http://localhost:3000
PERF_SENTINEL_REPO_PATH ?= $(HOME)/RustroverProjects/perf-sentinel
PERF_SENTINEL_LOCAL_BIN := $(PERF_SENTINEL_REPO_PATH)/target/release/perf-sentinel

.DEFAULT_GOAL := help

.PHONY: help up down reset validate smoke status logs grafana inspect psql ps clean-images seed-services teardown-services inject-all validate-findings

help: ## List available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  %-15s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

up: ## Bootstrap the cluster and the full observability stack
	./scripts/bootstrap.sh

down: ## Tear down the cluster
	./scripts/teardown.sh

reset: down up ## Teardown then bootstrap

validate: ## Validate manifests, helm values, dashboards, scripts (no cluster)
	@echo "==> yaml parse on manifests and values"
	@python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" \
	  manifests/namespaces.yaml \
	  manifests/postgres.yaml \
	  manifests/postgres-init-schemas.yaml \
	  manifests/tempo.yaml \
	  manifests/perf-sentinel-daemon.yaml \
	  cluster/k3d-config.yaml \
	  helm/values/kube-prometheus-stack.yaml \
	  helm/values/otel-collector.yaml
	@echo "==> helm template kube-prometheus-stack"
	@helm template lab-kps prometheus-community/kube-prometheus-stack --version 84.1.0 \
	  -f helm/values/kube-prometheus-stack.yaml >/dev/null
	@echo "==> helm template otel-collector"
	@helm template lab-otel open-telemetry/opentelemetry-collector --version 0.152.0 \
	  -f helm/values/otel-collector.yaml >/dev/null
	@echo "==> json parse on dashboards"
	@python3 -m json.tool < manifests/grafana-dashboards/perf-sentinel-overview.json >/dev/null
	@python3 -m json.tool < manifests/grafana-dashboards/kubernetes-cluster.json >/dev/null
	@echo "==> shell syntax check"
	@bash -n scripts/bootstrap.sh
	@bash -n scripts/teardown.sh
	@bash -n scripts/wait-for-ready.sh
	@bash -n scripts/port-forward.sh
	@echo "validation ok"

smoke: ## Run end-to-end smoke test against the running lab (CI-friendly)
	./scripts/smoke-test.sh

seed-services: ## Build + import + helm install the 3 Java services into shop
	./scripts/seed-services.sh

teardown-services: ## Remove the 3 Java services (cluster stays up)
	./scripts/teardown-services.sh

status: ## Curl-only status of cluster + perf-sentinel daemon endpoints
	@echo "==> Pods overview"
	@kubectl get pods -A 2>/dev/null || echo "kubectl not connected to cluster"
	@echo
	@echo "==> Daemon /api/status"
	@curl -fsS $(DAEMON_URL)/api/status | python3 -m json.tool || echo "daemon not reachable"
	@echo
	@echo "==> Daemon /api/findings (count)"
	@curl -fsS $(DAEMON_URL)/api/findings | python3 -c "import sys, json; d=json.load(sys.stdin); print('findings:', len(d) if isinstance(d, list) else d)" || true
	@echo
	@echo "==> Daemon /api/correlations (count)"
	@curl -fsS $(DAEMON_URL)/api/correlations | python3 -c "import sys, json; d=json.load(sys.stdin); print('correlations:', len(d) if isinstance(d, list) else d)" || true

logs: ## Tail logs of the observability namespace
	kubectl -n observability logs -l app.kubernetes.io/part-of=perf-sentinel-lab --all-containers --tail=200 -f || \
	kubectl -n observability logs --all-containers --tail=200 -f deployment/perf-sentinel-daemon

grafana: ## Open Grafana in the default browser
	@echo "Grafana: $(GRAFANA_URL)  (admin / admin)"
	@open $(GRAFANA_URL) 2>/dev/null || xdg-open $(GRAFANA_URL) 2>/dev/null || true

inspect: ## Launch the perf-sentinel TUI against the local daemon
	@if [ -x "$(PERF_SENTINEL_LOCAL_BIN)" ]; then \
		echo "==> using $(PERF_SENTINEL_LOCAL_BIN)"; \
		"$(PERF_SENTINEL_LOCAL_BIN)" query inspect --daemon-url $(DAEMON_URL); \
	elif command -v perf-sentinel >/dev/null 2>&1; then \
		echo "==> using perf-sentinel from PATH"; \
		perf-sentinel query inspect --daemon-url $(DAEMON_URL); \
	else \
		echo "TUI requires the perf-sentinel binary."; \
		echo "Install via cargo install (--path \$$PERF_SENTINEL_REPO_PATH/crates/sentinel-cli)"; \
		echo "or build from source: cd \$$PERF_SENTINEL_REPO_PATH && cargo build --release -p sentinel-cli"; \
		echo "or override PERF_SENTINEL_REPO_PATH if your perf-sentinel checkout is elsewhere."; \
		exit 1; \
	fi

psql: ## Open a psql shell against the lab database (uses .postgres-password)
	@if [ ! -f .postgres-password ]; then \
		echo "missing .postgres-password. Run 'make up' first."; \
		exit 1; \
	fi
	kubectl run -n db psql-shell --rm -it --restart=Never \
	  --image=postgres:18.3-alpine \
	  --env="PGPASSWORD=$$(cat .postgres-password)" \
	  -- psql -h postgres -U lab -d lab

ps: ## docker ps for k3d containers of the lab cluster
	docker ps --filter "label=k3d.cluster=$(CLUSTER_NAME)"

clean-images: ## Remove dangling docker images
	docker image prune -f
