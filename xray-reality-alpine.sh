#!/bin/sh
set -eu

APP_NAME="xray-reality-alpine"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_ETC_DIR="${XRAY_ETC_DIR:-/etc/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-$XRAY_ETC_DIR/config.json}"
XRAY_USERS_FILE="${XRAY_USERS_FILE:-$XRAY_ETC_DIR/users.tsv}"
XRAY_LOG_DIR="${XRAY_LOG_DIR:-/var/log/xray}"
XRAY_BOARD_DIR="${XRAY_BOARD_DIR:-/var/lib/xray-board}"
XRAY_STATE_FILE="${XRAY_STATE_FILE:-$XRAY_BOARD_DIR/state.json}"
XRAY_TITLE_FILE="${XRAY_TITLE_FILE:-$XRAY_BOARD_DIR/title.txt}"
XRAY_PORT="${XRAY_PORT:-443}"
XRAY_API_PORT="${XRAY_API_PORT:-10085}"
XRAY_NODE_NAME="${XRAY_NODE_NAME:-Xray Node}"
XRAY_TOTAL_GB="${XRAY_TOTAL_GB:-100}"
XRAY_REALITY_TARGET="${XRAY_REALITY_TARGET:-www.cloudflare.com:443}"
XRAY_REALITY_SERVER_NAMES="${XRAY_REALITY_SERVER_NAMES:-www.cloudflare.com}"
XRAY_USERS="${XRAY_USERS:-user1}"
XRAY_LISTEN="${XRAY_LISTEN:-0.0.0.0}"
XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME:-xray}"
XRAY_WATCH_SERVICE_NAME="${XRAY_WATCH_SERVICE_NAME:-xray-traffic-watch}"
XRAY_SYNC_INTERVAL="${XRAY_SYNC_INTERVAL:-60}"

die() {
  printf '%s\n' "[$APP_NAME] $*" >&2
  exit 1
}

info() {
  printf '%s\n' "[$APP_NAME] $*"
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g; s/\n/\\n/g'
}

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB PB", unit, " ");
    i = 1;
    while (b >= 1024 && i < 6) {
      b /= 1024;
      i++;
    }
    if (i == 1) {
      printf "%.0f %s", b, unit[i];
    } else {
      printf "%.2f %s", b, unit[i];
    }
  }'
}

bytes_from_gb() {
  awk -v gb="${1:-0}" 'BEGIN { printf "%.0f", gb * 1024 * 1024 * 1024 }'
}

ensure_dirs() {
  install -d -m 0755 "$XRAY_ETC_DIR" "$XRAY_LOG_DIR" "$XRAY_BOARD_DIR"
}

install_deps() {
  have apk || die "this installer currently targets Alpine Linux"
  apk add --no-cache curl jq unzip ca-certificates >/dev/null
}

detect_asset_suffix() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) printf '%s\n' "64" ;;
    aarch64|arm64) printf '%s\n' "arm64-v8a" ;;
    armv7l|armv7) printf '%s\n' "arm32-v7a" ;;
    i386|i686) printf '%s\n' "32" ;;
    *) die "unsupported architecture: $arch" ;;
  esac
}

latest_release_json() {
  curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest"
}

download_latest_xray() {
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT INT TERM

  release_json="$(latest_release_json)"
  tag_name="$(printf '%s\n' "$release_json" | jq -r '.tag_name')"
  [ -n "$tag_name" ] && [ "$tag_name" != "null" ] || die "failed to read latest Xray tag"

  suffix="$(detect_asset_suffix)"
  asset_name="Xray-linux-${suffix}.zip"
  asset_url="$(printf '%s\n' "$release_json" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' | head -n 1)"
  [ -n "$asset_url" ] && [ "$asset_url" != "null" ] || die "could not find asset ${asset_name}"

  info "downloading Xray ${tag_name} (${asset_name})"
  curl -fsSL -o "$tmpdir/xray.zip" "$asset_url"
  unzip -o -q "$tmpdir/xray.zip" -d "$tmpdir/unpacked"

  install -d -m 0755 /usr/local/share/xray
  install -m 0755 "$tmpdir/unpacked/xray" "$XRAY_BIN"
  [ -f "$tmpdir/unpacked/geoip.dat" ] && install -m 0644 "$tmpdir/unpacked/geoip.dat" /usr/local/share/xray/geoip.dat
  [ -f "$tmpdir/unpacked/geosite.dat" ] && install -m 0644 "$tmpdir/unpacked/geosite.dat" /usr/local/share/xray/geosite.dat
}

