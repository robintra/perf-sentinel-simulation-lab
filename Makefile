# perf-sentinel simulation lab Makefile.
# Run `make help` to list targets.

CLUSTER_NAME := perf-sentinel-lab
DAEMON_URL   := http://localhost:14318
GRAFANA_URL  := http://localhost:3000
PERF_SENTINEL_REPO_PATH ?= $(HOME)/RustroverProjects/perf-sentinel
PERF_SENTINEL_LOCAL_BIN := $(PERF_SENTINEL_REPO_PATH)/target/release/perf-sentinel

.DEFAULT_GOAL := help

.PHONY: help up down reset validate smoke status logs grafana inspect psql ps clean-images \
        seed-services teardown-services inject-all validate-findings \
        seed-electricity-maps verify-electricity-maps capture-greenops-screenshot redeploy-services \
        up-gitlab down-gitlab seed-gitlab-project verify-gitlab-perf-sentinel \
        up-cni reset-cni install-cni apply-network-policies remove-network-policies \
        hubble-ui verify-network-policies \
        verify-hybrid-daemon-batch verify-batch-tempo-scrape verify-daemon-otlp-direct \
        verify-multiformat-input verify-calibrate-mode verify-sidecar-pattern \
        verify-correlation-finding verify-pg-stat verify-grafana-dashboard \
        verify-ci-shift-left verify-output-formats-coverage \
        verify-template-gitlab-ci verify-template-jenkinsfile verify-template-github-actions \
        verify-multi-agent-load verify-long-running-drift \
        verify-failure-mode-daemon-restart verify-failure-mode-backend-down \
        verify-failure-mode-network-partition verify-cold-start-edge-cases \
        verify-daemon-ack-workflow \
        seed-scaphandre-mock verify-scaphandre-mock-validation \
        verify-all-scenarios

help: ## List available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  %-32s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

up: ## Bootstrap the cluster (redirects to up-cni since the CNI migration)
	@echo "Note: 'make up' is deprecated since the Cilium CNI migration."
	@echo "      The k3d config disables Flannel and the default network"
	@echo "      policy controller, so plain bootstrap.sh produces NotReady"
	@echo "      nodes. Redirecting to 'make up-cni' which installs Cilium"
	@echo "      first, then runs bootstrap.sh, then applies the zero-trust"
	@echo "      NetworkPolicy."
	@echo
	@$(MAKE) up-cni

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
	  manifests/scaphandre-mock.yaml \
	  cluster/k3d-config.yaml \
	  helm/values/kube-prometheus-stack.yaml \
	  helm/values/otel-collector.yaml
	@echo "==> helm template kube-prometheus-stack"
	@helm template lab-kps prometheus-community/kube-prometheus-stack --version 84.4.0 \
	  -f helm/values/kube-prometheus-stack.yaml >/dev/null
	@echo "==> helm template otel-collector"
	@helm template lab-otel open-telemetry/opentelemetry-collector --version 0.153.0 \
	  -f helm/values/otel-collector.yaml >/dev/null
	@echo "==> json parse on dashboards"
	@python3 -m json.tool < manifests/grafana-dashboards/perf-sentinel-overview.json >/dev/null
	@python3 -m json.tool < manifests/grafana-dashboards/kubernetes-cluster.json >/dev/null
	@echo "==> shell syntax check"
	@bash -n scripts/bootstrap.sh
	@bash -n scripts/teardown.sh
	@bash -n scripts/wait-for-ready.sh
	@bash -n scripts/port-forward.sh
	@bash -n scripts/seed-electricity-maps.sh
	@bash -n scripts/verify-electricity-maps.sh
	@bash -n scripts/capture-greenops-screenshot.sh
	@bash -n scripts/redeploy-services.sh
	@bash -n scripts/capture-trace-fixture.sh
	@bash -n scripts/up-gitlab.sh
	@bash -n scripts/down-gitlab.sh
	@bash -n scripts/seed-gitlab-project.sh
	@bash -n scripts/verify-gitlab-perf-sentinel.sh
	@bash -n scripts/install-cni.sh
	@bash -n scripts/up-cni.sh
	@bash -n scripts/hubble-ui.sh
	@bash -n scripts/verify-network-policies.sh
	@bash -n scenarios/hybrid-daemon-batch/verify.sh
	@bash -n scenarios/batch-tempo-scrape/verify.sh
	@bash -n scenarios/daemon-otlp-direct/verify.sh
	@bash -n scenarios/multiformat-input/verify.sh
	@bash -n scenarios/calibrate-mode/verify.sh
	@bash -n scenarios/sidecar-pattern/verify.sh
	@bash -n scenarios/correlation-finding/verify.sh
	@bash -n scenarios/pg-stat/verify.sh
	@bash -n scenarios/grafana-dashboard/verify.sh
	@bash -n scenarios/multi-agent-load/verify.sh
	@bash -n scenarios/long-running-drift/verify.sh
	@bash -n scenarios/failure-mode-daemon-restart/verify.sh
	@bash -n scenarios/failure-mode-backend-down/verify.sh
	@bash -n scenarios/failure-mode-network-partition/verify.sh
	@bash -n scenarios/cold-start-edge-cases/verify.sh
	@bash -n scenarios/daemon-ack-workflow/verify.sh
	@bash -n scenarios/scaphandre-mock-validation/verify.sh
	@echo "==> yaml parse on resilience scenario manifests"
	@python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" \
	  scenarios/multi-agent-load/manifests.yaml \
	  scenarios/long-running-drift/manifests.yaml \
	  scenarios/failure-mode-network-partition/manifests.yaml
	@echo "==> yaml parse on grafana-dashboard manifests"
	@python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" \
	  scenarios/grafana-dashboard/postgres-exporter.yaml \
	  scenarios/grafana-dashboard/alertrules.yaml
	@echo "==> json parse on grafana-dashboard extended dashboard"
	@python3 -m json.tool < scenarios/grafana-dashboard/dashboard-extended.json >/dev/null
	@echo "==> yaml parse on gitlab-ce values"
	@python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" \
	  helm/values/gitlab-ce.yaml
	@echo "==> yaml parse on network-policies"
	@python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" \
	  manifests/network-policies.yaml
	@echo "validation ok"

