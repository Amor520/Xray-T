# Xray Reality Alpine Script

This repo contains one main installer/manager script:

- `xray-reality-alpine.sh`

## What it does

- Downloads the latest `Xray-core` release from GitHub.
- Installs a minimal `VLESS + REALITY + Vision` inbound.
- Writes an OpenRC service for Xray.
- Writes a second OpenRC service that refreshes traffic state every minute.
- Exports a JSON state file for your own dashboard.

## Ports

- Public inbound: `1` port, usually `443/tcp`
- Local API: `1` loopback-only port, default `127.0.0.1:10085`, kept for optional Xray stats mode

## Install

```sh
busybox wget -O xray-reality-alpine.sh https://raw.githubusercontent.com/Amor520/Xray-T/main/xray-reality-alpine.sh
chmod +x ./xray-reality-alpine.sh
sudo XRAY_USERS="alice,bob" \
  XRAY_NODE_NAME="My Node" \
  XRAY_TOTAL_GB=100 \
  XRAY_REALITY_TARGET="www.cloudflare.com:443" \
  XRAY_REALITY_SERVER_NAMES="www.cloudflare.com" \
  ./xray-reality-alpine.sh install
```

The installer is intentionally light. On Alpine it prefers BusyBox `wget`
and `unzip`, and it does not pull in `jq`.

The default traffic mode is `XRAY_STATS_MODE=interface`, which reads network
interface counters and is safest on 128MB machines. If you need per-user Xray
statistics and have enough memory, install with `XRAY_STATS_MODE=xray`.

## Useful files

- `/etc/xray/config.json`
- `/etc/xray/users.tsv`
- `/etc/xray/reality.keys`
- `/etc/xray/connection-info.txt`
- `/var/lib/xray-board/state.json`
- `/var/lib/xray-board/title.txt`

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
