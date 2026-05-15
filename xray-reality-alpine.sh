#!/bin/sh
set -eu

APP_NAME="xray-reality-alpine"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_ETC_DIR="${XRAY_ETC_DIR:-/etc/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-$XRAY_ETC_DIR/config.json}"
XRAY_USERS_FILE="${XRAY_USERS_FILE:-$XRAY_ETC_DIR/users.tsv}"
XRAY_SHARE_LINKS_FILE="${XRAY_SHARE_LINKS_FILE:-$XRAY_ETC_DIR/share-links.txt}"
XRAY_LOG_DIR="${XRAY_LOG_DIR:-/var/log/xray}"
XRAY_BOARD_DIR="${XRAY_BOARD_DIR:-/var/lib/xray-board}"
XRAY_STATE_FILE="${XRAY_STATE_FILE:-$XRAY_BOARD_DIR/state.json}"
XRAY_TITLE_FILE="${XRAY_TITLE_FILE:-$XRAY_BOARD_DIR/title.txt}"
XRAY_BASELINE_FILE="${XRAY_BASELINE_FILE:-$XRAY_BOARD_DIR/baseline.env}"
XRAY_WATCH_ENV_FILE="${XRAY_WATCH_ENV_FILE:-$XRAY_ETC_DIR/traffic-watch.env}"
XRAY_SUB_ENV_FILE="${XRAY_SUB_ENV_FILE:-$XRAY_ETC_DIR/subscription.env}"
XRAY_PORT="${XRAY_PORT:-443}"
XRAY_PUBLIC_HOST="${XRAY_PUBLIC_HOST:-}"
XRAY_PUBLIC_PORT="${XRAY_PUBLIC_PORT:-$XRAY_PORT}"
XRAY_API_PORT="${XRAY_API_PORT:-10085}"
XRAY_NODE_NAME="${XRAY_NODE_NAME:-Xray Node}"
XRAY_TOTAL_GB="${XRAY_TOTAL_GB:-100}"
XRAY_REALITY_TARGET="${XRAY_REALITY_TARGET:-www.cloudflare.com:443}"
XRAY_REALITY_SERVER_NAMES="${XRAY_REALITY_SERVER_NAMES:-www.cloudflare.com}"
XRAY_USERS="${XRAY_USERS:-user1}"
XRAY_LISTEN="${XRAY_LISTEN:-0.0.0.0}"
XRAY_NETWORK="${XRAY_NETWORK:-tcp}"
XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME:-xray}"
XRAY_WATCH_SERVICE_NAME="${XRAY_WATCH_SERVICE_NAME:-xray-traffic-watch}"
XRAY_SUB_SERVICE_NAME="${XRAY_SUB_SERVICE_NAME:-xray-subscribe}"
XRAY_SYNC_INTERVAL="${XRAY_SYNC_INTERVAL:-60}"
XRAY_STATS_MODE="${XRAY_STATS_MODE:-interface}"
XRAY_NETDEV="${XRAY_NETDEV:-}"
XRAY_SUB_ENABLE="${XRAY_SUB_ENABLE:-0}"
XRAY_SUB_PORT="${XRAY_SUB_PORT:-8080}"
XRAY_SUB_PUBLIC_PORT="${XRAY_SUB_PUBLIC_PORT:-$XRAY_SUB_PORT}"
XRAY_SUB_LISTEN="${XRAY_SUB_LISTEN:-0.0.0.0}"
XRAY_SUB_DIR="${XRAY_SUB_DIR:-/var/lib/xray-sub}"
XRAY_SUB_TOKEN="${XRAY_SUB_TOKEN:-}"
XRAY_INTERACTIVE="${XRAY_INTERACTIVE:-auto}"

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

interactive_enabled() {
  [ "$XRAY_INTERACTIVE" != "0" ] || return 1
  [ "$XRAY_INTERACTIVE" = "1" ] && return 0
  [ -t 0 ]
}

prompt_default() {
  label="$1"
  default_value="$2"
  answer=''
  printf '%s [%s]: ' "$label" "$default_value" >&2
  IFS= read -r answer || answer=''
  if [ -n "$answer" ]; then
    printf '%s\n' "$answer"
  else
    printf '%s\n' "$default_value"
  fi
}