smoke: ## Run end-to-end smoke test against the running lab (CI-friendly)
	./scripts/smoke-test.sh

seed-services: ## Build + import + helm install the 3 Java services into shop
	./scripts/seed-services.sh

teardown-services: ## Remove the 3 Java services (cluster stays up)
	./scripts/teardown-services.sh

inject-all: ## Run all 10 k6 scenarios and assert findings (alias of validate-findings)
	./scripts/inject-all.sh

validate-findings: ## Run all 10 k6 scenarios and write tmp/validation-report.md
	./scripts/validate-findings.sh

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
	  --image=postgres@sha256:54451ecb8ab38c24c3ec123f2fd501303a3a1856a5c66e98cecf2460d5e1e9d7 \
	  --env="PGPASSWORD=$$(cat .postgres-password)" \
	  -- psql -h postgres -U lab -d lab

ps: ## docker ps for k3d containers of the lab cluster
	docker ps --filter "label=k3d.cluster=$(CLUSTER_NAME)"

clean-images: ## Remove dangling docker images
	docker image prune -f

seed-electricity-maps: ## Provision the Electricity Maps token Secret from .electricity-maps-token
	./scripts/seed-electricity-maps.sh

verify-electricity-maps: ## Confirm the daemon picked up the Electricity Maps token
	./scripts/verify-electricity-maps.sh

seed-scaphandre-mock: ## Apply the Scaphandre mock manifest (RAPL stand-in for the daemon scrape path)
	@kubectl apply -f manifests/scaphandre-mock.yaml
	@kubectl rollout status deployment/scaphandre-mock -n observability --timeout=120s

capture-greenops-screenshot: ## Capture the daemon report banner to artifacts/greenops-bandeau.png
	./scripts/capture-greenops-screenshot.sh

redeploy-services: ## Re-apply Helm values for the 3 Java services
	./scripts/redeploy-services.sh

up-gitlab: ## Deploy GitLab CE in namespace gitlab-ce (~10 min)
	./scripts/up-gitlab.sh

down-gitlab: ## Tear down GitLab CE
	./scripts/down-gitlab.sh

seed-gitlab-project: ## Bootstrap perf-sentinel-template-test project
	./scripts/seed-gitlab-project.sh

verify-gitlab-perf-sentinel: ## Validate the GitLab CI template end-to-end
	./scripts/verify-gitlab-perf-sentinel.sh

up-cni: ## Bootstrap with Cilium (or Calico) instead of Flannel
	./scripts/up-cni.sh

reset-cni: down up-cni ## Teardown then bootstrap with CNI

install-cni: ## Install Cilium (default) or Calico on a fresh cluster
	./scripts/install-cni.sh

apply-network-policies: ## Apply zero-trust NetworkPolicy
	kubectl apply -f manifests/network-policies.yaml

remove-network-policies: ## Remove NetworkPolicy (debug iteration)
	kubectl delete -f manifests/network-policies.yaml --ignore-not-found

hubble-ui: ## Enable Hubble UI on the active Cilium release
	./scripts/hubble-ui.sh

verify-network-policies: ## Probe the policy contract end-to-end
	./scripts/verify-network-policies.sh

