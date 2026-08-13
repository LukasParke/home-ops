# Centaur

[Centaur](https://github.com/paradigmxyz/centaur) runs in the
`centaur-system` namespace. Flux installs the upstream Helm chart and exposes
its Console internally at `https://centaur.${SECRET_DOMAIN}`.

## Initial setup

The deployment includes generated SOPS-encrypted infrastructure credentials and
a private firewall CA. Codex uses the local Bifrost deployment with
`cerberus/gpt-oss-120b` by default. A dedicated in-cluster adapter injects the
existing `GRAPHITI_BIFROST_VK`; the key is never exposed to sandbox pods.

The encrypted `OPENAI_API_KEY` sentinel exists only because Centaur requires its
built-in OpenAI harness credential to initialize. Requests do not go to OpenAI.

The initial Console user is
`5702154+LukasParke@users.noreply.github.com`. Retrieve its generated password
locally:

```sh
sops --decrypt kubernetes/apps/centaur/centaur/app/centaur-secrets.sops.yaml \
  | yq 'select(.metadata.name == "centaur-infra-env") |
      .stringData.IRON_CONTROL_INITIAL_USER_PASSWORD'
```

## Slack

Slack is disabled for the initial deployment. To enable it:

1. Add `SLACK_BOT_TOKEN`, `SLACK_SIGNING_SECRET`, and `SLACKBOT_API_KEY` to
   `centaur-secrets.sops.yaml`.
2. Set `slackbotv2.enabled` to `true` in `helmrelease.yaml`.
3. Add an external `HTTPRoute` for the Slackbot service.
4. Configure Slack event subscriptions and interactivity to use
   `https://<external-host>/api/webhooks/slack`.

## Discord

The Discord workload is fully staged but remains disabled until its application
values are available. It uses Discord's outbound Gateway connection and does not
need a public route.

1. Enable **Message Content Intent** for the Discord application.
2. Add these keys to the `centaur-infra-env` document in
   `centaur-secrets.sops.yaml`:

   ```yaml
   DISCORD_BOT_TOKEN: <bot-token>
   DISCORD_PUBLIC_KEY: <application-public-key>
   DISCORD_APPLICATION_ID: <application-id>
   DISCORDBOT_API_KEY: <generated-service-key>
   ```

   Generate the internal service key with `openssl rand -hex 32`.
3. Set `discordbot.guildAllowlist` in `helmrelease.yaml` to the permitted guild
   ID, or a comma-separated list of guild IDs.
4. Set `discordbot.enabled` to `true`.

The upstream chart enforces one Discord replica with a `Recreate` strategy to
prevent duplicate Gateway sessions during rollouts.