is_port() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 0 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

prompt_port() {
  label="$1"
  default_value="$2"
  while :; do
    value="$(prompt_default "$label" "$default_value")"
    if is_port "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    info "端口无效：$value"
  done
}

prompt_yes_no() {
  label="$1"
  default_value="$2"
  while :; do
    value="$(prompt_default "$label" "$default_value")"
    case "$value" in
      y|Y|yes|YES|Yes|是|开启|開啟) return 0 ;;
      n|N|no|NO|No|否|关闭|關閉) return 1 ;;
      *) info "请输入 y 或 n" ;;
    esac
  done
}

detect_public_host() {
  [ -n "$XRAY_PUBLIC_HOST" ] && {
    printf '%s\n' "$XRAY_PUBLIC_HOST"
    return 0
  }

  if have curl; then
    curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null && return 0
  fi

  if have busybox && busybox --list 2>/dev/null | grep -qx wget; then
    busybox wget -q -T 4 -O - https://api.ipify.org 2>/dev/null && return 0
  fi

  printf '%s\n' "YOUR_SERVER_IP"
}

ask_install_options() {
  interactive_enabled || return 0

  info "交互式安装：直接回车使用默认值"
  detected_host="$(detect_public_host || true)"
  [ -n "$detected_host" ] || detected_host="YOUR_SERVER_IP"

  XRAY_NODE_NAME="$(prompt_default "节点名称" "$XRAY_NODE_NAME")"
  XRAY_USERS="$(prompt_default "用户列表，多个用英文逗号分隔" "$XRAY_USERS")"
  XRAY_TOTAL_GB="$(prompt_default "总流量 GB" "$XRAY_TOTAL_GB")"
  XRAY_PORT="$(prompt_port "Xray 容器内端口" "$XRAY_PORT")"
  XRAY_PUBLIC_HOST="$(prompt_default "公网 IP 或域名" "$detected_host")"
  XRAY_PUBLIC_PORT="$(prompt_port "Xray 公网端口" "$XRAY_PORT")"

  if prompt_yes_no "是否开启订阅链接" "n"; then
    XRAY_SUB_ENABLE=1
    XRAY_SUB_PORT="$(prompt_port "订阅容器内端口" "$XRAY_SUB_PORT")"
    XRAY_SUB_PUBLIC_PORT="$(prompt_port "订阅公网端口" "$XRAY_SUB_PORT")"
  else
    XRAY_SUB_ENABLE=0
    XRAY_SUB_PORT=0
  fi
}

ensure_httpd() {
  [ "$XRAY_SUB_ENABLE" = "1" ] || return 0

  if have busybox && busybox --list 2>/dev/null | grep -qx httpd; then
    return 0
  fi

  if have httpd; then
    return 0
  fi

  if have apk; then
    info "installing busybox-extras for httpd"
    apk add --no-cache busybox-extras >/dev/null
  fi

  if have busybox && busybox --list 2>/dev/null | grep -qx httpd; then
    return 0
  fi

  have httpd || die "subscription needs BusyBox httpd; install busybox-extras or set XRAY_SUB_ENABLE=0"
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

generate_token() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

ensure_sub_token() {
  if [ -n "$XRAY_SUB_TOKEN" ]; then
    printf '%s\n' "$XRAY_SUB_TOKEN"
    return 0
  fi

  if [ -f "$XRAY_SUB_ENV_FILE" ]; then
    token="$(awk -F= '/^XRAY_SUB_TOKEN=/ {print $2; exit}' "$XRAY_SUB_ENV_FILE" | sed "s/^'//; s/'$//")"
    if [ -n "${token:-}" ]; then
      printf '%s\n' "$token"
      return 0
    fi
  fi

  generate_token
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
EOF

  if [ "$XRAY_STATS_MODE" = "xray" ]; then
    cat >> "$XRAY_CONFIG" <<EOF
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
EOF
  fi

  cat >> "$XRAY_CONFIG" <<EOF
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "${XRAY_LISTEN}",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": ${users_json},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "$(json_escape "$XRAY_NETWORK")",
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
: "${XRAY_SUB_ENABLE:=0}"
: "${XRAY_SUB_RENDER_BIN:=/usr/local/bin/xray-subscribe-render.sh}"

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

  if [ "$XRAY_SUB_ENABLE" = "1" ] && [ -x "$XRAY_SUB_RENDER_BIN" ]; then
    "$XRAY_SUB_RENDER_BIN" >/dev/null 2>&1 || true
  fi
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
    printf 'XRAY_SUB_ENABLE=%s\n' "$(shell_quote "$XRAY_SUB_ENABLE")"
    printf 'XRAY_SUB_RENDER_BIN=%s\n' "$(shell_quote "/usr/local/bin/xray-subscribe-render.sh")"
  } > "$XRAY_WATCH_ENV_FILE"
  chmod 0644 "$XRAY_WATCH_ENV_FILE"
}