parse_x25519_output() {
  output="$1"
  private="$(printf '%s\n' "$output" | awk -F': *' '/^Private[[:space:]]*key$|^PrivateKey$/ {print $2; exit}')"
  public="$(printf '%s\n' "$output" | awk -F': *' '/^Public[[:space:]]*key$|^Password$/ {print $2; exit}')"
  [ -n "${private:-}" ] || die "failed to parse x25519 private key"
  [ -n "${public:-}" ] || die "failed to parse x25519 public key"
  printf '%s\n%s\n' "$private" "$public"
}

ensure_reality_keys() {
  key_file="$XRAY_ETC_DIR/reality.keys"
  if [ -f "$key_file" ]; then
    private_key="$(awk -F= '/^private=/ {print $2; exit}' "$key_file")"
    public_key="$(awk -F= '/^public=/ {print $2; exit}' "$key_file")"
  else
    output="$("$XRAY_BIN" x25519)"
    parsed="$(parse_x25519_output "$output")"
    private_key="$(printf '%s\n' "$parsed" | sed -n '1p')"
    public_key="$(printf '%s\n' "$parsed" | sed -n '2p')"
    umask 077
    {
      printf 'private=%s\n' "$private_key"
      printf 'public=%s\n' "$public_key"
    } > "$key_file"
    chmod 0600 "$key_file"
  fi

  [ -n "${private_key:-}" ] || die "missing reality private key"
  [ -n "${public_key:-}" ] || die "missing reality public key"
  printf '%s\n%s\n' "$private_key" "$public_key"
}

generate_short_id() {
  od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

render_users() {
  users_json='['
  users_rows=''
  comma=''

  old_ifs=$IFS
  IFS=,
  set -- $XRAY_USERS
  IFS=$old_ifs

  [ "$#" -ge 1 ] || die "XRAY_USERS is empty"

  for email in "$@"; do
    email="$(trim "$email")"
    [ -n "$email" ] || continue
    uid=''
    if [ -f "$XRAY_USERS_FILE" ]; then
      uid="$(awk -F '\t' -v email="$email" '$1 == email { print $2; exit }' "$XRAY_USERS_FILE" 2>/dev/null || true)"
    fi
    [ -n "$uid" ] || uid="$("$XRAY_BIN" uuid)"
    escaped_email="$(json_escape "$email")"
    users_json="${users_json}${comma}{\"id\":\"${uid}\",\"level\":0,\"email\":\"${escaped_email}\",\"flow\":\"xtls-rprx-vision\"}"
    users_rows="${users_rows}${email}\t${uid}\n"
    comma=','
  done

  users_json="${users_json}]"
  printf '%s\n' "$users_json"
  printf '%b' "$users_rows" > "$XRAY_USERS_FILE"
  chmod 0644 "$XRAY_USERS_FILE"
}

render_config() {
  private_key="$1"
  short_id="$2"
  users_json="$3"
  server_names_json='['
  comma=''
  old_ifs=$IFS
  IFS=,
  set -- $XRAY_REALITY_SERVER_NAMES
  IFS=$old_ifs
  for server_name in "$@"; do
    server_name="$(trim "$server_name")"
    [ -n "$server_name" ] || continue
    server_names_json="${server_names_json}${comma}\"$(json_escape "$server_name")\""
    comma=','
  done
  server_names_json="${server_names_json}]"

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "error",
    "access": "/dev/null",
    "error": "$XRAY_LOG_DIR/error.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "listen": "127.0.0.1:${XRAY_API_PORT}",
    "services": [
      "StatsService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 0,
        "downlinkOnly": 0,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false,
      "statsOutboundUplink": false,
      "statsOutboundDownlink": false
    }
  },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "${XRAY_LISTEN}",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "users": ${users_json},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$(json_escape "$XRAY_REALITY_TARGET")",
          "xver": 0,
          "serverNames": ${server_names_json},
          "privateKey": "$(json_escape "$private_key")",
          "shortIds": ["$(json_escape "$short_id")"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
  chmod 0644 "$XRAY_CONFIG"
}

render_service() {
  cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

description="Xray core"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"

depend() {
  need net
}

start_pre() {
  /usr/local/bin/xray run -test -config /etc/xray/config.json || return 1
}
EOF
  chmod 0755 /etc/init.d/xray
}

render_watch_script() {
  cat > /usr/local/bin/xray-traffic-watch.sh <<'EOF'
#!/bin/sh
set -eu
umask 022

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_API_PORT="${XRAY_API_PORT:-10085}"
XRAY_USERS_FILE="${XRAY_USERS_FILE:-/etc/xray/users.tsv}"
XRAY_STATE_FILE="${XRAY_STATE_FILE:-/var/lib/xray-board/state.json}"
XRAY_TITLE_FILE="${XRAY_TITLE_FILE:-/var/lib/xray-board/title.txt}"
XRAY_NODE_NAME="${XRAY_NODE_NAME:-Xray Node}"
XRAY_TOTAL_GB="${XRAY_TOTAL_GB:-100}"
XRAY_SYNC_INTERVAL="${XRAY_SYNC_INTERVAL:-60}"

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB PB", unit, " ");
    i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%.0f %s", b, unit[i]; else printf "%.2f %s", b, unit[i];
  }'
}

