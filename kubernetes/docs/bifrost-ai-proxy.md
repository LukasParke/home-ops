# Research: Adding Bifrost AI Proxy to this cluster

**Status:** Research + cut-over implemented (see PR).
**Date:** 2026-08-08
**Scope decision:** Bifrost AI Proxy (OSS) replaces LiteLLM as the cluster's AI gateway.

---

## 1. What is Bifrost AI Proxy?

Bifrost ("the fastest AI gateway") is an LLM/API gateway from Maxim (project: `maximhq/bifrost`) that unifies access to many LLM providers behind a single OpenAI-compatible interface. Core capabilities relevant to this cluster:

- **Unified OpenAI-compatible API** — `/v1/chat/completions` to all upstreams.
- **Routing / failover / load balancing** — including **weighted key-level load balancing**, automatic failover, and (enterprise) **adaptive load balancing** using live performance metrics.
- **Drop-in LiteLLM compatibility** — since v1.3.0, Bifrost can accept LiteLLM-style config and act as a drop-in replacement (`model_list`, config-level fallbacks). This is highly relevant because we already run LiteLLM.
- **Supported provider families** — OpenAI-family (which covers all our llama.cpp hosts, which expose OpenAI-compatible `/v1` endpoints), Anthropic, Bedrock/Gemma, Azure, etc.
- **Governance & observability** — virtual API keys, logging, OTel traces (OTLP collectors), semantic caching, masked logging for compliance.

There are two editions:

| | Open Source (OSS) | Enterprise |
|---|---|---|
| License / source | Open source (`maximhq/bifrost`) | Proprietary, image from a Maxim regsitry (`us-west1-docker.pkg.dev/bifrost-enterprise/<org>/bifrost`) |
| Weighted key LB / failover / routing | Yes (core) | Yes |
| Adaptive load balancing (perf-based routing) | No | Yes (enterprise) |
| Advanced governance / SCIM / guardrails / compliance bits | No | Yes |
| Secrets/keys | Fine via K8s Secrets + SOPS | Same |

The rest of this doc focuses on the OSS edition, since adoption of the enterprise edition requires a Maxim image registry and (typically) a commercial relationship.

---

## 2. How this cluster already solves the same problem (LiteLLM)

This cluster already runs an LLM gateway: LiteLLM Proxy in the `default` namespace (chart `ghcr.io/berriai/litellm-helm`, currently pinned `1.89.3`). The docs `kubernetes/docs/litellm-plan.md` and `kubernetes/docs/agent-swarm-plan.md` describe the intended architecture:

- **One OpenAI-compatible proxy endpoint** — `litellm.${SECRET_DOMAIN}` (HTTPRoute behind Envoy Gateway `envoy-external`).
- **A "fleet" of 15 models across 4 local GPU hosts**, each host running llama.cpp exposing OpenAI-compatible `/v1` at an internal IP:
  - `cerberus` (Strix Halo, 128GB unified) — gpt-oss-120b, minimax-m2.1, etc.
  - `talos` (RTX 5090 32GB) — qwen3.6/ornith/devstral coding models.
  - `hephaestus` (RTX 3080 10GB) — gemma-4-12b, qwen3-embed, ornith-9b.
  - `delphi` (RTX 4080 SUPER 16GB) — mistral-small-3.2, deepseek-r1-14b, reranker.
- **Backing store** — LiteLLM uses a cloudnative-pg Postgres (`litellm-database`) for UI/usage metadata.
- **Secrets** — SOPS-encrypted (`kubernetes/components/sops/cluster-secrets.sops.yaml`), injected via Flux `postBuild.substituteFrom`.
- **Monitoring** — Prometheus ServiceMonitor (`/metrics`), Gatus health check, Homepage integration.

So the realistic question is not "should we add a gateway" but **"should we replace/migrate LiteLLM to Bifrost, or run them side-by-side?"**

---

## 3. Fit assessment for this cluster

### Strong alignment

