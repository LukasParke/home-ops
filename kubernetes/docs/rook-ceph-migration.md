# Rook-Ceph migration runbook

Replacing Unraid NFS (`10.10.10.215:/mnt/user/home-ops`, StorageClass `nfs`) as
the backing store for cluster state with Rook-Ceph on 3x 500GB NVMe drives
(one per node, StorageClass `ceph-rbd`, replica 3).

**Why:** the Unraid box chronically stalls NFS (thousands of
`nfs: server 10.10.10.215 not responding, timed out` kernel events/day), which
freezes every app with an NFS PVC and causes the probe-failure / restart storms
seen across the cluster. After this migration, Unraid's only roles are bulk
media (`/media` mounts, `immich-library`) and the VolSync backup target —
nothing on the serving path.

Safety properties of this plan:

- Both StorageClasses use `reclaimPolicy: Retain`; deleting a PVC never
  destroys data.
- Nothing on the NFS share is deleted during migration. It is the fallback
  copy until each app is verified on Ceph.
- The `rook-ceph-cluster` Flux Kustomization ships **suspended**; Ceph is not
  created until the drives are confirmed.

---

## Phase 0 — prerequisites

1. Install one 500GB NVMe drive in each node (zeus, poseidon, hades).
2. Get Unraid booting well enough to serve `/mnt/user/home-ops`. The existing
   data lives **only** there — migration copies from it. If the box stays
   dead, the array disks are plain XFS/BTRFS and can be mounted read-only from
   any Linux box to lift the share off.
3. On Unraid, create the backup repo directory (the CSI driver does not mkdir):
   `/mnt/user/home-ops/volsync-system/restic-repo`

## Phase 1 — build Ceph

1. Verify each node sees the new drive and record its by-id path. Enumeration
   is NOT stable across installs (zeus's new drive came up as `nvme0n1`,
   pushing the system disk to `nvme1n1`), so the CephCluster selects drives by
   by-id path, not kernel name:

   ```sh
   talosctl -n <ip> get disks
   talosctl -n <ip> ls -l /dev/disk/by-id/ | grep Sandisk
   ```

   Confirm each node's `/dev/disk/by-id/nvme-Sandisk_Optimus_5100_500GB_<serial>`
   matches the per-node entries in
   [`cluster/app/helmrelease.yaml`](../apps/rook-ceph/cluster/app/helmrelease.yaml);
   fill in any `REPLACE_ME` serials and push before unsuspending. The 1TB
   BIWIN is the Talos system disk everywhere — never hand it to Rook. Do
   **not** add the drives to Talos `machine.disks` — Talos would claim them
   for its own user volumes.

2. Enable the cluster (make the Git change durable, don't just resume):

   - Set `suspend: false` in [`cluster/ks.yaml`](../apps/rook-ceph/cluster/ks.yaml),
     commit, push; or `flux -n rook-ceph resume kustomization rook-ceph-cluster`
     for a quick start and flip the flag right after.

3. Wait and verify (~5-15 min; OSD prepare jobs format the drives):

   ```sh
   kubectl -n rook-ceph get cephcluster,pods
   kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
   kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
   ```

   Gate before continuing: `HEALTH_OK` (or `HEALTH_WARN` with only expected
   "too few PGs" noise that settles), 3 OSDs up/in, one per host,
   `kubectl get sc ceph-rbd` and `kubectl get volumesnapshotclass ceph-rbd`
   both exist.

## Phase 2 — migrate workloads (in order)

Migrate one app at a time; verify before moving on. Databases first — they are
the highest-value win.

### 2a. CNPG Postgres clusters (immich, ghostfolio, forgejo, bifrost)

`storageClass` is immutable on a PVC, so each cluster is dumped and recreated.
Per cluster (example: immich):

```sh
# 1. Scale the app down so the DB is quiescent
kubectl -n default scale deploy/immich-server deploy/immich-machine-learning --replicas=0

# 2. Dump from the primary (cluster name + '-1' is the usual primary; check
#    `kubectl -n default get cluster immich-database` for the real one)
kubectl -n default exec immich-database-1 -- \
  pg_dumpall -U postgres --clean --if-exists > immich-database.sql

# 3. Recreate the cluster on ceph-rbd: edit cluster-postgres.yaml
#    (storage.storageClass: ceph-rbd), commit, push — Flux deletes the old
#    cluster (PVCs go away, but Retain PVs keep the NFS data) and builds new.
#    Faster local loop: kubectl apply the edited manifest manually.

# 4. Restore
kubectl -n default exec -i immich-database-1 -- \
  psql -U postgres -d postgres < immich-database.sql

# 5. Scale the app back up and verify
```

The CNPG `-app` connection secrets are recreated by the operator with the same
names, so apps reconnect without config changes.

### 2b. App config PVCs (radarr, sonarr, lidarr, prowlarr, tautulli, vaultwarden, homepage, gatus, termix, steel, immich-machine-learning, valkey, graphiti, gitea-shared-storage)

Per app:

1. In the app's helmrelease: `storageClass: nfs` → `ceph-rbd` (keep the PVC
   name and size the same). Commit on the migration branch but don't push yet.