query_stat() {
  email="$1"
  stats_json="$2"
  printf '%s\n' "$stats_json" | jq -r --arg email "$email" '
    [ .stat[]? | select(.name == ("user>>>" + $email + ">>>traffic>>>uplink") or .name == ("user>>>" + $email + ">>>traffic>>>downlink")) | (.value // 0) ] | add // 0
  '
}

sync_once() {
  if ! stats_json="$("$XRAY_BIN" api statsquery --server="127.0.0.1:${XRAY_API_PORT}" -pattern 'user>>>' 2>/dev/null)"; then
    stats_json='{"stat":[]}'
  fi

  total_quota_bytes="$(awk -v gb="$XRAY_TOTAL_GB" 'BEGIN { printf "%.0f", gb * 1024 * 1024 * 1024 }')"
  total_used_bytes=0
  users_json='['
  comma=''

  while IFS="$(printf '\t')" read -r email uuid; do
    email="$(trim "$email")"
    uuid="$(trim "$uuid")"
    [ -n "${email:-}" ] || continue
    used_bytes="$(query_stat "$email" "$stats_json")"
    total_used_bytes=$((total_used_bytes + used_bytes))
    users_json="${users_json}${comma}{\"email\":\"$(printf '%s' "$email" | sed 's/\\/\\\\/g; s/"/\\"/g')\",\"uuid\":\"$(printf '%s' "$uuid" | sed 's/\\/\\\\/g; s/"/\\"/g')\",\"used_bytes\":${used_bytes},\"used_human\":\"$(human_bytes "$used_bytes")\"}"
    comma=','
  done < "$XRAY_USERS_FILE"

  users_json="${users_json}]"

  if [ "$total_used_bytes" -gt "$total_quota_bytes" ]; then
    remaining_bytes=0
  else
    remaining_bytes=$((total_quota_bytes - total_used_bytes))
  fi

  title="${XRAY_NODE_NAME} | 剩余 $(human_bytes "$remaining_bytes")"
  remaining_human="$(human_bytes "$remaining_bytes")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  install -d -m 0755 "$(dirname "$XRAY_STATE_FILE")"
  printf '%s\n' "$title" > "$XRAY_TITLE_FILE"

  jq -n \
    --arg node_name "$XRAY_NODE_NAME" \
    --arg title "$title" \
    --arg updated_at "$now" \
    --argjson total_quota_bytes "$total_quota_bytes" \
    --argjson total_used_bytes "$total_used_bytes" \
    --argjson remaining_bytes "$remaining_bytes" \
    --arg remaining_human "$remaining_human" \
    --argjson users "$users_json" \
    '{
      node_name: $node_name,
      title: $title,
      updated_at: $updated_at,
      total_quota_bytes: $total_quota_bytes,
      total_used_bytes: $total_used_bytes,
      remaining_bytes: $remaining_bytes,
      remaining_human: $remaining_human,
      users: $users
    }' > "$XRAY_STATE_FILE"
}

if [ "${1:-}" = "--once" ]; then
  sync_once
  exit 0
fi

while :; do
  sync_once || true
  sleep "${XRAY_SYNC_INTERVAL}"
done
EOF
  chmod 0755 /usr/local/bin/xray-traffic-watch.sh
}

