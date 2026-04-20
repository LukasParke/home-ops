#!/usr/bin/env bash
# Drill into one app: Flux Kustomization / HelmRelease / workload namespace.
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
	echo "Usage: $0 <name>" >&2
	echo "  name = Flux Kustomization metadata.name (e.g. gitlab, gatus) or HelmRelease name." >&2
	exit 1
fi

need_kubectl() {
	command -v kubectl >/dev/null 2>&1 || {
		echo "kubectl not found in PATH" >&2
		exit 1
	}
}

have_jq() {
	command -v jq >/dev/null 2>&1
}

need_kubectl

KS_JSON=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json 2>/dev/null || echo '{"items":[]}')
HR_JSON=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json 2>/dev/null || echo '{"items":[]}')

find_hr() {
	if have_jq; then
		echo "$HR_JSON" | jq -r --arg n "$APP" '.items[] | select(.metadata.name==$n) | "\(.metadata.namespace) \(.metadata.name)"' | head -1
	else
		kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | awk -v app="$APP" '$2 == app { print $1 " " $2; exit }'
	fi
}

section() {
	printf '\n━━ %s ━━\n' "$1"
}

found=false
FOUND_VIA_KS=false

describe_from_ks() {
	local ks_ns="$1"
	local ks_name="$2"
	local target_ns="$3"

	section "Flux Kustomization: ${ks_ns}/${ks_name}"
	kubectl describe kustomizations.kustomize.toolkit.fluxcd.io "$ks_name" -n "$ks_ns" | tail -60

	section "HelmReleases (namespace ${target_ns})"
	kubectl get helmreleases.helm.toolkit.fluxcd.io -n "$target_ns" -o wide 2>/dev/null || echo "(none or no access)"

	section "Pods (namespace ${target_ns}, not Completed/Succeeded)"
	kubectl get pods -n "$target_ns" --no-headers 2>/dev/null | awk '$3 != "Completed" && $3 != "Succeeded"' || true

	section "Recent Warning events (namespace ${target_ns})"
	kubectl get events -n "$target_ns" --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -35 || true
}

if have_jq; then
	mapfile -t KS_PARTS < <(
		echo "$KS_JSON" | jq -r --arg n "$APP" '
			(.items[] | select(.metadata.name == $n)) |
			.metadata.namespace,
			.metadata.name,
			(.spec.targetNamespace // .metadata.namespace)
		' | head -3
	)
	if [[ ${#KS_PARTS[@]} -eq 3 ]]; then
		KS_NS="${KS_PARTS[0]}"
		KS_NAME="${KS_PARTS[1]}"
		TARGET_NS="${KS_PARTS[2]}"
		found=true
		FOUND_VIA_KS=true
		describe_from_ks "$KS_NS" "$KS_NAME" "$TARGET_NS"
	fi
else
	while read -r ks_ns ks_name _; do
		if [[ "$ks_name" != "$APP" ]]; then
			continue
		fi
		target_ns=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io "$ks_name" -n "$ks_ns" -o jsonpath='{.spec.targetNamespace}' 2>/dev/null || true)
		if [[ -z "$target_ns" ]]; then
			target_ns="$ks_ns"
		fi
		KS_NS="$ks_ns"
		KS_NAME="$ks_name"
		TARGET_NS="$target_ns"
		found=true
		FOUND_VIA_KS=true
		describe_from_ks "$KS_NS" "$KS_NAME" "$TARGET_NS"
		break
	done < <(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2>/dev/null || true)
fi

if [[ "$found" != true ]]; then
	HR_LINE=$(find_hr || true)
	if [[ -n "$HR_LINE" ]]; then
		HR_NS=$(echo "$HR_LINE" | awk '{print $1}')
		HR_NAME=$(echo "$HR_LINE" | awk '{print $2}')
		found=true

		section "HelmRelease: ${HR_NS}/${HR_NAME}"
		kubectl describe helmreleases.helm.toolkit.fluxcd.io "$HR_NAME" -n "$HR_NS" | tail -80

		TARGET_NS="$HR_NS"

		section "Pods (namespace ${TARGET_NS}, not Completed/Succeeded)"
		kubectl get pods -n "$TARGET_NS" --no-headers 2>/dev/null | awk '$3 != "Completed" && $3 != "Succeeded"' || true

		section "Recent Warning events (namespace ${TARGET_NS})"
		kubectl get events -n "$TARGET_NS" --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -35 || true
	fi
fi

if [[ "$found" != true ]]; then
	echo "Could not find a Kustomization or HelmRelease named '${APP}'." >&2
	echo "Try: kubectl get ks -A | grep -i ${APP}; kubectl get hr -A | grep -i ${APP}" >&2
	exit 1
fi

section "Flux controller log lines mentioning '${APP}'"
for deploy in kustomize-controller helm-controller; do
	if ! kubectl get deployment -n flux-system "$deploy" &>/dev/null; then
		continue
	fi
	out=$(kubectl logs -n flux-system "deployment/$deploy" --tail=250 2>/dev/null | grep -Fi "$APP" | tail -25 || true)
	if [[ -n "$out" ]]; then
		echo "--- ${deploy} ---"
		echo "$out"
	fi
done

if [[ "$FOUND_VIA_KS" == true ]] && command -v flux >/dev/null 2>&1; then
	section "flux tree (${KS_NS}/${KS_NAME})"
	flux tree kustomization "$KS_NAME" -n "$KS_NS" 2>/dev/null || flux tree ks "$KS_NAME" -n "$KS_NS" 2>/dev/null || true
fi
