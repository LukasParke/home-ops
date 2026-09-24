# Infisical secret sync (staged, not active)

Moves the coder external-auth secret from the static SOPS file
(`../secret.sops.yaml`) to the self-hosted Infisical instance via the
Secrets Operator. **Not wired into the kustomization yet** — the Infisical
project and machine identity below can only be created through the Infisical
UI, and the coder pod must not reference a secret that doesn't exist yet.

## Enablement runbook

1. **In Infisical** (https://infisical.${SECRET_DOMAIN}):
   - Create project `coder` (slug `coder`), environment `prod`
   - Add secrets at path `/`: `CODER_GITHUB_EXTERNAL_AUTH_ID=github`,
     `CODER_GITHUB_EXTERNAL_AUTH_TYPE=github`, `CODER_GITHUB_CLIENT_ID`,
     `CODER_GITHUB_CLIENT_SECRET` (same values as the static file)
   - Create a **Machine Identity** with Universal Auth, member of the
     `coder` project
2. **In this repo:**
   - `sops machine-identity.sops.yaml` → replace both `changeme` values
   - Register both files in `../app/kustomization.yaml` and **delete**
     `../secret.sops.yaml` (the operator takes over the same
     `coder-external-auth` Secret with `creationPolicy: Orphan`, so the
     handoff is seamless)
   - PR + merge; Flux re-syncs and the operator refreshes the Secret every
     10 minutes; reloader rolls the coder pod on change
3. Update the GitHub external-auth values in Infisical from then on — never
   in the static file.

The InfisicalSecret itself is substituted with `${SECRET_DOMAIN}` through
the app's Flux Kustomization `postBuild` block once registered.
