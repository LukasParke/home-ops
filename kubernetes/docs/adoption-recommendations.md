# Adoption Recommendations: Upstream Tooling Review

**Date:** 2026-06-24  
**Sources reviewed:**
- Current repo (`LukasParke/home-ops`): Talos 1.12.4, Kubernetes 1.35.2, Flux + SOPS + Envoy Gateway + cloudnative-pg.
- Upstream template: `onedr0p/cluster-template` (now uses `just`, `CUE`, `TOML`, `flate`, `lefthook`).
- Active reference: `onedr0p/home-ops` (uses `tuppr`, `kopiur`, `volsync`, `gatus-sidecar`, `kromgo`, `external-secrets`, `openebs`, `rook-ceph`, etc.).
- Home-Operations announcement tooling: `flate`, `konflate`, `yayamlls`, `tuppr`, `kopiur`, `gatus-sidecar`, `drm-exporter`, `chaski`, `echo`, `external-dns-unifi-webhook`, `kromgo`, `k8s-schemas`, `renovate-presets`, `charts-mirror`, `towonel`.

---

## TL;DR Priority List

| Priority | Tool / Change | Why it fits this cluster |
|---|---|---|
| **High** | `k8s-schemas.home-operations.com` | Drop-in replacement for `kubernetes-schemas.pages.dev`; actively maintained by the community, cosign-signed OCI artifact, Renovate-bumped. |
| **High** | `renovate-presets` | Reduces custom manager boilerplate in `.renovaterc.json5` and fixes depName/sourceUrl/changelog gaps for CNPG, cloudnative-pg, and OCI charts. |
| **High** | `tuppr` | You are running Talos + K8s and currently upgrade manually. `tuppr` is a controller that automates Talos OS and Kubernetes version upgrades with CEL health checks and Prometheus metrics. |
| **Medium** | `gatus-sidecar` | You already run Gatus with a hand-maintained endpoint list. The sidecar auto-discovers HTTPRoutes/Services/Ingresses and writes the config for you. |
| **Medium** | `kromgo` | You already run kube-prometheus-stack. `kromgo` exposes PromQL-backed SVG badges/graphs for READMEs/Homepage without exposing Prometheus. |
| **Medium** | `drm-exporter` | Your nodes have `amdgpu` and `i915`/`xe` Talos extensions. This DaemonSet exposes GPU utilization, memory, power, and thermals to Prometheus. |
| **Medium** | `volsync` + `kopia` (or wait for `kopiur`) | You currently have **no backup operator**. Upstream uses both `volsync` and the new `kopiur`. `volsync` is stable today; `kopiur` is alpha but purpose-built for Kopia. |
| **Low / Watch** | `flate` + `konflate` + `yayamlls` | Modern replacement for `flux-local` + redhat YAML language server. Biggest payoff if you refactor CI/editor workflow; not urgent while `flux-local` works. |
| **Low / Watch** | `chaski` | Nice-to-have webhook relay for Alertmanager → Pushover/Discord/ntfy. Only adopt if you want richer, templated notifications than current Discord webhook. |
| **Low / Niche** | `towonel` | Open-source `cloudflared` alternative. Interesting if you want to self-host the tunnel endpoint, but you already have working Cloudflare Tunnel + Envoy Gateway. |
| **Avoid / Wait** | `echo` | You already have `echo` deployed; the home-ops version is functionally similar. |
| **Avoid / Wait** | `kopiur` as primary backup | Alpha, API changing, author asks not to run against data you care about yet. Evaluate, but use `volsync` for real data today. |

---

## 1. Quick Wins (low risk, immediate value)

### 1.1 Switch schema URLs to `k8s-schemas.home-operations.com`

**What:** Replace `https://kubernetes-schemas.pages.dev/...` with `https://k8s-schemas.home-operations.com/...` in manifest modelines.

**Why:**
- `kubernetes-schemas.pages.dev` is the legacy community schema site.
- `k8s-schemas` is actively maintained by home-operations, automatically rebuilt from upstream CRDs, cosign-signed, and published as an OCI artifact.
- It covers native Kubernetes types, CRDs, and kustomize, with a consistent URL pattern: `https://k8s-schemas.home-operations.com/{group}/{kind}_{version}.json`.

**Effort:** Search/replace across `kubernetes/`.

**Example change:**
```yaml
# Before
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
# After
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
```

### 1.2 Extend `home-operations/renovate-presets`

**What:** Add `github>home-operations/renovate-presets` to your `.renovaterc.json5` `extends` array (or import specific presets).

**Why:**
- Your current config already has a lot of custom regex managers and package rules.
- The shared presets provide managers/overrides for CNPG, cloudnative-pg, OCI charts, and other homelab tools that Renovate's built-in managers handle poorly.
- Reduces local config drift and benefits from community fixes.

**Effort:** Low. Start with a partial extend and remove overlapping custom managers.

**Example:**
```json5
{
  "extends": [
    "config:recommended",
    "docker:enableMajor",
    "helpers:pinGitHubActionDigests",
    "github>home-operations/renovate-presets",
    // ... your local rules
  ]
}
```

---

