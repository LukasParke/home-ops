#!/usr/bin/env bash
# One-time: replace the immutable nfs StorageClass (e.g. after adding subDir in Git).
# Deletes the Homepage Helm release so Helm recreates the PVC cleanly (avoids suspend/PVC drift).
# Requires: kubectl, flux. Run on a host with cluster access.

set -euo pipefail
NS_DEFAULT="${NS_DEFAULT:-default}"

echo "==> Remove Homepage Helm release (uninstalls workload + PVC; Flux will reinstall from Git)"
flux resume helmrelease homepage -n "$NS_DEFAULT" 2>/dev/null || true
kubectl delete helmrelease homepage -n "$NS_DEFAULT" --wait=true --timeout=120s

echo "==> Delete any leftover Homepage PVCs / pods"
kubectl delete pvc -n "$NS_DEFAULT" -l app.kubernetes.io/name=homepage --ignore-not-found --wait=true --timeout=120s || true
for p in $(kubectl get pvc -n "$NS_DEFAULT" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep '^homepage' || true); do
  kubectl delete pvc -n "$NS_DEFAULT" "$p" --wait=true --timeout=120s
done
kubectl delete pods -n "$NS_DEFAULT" -l app.kubernetes.io/name=homepage --ignore-not-found --wait=true --timeout=120s || true

echo "==> Delete StorageClass nfs (Flux will recreate from Git)"
kubectl delete storageclass nfs --ignore-not-found --wait=true --timeout=60s

echo "==> Reconcile Flux: StorageClass then Homepage (recreates HelmRelease)"
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization csi-driver-nfs -n kube-system --with-source
flux reconcile kustomization homepage -n "$NS_DEFAULT" --with-source

echo "==> Wait for HelmRelease Ready (up to ~5m)"
for _ in $(seq 1 60); do
  st=$(kubectl get hr homepage -n "$NS_DEFAULT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$st" == "True" ]] && break
  sleep 5
done

echo "==> Status"
kubectl get storageclass nfs -o wide 2>/dev/null || true
kubectl get pvc -n "$NS_DEFAULT" | grep -E 'NAME|homepage' || true
kubectl get pods -n "$NS_DEFAULT" -l app.kubernetes.io/name=homepage
echo "Done."
