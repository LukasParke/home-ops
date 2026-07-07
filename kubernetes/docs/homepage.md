# Homepage configuration

Homepage is configured from `kubernetes/apps/default/homepage/app/helmrelease.yaml`.

## Inventory source of truth

`services.yaml` is the source of truth for the dashboard inventory. Kubernetes
Ingress/Gateway discovery is disabled in `kubernetes.yaml` to avoid duplicate
entries and stale chart annotations after rollbacks.

Each in-cluster service entry should include either:

- `namespace` plus `app` when pods use `app.kubernetes.io/name=<app>`
- `namespace` plus `podSelector` when chart labels are non-standard

Use external HTTPS URLs for `href`, but use Kubernetes service DNS for widget
`url` values. This keeps widgets working even when public DNS, Cloudflare, or
the external gateway has a temporary outage.

## Manual grouping and bookmarks

The dashboard intentionally mixes Kubernetes-backed app/status entries with
link-only operational bookmarks. Link-only entries omit `namespace`, `app`, and
`podSelector`; they are navigation shortcuts and are not expected to report pod
status.

Current groups are organized around daily use and operations:

- `Homelab`: external homelab infrastructure links such as Unraid.
- `Home & Personal`: household/personal applications.
- `Media`: media management and photo services.
- `Network`: ingress, DNS, tunnel, and network-controller links/status.
- `Observability`: dashboards, status checks, and metrics shortcuts.
- `Tools`: utility applications.
- `GitOps`: Forgejo plus GitHub/GitOps maintenance shortcuts.
- `Operations`: Homepage, runbooks, and platform documentation.

Prefer adding safe link-only bookmarks before exposing additional cluster UIs.
Only add new secrets or routes when the target is expected to be maintained as a
real service, not just a convenience link.

## Enabled widgets

| Service | Widget | Internal URL/credentials |
| --- | --- | --- |
| Prowlarr | `prowlarr` | `PROWLARR__AUTH__APIKEY` |
| Radarr | `radarr` | `RADARR__AUTH__APIKEY` |
| Sonarr | `sonarr` | `SONARR__AUTH__APIKEY` |
| Lidarr | `lidarr` | `LIDARR__AUTH__APIKEY` |
| Tautulli | `tautulli` | `TAUTULLI_API_KEY` |
| Immich | `immich`, `version: 2` | `IMMICH_API_KEY` with `server.statistics` permission |
| Vaultwarden | `vaultwarden` | no token required; `http://vaultwarden.default.svc.cluster.local:8080` |
| Gatus | `gatus` | no token required; `http://gatus.default.svc.cluster.local:8080` |
| Grafana | `grafana`, `version: 2` | `GRAFANA_USERNAME`, `GRAFANA_PASSWORD` |

## Optional widgets and deferred links

Unraid, Cloudflare Tunnel, Forgejo, Home Assistant, Ghostfolio, and the
GitOps/Operations documentation shortcuts are listed as links/status entries
only unless valid widget credentials are added. Do not add widgets with empty,
expired, or under-scoped credentials; Homepage will proxy those requests and log
repeated widget errors.

Deferred items that need new routes, new secrets, or additional app entries:

- Hubble UI: useful for Cilium flow debugging, but it needs an HTTPRoute before
  adding a dashboard link.
- Prometheus and Alertmanager direct UIs: keep Grafana as the public metrics UI
  unless direct routes are intentionally added.
- UniFi host substitution: the current UniFi Console bookmark uses the known
  controller URL directly. Add a `UNIFI_HOST` secret only if the URL needs to be
  configurable.
- Plex and qBittorrent: add entries/widgets only after confirming desired URLs
  and credentials.

Ghostfolio bearer tokens expire after six months. From an in-cluster debug pod,
generate a fresh bearer token from the account security token before re-enabling
that widget:

```sh
curl -X POST http://ghostfolio.default.svc.cluster.local:3333/api/v1/auth/anonymous \
  -H 'Content-Type: application/json' \
  -d '{ "accessToken": "SECURITY_TOKEN_OF_ACCOUNT" }'
```

Store the returned token in `GHOSTFOLIO_WIDGET_BEARER_TOKEN`, then add the
`ghostfolio` widget back to the Ghostfolio service entry.