## 2. Operational Improvements

### 2.1 `tuppr` — automated Talos + Kubernetes upgrades

**What:** A Kubernetes controller that plans and executes Talos OS and Kubernetes upgrades.

**Why it fits:**
- You are on Talos 1.12.4 / K8s 1.35.2.
- Upgrades currently require manual `talosctl upgrade-k8s` and node-by-node `talosctl upgrade`.
- `tuppr` supports upgrade plans, CEL-based pre/post health checks, Prometheus metrics, and Grafana dashboards.
- Upstream (`onedr0p/home-ops`) already deploys it under `kubernetes/apps/system-upgrade/tuppr`.

**Effort:** Medium. Requires Talos `kubernetesTalosAPIAccess` enabled for the `system-upgrade` namespace.

**Considerations:**
- Test on one node first.
- Coordinate with your UniFi/Cloudflare/network setup so a node reboot doesn't look like an outage.
- Pin Kubernetes versions explicitly in the `Tuppr` CR; don't auto-upgrade to latest blindly.

### 2.2 `gatus-sidecar` — automated status-page endpoints

**What:** A sidecar that watches HTTPRoute, Ingress, Service, and Traefik IngressRoute resources and writes Gatus endpoint config.

**Why it fits:**
- You already run Gatus and manually curate `endpoints:` in `kubernetes/apps/default/gatus/app/helmrelease.yaml`.
- Every new app requires a manual Gatus entry (we just added LiteLLM manually).
- The sidecar would auto-generate endpoints from your existing HTTPRoutes and Services.

**Effort:** Medium. Requires RBAC, shared `emptyDir` config volume, and moving Gatus to a Deployment model that can load a sidecar-generated include file.

**Migration path:**
1. Add a `ServiceAccount` + `ClusterRole` for `gatus-sidecar`.
2. Mount an `emptyDir` at `/config` shared between Gatus and the sidecar.
3. Configure Gatus to include `/config/gatus-sidecar.yaml`.
4. Run sidecar with `--auto-httproute --auto-service --gateway-name=envoy-external`.
5. Retain a small manual file for external endpoints (e.g., SailPoint docs).

### 2.3 `kromgo` — PromQL badges and graphs

**What:** Safely expose PromQL query results as SVG badges or graphs, without exposing Prometheus.

**Why it fits:**
- You already run `kube-prometheus-stack`.
- Your Homepage dashboard could display live cluster metrics badges (CPU, memory, uptime, node count).
- You can embed badges in this repo's README.

**Effort:** Low-Medium. Single Deployment + ConfigMap mapping PromQL queries to badge IDs.

**Example use:**
```yaml
# ConfigMap
badges:
  node_count:
    query: count(kube_node_info)
    label: nodes
```
Then embed `https://kromgo.parke.dev/badges/node_count` in Homepage or README.

---

## 3. Observability & Hardware

### 3.1 `drm-exporter` — GPU metrics

**What:** DaemonSet that exports Intel/AMD GPU metrics to Prometheus.

**Why it fits:**
- Your node labels show `extensions.talos.dev/amdgpu` and the schematic likely includes `i915`/`xe`.
- Useful if you run Plex transcoding, AI/ML workloads (you just deployed LiteLLM), or any GPU-accelerated containers.
- Metrics: engine utilization, memory, frequency, power, temperature, fan speed.

**Effort:** Low. Deploy as DaemonSet with ServiceMonitor.

**Considerations:**
- Requires kernel support. Talos schematic must include the right GPU system extensions.
- Intel `xe` perf-PMU support requires Linux ≥ 6.16; verify Talos kernel version.

---

## 4. Backup & Storage (biggest current gap)

### 4.1 `volsync` + `kopia` — stable backup today

**What:** `volsync` is a volume snapshot replication operator; `kopia` is the backend it can use for encrypted, deduplicated backups.

**Why it fits:**
- Your cluster currently has **no backup solution** for stateful workloads (Postgres, Immich, Ghostfolio, Vaultwarden, Homepage, LiteLLM DB).
- Upstream (`onedr0p/home-ops`) deploys both `volsync-system/volsync` and `volsync-system/kopia`.
- cloudnative-pg has its own backups, but PVC-backed apps (Immich, Vaultwarden, Homepage) need something else.

**Effort:** Medium-High. Requires:
- `volsync` HelmRelease.
- A `kopia` repository server or S3-compatible backend.
- `ReplicationSource` / `ReplicationDestination` CRs per PVC.
- Secret management for repository credentials.

### 4.2 `kopiur` — watch, don't adopt yet

**What:** A Kopia-native Kubernetes backup operator written in Rust.

**Why watch it:**
- Purpose-built for Kopia with clean CRDs (`Repository`, `BackupConfig`, `Backup`, `BackupSchedule`, `Restore`, `Maintenance`).
- Upstream (`onedr0p/home-ops`) has already deployed it in parallel with `volsync`.

**Why wait:**
- Alpha status; maintainers explicitly say not to run against data you care about.
- API surface is still changing.

**Recommendation:** Deploy `volsync` + `kopia` now for real data. Stand up `kopiur` in a non-critical namespace to evaluate, or wait for a stable release.

