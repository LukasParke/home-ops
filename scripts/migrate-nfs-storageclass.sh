#!/usr/bin/env bash
# One-time: apply new nfs StorageClass parameters (subDir) after Git already has the change.
# Requires: kubectl, flux; kubeconfig with cluster access. Destroys Homepage PVC data in-cluster.

set -euo pipefail
NS_DEFAULT="${NS_DEFAULT:-default}"

echo "==> Suspend Homepage HelmRelease so pods stay down while the PVC is deleted"
flux suspend helmrelease homepage -n "$NS_DEFAULT"

echo "==> Delete Homepage pods and PVCs in $NS_DEFAULT"
kubectl delete pods -n "$NS_DEFAULT" -l app.kubernetes.io/name=homepage --ignore-not-found --wait=true --timeout=120s || true
for p in $(kubectl get pvc -n "$NS_DEFAULT" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep '^homepage' || true); do
  kubectl delete pvc -n "$NS_DEFAULT" "$p" --wait=true --timeout=120s
done

echo "==> Deleting StorageClass nfs (Flux will recreate from Git)"
kubectl delete storageclass nfs --ignore-not-found --wait=true --timeout=60s

echo "==> Reconcile Flux (csi-driver-nfs applies StorageClass; homepage recreates PVC)"
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization csi-driver-nfs -n kube-system --with-source

echo "==> Resume Homepage and reconcile"
flux resume helmrelease homepage -n "$NS_DEFAULT"
flux reconcile kustomization homepage -n "$NS_DEFAULT" --with-source

echo "==> Status"
kubectl get storageclass nfs -o wide 2>/dev/null || true
kubectl get pvc -n "$NS_DEFAULT"
kubectl get pods -n "$NS_DEFAULT" -l app.kubernetes.io/name=homepage
echo "Done."
