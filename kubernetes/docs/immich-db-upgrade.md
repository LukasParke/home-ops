# Immich Database: PostgreSQL Major Upgrade (16 → 17)

## Status

- **Current state:** Running on PG 16.9 + vectorchord 0.4.3 (healthy, data intact)
- **Attempted upgrade:** PR #33 bumped `imageName` to `17.5-0.4.3`
- **Result:** CNPG triggered an in-place major upgrade job (`pg_upgrade --link`),
  which **failed** at "Restoring database schemas in the new cluster"
- **Recovery:** Reverted to `16.9-0.4.3`; CNPG restarted both instances on PG16
  with zero data loss (pg_upgrade is non-destructive — it works on a copy in
  `pgdata-new` and leaves `pgdata` untouched)

## Verification findings

1. **vchord 0.4.3 DOES support PostgreSQL 17.** The
   `tensorchord/cloudnative-vectorchord` `versions.yaml` lists PG 17.10 as a
   supported base image, and the `17.5-0.4.3` image was pulled successfully by
   the upgrade job. The extension binaries exist for PG17.

2. **The in-place `imageName` change IS the correct CNPG procedure.** CNPG 1.26+
   (this cluster runs 1.30.0) supports declarative in-place major upgrades via
   `pg_upgrade`. Changing `imageName` to a new major version automatically
   triggers a major-upgrade Job. This is the intended workflow — the failure was
   not a procedural error.

3. **The failure is at pg_upgrade's schema-restore step.** pg_upgrade runs
   `pg_dump --schema-only` on the old cluster, then restores the DDL into the
   new cluster. A specific SQL statement in the schema dump failed. The detailed
   error is in `pg_upgrade_output.d/<timestamp>/log/pg_upgrade_dump_1.log`
   inside the upgrade Job pod, which is deleted on failure.

## Root cause (probable)

The schema restore fails because the `vchord` extension's internal SQL objects
(operator classes, functions, operator OIDs) differ between the PG16 and PG17
builds. When pg_upgrade replays the schema dump, a `CREATE` statement for a
vchord-dependent object fails because the OID or signature doesn't match the
new image's extension definition.

This is a known class of issue with extensions that manage custom access methods
or GiST/GIN-style operator classes across major PG upgrades.

## How to retry (when ready)

1. **Capture the detailed failure log first.** Temporarily patch the Cluster:
   ```bash
   kubectl patch cluster -n default immich-database --type merge \
     -p '{"spec":{"imageName":"ghcr.io/tensorchord/cloudnative-vectorchord:17.5-0.4.3"}}'
   ```
2. **Watch the upgrade Job** and grab the dump log before the pod is deleted:
   ```bash
   kubectl logs -n default -l cnpg.io/cluster=immich-database --tail=50
   # The job pod name ends in -major-upgrade-<rand>
   kubectl exec -n default <job-pod> -- \
     cat /var/lib/postgresql/data/pgdata-new/pg_upgrade_output.d/*/log/pg_upgrade_dump_1.log
   ```
   (If the pod is already gone, delete the failed Job and re-patch to retry.)
3. **The specific failing SQL statement** will be at the bottom of that log.
   Common fixes:
   - Drop the offending vchord indexes/tables before upgrade, recreate after
   - Use `pg_upgrade` without `--link` (slower but avoids some edge cases)
   - If vchord is fundamentally incompatible, do a logical-replication upgrade
     instead (CNPG Recipe 15 — set up a new PG17 cluster and replicate)

4. **Roll back** (if it fails again):
   ```bash
   kubectl patch cluster -n default immich-database --type merge \
     -p '{"spec":{"imageName":"ghcr.io/tensorchord/cloudnative-vectorchord:16.9-0.4.3"}}'
   kubectl delete job -n default immich-database-2-major-upgrade --ignore-not-found
   ```

## Alternatives if in-place upgrade won't work

- **Logical replication upgrade** (zero-downtime): Create a new PG17 cluster,
  use CNPG `Publication`/`Subscription` CRDs to replicate, then cutover. See
  CNPG Recipe 15.
- **Dump/restore**: `pg_dump` the immich DB, create a fresh PG17 cluster,
  `pg_restore`. Simplest but requires downtime and manual steps.

## Immich-specific notes

- Immich uses vchord for vector similarity search (smart search / CLIP).
- Before retrying, check Immich's docs for the minimum supported PostgreSQL and
  vectorchord versions — Immich may not require PG17.
- The `postInitApplicationSQL` (`CREATE EXTENSION vchord CASCADE`) only runs on
  fresh cluster init, NOT during pg_upgrade. The extension must already be
  available in the new image (it is).
