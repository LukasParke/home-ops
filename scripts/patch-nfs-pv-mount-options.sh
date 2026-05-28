#!/usr/bin/env bash
# Patch existing NFS CSI PV mount options to match the repo StorageClass.
#
# StorageClass mountOptions only affect newly provisioned PVs. Existing PVs keep
# the options they were created with until patched or recreated.
set -euo pipefail

OPTIONS='["nfsvers=4.1","proto=tcp","hard","timeo=600","retrans=2","noresvport"]'
DRY_RUN="${DRY_RUN:-server}"
PHASE_SELECTOR="${PHASE_SELECTOR:-Bound}"

need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "$1 not found in PATH" >&2
		exit 1
	}
}

need kubectl
need jq

echo "Patching nfs PV mountOptions to: ${OPTIONS}"
echo "DRY_RUN=${DRY_RUN} PHASE_SELECTOR=${PHASE_SELECTOR}"

kubectl get pv -o json | jq -r --arg phase "$PHASE_SELECTOR" '
	.items[]
	| select(.spec.storageClassName == "nfs")
	| select($phase == "all" or .status.phase == $phase)
	| .metadata.name
' | while read -r pv; do
	[[ -z "$pv" ]] && continue
	if [[ "$DRY_RUN" == "none" ]]; then
		echo "patch ${pv}"
		kubectl patch pv "$pv" --type merge -p "{\"spec\":{\"mountOptions\":${OPTIONS}}}"
	else
		echo "dry-run patch ${pv}"
		kubectl patch pv "$pv" --type merge --dry-run="$DRY_RUN" -p "{\"spec\":{\"mountOptions\":${OPTIONS}}}" >/dev/null
	fi
done

echo "Done."