verify-hybrid-daemon-batch: ## daemon Report -> HTML dashboard via report --input
	./scenarios/hybrid-daemon-batch/verify.sh

verify-batch-tempo-scrape: ## batch over Tempo via perf-sentinel tempo subcommand
	./scenarios/batch-tempo-scrape/verify.sh

verify-daemon-otlp-direct: ## services push OTLP straight to a dedicated daemon (no collector)
	./scenarios/daemon-otlp-direct/verify.sh

verify-multiformat-input: ## batch ingests Native + Jaeger + Zipkin coherently
	./scenarios/multiformat-input/verify.sh

verify-calibrate-mode: ## calibrate energy coefficients from baseline traces + power CSV
	./scenarios/calibrate-mode/verify.sh

verify-sidecar-pattern: ## perf-sentinel daemon as a per-service pod sidecar
	./scenarios/sidecar-pattern/verify.sh

verify-correlation-finding: ## cross-trace correlation finding via /api/correlations
	./scenarios/correlation-finding/verify.sh

verify-pg-stat: ## perf-sentinel report --pg-stat live integration
	./scenarios/pg-stat/verify.sh

verify-grafana-dashboard: ## Grafana dashboard import, audit, alerts, postgres-exporter integration
	./scenarios/grafana-dashboard/verify.sh

verify-ci-shift-left: ## CI shift-left workflow (clean / regression / acked) post-0.5.17
	./scenarios/ci-shift-left/verify.sh

verify-output-formats-coverage: ## Output formats, diff mode, signature presence, ack cap loader
	./scenarios/output-formats-coverage/verify.sh

verify-template-gitlab-ci: ## Validate upstream gitlab-ci.yml template via GitLab CE in-cluster
	./scenarios/template-gitlab-ci/verify.sh

verify-template-jenkinsfile: ## Validate upstream jenkinsfile.groovy via jenkinsfile-runner
	./scenarios/template-jenkinsfile/verify.sh

verify-template-github-actions: ## Validate upstream github-actions.yml via nektos/act --list
	./scenarios/template-github-actions/verify.sh

verify-multi-agent-load: ## telemetrygen Job parallel charges the prod daemon
	./scenarios/multi-agent-load/verify.sh

verify-long-running-drift: ## drift accelere 2h (LONG_RUN=1 for 24h leak hunting)
	./scenarios/long-running-drift/verify.sh

verify-failure-mode-daemon-restart: ## kubectl rollout restart while traffic flows
	./scenarios/failure-mode-daemon-restart/verify.sh

verify-failure-mode-backend-down: ## OTel collector / Tempo / Postgres scaled to 0 in turn
	./scenarios/failure-mode-backend-down/verify.sh

verify-failure-mode-network-partition: ## NetworkPolicy ingress isolation of the daemon
	./scenarios/failure-mode-network-partition/verify.sh

verify-cold-start-edge-cases: ## 4 sub-tests of cold-start corner cases
	./scenarios/cold-start-edge-cases/verify.sh

verify-daemon-ack-workflow: ## ack API end-to-end with PVC persistence and 0.5.21 counter asserts
	./scenarios/daemon-ack-workflow/verify.sh

verify-scaphandre-mock-validation: ## Scaphandre scrape path end-to-end against the Python stdlib mock
	./scenarios/scaphandre-mock-validation/verify.sh

verify-all-scenarios: ## Run all 22 scenarios sequentially (see docs/SCENARIOS.md)
	@# Order matters:
	@# - grafana-dashboard before pg-stat so pg-stat detects postgres-exporter
	@#   and exercises Path 2 (--pg-stat-prometheus).
	@# - ci-shift-left before output-formats-coverage because the latter
	@#   reuses /tmp/ci-shift-left/regression-report.json artefacts.
	@# - templates run before the resilience scenarios because they may
	@#   SKIP runtime steps when the GitLab/Jenkins/act environment is
	@#   not fully available.
	@# - resilience scenarios run last: they restart the daemon, scale
	@#   shared backends to 0, and apply temporary NetworkPolicies.
	@#   Running them after the rest avoids polluting earlier scenarios.
	@for s in hybrid-daemon-batch batch-tempo-scrape daemon-otlp-direct multiformat-input calibrate-mode sidecar-pattern correlation-finding grafana-dashboard pg-stat ci-shift-left output-formats-coverage template-gitlab-ci template-jenkinsfile template-github-actions multi-agent-load long-running-drift failure-mode-daemon-restart failure-mode-backend-down failure-mode-network-partition cold-start-edge-cases daemon-ack-workflow scaphandre-mock-validation; do \
	  echo "==> verify-$$s"; \
	  $(MAKE) verify-$$s || echo "$$s FAILED"; \
	done