url_host() {
  host="$1"
  case "$host" in
    \[*\]) printf '%s\n' "$host" ;;
    *:*) printf '[%s]\n' "$host" ;;
    *) printf '%s\n' "$host" ;;
  esac
}

percent_encode_all() {
  printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n' | sed 's/../%&/g'
}

first_reality_server_name() {
  first_server_name="$(printf '%s' "$XRAY_REALITY_SERVER_NAMES" | awk -F, '{print $1}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$first_server_name" ] || first_server_name="www.cloudflare.com"
  printf '%s\n' "$first_server_name"
}

render_subscription_env() {
  public_key="$1"
  short_id="$2"
  first_server_name="$(first_reality_server_name)"

  install -d -m 0755 "$XRAY_SUB_DIR"
  {
    printf 'XRAY_USERS_FILE=%s\n' "$(shell_quote "$XRAY_USERS_FILE")"
    printf 'XRAY_STATE_FILE=%s\n' "$(shell_quote "$XRAY_STATE_FILE")"
    printf 'XRAY_TITLE_FILE=%s\n' "$(shell_quote "$XRAY_TITLE_FILE")"
    printf 'XRAY_SUB_DIR=%s\n' "$(shell_quote "$XRAY_SUB_DIR")"
    printf 'XRAY_SUB_TOKEN=%s\n' "$(shell_quote "$XRAY_SUB_TOKEN")"
    printf 'XRAY_SUB_LISTEN=%s\n' "$(shell_quote "$XRAY_SUB_LISTEN")"
    printf 'XRAY_SUB_PORT=%s\n' "$(shell_quote "$XRAY_SUB_PORT")"
    printf 'XRAY_NODE_NAME=%s\n' "$(shell_quote "$XRAY_NODE_NAME")"
    printf 'XRAY_PUBLIC_HOST=%s\n' "$(shell_quote "$XRAY_PUBLIC_HOST")"
    printf 'XRAY_PUBLIC_PORT=%s\n' "$(shell_quote "$XRAY_PUBLIC_PORT")"
    printf 'XRAY_REALITY_SERVER_NAME=%s\n' "$(shell_quote "$first_server_name")"
    printf 'XRAY_PUBLIC_KEY=%s\n' "$(shell_quote "$public_key")"
    printf 'XRAY_SHORT_ID=%s\n' "$(shell_quote "$short_id")"
  } > "$XRAY_SUB_ENV_FILE"
  chmod 0644 "$XRAY_SUB_ENV_FILE"
}

render_subscription_script() {
  cat > /usr/local/bin/xray-subscribe-render.sh <<'EOF'
#!/bin/sh
set -eu
umask 022

XRAY_SUB_ENV_FILE="${XRAY_SUB_ENV_FILE:-/etc/xray/subscription.env}"
[ -f "$XRAY_SUB_ENV_FILE" ] && . "$XRAY_SUB_ENV_FILE"

: "${XRAY_USERS_FILE:=/etc/xray/users.tsv}"
: "${XRAY_TITLE_FILE:=/var/lib/xray-board/title.txt}"
: "${XRAY_SUB_DIR:=/var/lib/xray-sub}"
: "${XRAY_SUB_TOKEN:=sub}"
: "${XRAY_NODE_NAME:=Xray Node}"
: "${XRAY_PUBLIC_HOST:=YOUR_SERVER_IP}"
: "${XRAY_PUBLIC_PORT:=443}"
: "${XRAY_REALITY_SERVER_NAME:=www.cloudflare.com}"
: "${XRAY_PUBLIC_KEY:=}"
: "${XRAY_SHORT_ID:=}"

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

percent_encode_all() {
  printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n' | sed 's/../%&/g'
}

link_host() {
  host="$1"
  case "$host" in
    \[*\]) printf '%s\n' "$host" ;;
    *:*) printf '[%s]\n' "$host" ;;
    *) printf '%s\n' "$host" ;;
  esac
}

