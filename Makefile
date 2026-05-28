# Home-ops cluster helpers (kubectl + Flux). Requires kubectl; jq recommended.
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS := $(REPO_ROOT)/scripts

.DEFAULT_GOAL := help

.PHONY: help monitor monitor-watch app-errors reconcile reconcile-hr reconcile-ks nfs-triage nfs-probe nfs-patch-pvs

help:
	@echo "Targets:"
	@echo "  make monitor              Flux KS/HR health, Git source; groups identical error lines to find one root cause."
	@echo "  make monitor-watch       Same as monitor every 8s (needs watch(1))."
	@echo "  make nfs-triage          CSI NFS + not-Ready HRs + PVC pods (add RECONCILE=1 to also flux reconcile)."
	@echo "  make nfs-probe           Temporary DaemonSet probe: verifies every node can mount/write the NFS export."
	@echo "  make nfs-patch-pvs       Patch existing NFS PV mountOptions (set DRY_RUN=none to apply; default server dry-run)."
	@echo "  make app-errors APP=name Describe KS/HR + warnings/events/pods for that app name."
	@echo "  make reconcile                              Pull git + reconcile cluster-apps (full app tree)."
	@echo "  make reconcile-hr APP=name NS=namespace      flux reconcile helmrelease (needs flux CLI)."
	@echo "  make reconcile-ks APP=name NS=namespace       flux reconcile kustomization."
	@echo ""
	@echo "Examples:"
	@echo "  make reconcile"
	@echo "  make monitor"
	@echo "  make nfs-triage                 # or: make nfs-triage RECONCILE=1"
	@echo "  make nfs-probe"
	@echo "  make nfs-patch-pvs              # or: make nfs-patch-pvs DRY_RUN=none"
	@echo "  make app-errors APP=forgejo"
	@echo "  make reconcile-hr APP=forgejo NS=forgejo"

nfs-triage:
	@opts=""; [ "$(RECONCILE)" = "1" ] && opts="--reconcile" || true; \
	bash "$(SCRIPTS)/flux-nfs-triage.sh" $$opts

nfs-probe:
	@bash "$(SCRIPTS)/nfs-node-probe.sh"

nfs-patch-pvs:
	@DRY_RUN="$(or $(DRY_RUN),server)" PHASE_SELECTOR="$(or $(PHASE_SELECTOR),all)" bash "$(SCRIPTS)/patch-nfs-pv-mount-options.sh"

monitor:
	@bash "$(SCRIPTS)/flux-monitor.sh"

monitor-watch:
	@command -v watch >/dev/null || { echo "Install watch (procps) or run: watch -n8 make monitor" >&2; exit 1; }
	@watch -n8 "$(MAKE)" -f "$(REPO_ROOT)/Makefile" monitor

app-errors:
	@if [ -z "$(APP)" ]; then echo "Set APP= (e.g. APP=forgejo)" >&2; exit 1; fi
	@bash "$(SCRIPTS)/flux-app-errors.sh" "$(APP)"

reconcile:
	@command -v flux >/dev/null || { echo "flux CLI required" >&2; exit 1; }
	flux reconcile kustomization cluster-apps -n flux-system --with-source

reconcile-hr:
	@if [ -z "$(APP)" ] || [ -z "$(NS)" ]; then echo "Set APP=helmrelease-name NS=namespace (kubectl get hr -A)" >&2; exit 1; fi
	@command -v flux >/dev/null || { echo "flux CLI required" >&2; exit 1; }
	flux reconcile helmrelease "$(APP)" -n "$(NS)"

reconcile-ks:
	@if [ -z "$(APP)" ] || [ -z "$(NS)" ]; then echo "Set APP=kustomization-name NS=namespace (kubectl get ks -A)" >&2; exit 1; fi
	@command -v flux >/dev/null || { echo "flux CLI required" >&2; exit 1; }
	flux reconcile kustomization "$(APP)" -n "$(NS)"