2. Copy data with a one-off job (app scaled to 0 first):

   ```sh
   kubectl -n default scale deploy/<app> --replicas=0
   kubectl apply -f scripts/pvc-copy-job.yaml \
     # params: old PVC <name> (nfs) -> new PVC <name>-new (ceph-rbd)
   ```

   (Create the new ceph-rbd PVC first; mount both in one pod; `rsync -aHAX`.)
3. Point the helmrelease at the new PVC name, push, let Flux roll it out.
4. Verify the app, then delete the old nfs PVC object (data remains on the
   share thanks to Retain).

### 2c. Loki

Disposable data — no copy. Change `singleBinary.persistence.storageClass` to
`ceph-rbd` in
[`observability/loki/app/helmrelease.yaml`](../apps/observability/loki/app/helmrelease.yaml);
retention refills the new volume.

### 2d. firecrawl nuq-postgres

Job-queue DB, recreate empty: set `nuqPostgres.persistence.storageClass: ceph-rbd`.

### Stays on NFS

- `immich-library` (RWX, 100Gi) — bulk photos; Ceph capacity is for cluster state.
- `*arr` `/media` inline mounts — media serving is Unraid's job.

## Phase 3 — backups (VolSync -> Unraid restic)

Infra (volsync operator, rest-server on an NFS PVC) ships with this branch.
Per app, once it runs on ceph-rbd:

1. Include the component in the app's namespace `kustomization.yaml`:
   `- ../../../components/volsync` (path depth varies by app).
2. Add substitutions to the app's Flux `ks.yaml`:

   ```yaml
   postBuild:
     substitute:
       VOLSYNC_APP: radarr
       VOLSYNC_PVC: radarr
       VOLSYNC_SCHEDULE: "0 3 * * *"
     substituteFrom:
       - name: cluster-secrets
         kind: Secret
   ```

3. First run: restic repos auto-initialize on the first backup against
   rest-server. Verify: `kubectl -n default get replicationsource <app>`
   shows `status.lastSyncTime` set, and the repo directory appears under
   `volsync-system/restic-repo/` on the share.

For CNPG clusters, back up PVC `<cluster>-1` (or `-2`) the same way. VolSync
gives crash-consistent copies — restoring them is safe (Postgres replays WAL
on start) but not point-in-time. Scheduled `pg_dump` logical backups are the
planned follow-up.

## Restoring from a backup

1. Scale the app to 0.
2. Create a fresh empty `ceph-rbd` PVC to restore into (or reuse the app's
   PVC after clearing it).
3. Apply a one-shot restore:

   ```yaml
   apiVersion: volsync.backube/v1alpha1
   kind: ReplicationDestination
   metadata:
     name: <app>-restore
   spec:
     trigger: {}
     restic:
       repository: volsync-restic
       destinationPVC: <pvc-name>
       copyMethod: Direct
       accessModes: [ReadWriteOnce]
   ```

4. Wait for the mover job to complete, then delete the
   ReplicationDestination and scale the app back up.

Test the drill once on a throwaway PVC before trusting it. Full reference in
the VolSync usage docs.

## Day-2 notes

- `ceph -s` from the toolbox pod is the health check; PrometheusRule alerts
  (`CephHealthWarning` etc.) fire into kube-prometheus-stack.
- Node upgrades (tuppr): Rook manages PDBs and sets `noout` during drains;
  expect brief PG-recovery I/O after each node returns. Upgrade one node at a
  time and wait for `HEALTH_OK` between nodes.
- Capacity: ~465Gi usable at replica 3. Watch `ceph df`; stay under ~75%.
- Drive replacement: `kubectl -n rook-ceph get cephosd`; Rook OSD
  removal/replace flow in the rook docs.