write_base64() {
  src="$1"
  dest="$2"
  if command -v base64 >/dev/null 2>&1; then
    base64 < "$src" | tr -d '\n' > "$dest"
    printf '\n' >> "$dest"
    return 0
  fi
  if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx base64; then
    busybox base64 < "$src" | tr -d '\n' > "$dest"
    printf '\n' >> "$dest"
    return 0
  fi
  cp "$src" "$dest"
}

install -d -m 0755 "$XRAY_SUB_DIR"
plain_file="${XRAY_SUB_DIR}/${XRAY_SUB_TOKEN}.txt"
base64_file="${XRAY_SUB_DIR}/${XRAY_SUB_TOKEN}"
tmp_file="${plain_file}.tmp.$$"
host="$(link_host "$XRAY_PUBLIC_HOST")"
base_title="$XRAY_NODE_NAME"
[ -f "$XRAY_TITLE_FILE" ] && base_title="$(cat "$XRAY_TITLE_FILE" 2>/dev/null || printf '%s' "$XRAY_NODE_NAME")"
user_count="$(awk -F '\t' 'NF >= 2 { c++ } END { print c + 0 }' "$XRAY_USERS_FILE" 2>/dev/null || printf '0')"

: > "$tmp_file"
while IFS="$(printf '\t')" read -r email uuid; do
  email="$(trim "$email")"
  uuid="$(trim "$uuid")"
  [ -n "$email" ] || continue
  [ -n "$uuid" ] || continue
  title="$base_title"
  if [ "$user_count" -gt 1 ]; then
    title="${base_title} ${email}"
  fi
  remark="$(percent_encode_all "$title")"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none&flow=xtls-rprx-vision#%s\n' \
    "$uuid" "$host" "$XRAY_PUBLIC_PORT" "$XRAY_REALITY_SERVER_NAME" "$XRAY_PUBLIC_KEY" "$XRAY_SHORT_ID" "$remark" >> "$tmp_file"
done < "$XRAY_USERS_FILE"

mv "$tmp_file" "$plain_file"
write_base64 "$plain_file" "$base64_file"
chmod 0644 "$plain_file" "$base64_file"
EOF
  chmod 0755 /usr/local/bin/xray-subscribe-render.sh
}

render_subscription_httpd() {
  cat > /usr/local/bin/xray-subscribe-httpd.sh <<'EOF'
#!/bin/sh
set -eu

XRAY_SUB_ENV_FILE="${XRAY_SUB_ENV_FILE:-/etc/xray/subscription.env}"
[ -f "$XRAY_SUB_ENV_FILE" ] && . "$XRAY_SUB_ENV_FILE"

: "${XRAY_SUB_DIR:=/var/lib/xray-sub}"
: "${XRAY_SUB_LISTEN:=0.0.0.0}"
: "${XRAY_SUB_PORT:=8080}"

if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx httpd; then
  exec busybox httpd -f -p "${XRAY_SUB_LISTEN}:${XRAY_SUB_PORT}" -h "$XRAY_SUB_DIR"
fi

exec httpd -f -p "${XRAY_SUB_LISTEN}:${XRAY_SUB_PORT}" -h "$XRAY_SUB_DIR"
EOF
  chmod 0755 /usr/local/bin/xray-subscribe-httpd.sh
}