---

## 5. CI / Developer Experience

### 5.1 `flate` + `konflate` + `yayamlls`

**What:**
- `flate`: Offline Flux resource validator/inflator (replacement for `flux-local`).
- `konflate`: Read-only PR review tool that renders the real diff of a Flux change.
- `yayamlls`: Go-based YAML language server with Flux-aware rendering.

**Why consider:**
- Your current CI uses `flux-local` Docker image (`ghcr.io/allenporter/flux-local:v8.1.0`). It works but is slower and needs a cluster/CLI stack.
- `flate` is a single static binary, runs fully offline, and upstream `cluster-template` has switched its CI workflow to `flate.yaml`.
- `yayamlls` replaces the Node.js Red Hat YAML language server with a Go binary and adds code-lens rendering for HelmRelease/Kustomization.

**Effort:** Medium-High for full migration.
- Replace `.github/workflows/flux-local.yaml` with `flate` action.
- Update VS Code settings / `.mise` to use `yayamlls`.
- `konflate` is optional and requires hosting a read-only review UI.

**Recommendation:** Not urgent. Put on the roadmap if you find `flux-local` slow or want a faster local dev loop. The upstream `cluster-template` has made this the default, so it will likely become the community standard.

---

## 6. Notification & Tunneling (situational)

### 6.1 `chaski` — webhook relay

**What:** Route webhooks through CEL gates and Go templates to apprise-supported services (Discord, Pushover, ntfy, etc.) or HTTP targets.

**Why consider:**
- You currently send Alertmanager → Discord via a simple webhook.
- `chaski` lets you template messages, route by severity, filter noise, and support multiple channels.

**Effort:** Low-Medium.

**Recommendation:** Only adopt if you want richer, multi-channel alerting. Your current Discord webhook is fine for basic needs.

### 6.2 `towonel` — self-hosted tunnel

**What:** Open-source alternative to `cloudflared`. Agents connect outbound over QUIC to a hub you host on a VPS.

**Why consider:**
- You currently use Cloudflare Tunnel (`cloudflared`) + Envoy Gateway.
- `towonel` keeps the path under your control.

**Why wait:**
- Alpha status.
- Requires a public VPS with ports 443/tcp, 8443/tcp, and 51820/udp open.
- You already have a working, free Cloudflare Tunnel setup.

**Recommendation:** Watch it. Adopt only if you want to de-Cloudflare your ingress path and don't mind running the hub VPS.

---

## 7. Container Images

### 7.1 `home-operations/containers`

**What:** Community-built, rootless, multi-arch container images with semantic versioning and digest pinning.

**Why consider:**
- Some upstream images are bloated or poorly pinned.
- These images are purpose-built for Kubernetes, rootless, and Renovate-friendly.

**Recommendation:** Review on a per-app basis. Don't switch working apps just for the sake of it, but consider these images when adding new apps or replacing images that cause security/permission issues.

---

## 8. Template/Repo Modernization

### 8.1 Upstream `cluster-template` has changed significantly

Your repo is based on an older version of `onedr0p/cluster-template` that used:
- `cluster.yaml` / `nodes.yaml` (YAML)
- `Taskfile.yaml`
- `flux-local`
- `makejinja` with `cluster.sample.yaml`

Current upstream uses:
- `cluster.sample.toml` + `CUE` validation
- `justfile` (instead of Taskfile)
- `lefthook` (git hooks)
- `flate` (instead of flux-local)

**Recommendation:** This is a large refactor. Don't do it impulsively. Plan it as a separate migration if you want to stay aligned with upstream. The immediate-value items above (schemas, renovate-presets, tuppr, gatus-sidecar, kromgo, backup) can be adopted independently without rebasing on the new template.

---

## 9. Suggested Implementation Order

1. **Week 1:** Switch to `k8s-schemas.home-operations.com`; extend `renovate-presets`.
2. **Week 2:** Deploy `tuppr` for Talos/Kubernetes upgrades (test on one node).
3. **Week 3:** Deploy `kromgo` and add a few badges to Homepage/README.
4. **Week 4:** Add `drm-exporter` DaemonSet if GPU metrics are useful.
5. **Month 2:** Implement `volsync` + `kopia` backup for stateful PVCs.
6. **Month 2-3:** Migrate Gatus to use `gatus-sidecar`.
7. **Later:** Evaluate `flate/konflate/yayamlls` and decide on template modernization.
8. **Watch:** `kopiur`, `towonel`, `chaski`.

---

## 10. Things to avoid or deprioritize

- **`echo`**: You already deploy a similar echo service.
- **`kopiur` as primary backup**: Too alpha for production data.
- **`towonel` unless you want to self-host the tunnel hub**: Cloudflare Tunnel already works.
- **Full template rebase**: High risk, low immediate payoff. Adopt tools piecemeal instead.

---

## 11. Security Note

`cluster.yaml` contains a plaintext Cloudflare API token (`cfat_...`). Regardless of tooling choices, this should be rotated and moved into SOPS-encrypted secrets if it is not already known/accepted as a bootstrap-only value.
