#!/usr/bin/env bash
# Plan: storage / NFS / Flux triage (csi-driver-nfs gate + PVC workload health + optional reconciles).
# Run from a host with working kubectl (e.g. same network as API server as 10.10.10.59:6443).
set -euo pipefail

RECONCILE=false
if [[ "${1:-}" == "--reconcile" || "${1:-}" == "-r" ]]; then
	RECONCILE=true
fi

section() { printf '\n=== %s ===\n' "$1"; }
sub() { printf '\n-- %s\n' "$1"; }

need_kubectl() {
	command -v kubectl >/dev/null 2>&1 || {
		echo "kubectl not found in PATH" >&2
		exit 1
	}
}

have_jq() { command -v jq >/dev/null 2>&1; }

ks_ready() {
	local ns=$1
	local name=$2
	local out
	if have_jq; then
		out=$(
			kubectl get kustomizations.kustomize.toolkit.fluxcd.io "$name" -n "$ns" -o json 2>/dev/null | jq -r '
				(.status.conditions // []) | map(select(.type=="Ready")) | first
				| (if . == null then "False" else .status end)
			' 2>/dev/null
		) || out="False"
		echo "${out:-False}"
	else
		kubectl get kustomizations.kustomize.toolkit.fluxcd.io "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False"
	fi
}

need_kubectl

# Avoid long hangs when the API is down or unroutable
kubectl() { command kubectl --request-timeout=30s "$@"; }

# --- 1) CSI driver gate (Kustomization + HelmRelease + pods) ---
section "1) csi-driver-nfs (kube-system) — Kustomization / HelmRelease / StorageClass"
kubectl get kustomizations.kustomize.toolkit.fluxcd.io csi-driver-nfs -n kube-system -o wide 2>&1 || true
sub "Kustomization conditions (csi-driver-nfs)"
if have_jq; then
	kubectl get kustomizations.kustomize.toolkit.fluxcd.io csi-driver-nfs -n kube-system -o json 2>/dev/null | jq '.status.conditions' || true
else
	kubectl describe kustomizations.kustomize.toolkit.fluxcd.io csi-driver-nfs -n kube-system 2>&1 | tail -40 || true
fi
sub "HelmRelease csi-driver-nfs"
kubectl get helmreleases.helm.toolkit.fluxcd.io csi-driver-nfs -n kube-system -o wide 2>&1 || true
kubectl describe helmreleases.helm.toolkit.fluxcd.io csi-driver-nfs -n kube-system 2>&1 | tail -50 || true
sub "Pods (CSI NFS / nfs in name)"
kubectl get pods -n kube-system -o wide 2>&1 | grep -Ei 'nfs|csi-driver' || echo "(no matching pod lines)"
kubectl get pods -n kube-system -l 'app in (csi-nfs-node,csi-nfs-controller)' 2>&1 || true
kubectl get daemonset,deployment -n kube-system 2>&1 | grep -Ei 'nfs|csi' || true
sub "StorageClass nfs"
kubectl get storageclass nfs -o wide 2>&1 || true
sub "Recent Warning events (kube-system, last 20)"
kubectl get events -n kube-system --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true

CSI_KS_READY=$(ks_ready kube-system csi-driver-nfs)
if [[ "$CSI_KS_READY" == "True" ]]; then
	echo ""
	echo "csi-driver-nfs Kustomization Ready=True — Flux gate for dependsOn is satisfied."
else
	echo ""
	echo "WARNING: csi-driver-nfs Kustomization is not Ready=True (got: ${CSI_KS_READY})."
	echo "  Fix controller/node pods, Helm, or image pulls before dependent apps can reconcile."
fi

# --- 2) Not-Ready HelmReleases + PVCs (Failed / InProgress workloads) ---
section "2) Not-Ready HelmReleases + problem pods + nfs PVCs"

if have_jq; then
	sub "Not-Ready HelmReleases (namespace/name)"
	kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json | jq -r '
		.items[] | . as $item
		| ($item.status.conditions // []) | map(select(.type=="Ready")) | first as $r
		| select(($r == null) or ($r.status != "True"))
		| "\($item.metadata.namespace) \($item.metadata.name) ready=\($r.status // "?")"
	' || true
else
	kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o wide || true
fi

sub "PVCs using StorageClass nfs (all namespaces)"
if have_jq; then
	kubectl get pvc -A -o json 2>/dev/null | jq -r '
		.items[] | select(.spec.storageClassName == "nfs" or .spec.storageClassName == "nfs-csi")
		| "\(.metadata.namespace)\t\(.metadata.name)\t\(.status.phase)\t\(.spec.storageClassName // "∅")"
	' | column -t -s $'\t' 2>/dev/null || true
else
	kubectl get pvc -A -o wide || true
fi

# Drill into each namespace that has a triage set from the monitor; focus on not-Ready pods
TRIAGE_NAMESPACES="default gitlab"
for NS in $TRIAGE_NAMESPACES; do
	if ! kubectl get namespace "$NS" &>/dev/null; then
		continue
	fi
	sub "Namespace ${NS} — non-Running / non-Succeeded pods"
	kubectl get pods -n "$NS" -o wide 2>&1 | awk 'NR==1 || ($3 != "Running" && $3 != "Completed" && $3 != "Succeeded")' || true
	if have_jq; then
		PROBLEM_PODS=$(
			kubectl get pods -n "$NS" -o json 2>/dev/null | jq -r '
				.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded" and .status.phase != "Completed")
				| .metadata.name
			' 2>/dev/null | head -8
		)
	else
		PROBLEM_PODS=$(
			kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Succeeded" && $3 != "Completed" { print $1 }' | head -8
		)
	fi
	if [[ -n "${PROBLEM_PODS:-}" ]]; then
		for POD in $PROBLEM_PODS; do
			sub "describe pod ${NS}/${POD} (events + conditions)"
			kubectl describe pod "$POD" -n "$NS" 2>&1 | tail -80
		done
	fi
done

# --- 3) Optional: reconcile CSI then dependents (flux CLI) ---
if [[ "$RECONCILE" == true ]]; then
	section "3) flux reconcile (csi-driver-nfs + dependent Kustomizations)"
	if ! command -v flux &>/dev/null; then
		echo "flux CLI not found; install flux to use --reconcile" >&2
		exit 1
	fi
	flux reconcile source git flux-system -n flux-system
	flux reconcile kustomization csi-driver-nfs -n kube-system --with-source
	echo "Reconciling Kustomizations that depend on csi-driver-nfs (from repo)..."
	# default/
	for K in ghostfolio home-assistant homepage immich lidarr prowlarr radarr sonarr tautulli termix vaultwarden; do
		flux reconcile kustomization "$K" -n default --with-source || true
	done
	# gitlab
	flux reconcile kustomization gitlab -n gitlab --with-source || true
	# gatus: not in csi dependsOn but often failed alongside these rollouts
	flux reconcile kustomization gatus -n default --with-source || true
	section "Done. Re-run: make monitor"
else
	section "3) Reconcile skipped (run: $0 --reconcile after fixing CSI / storage)"
fi

section "Triage complete"