render_subscription_cgi() {
  cat > /usr/local/bin/xray-subscribe-cgi.sh <<'EOF'
#!/bin/sh
set -eu
umask 022

XRAY_SUB_ENV_FILE="${XRAY_SUB_ENV_FILE:-/etc/xray/subscription.env}"
[ -f "$XRAY_SUB_ENV_FILE" ] && . "$XRAY_SUB_ENV_FILE"

: "${XRAY_STATE_FILE:=/var/lib/xray-board/state.json}"
: "${XRAY_SUB_DIR:=/var/lib/xray-sub}"
: "${XRAY_SUB_TOKEN:=sub}"
: "${XRAY_EXPIRE_TIMESTAMP:=0}"
: "${XRAY_SUB_RENDER_BIN:=/usr/local/bin/xray-subscribe-render.sh}"

json_number() {
  key="$1"
  default_value="$2"
  [ -f "$XRAY_STATE_FILE" ] || {
    printf '%s\n' "$default_value"
    return 0
  }
  value="$(awk -v key="$key" '
    $0 ~ "\"" key "\"" {
      line=$0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      sub(/[,[:space:]].*$/, "", line)
      gsub(/[^0-9]/, "", line)
      print line
      exit
    }
  ' "$XRAY_STATE_FILE")"
  [ -n "${value:-}" ] || value="$default_value"
  printf '%s\n' "$value"
}

serve_file() {
  path="$1"
  content_type="$2"

  if [ ! -f "$path" ] && [ -x "$XRAY_SUB_RENDER_BIN" ]; then
    "$XRAY_SUB_RENDER_BIN" >/dev/null 2>&1 || true
  fi

  if [ ! -f "$path" ]; then
    printf 'Status: 404 Not Found\r\n'
    printf 'Content-Type: text/plain\r\n'
    printf '\r\n'
    printf 'subscription not found\n'
    return 0
  fi

  used_bytes="$(json_number total_used_bytes 0)"
  total_bytes="$(json_number total_quota_bytes 0)"
  printf 'Content-Type: %s\r\n' "$content_type"
  printf 'Cache-Control: no-store\r\n'
  printf 'Profile-Update-Interval: 1\r\n'
  printf 'Subscription-Userinfo: upload=0; download=%s; total=%s; expire=%s\r\n' "$used_bytes" "$total_bytes" "$XRAY_EXPIRE_TIMESTAMP"
  printf '\r\n'
  cat "$path"
}

case "${REQUEST_URI:-}${SCRIPT_NAME:-}" in
  *.txt*) serve_file "${XRAY_SUB_DIR}/${XRAY_SUB_TOKEN}.txt" "text/plain; charset=utf-8" ;;
  *) serve_file "${XRAY_SUB_DIR}/${XRAY_SUB_TOKEN}" "text/plain; charset=utf-8" ;;
esac
EOF
  chmod 0755 /usr/local/bin/xray-subscribe-cgi.sh

  install -d -m 0755 "$XRAY_SUB_DIR/cgi-bin"
  cat > "$XRAY_SUB_DIR/cgi-bin/$XRAY_SUB_TOKEN" <<'EOF'
#!/bin/sh
exec /usr/local/bin/xray-subscribe-cgi.sh
EOF
  cat > "$XRAY_SUB_DIR/cgi-bin/${XRAY_SUB_TOKEN}.txt" <<'EOF'
#!/bin/sh
exec /usr/local/bin/xray-subscribe-cgi.sh
EOF
  chmod 0755 "$XRAY_SUB_DIR/cgi-bin/$XRAY_SUB_TOKEN" "$XRAY_SUB_DIR/cgi-bin/${XRAY_SUB_TOKEN}.txt"
}

render_subscription_service() {
  cat > /etc/init.d/xray-subscribe <<'EOF'
#!/sbin/openrc-run

description="Xray subscription http server"
command="/usr/local/bin/xray-subscribe-httpd.sh"
command_background="yes"
pidfile="/run/xray-subscribe.pid"

depend() {
  need net
}

start_pre() {
  /usr/local/bin/xray-subscribe-render.sh || return 1
}
EOF
  chmod 0755 /etc/init.d/xray-subscribe
}