1. **Drop-in LiteLLM compatibility.** Bifrost can consume LiteLLM-style `model_list`/fallback config. Our entire `proxy_config.model_list` (15 entries) is structurally reusable, which lowers migration cost significantly.
2. **Our upstreams are OpenAI-compatible `/v1` internals.** Bifrost's OpenAI-family support maps directly to all four llama.cpp hosts (they already use `model: openai/<name>` + `api_base` in LiteLLM). No protocol translation needed.
3. **Weighted load balancing / failover is a core OSS feature.** With multiple GPU hosts serving overlapping models, weighted keys and automatic failover are genuinely useful. LiteLLM does load-balance too but Bifrost emphasizes routing performance as its headline differentiator (advertised as the "fastest" gateway).
4. **Helm chart + Postgres + Go CLI ergonomics** match the repo's existing patterns (app-template/upstream OCI charts + cloudnative-pg). Deployment model is very similar to what LiteLLM already does.
5. **OTel traces** (OTLP) align with the existing `observability` namespace (Prometheus/Grafana stack) if we want request-level tracing.

### Caveats / friction

1. **Running a second gateway means maintaining a second config surface + second set of secrets + second DB.** If we keep two proxies, every model addition must be mirrored in two places — exactly the sort of drift this repo's GitOps setup tries to avoid.
2. **Bifrost is newer/less battle-tested than LiteLLM; some differentiating features are enterprise-only** (adaptive load balancing, richer governance). The OSS feature that makes Bifrost compelling for us today (weighted key LB over OpenAI-compatible local hosts) overlaps with what LiteLLM already provides through `router_settings`.
3. **Enterprise edition needs a Maxim registry** — not usable in a public GitOps repo without vendor-provided credentials. Only consider OSS here.
4. **The repo's docs and Homepage/Gatus currently reference LiteLLM** (`litellm.${SECRET_DOMAIN}`, `litellm.default.svc.cluster.local:4000`, agent-swarm-plan's `apiBase`). A migration touches the swarm plan's `apiBase`/`apiKey` for every agent.

---

## 4. Recommendation

**Decision: replace LiteLLM with Bifrost (OSS).** The cluster's coding agents (Pi, Hermes, Goose) were underperforming on LiteLLM's OpenAI-compatible surface, which translates everything into Chat Completions and drops/mangles agentic features (extended thinking, Responses API, richer tool schemas). Bifrost natively serves the Responses API (since v1.3.0) and is built for low-overhead routing — a better fit for tool-call-heavy agent loops. Its LiteLLM-drop-in support means the 15-model fleet config translates directly.

---

## 5. What a migration would look like (implemented in this PR)

> Implemented: see `kubernetes/apps/default/bifrost/app/` (HelmRepository `maximhq.github.io/bifrost/helm-charts`, HelmRelease with all 15 models mapped to per-host provider keys, cloudnative-pg `bifrost-database`, HTTPRoute `bifrost.${SECRET_DOMAIN}`). The `litellm` app dir was removed, Homepage updated, and docs re-pointed to Bifrost.

Deployment model mirrors the previous LiteLLM layout:

```text
kubernetes/apps/default/
└── bifrost/
    ├── ks.yaml                     # dependsOn cloudnative-pg + csi-driver-nfs
    └── app/
        ├── kustomization.yaml
        ├── ocirepository.yaml      # oci://.../bifrost Helm chart
        ├── helmrelease.yaml
        ├── cluster-postgres.yaml   # cloudnative-pg Cluster (or reuse litellm-database)
        ├── httproute.yaml          # bifrost.${SECRET_DOMAIN} behind envoy-external
        └── secret.sops.yaml        # encryption key, admin creds, provider keys (SOPS)
```

Key Helm values (OSS, from Bifrost docs) that map onto our fleet:

```yaml
storage:
  mode: postgres
postgresql:
  external:
    enabled: true
    host: <cnpg rw service>.default.svc.cluster.local
    ...
bifrost:
  encryptionKeySecret:
    name: "bifrost-encryption"
    key: "encryption-key"
  providers:
    # One block per GPU host, each with the relevant model(s) and weights:
    openai:
      keys:
        - name: cerberus
          value: "env.CERBERUS_LLAMASWAP_API_KEY"
          models: ["gpt-oss-120b", "minimax-m2.1", ...]
          weight: 1
        - name: talos
          value: "env.TALOS_LLAMASWAP_API_KEY"
          models: ["qwen3.6-35b-a3b", "devstral-24b", ...]
          weight: 1
        ...
    # network_config: default_request_timeout_in_seconds, etc.
  cluster:
    enabled: false               # single replica; HA only if needed
```