render_watch_service() {
  cat > /etc/init.d/xray-traffic-watch <<'EOF'
#!/sbin/openrc-run

description="Xray traffic watcher"
command="/usr/local/bin/xray-traffic-watch.sh"
command_background="yes"
pidfile="/run/xray-traffic-watch.pid"

depend() {
  need xray
  need net
}
EOF
  chmod 0755 /etc/init.d/xray-traffic-watch
}

backup_if_exists() {
  path="$1"
  if [ -e "$path" ]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "${path}.bak.${ts}"
  fi
}

write_connection_info() {
  public_key="$1"
  short_id="$2"
  {
    printf 'public_key=%s\n' "$public_key"
    printf 'short_id=%s\n' "$short_id"
    printf 'port=%s\n' "$XRAY_PORT"
    printf 'api_port=%s\n' "$XRAY_API_PORT"
    printf 'target=%s\n' "$XRAY_REALITY_TARGET"
    printf 'server_names=%s\n' "$XRAY_REALITY_SERVER_NAMES"
    printf 'users_file=%s\n' "$XRAY_USERS_FILE"
  } > "$XRAY_ETC_DIR/connection-info.txt"
  chmod 0644 "$XRAY_ETC_DIR/connection-info.txt"
}

install_all() {
  need_root
  install_deps
  ensure_dirs
  download_latest_xray

  if ! have rc-update; then
    info "OpenRC tools not found; service files will still be written"
  fi

  private_public="$(ensure_reality_keys)"
  private_key="$(printf '%s\n' "$private_public" | sed -n '1p')"
  public_key="$(printf '%s\n' "$private_public" | sed -n '2p')"

  short_id="${XRAY_SHORT_ID:-$(generate_short_id)}"

  users_json="$(render_users)"

  backup_if_exists "$XRAY_CONFIG"
  render_config "$private_key" "$short_id" "$users_json"
  write_connection_info "$public_key" "$short_id"

  render_service
  render_watch_script
  render_watch_service

  if have rc-update; then
    rc-update add xray default >/dev/null 2>&1 || true
    rc-update add xray-traffic-watch default >/dev/null 2>&1 || true
  fi

  if have rc-service; then
    rc-service xray restart >/dev/null 2>&1 || rc-service xray start >/dev/null 2>&1 || true
    rc-service xray-traffic-watch restart >/dev/null 2>&1 || rc-service xray-traffic-watch start >/dev/null 2>&1 || true
  fi

  info "installed Xray at $XRAY_BIN"
  info "config: $XRAY_CONFIG"
  info "state:  $XRAY_STATE_FILE"
  info "API port: 127.0.0.1:${XRAY_API_PORT}"
  info "public port: ${XRAY_PORT}"
  info "public key: $public_key"
  info "short id: $short_id"
  info "users: $XRAY_USERS_FILE"
  info "user UUIDs:"
  awk -F '\t' 'NF >= 2 { printf "  %s -> %s\n", $1, $2 }' "$XRAY_USERS_FILE"
}

sync_once() {
  XRAY_BIN="${XRAY_BIN}" XRAY_API_PORT="${XRAY_API_PORT}" XRAY_USERS_FILE="${XRAY_USERS_FILE}" XRAY_STATE_FILE="${XRAY_STATE_FILE}" XRAY_TITLE_FILE="${XRAY_TITLE_FILE}" XRAY_NODE_NAME="${XRAY_NODE_NAME}" XRAY_TOTAL_GB="${XRAY_TOTAL_GB}" /usr/local/bin/xray-traffic-watch.sh --once
}

show_status() {
  if [ -f "$XRAY_STATE_FILE" ]; then
    cat "$XRAY_STATE_FILE"
  else
    die "state file not found: $XRAY_STATE_FILE"
  fi
}

usage() {
  cat <<EOF
Usage:
  $0 install
  $0 sync
  $0 status

Environment:
  XRAY_USERS="alice,bob"
  XRAY_NODE_NAME="My Node"
  XRAY_TOTAL_GB=100
  XRAY_PORT=443
  XRAY_API_PORT=10085
  XRAY_REALITY_TARGET="www.cloudflare.com:443"
  XRAY_REALITY_SERVER_NAMES="www.cloudflare.com"
  XRAY_SHORT_ID=optional-short-id
EOF
}

cmd="${1:-}"
case "$cmd" in
  install) install_all ;;
  sync) need_root; sync_once ;;
  status) show_status ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