write_subscription_info() {
  if [ "$XRAY_SUB_ENABLE" != "1" ]; then
    rm -f "$XRAY_ETC_DIR/subscription-info.txt"
    return 0
  fi

  host="$(url_host "$XRAY_PUBLIC_HOST")"
  {
    printf 'enabled=1\n'
    printf 'listen=%s\n' "$XRAY_SUB_LISTEN"
    printf 'port=%s\n' "$XRAY_SUB_PORT"
    printf 'public_url_base64=http://%s:%s/cgi-bin/%s\n' "$host" "$XRAY_SUB_PUBLIC_PORT" "$XRAY_SUB_TOKEN"
    printf 'public_url_plain=http://%s:%s/cgi-bin/%s.txt\n' "$host" "$XRAY_SUB_PUBLIC_PORT" "$XRAY_SUB_TOKEN"
    printf 'static_url_base64=http://%s:%s/%s\n' "$host" "$XRAY_SUB_PUBLIC_PORT" "$XRAY_SUB_TOKEN"
    printf 'static_url_plain=http://%s:%s/%s.txt\n' "$host" "$XRAY_SUB_PUBLIC_PORT" "$XRAY_SUB_TOKEN"
    printf 'traffic_header=Subscription-Userinfo\n'
    printf 'dir=%s\n' "$XRAY_SUB_DIR"
  } > "$XRAY_ETC_DIR/subscription-info.txt"
  chmod 0644 "$XRAY_ETC_DIR/subscription-info.txt"
}

write_share_links() {
  public_key="$1"
  short_id="$2"
  host="$(url_host "$XRAY_PUBLIC_HOST")"
  server_name="$(first_reality_server_name)"
  user_count="$(awk -F '\t' 'NF >= 2 { c++ } END { print c + 0 }' "$XRAY_USERS_FILE" 2>/dev/null || printf '0')"

  : > "$XRAY_SHARE_LINKS_FILE"
  while IFS="$(printf '\t')" read -r email uuid; do
    email="$(trim "$email")"
    uuid="$(trim "$uuid")"
    [ -n "$email" ] || continue
    [ -n "$uuid" ] || continue
    title="$XRAY_NODE_NAME"
    if [ "$user_count" -gt 1 ]; then
      title="${XRAY_NODE_NAME} ${email}"
    fi
    remark="$(percent_encode_all "$title")"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=%s&headerType=none&flow=xtls-rprx-vision#%s\n' \
      "$uuid" "$host" "$XRAY_PUBLIC_PORT" "$server_name" "$public_key" "$short_id" "$XRAY_NETWORK" "$remark" >> "$XRAY_SHARE_LINKS_FILE"
  done < "$XRAY_USERS_FILE"
  chmod 0644 "$XRAY_SHARE_LINKS_FILE"
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
    printf 'public_host=%s\n' "$XRAY_PUBLIC_HOST"
    printf 'public_port=%s\n' "$XRAY_PUBLIC_PORT"
    printf 'stats_mode=%s\n' "$XRAY_STATS_MODE"
    if [ "$XRAY_STATS_MODE" = "xray" ]; then
      printf 'api_port=%s\n' "$XRAY_API_PORT"
    else
      printf 'api_port=disabled\n'
    fi
    printf 'netdev=%s\n' "$XRAY_NETDEV"
    printf 'target=%s\n' "$XRAY_REALITY_TARGET"
    printf 'server_names=%s\n' "$XRAY_REALITY_SERVER_NAMES"
    printf 'users_file=%s\n' "$XRAY_USERS_FILE"
    printf 'share_links_file=%s\n' "$XRAY_SHARE_LINKS_FILE"
    printf 'subscription_enabled=%s\n' "$XRAY_SUB_ENABLE"
    if [ "$XRAY_SUB_ENABLE" = "1" ]; then
      printf 'subscription_port=%s\n' "$XRAY_SUB_PORT"
      printf 'subscription_public_port=%s\n' "$XRAY_SUB_PUBLIC_PORT"
      printf 'subscription_token=%s\n' "$XRAY_SUB_TOKEN"
    fi
  } > "$XRAY_ETC_DIR/connection-info.txt"
  chmod 0644 "$XRAY_ETC_DIR/connection-info.txt"
}

