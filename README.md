# Xray Reality Alpine Script

This repo contains one main installer/manager script:

- `xray-reality-alpine.sh`

## What it does

- Downloads the latest `Xray-core` release from GitHub.
- Installs a minimal `VLESS + REALITY + Vision` inbound.
- Writes an OpenRC service for Xray.
- Writes a second OpenRC service that refreshes traffic state every minute.
- Exports a JSON state file for your own dashboard.
- Optionally serves an HTTP subscription with the remaining traffic in node names.

## Ports

- Default mode: `1` public port, usually `443/tcp`
- `XRAY_STATS_MODE=xray`: adds `1` loopback-only API port, default `127.0.0.1:10085`
- Optional subscription: `1` HTTP port, default `8080/tcp` when enabled.
- If your provider maps an external port to the container, keep `XRAY_PORT`
  as the internal/container port and use the external port only in the client link.

## Install

```sh
busybox wget -O xray-reality-alpine.sh https://raw.githubusercontent.com/Amor520/Xray-T/main/xray-reality-alpine.sh
chmod +x ./xray-reality-alpine.sh
./xray-reality-alpine.sh install
```

The interactive installer uses Chinese prompts and keeps the question list
short. It asks for the node name, users, quota, Xray internal/public port, and
whether to enable an HTTP subscription. Subscription ports are only asked when
subscription is enabled.

For unattended installs:

```sh
XRAY_USERS="alice,bob" \
  XRAY_NODE_NAME="My Node" \
  XRAY_TOTAL_GB=100 \
  XRAY_PORT=443 \
  XRAY_PUBLIC_HOST="203.0.113.10" \
  XRAY_PUBLIC_PORT=443 \
  XRAY_SUB_ENABLE=1 \
  XRAY_SUB_PORT=8080 \
  XRAY_SUB_PUBLIC_PORT=8080 \
  XRAY_REALITY_TARGET="www.cloudflare.com:443" \
  XRAY_REALITY_SERVER_NAMES="www.cloudflare.com" \
  ./xray-reality-alpine.sh install --no-interactive
```

The installer is intentionally light. On Alpine it prefers BusyBox `wget`
and `unzip`, and it does not pull in `jq`.

The default traffic mode is `XRAY_STATS_MODE=interface`, which reads network
interface counters and is safest on 128MB machines. If you need per-user Xray
statistics and have enough memory, install with `XRAY_STATS_MODE=xray`.

`XRAY_NETWORK` defaults to `tcp`, which is the most widely compatible value for
VLESS + REALITY + Vision client imports.

## Useful files

- `/etc/xray/config.json`
- `/etc/xray/users.tsv`
- `/etc/xray/reality.keys`
- `/etc/xray/connection-info.txt`
- `/etc/xray/share-links.txt`
- `/var/lib/xray-board/state.json`
- `/var/lib/xray-board/title.txt`
- `/etc/xray/subscription-info.txt`
- `/var/lib/xray-sub/<token>`
- `/var/lib/xray-sub/<token>.txt`

## Dashboard output

The watcher writes a JSON blob like:

```json
{
  "node_name": "My Node",
  "title": "My Node | 剩余 87.23 GB",
  "updated_at": "2026-05-15T00:00:00Z",
  "stats_mode": "interface",
  "netdev": "eth0",
  "total_quota_bytes": 107374182400,
  "total_used_bytes": 14533201920,
  "remaining_bytes": 92840980480,
  "remaining_human": "87.23 GB",
  "users": [
    {
      "email": "alice",
      "uuid": "....",
      "used_bytes": 123,
      "used_human": "123 B"
    }
  ]
}
```

Your own board can poll `state.json` or `title.txt` every minute.

When subscription is enabled, the watcher also refreshes the subscription files
every minute. Use the base64 URL from `/etc/xray/subscription-info.txt` for most
clients, or the `.txt` URL for clients that prefer plain `vless://` lines.
The public subscription URLs are served through a tiny CGI endpoint that adds a
`Subscription-Userinfo` response header, so Sub-Store and compatible clients can
show traffic usage. Static fallback URLs are also written to
`/etc/xray/subscription-info.txt`.
The installer also prints direct `vless://` import links and stores them in
`/etc/xray/share-links.txt`.
