#!/usr/bin/env bash
# High-level Flux reconcile / Helm health: surfaces anything not Ready.
set -euo pipefail

need_kubectl() {
	command -v kubectl >/dev/null 2>&1 || {
		echo "kubectl not found in PATH" >&2
		exit 1
	}
}

have_jq() {
	command -v jq >/dev/null 2>&1
}

section() {
	printf '\n%s\n' "$1"
}

need_kubectl

if ! have_jq; then
	section "=== Kustomizations (all) — install jq for Ready filtering ==="
	kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o wide 2>/dev/null || kubectl get ks -A -o wide
	section "=== HelmReleases (all) ==="
	kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o wide 2>/dev/null || kubectl get hr -A -o wide
	exit 0
fi

problem_ks=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq '[.items[] | . as $item | ($item.status.conditions // []) | map(select(.type=="Ready")) | first as $r | select(($r == null) or ($r.status != "True")) | "\($item.metadata.namespace)/\($item.metadata.name)"]')
problem_hr=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json | jq '[.items[] | . as $item | ($item.status.conditions // []) | map(select(.type=="Ready")) | first as $r | select(($r == null) or ($r.status != "True")) | "\($item.metadata.namespace)/\($item.metadata.name)"]')

ks_count=$(echo "$problem_ks" | jq 'length')
hr_count=$(echo "$problem_hr" | jq 'length')

SKIP_PROBLEM_DETAIL=0
if [[ "$ks_count" -eq 0 && "$hr_count" -eq 0 ]]; then
	echo "OK — all Flux Kustomizations and HelmReleases report Ready=True."
	SKIP_PROBLEM_DETAIL=1
else
	echo "Attention — ${ks_count} Kustomization(s), ${hr_count} HelmRelease(s) not Ready:"
	echo "$problem_ks" | jq -r '.[]' | sed 's/^/  ks  /'
	echo "$problem_hr" | jq -r '.[]' | sed 's/^/  hr  /'
fi

if [[ "$SKIP_PROBLEM_DETAIL" -eq 1 ]]; then
	section "=== GitRepository (flux-system source health) ==="
	kubectl get gitrepository.source.toolkit.fluxcd.io -n flux-system -o json 2>/dev/null | jq -r '
	  def ready: (.status.conditions // []) | map(select(.type=="Ready")) | first;
	  .items[]?
	  | . as $item
	  | ready as $r
	  | select(($r == null) or ($r.status != "True"))
	  | "[\($item.metadata.name)] ready=\($r.status // "?") msg=\(($r.message // "") | gsub("\\n"; " "))"
	' || echo "(no GitRepository in flux-system or not accessible)"
	echo ""
	exit 0
fi

section "=== Kustomizations — grouped blocker message (same issue → one line) ==="
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq -r '
	def ready: (.status.conditions // []) | map(select(.type=="Ready")) | first;
	def suspended: (.spec.suspend // false);
	
	[
		.items[]
		| . as $item
		| suspended as $sus
		| ready as $r
		| select(($sus == true) or ($r == null) or ($r.status != "True"))
		| {
				ref: "\($item.metadata.namespace)/\($item.metadata.name)",
				rs: ($r.status // "?"),
				msg: (($r.message // "") | gsub("[\\r\\n]+"; " "))
			}
	]
	| group_by(.msg)
	| sort_by(-length)
	| .[]
	| . as $g
	| ($g | length) as $n
	| ($g | map(.ref)) as $refs
	| ($refs | length) as $total
	| ($refs | if $total > 14 then (.[0:14] | join(", ")) + " (+\($total - 14) more)" else join(", ") end) as $refstr
	| "\n(\($n)×) [\($g[0].rs)] \($g[0].msg)\n  → \($refstr)"
'

section "=== HelmReleases — grouped failure message ==="
kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json | jq -r '
	def ready: (.status.conditions // []) | map(select(.type=="Ready")) | first;
	def suspended: (.spec.suspend // false);
	
	[
		.items[]
		| . as $item
		| suspended as $sus
		| ready as $r
		| select(($sus == true) or ($r == null) or ($r.status != "True"))
		| {
				ref: "\($item.metadata.namespace)/\($item.metadata.name)",
				rs: ($r.status // "?"),
				msg: (($r.message // "") | gsub("[\\r\\n]+"; " "))
			}
	]
	| group_by(.msg)
	| sort_by(-length)
	| .[]
	| . as $g
	| ($g | length) as $n
	| ($g | map(.ref)) as $refs
	| ($refs | length) as $total
	| ($refs | if $total > 14 then (.[0:14] | join(", ")) + " (+\($total - 14) more)" else join(", ") end) as $refstr
	| "\n(\($n)×) [\($g[0].rs)] \($g[0].msg)\n  → \($refstr)"
'

section "=== Kustomizations (detail: not Ready or suspended) ==="
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq -r '
  def ready: (.status.conditions // []) | map(select(.type=="Ready")) | first;
  .items[]
  | . as $item
  | ($item.spec.suspend // false) as $sus
  | ready as $r
  | select(($sus == true) or ($r == null) or ($r.status != "True"))
  | "[\($item.metadata.namespace)/\($item.metadata.name)] suspend=\($sus) ready=\($r.status // "unknown") msg=\(($r.message // "") | gsub("\\n"; " "))"
'

section "=== HelmReleases (detail: not Ready or suspended) ==="
kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json | jq -r '
  def ready: (.status.conditions // []) | map(select(.type=="Ready")) | first;
  .items[]
  | . as $item
  | ($item.spec.suspend // false) as $sus
  | ready as $r
  | select(($sus == true) or ($r == null) or ($r.status != "True"))
  | "[\($item.metadata.namespace)/\($item.metadata.name)] suspend=\($sus) ready=\($r.status // "unknown") msg=\(($r.message // "") | gsub("\\n"; " "))"
'

section "=== GitRepository (flux-system source health) ==="
kubectl get gitrepository.source.toolkit.fluxcd.io -n flux-system -o json 2>/dev/null | jq -r '
  def ready: (.status.conditions // []) | map(select(.type=="Ready")) | first;
  .items[]?
  | . as $item
  | ready as $r
  | select(($r == null) or ($r.status != "True"))
  | "[\($item.metadata.name)] ready=\($r.status // "?") msg=\(($r.message // "") | gsub("\\n"; " "))"
' || echo "(no GitRepository in flux-system or not accessible)"

echo ""
