# Home-ops cluster helpers (kubectl + Flux). Requires kubectl; jq recommended.
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS := $(REPO_ROOT)/scripts

.DEFAULT_GOAL := help

.PHONY: help monitor monitor-watch app-errors reconcile-hr reconcile-ks

help:
	@echo "Targets:"
	@echo "  make monitor              Flux KS/HR health, Git source; groups identical error lines to find one root cause."
	@echo "  make monitor-watch       Same as monitor every 8s (needs watch(1))."
	@echo "  make app-errors APP=name Describe KS/HR + warnings/events/pods for that app name."
	@echo "  make reconcile-hr APP=name NS=namespace      flux reconcile helmrelease (needs flux CLI)."
	@echo "  make reconcile-ks APP=name NS=namespace       flux reconcile kustomization."
	@echo ""
	@echo "Examples:"
	@echo "  make monitor"
	@echo "  make app-errors APP=gitlab"
	@echo "  make reconcile-hr APP=gitlab NS=gitlab"

monitor:
	@bash "$(SCRIPTS)/flux-monitor.sh"

monitor-watch:
	@command -v watch >/dev/null || { echo "Install watch (procps) or run: watch -n8 make monitor" >&2; exit 1; }
	@watch -n8 "$(MAKE)" -f "$(REPO_ROOT)/Makefile" monitor

app-errors:
	@if [ -z "$(APP)" ]; then echo "Set APP= (e.g. APP=gitlab)" >&2; exit 1; fi
	@bash "$(SCRIPTS)/flux-app-errors.sh" "$(APP)"

reconcile-hr:
	@if [ -z "$(APP)" ] || [ -z "$(NS)" ]; then echo "Set APP=helmrelease-name NS=namespace (kubectl get hr -A)" >&2; exit 1; fi
	@command -v flux >/dev/null || { echo "flux CLI required" >&2; exit 1; }
	flux reconcile helmrelease "$(APP)" -n "$(NS)"

reconcile-ks:
	@if [ -z "$(APP)" ] || [ -z "$(NS)" ]; then echo "Set APP=kustomization-name NS=namespace (kubectl get ks -A)" >&2; exit 1; fi
	@command -v flux >/dev/null || { echo "flux CLI required" >&2; exit 1; }
	flux reconcile kustomization "$(APP)" -n "$(NS)"
