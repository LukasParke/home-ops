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

## Enabled widgets

| Service | Widget | Internal URL/credentials |
| --- | --- | --- |
| Cloudflare Tunnel | `cloudflared` | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_TUNNEL_API_TOKEN` |
| Prowlarr | `prowlarr` | `PROWLARR__AUTH__APIKEY` |
| Radarr | `radarr` | `RADARR__AUTH__APIKEY` |
| Sonarr | `sonarr` | `SONARR__AUTH__APIKEY` |
| Lidarr | `lidarr` | `LIDARR__AUTH__APIKEY` |
| Tautulli | `tautulli` | `TAUTULLI_API_KEY` |
| Immich | `immich`, `version: 2` | `IMMICH_API_KEY` with `server.statistics` permission |
| Vaultwarden | `vaultwarden` | no token required |
| Gatus | `gatus` | no token required |
| Grafana | `grafana`, `version: 2` | `GRAFANA_USERNAME`, `GRAFANA_PASSWORD` |

## Optional widgets

Unraid, qBittorrent, Plex, Forgejo, Home Assistant, and Ghostfolio are listed as
links/status entries only unless valid widget credentials are added. Do not add
widgets with empty or expired credentials; Homepage will proxy those requests and
log repeated widget errors.

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
