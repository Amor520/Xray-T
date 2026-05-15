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
XRAY_BASELINE_FILE="${XRAY_BASELINE_FILE:-$XRAY_BOARD_DIR/baseline.env}"
XRAY_WATCH_ENV_FILE="${XRAY_WATCH_ENV_FILE:-$XRAY_ETC_DIR/traffic-watch.env}"
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
XRAY_STATS_MODE="${XRAY_STATS_MODE:-interface}"
XRAY_NETDEV="${XRAY_NETDEV:-}"

die() {
  printf '%s\n' "[$APP_NAME] $*" >&2
  exit 1
}

info() {
  printf '%s\n' "[$APP_NAME] $*" >&2
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

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
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
  if have busybox && busybox --list 2>/dev/null | grep -qx wget; then
    return 0
  fi
  have wget || have curl || die "install wget or curl first"
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

have_busybox_unzip() {
  have busybox && busybox --list 2>/dev/null | grep -qx unzip
}

download_url() {
  url="$1"
  dest="$2"

  if have busybox && busybox --list 2>/dev/null | grep -qx wget; then
    busybox wget -O "$dest" "$url" >/dev/null 2>&1 && return 0
  fi

  if have wget && wget --help 2>&1 | grep -q -- '--inet4-only'; then
    wget -4 -O "$dest" "$url" >/dev/null 2>&1 && return 0
  fi

  if have wget; then
    wget -O "$dest" "$url" >/dev/null 2>&1 && return 0
  fi

  if have curl; then
    curl -4 -fL -o "$dest" "$url" >/dev/null 2>&1 && return 0
    curl -fL -o "$dest" "$url" >/dev/null 2>&1 && return 0
  fi

  die "failed to download $url"
}

extract_zip() {
  zip_file="$1"
  dest_dir="$2"

  if have_busybox_unzip; then
    busybox unzip -o "$zip_file" xray -d "$dest_dir" >/dev/null
    return 0
  fi

  if have unzip; then
    unzip -o -q "$zip_file" xray -d "$dest_dir"
    return 0
  fi

  die "need unzip support; on Alpine, busybox usually provides it, otherwise install unzip"
}

download_latest_xray() {
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT INT TERM

  suffix="$(detect_asset_suffix)"
  asset_name="Xray-linux-${suffix}.zip"
  asset_url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset_name}"

  info "downloading latest Xray (${asset_name})"
  download_url "$asset_url" "$tmpdir/xray.zip"
  info "extracting Xray binary"
  extract_zip "$tmpdir/xray.zip" "$tmpdir/unpacked"

  install -d -m 0755 /usr/local/share/xray
  install -m 0755 "$tmpdir/unpacked/xray" "$XRAY_BIN"

  if ! "$XRAY_BIN" version >/dev/null 2>&1; then
    die "downloaded Xray binary exists but cannot execute on this system"
  fi
}

parse_x25519_output() {
  output="$1"
  private="$(printf '%s\n' "$output" | awk -F': *' '/^(Private[[:space:]]*key|PrivateKey):/ {print $2; exit}')"
  public="$(printf '%s\n' "$output" | awk -F': *' '/^(Public[[:space:]]*key|PublicKey|Password)/ {print $2; exit}')"
  [ -n "${private:-}" ] || die "failed to parse x25519 private key"
  [ -n "${public:-}" ] || die "failed to parse x25519 public key"
  printf '%s\n%s\n' "$private" "$public"
}

ensure_reality_keys() {
  key_file="$XRAY_ETC_DIR/reality.keys"
  if [ -f "$key_file" ]; then
    private_key="$(awk -F= '/^private=/ {print $2; exit}' "$key_file")"
    public_key="$(awk -F= '/^public=/ {print $2; exit}' "$key_file")"
    if [ -n "${private_key:-}" ] && [ -n "${public_key:-}" ]; then
      printf '%s\n%s\n' "$private_key" "$public_key"
      return 0
    fi
    info "existing Reality key file is incomplete; regenerating"
    rm -f "$key_file"
  fi

  info "generating Reality keypair"
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

XRAY_WATCH_ENV_FILE="${XRAY_WATCH_ENV_FILE:-/etc/xray/traffic-watch.env}"
[ -f "$XRAY_WATCH_ENV_FILE" ] && . "$XRAY_WATCH_ENV_FILE"

: "${XRAY_BIN:=/usr/local/bin/xray}"
: "${XRAY_API_PORT:=10085}"
: "${XRAY_USERS_FILE:=/etc/xray/users.tsv}"
: "${XRAY_STATE_FILE:=/var/lib/xray-board/state.json}"
: "${XRAY_TITLE_FILE:=/var/lib/xray-board/title.txt}"
: "${XRAY_BASELINE_FILE:=/var/lib/xray-board/baseline.env}"
: "${XRAY_NODE_NAME:=Xray Node}"
: "${XRAY_TOTAL_GB:=100}"
: "${XRAY_SYNC_INTERVAL:=60}"
: "${XRAY_STATS_MODE:=interface}"
: "${XRAY_NETDEV:=}"

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
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%.0f %s", b, unit[i]; else printf "%.2f %s", b, unit[i];
  }'
}

