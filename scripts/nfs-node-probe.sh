#!/usr/bin/env bash
# Verify every Linux node can mount and write to the NFS export used by the nfs StorageClass.
set -euo pipefail

NS="${NS:-default}"
NAME="${NAME:-nfs-node-probe}"
IMAGE="${IMAGE:-docker.io/library/busybox:1.36}"
TIMEOUT="${TIMEOUT:-180s}"
KEEP="${KEEP:-0}"

need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "$1 not found in PATH" >&2
		exit 1
	}
}

need kubectl

SERVER="${SERVER:-$(kubectl get storageclass nfs -o jsonpath='{.parameters.server}')}"
SHARE="${SHARE:-$(kubectl get storageclass nfs -o jsonpath='{.parameters.share}')}"

if [[ -z "$SERVER" || -z "$SHARE" ]]; then
	echo "Could not read nfs StorageClass server/share" >&2
	exit 1
fi

cleanup() {
	if [[ "$KEEP" != "1" ]]; then
		kubectl delete daemonset "$NAME" -n "$NS" --ignore-not-found --wait=true --timeout=60s >/dev/null || true
	fi
}
trap cleanup EXIT

echo "Probing NFS export ${SERVER}:${SHARE} from every Linux node"

kubectl apply -n "$NS" -f - <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${NAME}
  labels:
    app.kubernetes.io/name: ${NAME}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: ${NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${NAME}
    spec:
      terminationGracePeriodSeconds: 5
      tolerations:
        - operator: Exists
      containers:
        - name: probe
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -ec
          args:
            - |
              node="\${NODE_NAME}"
              file="/mnt/nfs/.nfs-node-probe-\${node}"
              date -Iseconds > "\${file}"
              test -s "\${file}"
              rm -f "\${file}"
              echo "nfs probe ok node=\${node}"
              touch /tmp/ready
              sleep 3600
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - test -f /tmp/ready
            periodSeconds: 2
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: export
              mountPath: /mnt/nfs
      volumes:
        - name: export
          nfs:
            server: ${SERVER}
            path: ${SHARE}
YAML

kubectl rollout status daemonset "$NAME" -n "$NS" --timeout="$TIMEOUT"
kubectl get pods -n "$NS" -l "app.kubernetes.io/name=${NAME}" -o wide
kubectl logs -n "$NS" -l "app.kubernetes.io/name=${NAME}" --all-containers=true

echo "NFS node probe passed."
