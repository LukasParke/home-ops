# NFS-backed storage conventions (home-ops)

This repo uses the **CSI NFS driver** and a **`nfs` StorageClass** (`nfs.csi.k8s.io`) for cluster volumes, plus optional **inline NFS mounts** from cluster secrets (`MEDIA_NFS_SERVER`, `MEDIA_NFS_PATH`) on some media workloads.

---

## Deployments + ReadWriteOnce PVCs: use `strategy: Recreate`

Kubernetes **Deployments** default to **RollingUpdate**. During a rollout, **two Pods can exist briefly**. A **ReadWriteOnce (RWO)** volume can attach to **only one node at a time**, so the second Pod often **cannot mount** the volume and appears stuck (`Pending` / `ContainerCreating` with `FailedMount`, or a prior Pod stuck `Terminating`).

**Mitigation for [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) workloads:** set **`controllers.<name>.strategy: Recreate`** on any controller that mounts an RWO CSI PVC (or equivalent single-writer volume).

```yaml
controllers:
  myapp:
    strategy: Recreate
```

This is already applied for NFS-backed app-template stacks such as homepage, `*arr`, tautulli, vaultwarden, home-assistant, and termix.

**Do not assume this applies everywhere:** StatefulSets, operators (e.g. CloudNativePG), and large upstream umbrella charts use different rollout mechanics.

---

## Immich chart: server / machine-learning strategy

The official Immich chart (`oci://ghcr.io/immich-app/immich-charts/immich`) merges **hardcoded** controller defaults **after** user values for `server` and `machine-learning`, fixing **`strategy: RollingUpdate`** in the chart templates. That **overrides** `controllers.main.strategy` in Helm values for those components.

- **Valkey** subchart hardcodes **`Recreate`** already (no extra values needed for RWO queue persistence).
- **Server** and **machine-learning** need **`Recreate`** for RWO NFS (library PVC + ML cache PVC). This repo applies it with a **Flux HelmRelease `postRenderers`** kustomize patch on Deployments `immich-server` and `immich-machine-learning` — see [`kubernetes/apps/default/immich/app/helmrelease.yaml`](../apps/default/immich/app/helmrelease.yaml).

If you upgrade the Immich chart, re-check whether upstream removes the hardcoded strategy so values-only `Recreate` becomes possible (then you could drop the post-renderer).

---

## GitLab and CloudNativePG

- **GitLab** ([`kubernetes/apps/gitlab/gitlab/app/helmrelease.yaml`](../apps/gitlab/gitlab/app/helmrelease.yaml)): Bitnami-style components use NFS `storageClass` where configured; many pieces are StatefulSets or subcharts — **not** the same `controllers.*.strategy` pattern. Follow inline comments in that file and upstream chart docs.
- **CNPG `Cluster`** (e.g. [`kubernetes/apps/default/ghostfolio/app/cluster-postgres.yaml`](../apps/default/ghostfolio/app/cluster-postgres.yaml), Immich Postgres): storage class is set on the **Cluster** spec; rollout is handled by the operator — **do not** try to set Deployment `Recreate` here.

---

## Flux ordering

Any workload that provisions **`nfs` CSI PVCs** should have its Flux **`Kustomization`** **`dependsOn`** the **`csi-driver-nfs`** Kustomization in **`kube-system`** so the StorageClass exists before Helm tries to bind volumes — see [`kubernetes/apps/kube-system/csi-driver-nfs/ks.yaml`](../apps/kube-system/csi-driver-nfs/ks.yaml) and each app’s `ks.yaml`.

---

## Inline NFS volumes (`type: nfs`) on `*arr`

`*arr` stacks often mount:

1. A **CSI PVC** for `/config` (RWO) — **`Recreate`** applies.
2. An **inline NFS volume** for `/media` — often shared read/write at the NAS export level; multiple Pods may mount it depending on export semantics. **`Recreate`** still prevents **two Pods fighting the RWO config PVC** during upgrades.

---

## Operational symptoms (storage / CSI)

When NFS or the CSI plugin is unhealthy, typical symptoms include:

- `Warning FailedMount ... rpc ... mount ... timeout after ...`
- Pods **`Pending`** with **`ContainerCreating`** forever
- Old Pods **`Terminating`** for hours while readiness probes fail or the kubelet repeats **`Killing`**

Those require **infra / CSI / NFS** troubleshooting first; Git-only changes cannot fix a broken mount path or NAS outage.

---

## Helm timeouts

Slow NFS rollouts can exceed default Helm wait windows and trigger remediation rollbacks. Heavy charts (e.g. GitLab) may set explicit **`spec.timeout`** on **`HelmRelease`**; consider raising **`timeout`** on app-template releases if upgrades consistently hit timeouts **after** storage is healthy.

---

## Checklist: new workload using `storageClass: nfs`

1. Add **`dependsOn`** **`csi-driver-nfs`** (`kube-system`) on the app Flux **`Kustomization`** (`ks.yaml`).
2. For **Deployment** + **RWO** PVC using app-template: set **`controllers.<name>.strategy: Recreate`**.
3. For **Immich-shaped** upstream charts that hardcode RollingUpdate: confirm whether **`postRenderers`** or upstream values are needed (see Immich section above).
4. If adding **Ghostfolio Valkey** persistence with RWO NFS: enable persistence in [`kubernetes/apps/default/ghostfolio/app/helmrelease-valkey.yaml`](../apps/default/ghostfolio/app/helmrelease-valkey.yaml) **and** add **`controllers.valkey.strategy: Recreate`** in the same change.
5. Consider **`spec.timeout`** on **`HelmRelease`** if NFS-backed rollouts are consistently slow.

---

## Related paths (inventory)

| Mechanism | Location |
|-----------|----------|
| CSI NFS HelmRelease | [`kubernetes/apps/kube-system/csi-driver-nfs/app/`](../apps/kube-system/csi-driver-nfs/app/) |
| StorageClass `nfs` | [`kubernetes/apps/kube-system/csi-driver-nfs/app/storageclass.yaml`](../apps/kube-system/csi-driver-nfs/app/storageclass.yaml) |
| Template twin (bootstrap) | [`templates/config/kubernetes/components/nfs/storageclass.yaml.j2`](../../templates/config/kubernetes/components/nfs/storageclass.yaml.j2) |
| Media NFS secrets (example keys) | [`kubernetes/components/sops/cluster-secrets.stringData.example.yaml`](../components/sops/cluster-secrets.stringData.example.yaml) |