stat_value() {
  target="$1"
  stats_json="$2"
  printf '%s\n' "$stats_json" | sed 's/[{},]/\n/g' | awk -v target="$target" '
    $0 ~ /"name"[[:space:]]*:/ {
      line=$0
      sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      current=line
    }
    current == target && $0 ~ /"value"[[:space:]]*:/ {
      line=$0
      sub(/^.*"value"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      gsub(/[^0-9]/, "", line)
      print line
      exit
    }
  '
}

query_stat() {
  email="$1"
  stats_json="$2"
  uplink="$(stat_value "user>>>${email}>>>traffic>>>uplink" "$stats_json")"
  downlink="$(stat_value "user>>>${email}>>>traffic>>>downlink" "$stats_json")"
  printf '%s\n' "$(( ${uplink:-0} + ${downlink:-0} ))"
}

users_json_unknown() {
  users_json='['
  comma=''
  while IFS="$(printf '\t')" read -r email uuid; do
    email="$(trim "$email")"
    uuid="$(trim "$uuid")"
    [ -n "${email:-}" ] || continue
    users_json="${users_json}${comma}{\"email\":\"$(json_escape "$email")\",\"uuid\":\"$(json_escape "$uuid")\",\"used_bytes\":null,\"used_human\":null,\"tracked\":false}"
    comma=','
  done < "$XRAY_USERS_FILE"
  printf '%s]\n' "$users_json"
}

detect_netdev() {
  if [ -n "$XRAY_NETDEV" ]; then
    printf '%s\n' "$XRAY_NETDEV"
    return 0
  fi

  if [ -r /proc/net/route ]; then
    awk '$2 == "00000000" { print $1; exit }' /proc/net/route
    return 0
  fi

  awk -F: 'NR > 2 { gsub(/[ \t]/, "", $1); if ($1 != "lo") { print $1; exit } }' /proc/net/dev
}

read_netdev_total() {
  dev="$1"
  rx_file="/sys/class/net/${dev}/statistics/rx_bytes"
  tx_file="/sys/class/net/${dev}/statistics/tx_bytes"

  if [ -r "$rx_file" ] && [ -r "$tx_file" ]; then
    read -r rx < "$rx_file"
    read -r tx < "$tx_file"
    printf '%s\n' "$(( ${rx:-0} + ${tx:-0} ))"
    return 0
  fi

  awk -v dev="$dev" -F '[: ]+' '$2 == dev { print $3 + $11; exit }' /proc/net/dev
}

baseline_value() {
  key="$1"
  [ -f "$XRAY_BASELINE_FILE" ] || return 0
  awk -F= -v key="$key" '$1 == key { print $2; exit }' "$XRAY_BASELINE_FILE"
}

write_baseline() {
  dev="$1"
  total="$2"
  install -d -m 0755 "$(dirname "$XRAY_BASELINE_FILE")"
  {
    printf 'netdev=%s\n' "$dev"
    printf 'total=%s\n' "$total"
  } > "$XRAY_BASELINE_FILE"
}

sync_interface() {
  netdev="$(detect_netdev)"
  [ -n "$netdev" ] || netdev="unknown"
  current_total=0

  if [ "$netdev" != "unknown" ]; then
    current_total="$(read_netdev_total "$netdev")"
  fi

  baseline_netdev="$(baseline_value netdev || true)"
  baseline_total="$(baseline_value total || true)"

  if [ -z "${baseline_total:-}" ] || [ "$baseline_netdev" != "$netdev" ] || [ "$current_total" -lt "$baseline_total" ]; then
    baseline_total="$current_total"
    write_baseline "$netdev" "$baseline_total"
  fi

  total_used_bytes=$((current_total - baseline_total))
  users_json="$(users_json_unknown)"
  write_state "$total_used_bytes" "$users_json" "interface" "$netdev"
}

sync_xray() {
  if ! stats_json="$("$XRAY_BIN" api statsquery --server="127.0.0.1:${XRAY_API_PORT}" -pattern 'user>>>' 2>/dev/null)"; then
    stats_json='{"stat":[]}'
  fi

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
  write_state "$total_used_bytes" "$users_json" "xray" ""
}

write_state() {
  total_used_bytes="$1"
  users_json="$2"
  stats_mode="$3"
  netdev="$4"
  total_quota_bytes="$(awk -v gb="$XRAY_TOTAL_GB" 'BEGIN { printf "%.0f", gb * 1024 * 1024 * 1024 }')"

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

  {
    printf '{\n'
    printf '  "node_name": "%s",\n' "$(json_escape "$XRAY_NODE_NAME")"
    printf '  "title": "%s",\n' "$(json_escape "$title")"
    printf '  "updated_at": "%s",\n' "$(json_escape "$now")"
    printf '  "stats_mode": "%s",\n' "$(json_escape "$stats_mode")"
    printf '  "netdev": "%s",\n' "$(json_escape "$netdev")"
    printf '  "total_quota_bytes": %s,\n' "$total_quota_bytes"
    printf '  "total_used_bytes": %s,\n' "$total_used_bytes"
    printf '  "remaining_bytes": %s,\n' "$remaining_bytes"
    printf '  "remaining_human": "%s",\n' "$(json_escape "$remaining_human")"
    printf '  "users": %s\n' "$users_json"
    printf '}\n'
  } > "$XRAY_STATE_FILE"
}

sync_once() {
  case "$XRAY_STATS_MODE" in
    interface) sync_interface ;;
    xray) sync_xray ;;
    *) XRAY_STATS_MODE=interface; sync_interface ;;
  esac
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