Flux wiring (ks.yaml) would simply reuse the pattern already in `litellm/ks.yaml`: `dependsOn: cloudnative-pg (cnpg-system)`, `csi-driver-nfs (kube-system)`, `postBuild.substituteFrom: cluster-secrets`, `targetNamespace: default`.

**Migration steps (bidirectional rollback is the easy part because LiteLLM stays until cut-over):**
1. Add `BIFROST_ENCRYPTION_KEY` + `BIFROST_ADMIN_USERNAME` + `BIFROST_ADMIN_PASSWORD` to SOPS (`cluster-secrets.sops.yaml`). Provider keys (`CERBERUS_LLAMASWAP_API_KEY`, etc.) already exist.
2. Stand up Bifrost pointing at its own cloudnative-pg DB, behind `bifrost.${SECRET_DOMAIN}`.
3. Translate the 15-entry `model_list` into Bifrost `providers.openai.keys` (per-host key blocks).
4. Smoke-test against one host (e.g. `qwen3.6-27b-dense` on `talos`) with the same client config the swarm already uses.
5. Once verified, flip the agent-swarm `apiBase` and HTTPRoute/Homepage/Gatus to Bifrost, then remove the LiteLLM HelmRelease + DB.

## 5b. Schema validation (chart 2.1.34 / app 1.5.12)

Validated the HelmRelease against the chart's own `values.schema.json` (via `jsonschema`) and `helm template`. Key findings vs. the older docs examples:

- **`bifrost.client.disableDbPingsInHealth`** is camelCase (not `disable_db_pings_in_health`); the chart maps it to `disable_db_pings_in_health` in config.json.
- **`network_config` retry keys are `retry_backoff_initial_ms` / `retry_backoff_max_ms`** (with `_ms`); the chart emits them as `retry_backoff_initial` / `retry_backoff_max` at runtime.
- **No `serviceMonitor` key** in this chart — metrics are served at `/metrics` on the `http` service port; a standalone `ServiceMonitor` is used instead.
- **`postgresql.external.existingSecret`** is honored: the chart injects `BIFROST_POSTGRES_PASSWORD` from the secret's `password` key (cloudnative-pg generates `bifrost-database-app` with `username`/`password`).
- **`bifrost.authConfig`** protects the admin dashboard/API via `cluster-secrets` (`BIFROST_ADMIN_USERNAME`/`BIFROST_ADMIN_PASSWORD`).
- **`enforceAuthOnInference: true`** (chart default) means inference requests need a valid virtual key — agents must be issued Bifrost virtual keys (unlike LiteLLM's single master key).
- Probes default to `/health` on port `http`; set explicitly for clarity.
- The chart requires `image.tag` (no default) and adds `id` to each provider key from `name`.

## 6. Open decisions (only after you decide to pursue it)

1. **Replace vs. side-by-side?** Recommended: replace (see §4). Confirm you don't need both UI/admin surfaces simultaneously.
2. **DB:** Spin up a fresh cloudnative-pg `bifrost-database` (clean) or reuse `litellm-database`. Clean is safer.
3. **Which models are "primary" per host, and what failover weights?** This is the interesting part — see §5 `providers.openai.keys.weight`.
4. **HA / replica count.** Single replica is fine for a homelab gateway; Bifrost cluster mode (gossip + grpc ports + Postgres) only if you want HA.
5. **Observability.** Enable Bifrost OTel traces to the existing `observability` stack? Enterprise features (adaptive LB, guardrails) are out of scope for OSS.
6. **Virtual keys.** Because `enforceAuthOnInference` is on, agents (Pi/Hermes/Goose) need Bifrost virtual keys, not the admin password. Decide how to issue/rotate them.

---

## 7. Sources

- Bifrost Helm deployment guides (governance, storage/MinIO, cluster mode, enterprise example) — `maximhq/bifrost` docs.
- Bifrost provider/weighted load-balancing config and OpenAI-compatible API docs.
- Bifrost v1.3.0 changelog (LiteLLM drop-in support, OTel traces, Responses API).
- Local repo context: `kubernetes/apps/default/litellm/app/*`, `kubernetes/docs/litellm-plan.md`, `kubernetes/docs/agent-swarm-plan.md`, `kubernetes/docs/adoption-recommendations.md`.