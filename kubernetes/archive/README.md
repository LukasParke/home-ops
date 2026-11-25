# Archived Workloads

Workloads moved here are pruned from the cluster by Flux and ignored by Renovate (`ignorePaths` in `.renovaterc.json5`).

## Redeploying Firecrawl

1. Move both directories back into `kubernetes/apps/default/`:
   ```sh
   git mv kubernetes/archive/firecrawl kubernetes/apps/default/firecrawl
   git mv kubernetes/archive/firecrawl-mcp kubernetes/apps/default/firecrawl-mcp
   ```
2. Add both entries back to `kubernetes/apps/default/kustomization.yaml`:
   ```yaml
   - ./firecrawl/ks.yaml
   - ./firecrawl-mcp/ks.yaml
   ```
3. Note: `firecrawl/app/httproute.yaml` was switched to `envoy-internal` because `USE_DB_AUTHENTICATION` is `false`. If you need public access on `envoy-external`, attach an Envoy `SecurityPolicy` (`apiKeyAuth`) first.