render_watch_env() {
  {
    printf 'XRAY_BIN=%s\n' "$(shell_quote "$XRAY_BIN")"
    printf 'XRAY_API_PORT=%s\n' "$(shell_quote "$XRAY_API_PORT")"
    printf 'XRAY_USERS_FILE=%s\n' "$(shell_quote "$XRAY_USERS_FILE")"
    printf 'XRAY_STATE_FILE=%s\n' "$(shell_quote "$XRAY_STATE_FILE")"
    printf 'XRAY_TITLE_FILE=%s\n' "$(shell_quote "$XRAY_TITLE_FILE")"
    printf 'XRAY_BASELINE_FILE=%s\n' "$(shell_quote "$XRAY_BASELINE_FILE")"
    printf 'XRAY_NODE_NAME=%s\n' "$(shell_quote "$XRAY_NODE_NAME")"
    printf 'XRAY_TOTAL_GB=%s\n' "$(shell_quote "$XRAY_TOTAL_GB")"
    printf 'XRAY_SYNC_INTERVAL=%s\n' "$(shell_quote "$XRAY_SYNC_INTERVAL")"
    printf 'XRAY_STATS_MODE=%s\n' "$(shell_quote "$XRAY_STATS_MODE")"
    printf 'XRAY_NETDEV=%s\n' "$(shell_quote "$XRAY_NETDEV")"
  } > "$XRAY_WATCH_ENV_FILE"
  chmod 0644 "$XRAY_WATCH_ENV_FILE"
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
    printf 'stats_mode=%s\n' "$XRAY_STATS_MODE"
    printf 'netdev=%s\n' "$XRAY_NETDEV"
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
  info "checking latest release"
  download_latest_xray

  if ! have rc-update; then
    info "OpenRC tools not found; service files will still be written"
  fi

  private_public="$(ensure_reality_keys)"
  private_key="$(printf '%s\n' "$private_public" | sed -n '1p')"
  public_key="$(printf '%s\n' "$private_public" | sed -n '2p')"

  short_id="${XRAY_SHORT_ID:-$(generate_short_id)}"

  info "writing users and config"
  users_json="$(render_users)"

  backup_if_exists "$XRAY_CONFIG"
  render_config "$private_key" "$short_id" "$users_json"
  write_connection_info "$public_key" "$short_id"

  info "writing OpenRC services"
  render_watch_env
  render_service
  render_watch_script
  render_watch_service

  if have rc-update; then
    info "enabling services"
    rc-update add xray default >/dev/null 2>&1 || true
    rc-update add xray-traffic-watch default >/dev/null 2>&1 || true
  fi

  if have rc-service; then
    info "starting services"
    if rc-service xray status >/dev/null 2>&1; then
      rc-service xray restart
    else
      rc-service xray start
    fi
    rc-service xray-traffic-watch stop >/dev/null 2>&1 || true
    rc-service xray-traffic-watch start
  fi

  info "installed Xray at $XRAY_BIN"
  info "config: $XRAY_CONFIG"
  info "state:  $XRAY_STATE_FILE"
  info "API port: 127.0.0.1:${XRAY_API_PORT}"
  info "public port: ${XRAY_PORT}"
  info "stats mode: ${XRAY_STATS_MODE}"
  info "public key: $public_key"
  info "short id: $short_id"
  info "users: $XRAY_USERS_FILE"
  info "user UUIDs:"
  awk -F '\t' 'NF >= 2 { printf "  %s -> %s\n", $1, $2 }' "$XRAY_USERS_FILE"
}

sync_once() {
  XRAY_WATCH_ENV_FILE="${XRAY_WATCH_ENV_FILE}" /usr/local/bin/xray-traffic-watch.sh --once
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
  XRAY_STATS_MODE=interface
  XRAY_NETDEV=optional-interface-name
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