install_all() {
  need_root
  ask_install_options
  if [ -z "$XRAY_PUBLIC_HOST" ]; then
    XRAY_PUBLIC_HOST="$(detect_public_host || true)"
    [ -n "$XRAY_PUBLIC_HOST" ] || XRAY_PUBLIC_HOST="YOUR_SERVER_IP"
  fi
  install_deps
  ensure_httpd
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
  if [ "$XRAY_SUB_ENABLE" = "1" ]; then
    XRAY_SUB_TOKEN="$(ensure_sub_token)"
  fi

  info "writing users and config"
  users_json="$(render_users)"

  backup_if_exists "$XRAY_CONFIG"
  render_config "$private_key" "$short_id" "$users_json"
  write_share_links "$public_key" "$short_id"
  write_connection_info "$public_key" "$short_id"

  info "writing OpenRC services"
  render_watch_env
  render_service
  render_watch_script
  render_watch_service
  if [ "$XRAY_SUB_ENABLE" = "1" ]; then
    info "writing subscription service"
    render_subscription_env "$public_key" "$short_id"
    render_subscription_script
    render_subscription_httpd
    render_subscription_cgi
    render_subscription_service
    write_subscription_info
    /usr/local/bin/xray-subscribe-render.sh || true
  else
    write_subscription_info
  fi

  if have rc-update; then
    info "enabling services"
    rc-update add xray default >/dev/null 2>&1 || true
    rc-update add xray-traffic-watch default >/dev/null 2>&1 || true
    if [ "$XRAY_SUB_ENABLE" = "1" ]; then
      rc-update add xray-subscribe default >/dev/null 2>&1 || true
    else
      rc-update del xray-subscribe default >/dev/null 2>&1 || true
    fi
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
    if [ "$XRAY_SUB_ENABLE" = "1" ]; then
      if rc-service xray-subscribe status >/dev/null 2>&1; then
        rc-service xray-subscribe restart
      else
        rc-service xray-subscribe start
      fi
    else
      rc-service xray-subscribe stop >/dev/null 2>&1 || true
    fi
  fi

  info "installed Xray at $XRAY_BIN"
  info "config: $XRAY_CONFIG"
  info "state:  $XRAY_STATE_FILE"
  info "public port: ${XRAY_PORT}"
  if [ -n "$XRAY_PUBLIC_HOST" ]; then
    info "client address: ${XRAY_PUBLIC_HOST}:${XRAY_PUBLIC_PORT}"
  fi
  info "stats mode: ${XRAY_STATS_MODE}"
  if [ "$XRAY_STATS_MODE" = "xray" ]; then
    info "API port: 127.0.0.1:${XRAY_API_PORT}"
  else
    info "API port: disabled"
  fi
  info "public key: $public_key"
  info "short id: $short_id"
  info "users: $XRAY_USERS_FILE"
  info "user UUIDs:"
  awk -F '\t' 'NF >= 2 { printf "  %s -> %s\n", $1, $2 }' "$XRAY_USERS_FILE"
  info "direct vless links:"
  awk '{ printf "  %s\n", $0 }' "$XRAY_SHARE_LINKS_FILE"
  if [ "$XRAY_SUB_ENABLE" = "1" ]; then
    host="$(url_host "$XRAY_PUBLIC_HOST")"
    info "subscription base64: http://${host}:${XRAY_SUB_PUBLIC_PORT}/cgi-bin/${XRAY_SUB_TOKEN}"
    info "subscription plain:  http://${host}:${XRAY_SUB_PUBLIC_PORT}/cgi-bin/${XRAY_SUB_TOKEN}.txt"
    info "subscription traffic header: Subscription-Userinfo"
  fi
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
  $0 install [--no-interactive]
  $0 sync
  $0 status

Environment:
  XRAY_INTERACTIVE=auto
  XRAY_USERS="alice,bob"
  XRAY_NODE_NAME="My Node"
  XRAY_TOTAL_GB=100
  XRAY_PORT=443
  XRAY_PUBLIC_HOST=server-public-ip
  XRAY_PUBLIC_PORT=443
  XRAY_NETWORK=tcp
  XRAY_API_PORT=10085
  XRAY_STATS_MODE=interface
  XRAY_NETDEV=optional-interface-name
  XRAY_SUB_ENABLE=0
  XRAY_SUB_PORT=8080
  XRAY_SUB_PUBLIC_PORT=8080
  XRAY_REALITY_TARGET="www.cloudflare.com:443"
  XRAY_REALITY_SERVER_NAMES="www.cloudflare.com"
  XRAY_SHORT_ID=optional-short-id
EOF
}

cmd="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi
case "$cmd" in
  install)
    case "${1:-}" in
      --no-interactive|--non-interactive|-y) XRAY_INTERACTIVE=0 ;;
    esac
    install_all
    ;;
  sync) need_root; sync_once ;;
  status) show_status ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
