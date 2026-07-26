#!/usr/bin/env bash
# mb-singbox: state-driven Sing-box manager for Linux VPS hosts.
# jq expressions intentionally use single quotes so jq expands their $variables.
# shellcheck disable=SC2016

set -uo pipefail
umask 077

VERSION="0.1.0"
PROGRAM="mb-singbox"
INSTALL_PATH="${MB_SINGBOX_INSTALL_PATH:-/usr/local/sbin/mb-singbox}"
MANAGER_REPO="${MB_SINGBOX_REPO:-BBMCoin04/mb-singbox}"
MANAGER_REF="${MB_SINGBOX_REF:-main}"
MANAGER_RAW_BASE="https://raw.githubusercontent.com/${MANAGER_REPO}/${MANAGER_REF}"
ROOT_DIR="${MB_SINGBOX_ROOT:-/etc/mb-singbox}"
STATE_FILE="${MB_SINGBOX_STATE_FILE:-${ROOT_DIR}/state.json}"
SERVER_CONFIG="${MB_SINGBOX_SERVER_CONFIG:-${ROOT_DIR}/server.json}"
CLIENT_DIR="${MB_SINGBOX_CLIENT_DIR:-${ROOT_DIR}/clients}"
LINK_DIR="${MB_SINGBOX_LINK_DIR:-${ROOT_DIR}/links}"
QR_DIR="${MB_SINGBOX_QR_DIR:-${ROOT_DIR}/qrcodes}"
BACKUP_DIR="${MB_SINGBOX_BACKUP_DIR:-${ROOT_DIR}/backups}"
LOG_DIR="${MB_SINGBOX_LOG_DIR:-/var/log/mb-singbox}"
SINGBOX_HOME="${MB_SINGBOX_CORE_DIR:-/usr/local/lib/mb-singbox}"
SINGBOX_BIN="${MB_SINGBOX_BIN:-${SINGBOX_HOME}/sing-box}"
SERVICE_FILE="${MB_SINGBOX_SERVICE_FILE:-/etc/systemd/system/mb-singbox.service}"
SERVICE_NAME="mb-singbox.service"
CLOUDFLARED_BIN="${MB_SINGBOX_CLOUDFLARED_BIN:-${SINGBOX_HOME}/cloudflared}"
ARGO_SERVICE_FILE="${MB_SINGBOX_ARGO_SERVICE_FILE:-/etc/systemd/system/mb-singbox-argo.service}"
ARGO_SERVICE_NAME="mb-singbox-argo.service"
ARGO_TOKEN_FILE="${ROOT_DIR}/argo-token"
BBR_FILE="${MB_SINGBOX_BBR_FILE:-/etc/sysctl.d/99-mb-singbox-bbr.conf}"
LOCK_FILE="${MB_SINGBOX_LOCK_FILE:-/run/lock/mb-singbox.lock}"
SELF_PATH="${BASH_SOURCE[0]}"
if [[ -f "$SELF_PATH" ]]; then
  SELF_PATH="$(readlink -f "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")"
else
  SELF_PATH=""
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_BOLD=""
  C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

pause() {
  [[ -t 0 ]] || return 0
  read -r -p "按 Enter 键继续..." _
}

confirm() {
  local prompt="$1" answer
  read -r -p "${prompt} [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
  if (( EUID != 0 )); then
    error "此操作需要 root 权限，请使用 sudo 运行。"
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    error "第一版只支持使用 systemd 的 Linux VPS。"
    return 1
  fi
}

ensure_directories() {
  install -d -m 0700 "$ROOT_DIR" "$CLIENT_DIR" "$LINK_DIR" "$QR_DIR" "$BACKUP_DIR" "$LOG_DIR"
  install -d -m 0755 "$SINGBOX_HOME" "$(dirname "$LOCK_FILE")"
}

acquire_lock() {
  ensure_directories
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    error "另一个 MB-Singbox 操作正在进行。"
    return 1
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_domain() {
  local domain="${1,,}"
  (( ${#domain} <= 253 )) || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

validate_host() {
  local host="$1"
  validate_domain "$host" || [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$host" == *:* ]]
}

validate_name() {
  [[ -n "$1" && ${#1} -le 48 && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

safe_id() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-24)"
  [[ -n "$value" ]] || value="node"
  printf '%s-%s' "$value" "$(openssl rand -hex 3)"
}

new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    local h
    h="$(openssl rand -hex 16)"
    printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$(( (16#${h:16:1} & 3) | 8 ))" "${h:17:3}" "${h:20:12}"
  fi
}

random_password() {
  openssl rand -base64 24 | tr '+/' '-_' | tr -d '='
}

urlencode() {
  jq -nr --arg value "$1" '$value|@uri'
}

base64_nowrap() {
  base64 | tr -d '\n'
}

format_uri_host() {
  if [[ "$1" == *:* && "$1" != \[*\] ]]; then
    printf '[%s]' "$1"
  else
    printf '%s' "$1"
  fi
}

state_valid() {
  jq -e '
    .schema == 1 and
    (.server_address | type == "string") and
    (.nodes | type == "array") and
    (.argo | type == "object") and
    (.firewall_managed | type == "boolean")
  ' "$1" >/dev/null 2>&1
}

init_state() {
  ensure_directories
  if [[ -s "$STATE_FILE" ]]; then
    state_valid "$STATE_FILE" || {
      error "状态文件格式不正确：${STATE_FILE}"
      return 1
    }
    return 0
  fi
  jq -n --arg now "$(date -u +%FT%TZ)" '{
    schema: 1,
    server_address: "",
    created_at: $now,
    firewall_managed: false,
    nodes: [],
    argo: {
      enabled: false,
      mode: "",
      node_id: "",
      hostname: "",
      origin_port: 0
    }
  }' > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}

install_dependencies() {
  local missing=() command_name
  for command_name in curl jq openssl tar flock ss; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  command -v qrencode >/dev/null 2>&1 || missing+=("qrencode")
  (( ${#missing[@]} == 0 )) && return 0

  warn "缺少必要命令：${missing[*]}，准备安装依赖。"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq openssl tar util-linux iproute2 qrencode
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl jq openssl tar util-linux iproute qrencode
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl jq openssl tar util-linux iproute qrencode
  else
    error "无法识别受支持的包管理器，请手动安装：curl jq openssl tar util-linux iproute2 qrencode"
    return 1
  fi

  for command_name in curl jq openssl tar flock ss qrencode; do
    command -v "$command_name" >/dev/null 2>&1 || {
      error "安装依赖后仍缺少命令：${command_name}"
      return 1
    }
  done
}

core_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l) printf 'armv7\n' ;;
    i386|i686) printf '386\n' ;;
    *) error "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
  esac
}

latest_stable_version() {
  curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL \
    https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -er '.tag_name | ltrimstr("v")'
}

current_core_version() {
  [[ -x "$SINGBOX_BIN" ]] || return 1
  "$SINGBOX_BIN" version 2>/dev/null | awk '/sing-box version/ {print $3; exit}'
}

download_core() {
  local version="${1:-}" arch archive_url release_json temp_dir archive expected actual extracted
  [[ -n "$version" ]] || version="$(latest_stable_version)" || {
    error "无法取得 Sing-box 最新稳定版。"
    return 1
  }
  version="${version#v}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    error "版本格式不正确：${version}"
    return 1
  }
  arch="$(core_arch)" || return 1
  temp_dir="$(mktemp -d /tmp/mb-singbox-core.XXXXXX)" || return 1
  archive="sing-box-${version}-linux-${arch}.tar.gz"
  release_json="$temp_dir/release.json"

  info "正在读取 Sing-box ${version} 官方 Release 元数据..." >&2
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL \
    "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${version}" -o "$release_json"; then
    rm -rf "$temp_dir"
    error "无法取得 Sing-box Release 元数据。"
    return 1
  fi
  if jq -e '.prerelease or .draft' "$release_json" >/dev/null; then
    rm -rf "$temp_dir"
    error "版本 ${version} 是预发布版或草稿，第一版拒绝安装。"
    return 1
  fi
  archive_url="$(jq -er --arg name "$archive" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")" || {
    rm -rf "$temp_dir"
    error "Release 中没有适合当前系统的资产：${archive}"
    return 1
  }
  expected="$(jq -er --arg name "$archive" '.assets[] | select(.name == $name) | .digest | select(startswith("sha256:")) | ltrimstr("sha256:")' "$release_json")" || {
    rm -rf "$temp_dir"
    error "Release 未提供资产 SHA-256 摘要，拒绝安装。"
    return 1
  }

  info "正在下载 Sing-box ${version} (${arch})..." >&2
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$archive_url" -o "$temp_dir/$archive"; then
    rm -rf "$temp_dir"
    error "Sing-box 下载失败。"
    return 1
  fi
  actual="$(sha256sum "$temp_dir/$archive" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$temp_dir"
    error "Sing-box SHA-256 校验失败，拒绝安装。"
    return 1
  fi
  if ! tar -xzf "$temp_dir/$archive" -C "$temp_dir"; then
    rm -rf "$temp_dir"
    error "Sing-box 压缩包无法解压。"
    return 1
  fi
  extracted="$temp_dir/sing-box-${version}-linux-${arch}/sing-box"
  if [[ ! -x "$extracted" ]]; then
    rm -rf "$temp_dir"
    error "压缩包中没有找到 Sing-box 二进制。"
    return 1
  fi
  printf '%s\n' "$extracted"
}

write_service_file() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MB-Singbox managed proxy service
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${SERVER_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
}

install_or_update_core() {
  local requested="${1:-}" current="" extracted candidate version backup=""
  require_root
  require_systemd || return 1
  install_dependencies || return 1
  init_state || return 1
  acquire_lock || return 1

  current="$(current_core_version 2>/dev/null || true)"
  extracted="$(download_core "$requested")" || return 1
  version="$($extracted version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
  [[ -n "$version" ]] || {
    rm -rf "$(dirname "$(dirname "$extracted")")"
    error "无法读取下载内核的版本。"
    return 1
  }

  if [[ -s "$SERVER_CONFIG" ]] && ! "$extracted" check -c "$SERVER_CONFIG"; then
    rm -rf "$(dirname "$(dirname "$extracted")")"
    error "现有服务端配置未通过 Sing-box ${version} 检查，不会更新内核。"
    return 1
  fi

  ensure_directories
  if [[ -x "$SINGBOX_BIN" ]]; then
    backup="${SINGBOX_HOME}/sing-box.previous"
    cp -a "$SINGBOX_BIN" "$backup"
  fi
  install -m 0755 "$extracted" "$SINGBOX_BIN"
  rm -rf "$(dirname "$(dirname "$extracted")")"
  write_service_file || return 1

  if [[ -s "$SERVER_CONFIG" ]]; then
    if ! systemctl restart "$SERVICE_NAME"; then
      if [[ -n "$backup" && -x "$backup" ]]; then
        install -m 0755 "$backup" "$SINGBOX_BIN"
        systemctl restart "$SERVICE_NAME" || true
      fi
      error "新内核启动失败，已尝试恢复旧内核。"
      return 1
    fi
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  rm -f "${SINGBOX_HOME}/sing-box.previous"
  ok "Sing-box ${version} 已安装到 ${SINGBOX_BIN}"
  [[ -n "$current" ]] && info "更新前版本：${current}"
}

require_core() {
  if [[ ! -x "$SINGBOX_BIN" ]]; then
    error "尚未安装 Sing-box 内核，请先选择 '安装/更新 Sing-box'。"
    return 1
  fi
}

render_server_config() {
  local state="$1" output="$2"
  jq 'def inbound:
    if .type == "reality" then {
      type: "vless", tag: ("in-" + .id), listen: "::", listen_port: .port,
      users: [{name: .name, uuid: .uuid, flow: "xtls-rprx-vision"}],
      tls: {
        enabled: true, server_name: .server_name,
        reality: {
          enabled: true,
          handshake: {server: .server_name, server_port: 443},
          private_key: .private_key,
          short_id: [.short_id],
          max_time_difference: "1m"
        }
      }
    }
    elif .type == "hysteria2" then {
      type: "hysteria2", tag: ("in-" + .id), listen: "::", listen_port: .port,
      users: [{name: .name, password: .password}],
      obfs: {type: "salamander", password: .obfs_password},
      tls: {enabled: true, certificate_path: .certificate_path, key_path: .key_path}
    }
    elif .type == "tuic" then {
      type: "tuic", tag: ("in-" + .id), listen: "::", listen_port: .port,
      users: [{name: .name, uuid: .uuid, password: .password}],
      congestion_control: "bbr", zero_rtt_handshake: false, heartbeat: "10s",
      tls: {enabled: true, certificate_path: .certificate_path, key_path: .key_path}
    }
    elif .type == "anytls" then {
      type: "anytls", tag: ("in-" + .id), listen: "::", listen_port: .port,
      users: [{name: .name, password: .password}],
      tls: {enabled: true, certificate_path: .certificate_path, key_path: .key_path}
    }
    elif .type == "vmess" then {
      type: "vmess", tag: ("in-" + .id), listen: "::", listen_port: .port,
      users: [{name: .name, uuid: .uuid, alterId: 0}],
      tls: {enabled: true, certificate_path: .certificate_path, key_path: .key_path},
      transport: {type: "ws", path: .path}
    }
    else error("unknown node type: " + .type)
    end;

  def argo_inbound($root):
    ($root.nodes[] | select(.id == $root.argo.node_id)) as $node |
    {
      type: "vmess", tag: ("in-argo-" + $node.id), listen: "127.0.0.1",
      listen_port: $root.argo.origin_port,
      users: [{name: ($node.name + "-Argo"), uuid: $node.uuid, alterId: 0}],
      transport: {type: "ws", path: $node.path}
    };

  . as $root | {
    log: {level: "info", timestamp: true},
    inbounds: (([.nodes[] | inbound]) + (if .argo.enabled then [argo_inbound($root)] else [] end)),
    outbounds: [{type: "direct", tag: "direct"}],
    route: {final: "direct", auto_detect_interface: true}
  }' "$state" > "$output"
}

make_outbound_json() {
  local node_json="$1" server_address="$2" argo_hostname="${3:-}"
  jq -n --argjson n "$node_json" --arg server "$server_address" --arg argo "$argo_hostname" '
    if $argo != "" then {
      type: "vmess", tag: ("node-" + $n.id + "-argo"), server: $argo, server_port: 443,
      uuid: $n.uuid, security: "auto", alter_id: 0, network: "tcp",
      tls: {enabled: true, server_name: $argo},
      transport: {type: "ws", path: $n.path, headers: {Host: $argo}}
    }
    elif $n.type == "reality" then {
      type: "vless", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      uuid: $n.uuid, flow: "xtls-rprx-vision", network: "tcp",
      tls: {
        enabled: true, server_name: $n.server_name,
        utls: {enabled: true, fingerprint: "chrome"},
        reality: {enabled: true, public_key: $n.public_key, short_id: $n.short_id}
      }
    }
    elif $n.type == "hysteria2" then {
      type: "hysteria2", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      password: $n.password,
      obfs: {type: "salamander", password: $n.obfs_password},
      tls: {enabled: true, server_name: $n.tls_domain}
    }
    elif $n.type == "tuic" then {
      type: "tuic", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      uuid: $n.uuid, password: $n.password,
      congestion_control: "bbr", udp_relay_mode: "native", zero_rtt_handshake: false,
      tls: {enabled: true, server_name: $n.tls_domain}
    }
    elif $n.type == "anytls" then {
      type: "anytls", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      password: $n.password,
      tls: {enabled: true, server_name: $n.tls_domain}
    }
    elif $n.type == "vmess" then {
      type: "vmess", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      uuid: $n.uuid, security: "auto", alter_id: 0, network: "tcp",
      tls: {enabled: true, server_name: $n.tls_domain},
      transport: {type: "ws", path: $n.path, headers: {Host: $n.tls_domain}}
    }
    else error("unknown node type")
    end'
}

render_client_config() {
  local outbounds_file="$1" mode="$2" output="$3"
  jq -n --slurpfile proxies "$outbounds_file" --arg mode "$mode" '
    ($proxies[0]) as $p |
    ($p | map(.tag)) as $tags |
    {
      log: {level: "info", timestamp: true},
      dns: {
        servers: [
          {type: "local", tag: "dns-local"},
          {
            type: "https", tag: "dns-remote", server: "1.1.1.1", server_port: 443,
            path: "/dns-query", tls: {enabled: true, server_name: "cloudflare-dns.com"},
            detour: "proxy"
          }
        ],
        final: "dns-remote",
        strategy: "prefer_ipv4"
      },
      inbounds: (if $mode == "tun" then [
        {
          type: "tun", tag: "tun-in", address: ["172.19.0.1/30"],
          auto_route: true, strict_route: true, stack: "mixed"
        },
        {
          type: "mixed", tag: "mixed-in", listen: "127.0.0.1",
          listen_port: 2080, set_system_proxy: false
        }
      ] else [
        {
          type: "mixed", tag: "mixed-in", listen: "127.0.0.1",
          listen_port: 2080, set_system_proxy: true
        }
      ] end),
      outbounds: ($p + [
        {
          type: "selector", tag: "proxy", outbounds: $tags,
          default: $tags[0], interrupt_exist_connections: false
        },
        {type: "direct", tag: "direct"}
      ]),
      route: {
        rules: [
          {protocol: "dns", action: "hijack-dns"},
          {ip_is_private: true, action: "route", outbound: "direct"}
        ],
        final: "proxy",
        auto_detect_interface: true,
        default_domain_resolver: "dns-local"
      },
      experimental: {
        clash_api: {external_controller: "127.0.0.1:9090", default_mode: "rule"}
      }
    }' > "$output"
}

node_share_link() {
  local node_json="$1" server="$2" argo_hostname="${3:-}" type name port uri_host uuid password tls_domain path short_id public_key obfs vmess_json
  type="$(jq -r '.type' <<<"$node_json")"
  name="$(jq -r '.name' <<<"$node_json")"
  port="$(jq -r '.port' <<<"$node_json")"
  uri_host="$(format_uri_host "$server")"

  if [[ -n "$argo_hostname" ]]; then
    uuid="$(jq -r '.uuid' <<<"$node_json")"
    path="$(jq -r '.path' <<<"$node_json")"
    vmess_json="$(jq -nc --arg ps "${name}-Argo" --arg add "$argo_hostname" --arg id "$uuid" --arg host "$argo_hostname" --arg path "$path" '{v:"2",ps:$ps,add:$add,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
    printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64_nowrap)"
    return 0
  fi

  case "$type" in
    reality)
      uuid="$(jq -r '.uuid' <<<"$node_json")"
      tls_domain="$(jq -r '.server_name' <<<"$node_json")"
      short_id="$(jq -r '.short_id' <<<"$node_json")"
      public_key="$(jq -r '.public_key' <<<"$node_json")"
      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$uuid" "$uri_host" "$port" "$(urlencode "$tls_domain")" "$(urlencode "$public_key")" "$(urlencode "$short_id")" "$(urlencode "$name")"
      ;;
    hysteria2)
      password="$(jq -r '.password' <<<"$node_json")"
      tls_domain="$(jq -r '.tls_domain' <<<"$node_json")"
      obfs="$(jq -r '.obfs_password' <<<"$node_json")"
      printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=0&obfs=salamander&obfs-password=%s#%s\n' \
        "$(urlencode "$password")" "$uri_host" "$port" "$(urlencode "$tls_domain")" "$(urlencode "$obfs")" "$(urlencode "$name")"
      ;;
    tuic)
      uuid="$(jq -r '.uuid' <<<"$node_json")"
      password="$(jq -r '.password' <<<"$node_json")"
      tls_domain="$(jq -r '.tls_domain' <<<"$node_json")"
      printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=0#%s\n' \
        "$uuid" "$(urlencode "$password")" "$uri_host" "$port" "$(urlencode "$tls_domain")" "$(urlencode "$name")"
      ;;
    anytls)
      password="$(jq -r '.password' <<<"$node_json")"
      tls_domain="$(jq -r '.tls_domain' <<<"$node_json")"
      printf 'anytls://%s@%s:%s/?sni=%s&insecure=0#%s\n' \
        "$(urlencode "$password")" "$uri_host" "$port" "$(urlencode "$tls_domain")" "$(urlencode "$name")"
      ;;
    vmess)
      uuid="$(jq -r '.uuid' <<<"$node_json")"
      tls_domain="$(jq -r '.tls_domain' <<<"$node_json")"
      path="$(jq -r '.path' <<<"$node_json")"
      vmess_json="$(jq -nc --arg ps "$name" --arg add "$server" --arg port "$port" --arg id "$uuid" --arg host "$tls_domain" --arg path "$path" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
      printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64_nowrap)"
      ;;
    *) return 1 ;;
  esac
}

generate_outputs() {
  local state="$1" temp_root server node_json id name outbounds_file link link_file argo_hostname=""
  temp_root="$(mktemp -d "${ROOT_DIR}/.outputs.XXXXXX")" || return 1
  install -d -m 0700 "$temp_root/clients" "$temp_root/links" "$temp_root/qrcodes"
  server="$(jq -r '.server_address' "$state")"
  if [[ -z "$server" && "$(jq '.nodes|length' "$state")" -gt 0 ]]; then
    rm -rf "$temp_root"
    error "尚未设置客户端连接使用的服务器地址。"
    return 1
  fi

  printf '[]\n' > "$temp_root/all-outbounds.json"
  while IFS= read -r node_json; do
    id="$(jq -r '.id' <<<"$node_json")"
    name="$(jq -r '.name' <<<"$node_json")"
    outbounds_file="$temp_root/${id}-outbounds.json"
    jq -n --argjson outbound "$(make_outbound_json "$node_json" "$server")" '[$outbound]' > "$outbounds_file"
    render_client_config "$outbounds_file" tun "$temp_root/clients/${id}-windows-tun.json" || { rm -rf "$temp_root"; return 1; }
    render_client_config "$outbounds_file" system-proxy "$temp_root/clients/${id}-windows-system-proxy.json" || { rm -rf "$temp_root"; return 1; }
    link="$(node_share_link "$node_json" "$server")"
    link_file="$temp_root/links/${id}.txt"
    printf '%s\n' "$link" > "$link_file"
    printf '%s\n' "$name" >> "$temp_root/links/all.txt"
    printf '%s\n\n' "$link" >> "$temp_root/links/all.txt"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -o "$temp_root/qrcodes/${id}.png" -s 6 -m 2 "$link" || true
    fi
    jq --argjson outbound "$(make_outbound_json "$node_json" "$server")" '. + [$outbound]' "$temp_root/all-outbounds.json" > "$temp_root/all-outbounds.next"
    mv "$temp_root/all-outbounds.next" "$temp_root/all-outbounds.json"
  done < <(jq -c '.nodes[]' "$state")

  if jq -e '.argo.enabled and (.argo.hostname != "")' "$state" >/dev/null; then
    argo_hostname="$(jq -r '.argo.hostname' "$state")"
    node_json="$(jq -c --arg id "$(jq -r '.argo.node_id' "$state")" '.nodes[] | select(.id == $id)' "$state")"
    if [[ -n "$node_json" ]]; then
      id="$(jq -r '.id' <<<"$node_json")"
      name="$(jq -r '.name' <<<"$node_json")"
      link="$(node_share_link "$node_json" "$server" "$argo_hostname")"
      printf '%s\n' "$link" > "$temp_root/links/${id}-argo.txt"
      printf '%s-Argo\n%s\n\n' "$name" "$link" >> "$temp_root/links/all.txt"
      command -v qrencode >/dev/null 2>&1 && qrencode -o "$temp_root/qrcodes/${id}-argo.png" -s 6 -m 2 "$link" || true
      jq --argjson outbound "$(make_outbound_json "$node_json" "$server" "$argo_hostname")" '. + [$outbound]' "$temp_root/all-outbounds.json" > "$temp_root/all-outbounds.next"
      mv "$temp_root/all-outbounds.next" "$temp_root/all-outbounds.json"
    fi
  fi

  if [[ "$(jq 'length' "$temp_root/all-outbounds.json")" -gt 0 ]]; then
    render_client_config "$temp_root/all-outbounds.json" tun "$temp_root/clients/windows-all-tun.json" || { rm -rf "$temp_root"; return 1; }
    render_client_config "$temp_root/all-outbounds.json" system-proxy "$temp_root/clients/windows-all-system-proxy.json" || { rm -rf "$temp_root"; return 1; }
  fi
  rm -f "$temp_root"/*-outbounds.json "$temp_root/all-outbounds.json"

  rm -rf "${CLIENT_DIR}.old" "${LINK_DIR}.old" "${QR_DIR}.old"
  [[ -d "$CLIENT_DIR" ]] && mv "$CLIENT_DIR" "${CLIENT_DIR}.old"
  [[ -d "$LINK_DIR" ]] && mv "$LINK_DIR" "${LINK_DIR}.old"
  [[ -d "$QR_DIR" ]] && mv "$QR_DIR" "${QR_DIR}.old"
  mv "$temp_root/clients" "$CLIENT_DIR"
  mv "$temp_root/links" "$LINK_DIR"
  mv "$temp_root/qrcodes" "$QR_DIR"
  rm -rf "$temp_root" "${CLIENT_DIR}.old" "${LINK_DIR}.old" "${QR_DIR}.old"
  chmod -R go-rwx "$CLIENT_DIR" "$LINK_DIR" "$QR_DIR"
}

backup_current() {
  local stamp target
  stamp="$(date +%Y%m%d-%H%M%S)"
  target="${BACKUP_DIR}/${stamp}"
  install -d -m 0700 "$target"
  [[ -s "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$target/state.json"
  [[ -s "$SERVER_CONFIG" ]] && cp -a "$SERVER_CONFIG" "$target/server.json"
  printf '%s\n' "$target"
}

apply_candidate_state() {
  local candidate="$1" candidate_config backup service_was_active=0
  require_core || return 1
  state_valid "$candidate" || {
    error "候选状态格式不正确。"
    return 1
  }
  candidate_config="$(mktemp "${ROOT_DIR}/.server.XXXXXX.json")" || return 1
  render_server_config "$candidate" "$candidate_config" || {
    rm -f "$candidate_config"
    error "生成服务端候选配置失败。"
    return 1
  }
  if ! "$SINGBOX_BIN" check -c "$candidate_config"; then
    rm -f "$candidate_config"
    error "候选配置未通过 Sing-box 检查，不会替换现有配置。"
    return 1
  fi
  generate_outputs "$candidate" || {
    rm -f "$candidate_config"
    error "桌面端配置生成失败，不会替换现有状态。"
    return 1
  }

  backup="$(backup_current)" || { rm -f "$candidate_config"; return 1; }
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && service_was_active=1
  install -m 0600 "$candidate" "$STATE_FILE"
  install -m 0600 "$candidate_config" "$SERVER_CONFIG"
  rm -f "$candidate_config"
  write_service_file || return 1

  if [[ "$(jq '.nodes|length' "$STATE_FILE")" -eq 0 ]]; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    ok "状态已更新；当前没有节点，服务保持停止。"
    return 0
  fi

  if systemctl enable --now "$SERVICE_NAME" && systemctl restart "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "服务端配置已通过检查并生效。"
    return 0
  fi

  error "新配置启动失败，正在恢复上一个状态。"
  [[ -s "$backup/state.json" ]] && install -m 0600 "$backup/state.json" "$STATE_FILE"
  [[ -s "$backup/server.json" ]] && install -m 0600 "$backup/server.json" "$SERVER_CONFIG"
  if (( service_was_active )); then
    systemctl restart "$SERVICE_NAME" || true
  else
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  generate_outputs "$STATE_FILE" || true
  return 1
}

ensure_server_address() {
  local current input candidate
  current="$(jq -r '.server_address' "$STATE_FILE")"
  if [[ -n "$current" ]]; then
    printf '当前客户端连接地址：%s\n' "$current"
    confirm "是否修改客户端连接地址？" || return 0
  fi
  while true; do
    read -r -p "请输入 VPS 公网 IP 或解析到本机的域名：" input
    input="$(trim "$input")"
    if validate_host "$input"; then
      break
    fi
    error "地址格式不正确。"
  done
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq --arg value "$input" '.server_address = $value' "$STATE_FILE" > "$candidate"
  install -m 0600 "$candidate" "$STATE_FILE"
  rm -f "$candidate"
  ok "客户端连接地址已设为 ${input}。"
}

port_in_state() {
  local port="$1" network="$2"
  jq -e --argjson port "$port" --arg network "$network" '
    any(.nodes[];
      .port == $port and
      (if $network == "udp" then (.type == "hysteria2" or .type == "tuic") else (.type == "reality" or .type == "anytls" or .type == "vmess") end)
    ) or (.argo.enabled and $network == "tcp" and .argo.origin_port == $port)
  ' "$STATE_FILE" >/dev/null
}

port_listening() {
  local port="$1" network="$2"
  if [[ "$network" == "udp" ]]; then
    ss -H -lun 2>/dev/null | awk -v p=":${port}" '$5 ~ p "$" {found=1} END {exit !found}'
  else
    ss -H -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" {found=1} END {exit !found}'
  fi
}

choose_port() {
  local network="$1" default="$2" input
  while true; do
    read -r -p "监听端口 [${default}]：" input
    input="${input:-$default}"
    if ! validate_port "$input"; then
      error "端口必须是 1 到 65535 的整数。"
    elif port_in_state "$input" "$network"; then
      error "${network^^} ${input} 已被另一个 MB-Singbox 节点使用。"
    elif port_listening "$input" "$network"; then
      error "系统中已有程序监听 ${network^^} ${input}。"
    else
      printf '%s' "$input"
      return 0
    fi
  done
}

CERT_DOMAIN=""
CERT_FILE=""
KEY_FILE=""
select_certificate() {
  local -a domains=()
  local cert domain index choice manual
  shopt -s nullglob
  for cert in /etc/acme/certs/*/fullchain.pem; do
    domain="$(basename "$(dirname "$cert")")"
    [[ -s "$cert" && -s "/etc/acme/certs/${domain}/key.pem" ]] && domains+=("$domain")
  done
  shopt -u nullglob

  printf '\nTLS 证书：\n'
  if (( ${#domains[@]} > 0 )); then
    for index in "${!domains[@]}"; do
      printf '  %d. %s\n' "$((index + 1))" "${domains[$index]}"
    done
    printf '  m. 手动输入证书路径\n'
    read -r -p "请选择：" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#domains[@]} )); then
      CERT_DOMAIN="${domains[$((choice - 1))]}"
      CERT_FILE="/etc/acme/certs/${CERT_DOMAIN}/fullchain.pem"
      KEY_FILE="/etc/acme/certs/${CERT_DOMAIN}/key.pem"
    elif [[ "$choice" == "m" || "$choice" == "M" ]]; then
      manual=1
    else
      error "无效选项。"
      return 1
    fi
  else
    warn "没有发现 MB-ACME 已部署证书。"
    manual=1
  fi

  if [[ "${manual:-0}" == "1" ]]; then
    read -r -p "证书域名（SNI）：" CERT_DOMAIN
    CERT_DOMAIN="${CERT_DOMAIN,,}"
    validate_domain "$CERT_DOMAIN" || { error "证书域名格式不正确。"; return 1; }
    read -r -p "完整证书链绝对路径：" CERT_FILE
    read -r -p "私钥绝对路径：" KEY_FILE
  fi
  [[ "$CERT_FILE" == /* && -s "$CERT_FILE" ]] || { error "完整证书链不存在或为空。"; return 1; }
  [[ "$KEY_FILE" == /* && -s "$KEY_FILE" ]] || { error "私钥不存在或为空。"; return 1; }
  if ! openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
    error "无法解析证书文件。"
    return 1
  fi
  if ! openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1; then
    error "无法解析私钥文件。"
    return 1
  fi
  if [[ "$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl pkey -pubin -outform der | sha256sum | awk '{print $1}')" != \
        "$(openssl pkey -in "$KEY_FILE" -pubout -outform der | sha256sum | awk '{print $1}')" ]]; then
    error "证书与私钥不匹配。"
    return 1
  fi
  ok "已选择证书：${CERT_DOMAIN}"
}

read_node_name() {
  local default="$1" input
  while true; do
    read -r -p "节点名称 [${default}]：" input
    input="${input:-$default}"
    if validate_name "$input"; then
      printf '%s' "$input"
      return 0
    fi
    error "节点名称不能为空，最长 48 个字符。"
  done
}

add_reality_node() {
  local name id port uuid target keys private_key public_key short_id node candidate
  name="$(read_node_name "Reality")" || return 1
  id="$(safe_id "$name")"
  port="$(choose_port tcp 443)" || return 1
  read -r -p "Reality 握手域名 [www.microsoft.com]：" target
  target="${target:-www.microsoft.com}"
  target="${target,,}"
  validate_domain "$target" || { error "握手域名格式不正确。"; return 1; }
  uuid="$(new_uuid)"
  keys="$($SINGBOX_BIN generate reality-keypair)" || return 1
  private_key="$(awk '/PrivateKey:/ {print $2}' <<<"$keys")"
  public_key="$(awk '/PublicKey:/ {print $2}' <<<"$keys")"
  [[ -n "$private_key" && -n "$public_key" ]] || { error "Reality 密钥生成失败。"; return 1; }
  short_id="$(openssl rand -hex 8)"
  node="$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg server_name "$target" --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" '{id:$id,name:$name,type:"reality",port:$port,uuid:$uuid,server_name:$server_name,private_key:$private_key,public_key:$public_key,short_id:$short_id}')"
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq --argjson node "$node" '.nodes += [$node]' "$STATE_FILE" > "$candidate"
  if apply_candidate_state "$candidate"; then
    rm -f "$candidate"
    sync_firewall_if_managed
    show_node_result "$id"
  else
    rm -f "$candidate"
    return 1
  fi
}

add_tls_node() {
  local type="$1" default_name default_port network name id port uuid password obfs path node candidate
  case "$type" in
    hysteria2) default_name="Hysteria2"; default_port=8443; network=udp ;;
    tuic) default_name="TUIC"; default_port=9443; network=udp ;;
    anytls) default_name="AnyTLS"; default_port=10443; network=tcp ;;
    vmess) default_name="VMess-WS"; default_port=11443; network=tcp ;;
    *) return 1 ;;
  esac
  name="$(read_node_name "$default_name")" || return 1
  id="$(safe_id "$name")"
  port="$(choose_port "$network" "$default_port")" || return 1
  select_certificate || return 1
  password="$(random_password)"
  uuid="$(new_uuid)"
  obfs="$(random_password)"
  path="/$(openssl rand -hex 8)"
  case "$type" in
    hysteria2)
      node="$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg password "$password" --arg obfs "$obfs" --arg domain "$CERT_DOMAIN" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{id:$id,name:$name,type:"hysteria2",port:$port,password:$password,obfs_password:$obfs,tls_domain:$domain,certificate_path:$cert,key_path:$key}')"
      ;;
    tuic)
      node="$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --arg domain "$CERT_DOMAIN" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{id:$id,name:$name,type:"tuic",port:$port,uuid:$uuid,password:$password,tls_domain:$domain,certificate_path:$cert,key_path:$key}')"
      ;;
    anytls)
      node="$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg password "$password" --arg domain "$CERT_DOMAIN" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{id:$id,name:$name,type:"anytls",port:$port,password:$password,tls_domain:$domain,certificate_path:$cert,key_path:$key}')"
      ;;
    vmess)
      node="$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" --arg domain "$CERT_DOMAIN" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{id:$id,name:$name,type:"vmess",port:$port,uuid:$uuid,path:$path,tls_domain:$domain,certificate_path:$cert,key_path:$key}')"
      ;;
  esac
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq --argjson node "$node" '.nodes += [$node]' "$STATE_FILE" > "$candidate"
  if apply_candidate_state "$candidate"; then
    rm -f "$candidate"
    sync_firewall_if_managed
    show_node_result "$id"
  else
    rm -f "$candidate"
    return 1
  fi
}

add_node_menu() {
  local choice
  require_root
  require_core || return 1
  init_state || return 1
  acquire_lock || return 1
  ensure_server_address || return 1
  printf '\n创建节点：\n'
  printf '  1. VLESS-Reality-Vision（TCP，无需证书）\n'
  printf '  2. Hysteria2（UDP，需要证书）\n'
  printf '  3. TUIC（UDP，需要证书）\n'
  printf '  4. AnyTLS（TCP，需要证书）\n'
  printf '  5. VMess-WebSocket-TLS（TCP，可联动 Argo）\n'
  printf '  0. 返回\n'
  read -r -p "请选择：" choice
  case "$choice" in
    1) add_reality_node ;;
    2) add_tls_node hysteria2 ;;
    3) add_tls_node tuic ;;
    4) add_tls_node anytls ;;
    5) add_tls_node vmess ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

show_node_result() {
  local id="$1" node name type port link_file
  node="$(jq -c --arg id "$id" '.nodes[] | select(.id == $id)' "$STATE_FILE")"
  [[ -n "$node" ]] || return 1
  name="$(jq -r '.name' <<<"$node")"
  type="$(jq -r '.type' <<<"$node")"
  port="$(jq -r '.port' <<<"$node")"
  link_file="${LINK_DIR}/${id}.txt"
  printf '\n%s节点已创建%s\n' "$C_BOLD" "$C_RESET"
  printf '名称：%s\n协议：%s\n端口：%s\n' "$name" "$type" "$port"
  printf 'Windows TUN：%s/%s-windows-tun.json\n' "$CLIENT_DIR" "$id"
  printf 'Windows 系统代理：%s/%s-windows-system-proxy.json\n' "$CLIENT_DIR" "$id"
  if [[ -s "$link_file" ]]; then
    printf '\n分享链接：\n'
    cat "$link_file"
    if command -v qrencode >/dev/null 2>&1 && [[ -t 1 ]]; then
      printf '\n'
      qrencode -t ANSIUTF8 -m 1 "$(cat "$link_file")" || true
    fi
  fi
}

list_nodes() {
  init_state || return 1
  printf '\n%s节点列表%s\n' "$C_BOLD" "$C_RESET"
  if [[ "$(jq '.nodes|length' "$STATE_FILE")" -eq 0 ]]; then
    printf '尚未创建节点。\n'
    return 0
  fi
  jq -r '.nodes[] | [.id, .name, .type, (.port|tostring), (if (.type=="hysteria2" or .type=="tuic") then "UDP" else "TCP" end)] | @tsv' "$STATE_FILE" | \
    awk -F '\t' '{printf "%-30s  %-18s  %-10s  %5s/%s\n", $1, $2, $3, $4, $5}'
  printf '\n桌面端汇总配置：\n  %s/windows-all-tun.json\n  %s/windows-all-system-proxy.json\n' "$CLIENT_DIR" "$CLIENT_DIR"
  printf '全部分享链接：%s/all.txt\n' "$LINK_DIR"
  if jq -e '.argo.enabled' "$STATE_FILE" >/dev/null; then
    printf 'Argo：%s，%s\n' "$(jq -r '.mode' "$STATE_FILE")" "$(jq -r '.hostname // "等待域名"' "$STATE_FILE")"
  fi
}

view_node_menu() {
  local id
  list_nodes
  [[ "$(jq '.nodes|length' "$STATE_FILE")" -gt 0 ]] || return 0
  read -r -p "输入节点 ID 查看详情（留空返回）：" id
  [[ -n "$id" ]] || return 0
  if jq -e --arg id "$id" 'any(.nodes[]; .id == $id)' "$STATE_FILE" >/dev/null; then
    show_node_result "$id"
  else
    error "节点不存在：${id}"
    return 1
  fi
}

choose_port_for_node() {
  local network="$1" default="$2" node_id="$3" input current
  current="$(jq -r --arg id "$node_id" '.nodes[] | select(.id==$id) | .port' "$STATE_FILE")"
  while true; do
    read -r -p "监听端口 [${default}]：" input
    input="${input:-$default}"
    if ! validate_port "$input"; then
      error "端口必须是 1 到 65535 的整数。"
    elif [[ "$input" == "$current" ]]; then
      printf '%s' "$input"
      return 0
    elif jq -e --arg id "$node_id" --argjson port "$input" --arg network "$network" '
      any(.nodes[];
        .id != $id and .port == $port and
        (if $network == "udp" then (.type=="hysteria2" or .type=="tuic") else (.type=="reality" or .type=="anytls" or .type=="vmess") end)
      ) or (.argo.enabled and $network=="tcp" and .argo.origin_port==$port)
    ' "$STATE_FILE" >/dev/null; then
      error "${network^^} ${input} 已被另一个 MB-Singbox 入站使用。"
    elif port_listening "$input" "$network"; then
      error "系统中已有程序监听 ${network^^} ${input}。"
    else
      printf '%s' "$input"
      return 0
    fi
  done
}

apply_node_field_update() {
  local id="$1" filter="$2"
  shift 2
  local candidate
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq --arg id "$id" "$@" "(.nodes[] | select(.id == \$id)) |= (${filter})" "$STATE_FILE" > "$candidate"
  if apply_candidate_state "$candidate"; then
    rm -f "$candidate"
    sync_firewall_if_managed
    ok "节点配置已更新。"
  else
    rm -f "$candidate"
    return 1
  fi
}

edit_node() {
  local id node type network choice value port
  require_root
  require_core || return 1
  init_state || return 1
  acquire_lock || return 1
  list_nodes
  [[ "$(jq '.nodes|length' "$STATE_FILE")" -gt 0 ]] || return 0
  read -r -p "输入要修改的节点 ID：" id
  node="$(jq -c --arg id "$id" '.nodes[] | select(.id==$id)' "$STATE_FILE")"
  [[ -n "$node" ]] || { error "节点不存在：${id}"; return 1; }
  type="$(jq -r '.type' <<<"$node")"
  case "$type" in hysteria2|tuic) network=udp ;; *) network=tcp ;; esac

  printf '\n修改节点：%s (%s)\n' "$(jq -r '.name' <<<"$node")" "$type"
  printf '  1. 修改显示名称\n'
  printf '  2. 修改监听端口\n'
  [[ "$type" != "reality" ]] && printf '  3. 更换 TLS 证书\n'
  [[ "$type" == "reality" ]] && printf '  4. 修改 Reality 握手域名\n'
  [[ "$type" == "vmess" ]] && printf '  4. 修改 WebSocket 路径\n'
  printf '  5. 重新生成认证凭据\n'
  printf '  0. 返回\n'
  read -r -p "请选择：" choice
  case "$choice" in
    1)
      value="$(read_node_name "$(jq -r '.name' <<<"$node")")" || return 1
      apply_node_field_update "$id" '.name=$value' --arg value "$value"
      ;;
    2)
      port="$(choose_port_for_node "$network" "$(jq -r '.port' <<<"$node")" "$id")" || return 1
      apply_node_field_update "$id" '.port=$port' --argjson port "$port"
      ;;
    3)
      [[ "$type" != "reality" ]] || { error "Reality 节点不使用证书。"; return 1; }
      select_certificate || return 1
      apply_node_field_update "$id" '.tls_domain=$domain | .certificate_path=$cert | .key_path=$key' --arg domain "$CERT_DOMAIN" --arg cert "$CERT_FILE" --arg key "$KEY_FILE"
      ;;
    4)
      if [[ "$type" == "reality" ]]; then
        read -r -p "新的 Reality 握手域名：" value
        value="${value,,}"
        validate_domain "$value" || { error "域名格式不正确。"; return 1; }
        apply_node_field_update "$id" '.server_name=$value' --arg value "$value"
      elif [[ "$type" == "vmess" ]]; then
        read -r -p "新的 WebSocket 路径（必须以 / 开头）：" value
        [[ "$value" == /* && "$value" != *[[:space:]]* ]] || { error "WebSocket 路径格式不正确。"; return 1; }
        apply_node_field_update "$id" '.path=$value' --arg value "$value"
      else
        error "该节点没有此选项。"
        return 1
      fi
      ;;
    5)
      warn "重新生成认证凭据后，旧客户端配置和分享链接会立即失效。"
      confirm "确定继续？" || return 0
      case "$type" in
        reality)
          local keys private_key public_key
          keys="$($SINGBOX_BIN generate reality-keypair)" || return 1
          private_key="$(awk '/PrivateKey:/ {print $2}' <<<"$keys")"
          public_key="$(awk '/PublicKey:/ {print $2}' <<<"$keys")"
          apply_node_field_update "$id" '.uuid=$uuid | .private_key=$private_key | .public_key=$public_key | .short_id=$short_id' \
            --arg uuid "$(new_uuid)" --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$(openssl rand -hex 8)"
          ;;
        hysteria2)
          apply_node_field_update "$id" '.password=$password | .obfs_password=$obfs' --arg password "$(random_password)" --arg obfs "$(random_password)"
          ;;
        tuic)
          apply_node_field_update "$id" '.uuid=$uuid | .password=$password' --arg uuid "$(new_uuid)" --arg password "$(random_password)"
          ;;
        anytls)
          apply_node_field_update "$id" '.password=$password' --arg password "$(random_password)"
          ;;
        vmess)
          apply_node_field_update "$id" '.uuid=$uuid | .path=$path' --arg uuid "$(new_uuid)" --arg path "/$(openssl rand -hex 8)"
          ;;
      esac
      ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

delete_node() {
  local id candidate argo_bound=0
  require_root
  init_state || return 1
  acquire_lock || return 1
  list_nodes
  read -r -p "输入要删除的节点 ID：" id
  jq -e --arg id "$id" 'any(.nodes[]; .id == $id)' "$STATE_FILE" >/dev/null || {
    error "节点不存在：${id}"
    return 1
  }
  jq -e --arg id "$id" '.argo.enabled and .argo.node_id == $id' "$STATE_FILE" >/dev/null && argo_bound=1
  warn "将删除节点 ${id} 的服务端配置、桌面配置、链接和二维码。"
  (( argo_bound )) && warn "该节点绑定了 Argo，Argo 本地服务也会停止；不会删除 Cloudflare 远程 Tunnel。"
  confirm "确定删除？" || return 0
  (( argo_bound )) && stop_argo_service
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq --arg id "$id" '
    .nodes |= map(select(.id != $id)) |
    if .argo.node_id == $id then .argo = {enabled:false,mode:"",node_id:"",hostname:"",origin_port:0} else . end
  ' "$STATE_FILE" > "$candidate"
  if apply_candidate_state "$candidate"; then
    rm -f "$candidate"
    sync_firewall_if_managed
    ok "节点 ${id} 已删除。"
  else
    rm -f "$candidate"
    return 1
  fi
}

random_local_port() {
  local port
  for _ in {1..100}; do
    port="$((20000 + RANDOM % 30000))"
    if ! port_in_state "$port" tcp && ! port_listening "$port" tcp; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

cloudflared_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l) printf 'arm\n' ;;
    i386|i686) printf '386\n' ;;
    *) return 1 ;;
  esac
}

install_cloudflared() {
  local arch temp_dir release_json asset url expected actual
  arch="$(cloudflared_arch)" || { error "cloudflared 不支持当前架构。"; return 1; }
  temp_dir="$(mktemp -d /tmp/cloudflared.XXXXXX)" || return 1
  release_json="$temp_dir/release.json"
  asset="cloudflared-linux-${arch}"
  info "正在读取 Cloudflare 官方 Release 元数据..."
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL \
    https://api.github.com/repos/cloudflare/cloudflared/releases/latest -o "$release_json"; then
    rm -rf "$temp_dir"
    error "无法取得 cloudflared Release 元数据。"
    return 1
  fi
  url="$(jq -er --arg name "$asset" '.assets[] | select(.name==$name) | .browser_download_url' "$release_json")" || {
    rm -rf "$temp_dir"
    error "Release 中没有适合当前系统的 cloudflared 资产。"
    return 1
  }
  expected="$(jq -er --arg name "$asset" '.assets[] | select(.name==$name) | .digest | select(startswith("sha256:")) | ltrimstr("sha256:")' "$release_json")" || {
    rm -rf "$temp_dir"
    error "Release 未提供 cloudflared SHA-256 摘要，拒绝安装。"
    return 1
  }
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$url" -o "$temp_dir/$asset"; then
    rm -rf "$temp_dir"
    error "cloudflared 下载失败。"
    return 1
  fi
  actual="$(sha256sum "$temp_dir/$asset" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$temp_dir"
    error "cloudflared SHA-256 校验失败，拒绝安装。"
    return 1
  fi
  if ! chmod 0755 "$temp_dir/$asset" || ! "$temp_dir/$asset" version >/dev/null 2>&1; then
    rm -rf "$temp_dir"
    error "下载的 cloudflared 无法执行。"
    return 1
  fi
  install -m 0755 "$temp_dir/$asset" "$CLOUDFLARED_BIN"
  rm -rf "$temp_dir"
  ok "cloudflared 已安装。"
}

write_argo_service() {
  local mode="$1" origin_port="$2"
  if [[ "$mode" == "named" ]]; then
    cat > "$ARGO_SERVICE_FILE" <<EOF
[Unit]
Description=MB-Singbox Cloudflare Named Tunnel
Wants=network-online.target ${SERVICE_NAME}
After=network-online.target ${SERVICE_NAME}

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --no-autoupdate run --token-file ${ARGO_TOKEN_FILE}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  else
    cat > "$ARGO_SERVICE_FILE" <<EOF
[Unit]
Description=MB-Singbox Cloudflare Quick Tunnel
Wants=network-online.target ${SERVICE_NAME}
After=network-online.target ${SERVICE_NAME}

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --no-autoupdate --url http://127.0.0.1:${origin_port}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  fi
  chmod 0644 "$ARGO_SERVICE_FILE"
  systemctl daemon-reload
}

stop_argo_service() {
  systemctl disable --now "$ARGO_SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$ARGO_SERVICE_FILE" "$ARGO_TOKEN_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

wait_quick_hostname() {
  local hostname=""
  for _ in {1..20}; do
    hostname="$(journalctl -u "$ARGO_SERVICE_NAME" --since '-2 minutes' --no-pager 2>/dev/null | grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' | tail -n 1 | sed 's#https://##')"
    [[ -n "$hostname" ]] && { printf '%s' "$hostname"; return 0; }
    sleep 1
  done
  return 1
}

configure_argo() {
  local -a vmess_ids=()
  local line index choice id mode hostname token origin candidate rollback
  require_root
  require_core || return 1
  init_state || return 1
  acquire_lock || return 1
  while IFS= read -r line; do vmess_ids+=("$line"); done < <(jq -r '.nodes[] | select(.type=="vmess") | .id' "$STATE_FILE")
  if (( ${#vmess_ids[@]} == 0 )); then
    error "请先创建一个 VMess-WebSocket-TLS 节点。"
    return 1
  fi
  if jq -e '.argo.enabled' "$STATE_FILE" >/dev/null; then
    warn "当前已有 Argo 配置。请先停用，再重新配置。"
    return 1
  fi
  install_cloudflared || return 1
  printf '\n选择绑定的 VMess 节点：\n'
  for index in "${!vmess_ids[@]}"; do
    id="${vmess_ids[$index]}"
    printf '  %d. %s (%s)\n' "$((index + 1))" "$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.name' "$STATE_FILE")" "$id"
  done
  read -r -p "请选择：" choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#vmess_ids[@]} )); then
    error "无效选项。"
    return 1
  fi
  id="${vmess_ids[$((choice - 1))]}"
  printf '\nArgo 模式：\n  1. Named Tunnel（固定域名，长期备用）\n  2. Quick Tunnel（随机域名，临时救急）\n'
  read -r -p "请选择：" choice
  case "$choice" in
    1)
      mode="named"
      read -r -p "Cloudflare Tunnel 公网主机名（例如 backup.example.com）：" hostname
      hostname="${hostname,,}"
      validate_domain "$hostname" || { error "主机名格式不正确。"; return 1; }
      read -r -s -p "Cloudflare Tunnel Token（输入不可见）：" token
      printf '\n'
      [[ -n "$token" ]] || { error "Token 不能为空。"; return 1; }
      printf '%s' "$token" > "$ARGO_TOKEN_FILE"
      chmod 0600 "$ARGO_TOKEN_FILE"
      ;;
    2) mode="quick"; hostname="" ;;
    *) error "无效选项。"; return 1 ;;
  esac
  origin="$(random_local_port)" || { error "无法分配 Argo 本地端口。"; return 1; }
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq --arg mode "$mode" --arg id "$id" --arg hostname "$hostname" --argjson origin "$origin" '.argo={enabled:true,mode:$mode,node_id:$id,hostname:$hostname,origin_port:$origin}' "$STATE_FILE" > "$candidate"
  if ! apply_candidate_state "$candidate"; then
    rm -f "$candidate" "$ARGO_TOKEN_FILE"
    return 1
  fi
  rm -f "$candidate"
  write_argo_service "$mode" "$origin" || return 1
  if ! systemctl enable --now "$ARGO_SERVICE_NAME" || ! systemctl is-active --quiet "$ARGO_SERVICE_NAME"; then
    error "Argo 服务启动失败，正在撤销本地 Argo 配置。"
    stop_argo_service
    rollback="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
    jq '.argo={enabled:false,mode:"",node_id:"",hostname:"",origin_port:0}' "$STATE_FILE" > "$rollback"
    apply_candidate_state "$rollback" || true
    rm -f "$rollback"
    return 1
  fi
  if [[ "$mode" == "quick" ]]; then
    hostname="$(wait_quick_hostname)" || {
      warn "Quick Tunnel 已启动，但暂未从日志取得随机域名。稍后可在 Argo 菜单刷新。"
      return 0
    }
    candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
    jq --arg hostname "$hostname" '.argo.hostname=$hostname' "$STATE_FILE" > "$candidate"
    install -m 0600 "$candidate" "$STATE_FILE"
    rm -f "$candidate"
    generate_outputs "$STATE_FILE"
  else
    printf '\n请在 Cloudflare Zero Trust 中确认 Public Hostname 的服务指向：\n  http://127.0.0.1:%s\n' "$origin"
  fi
  ok "Argo 已启用：${hostname:-等待 Quick Tunnel 域名}"
}

refresh_quick_argo() {
  local hostname candidate
  jq -e '.argo.enabled and .argo.mode=="quick"' "$STATE_FILE" >/dev/null || { error "当前未启用 Quick Tunnel。"; return 1; }
  hostname="$(wait_quick_hostname)" || { error "仍未从 cloudflared 日志取得随机域名。"; return 1; }
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq --arg hostname "$hostname" '.argo.hostname=$hostname' "$STATE_FILE" > "$candidate"
  install -m 0600 "$candidate" "$STATE_FILE"
  rm -f "$candidate"
  generate_outputs "$STATE_FILE"
  ok "Quick Tunnel 域名已更新：${hostname}"
}

disable_argo() {
  local candidate
  jq -e '.argo.enabled' "$STATE_FILE" >/dev/null || { info "Argo 当前未启用。"; return 0; }
  warn "将停止并删除 MB-Singbox 的本地 cloudflared 服务。"
  warn "Cloudflare 账户中的 Named Tunnel 不会被删除。"
  confirm "确定停用 Argo？" || return 0
  stop_argo_service
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq '.argo={enabled:false,mode:"",node_id:"",hostname:"",origin_port:0}' "$STATE_FILE" > "$candidate"
  if apply_candidate_state "$candidate"; then
    rm -f "$candidate"
    ok "Argo 已停用。"
  else
    rm -f "$candidate"
    return 1
  fi
}

argo_menu() {
  local choice
  init_state || return 1
  printf '\nArgo（仅 VMess-WebSocket）：\n'
  if jq -e '.argo.enabled' "$STATE_FILE" >/dev/null; then
    printf '状态：已启用，模式=%s，域名=%s，源站=127.0.0.1:%s\n' "$(jq -r '.argo.mode' "$STATE_FILE")" "$(jq -r '.argo.hostname // "等待中"' "$STATE_FILE")" "$(jq -r '.argo.origin_port' "$STATE_FILE")"
  else
    printf '状态：未启用\n'
  fi
  printf '  1. 配置 Argo\n  2. 刷新 Quick Tunnel 域名\n  3. 停用 Argo\n  4. 查看 cloudflared 日志\n  0. 返回\n'
  read -r -p "请选择：" choice
  case "$choice" in
    1) configure_argo ;;
    2) refresh_quick_argo ;;
    3) disable_argo ;;
    4) journalctl -u "$ARGO_SERVICE_NAME" -n 100 --no-pager ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

ufw_is_active() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'
}

remove_managed_ufw_rules() {
  local numbers number
  command -v ufw >/dev/null 2>&1 || return 0
  numbers="$(ufw status numbered 2>/dev/null | sed -n '/#[[:space:]]*MB-Singbox/s/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' | sort -rn)"
  while IFS= read -r number; do
    [[ -n "$number" ]] && ufw --force delete "$number" >/dev/null
  done <<<"$numbers"
}

sync_ufw_rules() {
  local type port protocol
  ufw_is_active || { error "UFW 尚未启用。"; return 1; }
  remove_managed_ufw_rules
  while IFS=$'\t' read -r type port; do
    case "$type" in
      hysteria2|tuic) protocol=udp ;;
      *) protocol=tcp ;;
    esac
    ufw allow "${port}/${protocol}" comment "MB-Singbox" >/dev/null || return 1
  done < <(jq -r '.nodes[] | [.type, .port] | @tsv' "$STATE_FILE")
  ok "UFW 已同步当前节点需要的 TCP/UDP 端口。"
}

sync_firewall_if_managed() {
  jq -e '.firewall_managed' "$STATE_FILE" >/dev/null 2>&1 || return 0
  sync_ufw_rules || warn "自动同步 UFW 规则失败，请从系统工具菜单检查。"
}

configure_ufw() {
  local ssh_port candidate
  if ! command -v ufw >/dev/null 2>&1; then
    confirm "系统没有 UFW，是否安装？" || return 0
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ufw || return 1
    else
      error "当前系统请手动安装 UFW。"
      return 1
    fi
  fi
  if ! ufw_is_active; then
    ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"
    ssh_port="${ssh_port:-22}"
    warn "启用 UFW 会改变服务器入站防火墙。脚本会先放行 SSH TCP ${ssh_port} 和所有当前节点端口。"
    confirm "确定启用 UFW？" || return 0
    ufw allow "${ssh_port}/tcp" comment "SSH before MB-Singbox" >/dev/null || return 1
    ufw --force enable || return 1
  fi
  sync_ufw_rules || return 1
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq '.firewall_managed=true' "$STATE_FILE" > "$candidate"
  install -m 0600 "$candidate" "$STATE_FILE"
  rm -f "$candidate"
  ok "MB-Singbox 将在节点增删后自动同步自己的 UFW 规则。"
}

disable_ufw_management() {
  local candidate
  warn "只会删除注释为 MB-Singbox 的规则，不会停用 UFW，也不会删除其他规则。"
  confirm "确定停止管理并删除 MB-Singbox UFW 规则？" || return 0
  remove_managed_ufw_rules
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq '.firewall_managed=false' "$STATE_FILE" > "$candidate"
  install -m 0600 "$candidate" "$STATE_FILE"
  rm -f "$candidate"
  ok "已停止管理 UFW。"
}

show_bbr_status() {
  printf '当前拥塞控制：%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  printf '可用算法：%s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf '未知')"
  printf '默认队列：%s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知')"
  [[ -f "$BBR_FILE" ]] && printf 'MB-Singbox BBR：已配置\n' || printf 'MB-Singbox BBR：未配置\n'
}

enable_bbr() {
  if ! modprobe tcp_bbr 2>/dev/null && ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    error "当前内核不支持 BBR；脚本不会替换内核。"
    return 1
  fi
  cat > "$BBR_FILE" <<'EOF'
# Managed by MB-Singbox.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  chmod 0644 "$BBR_FILE"
  if sysctl --system >/dev/null && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
    ok "BBR + fq 已启用。它只直接作用于 TCP，不加速 Hysteria2/TUIC 的 QUIC 拥塞控制。"
  else
    error "BBR 应用失败。"
    return 1
  fi
}

disable_bbr() {
  [[ -f "$BBR_FILE" ]] || { info "MB-Singbox 没有创建 BBR 配置。"; return 0; }
  rm -f "$BBR_FILE"
  sysctl --system >/dev/null || true
  ok "已删除 MB-Singbox 的 BBR 配置，并重新加载系统原有 sysctl 配置。"
}

http_probe() {
  local name="$1" url="$2" code
  code="$(curl --proto '=https' --tlsv1.2 -L -o /dev/null -sS --connect-timeout 8 --max-time 15 -w '%{http_code}' "$url" 2>/dev/null || printf '000')"
  if [[ "$code" =~ ^(200|204|301|302|307|308|401)$ ]]; then
    printf '%-12s 可访问（HTTP %s）\n' "$name" "$code"
  elif [[ "$code" == "403" || "$code" == "451" ]]; then
    printf '%-12s 被拒绝或受地区限制（HTTP %s）\n' "$name" "$code"
  else
    printf '%-12s 无法确认（HTTP %s）\n' "$name" "$code"
  fi
}

check_ai_access() {
  printf '\nAI 服务出口连通性检测（不代表账号一定可用）：\n'
  http_probe "ChatGPT" "https://chatgpt.com/cdn-cgi/trace"
  http_probe "OpenAI API" "https://api.openai.com/v1/models"
  http_probe "Gemini" "https://gemini.google.com/"
  http_probe "Claude" "https://claude.ai/"
  printf '\n结果主要取决于 VPS 出口 IP、地区和信誉；本功能只诊断，不修改出口。\n'
}

system_tools_menu() {
  local choice
  printf '\n系统工具：\n'
  show_bbr_status
  if ufw_is_active; then printf 'UFW：已启用\n'; else printf 'UFW：未启用或未安装\n'; fi
  printf '  1. 启用 BBR + fq\n  2. 关闭 MB-Singbox 配置的 BBR\n  3. 配置并同步 UFW\n  4. 停止管理 UFW\n  5. AI 服务可用性检测\n  0. 返回\n'
  read -r -p "请选择：" choice
  case "$choice" in
    1) enable_bbr ;;
    2) disable_bbr ;;
    3) configure_ufw ;;
    4) disable_ufw_management ;;
    5) check_ai_access ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

check_configuration() {
  require_core || return 1
  [[ -s "$SERVER_CONFIG" ]] || { error "尚未生成服务端配置。"; return 1; }
  "$SINGBOX_BIN" check -c "$SERVER_CONFIG"
}

service_menu() {
  local choice
  printf '\n服务管理：\n'
  systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null | head -n 8 || true
  printf '  1. 启动\n  2. 停止\n  3. 重启\n  4. 配置检查\n  5. 最近日志\n  0. 返回\n'
  read -r -p "请选择：" choice
  case "$choice" in
    1) check_configuration && systemctl enable --now "$SERVICE_NAME" ;;
    2) systemctl stop "$SERVICE_NAME" ;;
    3) check_configuration && systemctl restart "$SERVICE_NAME" ;;
    4) check_configuration ;;
    5) journalctl -u "$SERVICE_NAME" -n 100 --no-pager ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

install_manager_binary() {
  install -d -m 0755 "$(dirname "$INSTALL_PATH")"
  if [[ "$SELF_PATH" == "$INSTALL_PATH" ]]; then
    chmod 0755 "$INSTALL_PATH"
  elif [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]]; then
    install -m 0755 "$SELF_PATH" "$INSTALL_PATH"
  else
    error "当前脚本来自临时数据流，无法安装固定副本。请使用 install.sh。"
    return 1
  fi
}

update_manager() {
  local stamp installer source_url rc
  require_root
  command -v curl >/dev/null 2>&1 || install_dependencies || return 1
  stamp="$(date +%s)"
  installer="$(mktemp /tmp/mb-singbox-installer.XXXXXX.sh)" || return 1
  source_url="${MANAGER_RAW_BASE}/mb-singbox.sh?ts=${stamp}"
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "${MANAGER_RAW_BASE}/install.sh?ts=${stamp}" -o "$installer"; then
    rm -f "$installer"
    error "无法下载 MB-Singbox 引导安装器。"
    return 1
  fi
  if ! bash -n "$installer" || ! grep -q '^# Bootstrap installer for mb-singbox\.$' "$installer"; then
    rm -f "$installer"
    error "下载内容未通过安装器校验。"
    return 1
  fi
  MB_SINGBOX_REPO="$MANAGER_REPO" MB_SINGBOX_REF="$MANAGER_REF" MB_SINGBOX_SOURCE_URL="$source_url" MB_SINGBOX_INSTALL_PATH="$INSTALL_PATH" bash "$installer" version
  rc=$?
  rm -f "$installer"
  (( rc == 0 )) || return "$rc"
  ok "MB-Singbox 管理器已更新。"
}

maintenance_menu() {
  local choice
  printf '\n安装/更新：\n'
  printf '当前管理器：%s\n' "$VERSION"
  printf '当前内核：%s\n' "$(current_core_version 2>/dev/null || printf '未安装')"
  printf '  1. 安装/更新 Sing-box 最新稳定版\n  2. 安装指定 Sing-box 稳定版本\n  3. 更新 MB-Singbox 管理器\n  4. 重新生成桌面端配置\n  0. 返回\n'
  read -r -p "请选择：" choice
  case "$choice" in
    1) install_or_update_core ;;
    2)
      read -r -p "版本号（例如 1.13.14）：" choice
      install_or_update_core "$choice"
      ;;
    3)
      if update_manager; then
        info "正在重新载入最新版菜单..."
        exec "$INSTALL_PATH"
      fi
      ;;
    4)
      require_core && generate_outputs "$STATE_FILE" && ok "桌面端配置已重新生成。"
      ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

uninstall_all() {
  require_root
  init_state || return 1
  printf '\n%s彻底卸载范围%s\n' "$C_BOLD" "$C_RESET"
  printf '将删除：MB-Singbox 服务、内核、状态、服务端/桌面配置、链接、二维码、备份、日志、cloudflared 本地服务、UFW 自建规则和 BBR sysctl 文件。\n'
  printf '不会删除：MB-ACME、/etc/acme/certs、Cloudflare 远程 Named Tunnel、系统其他 UFW/sysctl 配置。\n'
  warn "该操作不可恢复，客户端配置和节点密钥也会被删除。"
  confirm "确认彻底卸载 MB-Singbox？" || return 0
  read -r -p "请输入 DELETE 确认：" _confirm_word
  [[ "$_confirm_word" == "DELETE" ]] || { info "已取消。"; return 0; }

  stop_argo_service
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  remove_managed_ufw_rules
  rm -f "$BBR_FILE"
  sysctl --system >/dev/null 2>&1 || true
  rm -rf "$ROOT_DIR" "$LOG_DIR" "$SINGBOX_HOME"
  rm -f "$INSTALL_PATH"
  ok "MB-Singbox 本地资源已彻底卸载。"
  exit 0
}

show_status_line() {
  local core service nodes argo
  core="$(current_core_version 2>/dev/null || printf '未安装')"
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then service="运行中"; else service="已停止"; fi
  nodes="$(jq '.nodes|length' "$STATE_FILE" 2>/dev/null || printf '0')"
  if jq -e '.argo.enabled' "$STATE_FILE" >/dev/null 2>&1; then argo="已启用"; else argo="未启用"; fi
  printf 'Sing-box：%s  服务：%s  节点：%s  Argo：%s\n' "$core" "$service" "$nodes" "$argo"
}

banner() {
  [[ -t 1 ]] && clear || true
  printf '%s%s' "$C_BOLD" "$C_CYAN"
  cat <<'EOF'
 __  __  ____        ____  _             _                
|  \/  || __ )      / ___|(_)_ __   __ _| |__   _____  __
| |\/| ||  _ \ _____\___ \| | '_ \ / _` | '_ \ / _ \ \/ /
| |  | || |_) |_____|___) | | | | | (_| | |_) | (_) >  < 
|_|  |_||____/     |____/|_|_| |_|\__, |_.__/ \___/_/\_\
                                  |___/                   
EOF
  printf '%s' "$C_RESET"
  printf '%sMB-Singbox %s%s\n' "$C_BOLD" "$VERSION" "$C_RESET"
  printf '轻量、可校验的 Sing-box 节点管理器\n\n'
}

main_menu() {
  local choice
  require_root
  require_systemd || return 1
  install_dependencies || return 1
  init_state || return 1
  install_manager_binary || return 1
  while true; do
    banner
    show_status_line
    printf '\n  1. 安装/更新\n'
    printf '  2. 创建节点\n'
    printf '  3. 查看节点、桌面配置与分享链接\n'
    printf '  4. 修改节点配置\n'
    printf '  5. 删除节点\n'
    printf '  6. 服务管理与日志\n'
    printf '  7. Argo 应急隧道（VMess-WS 专属）\n'
    printf '  8. BBR、UFW 与 AI 检测\n'
    printf '  9. 修改客户端连接地址\n'
    printf ' 10. 彻底卸载\n'
    printf '  0. 退出\n'
    read -r -p "请选择：" choice
    printf '\n'
    case "$choice" in
      1) maintenance_menu; pause ;;
      2) add_node_menu; pause ;;
      3) view_node_menu; pause ;;
      4) edit_node; pause ;;
      5) delete_node; pause ;;
      6) service_menu; pause ;;
      7) argo_menu; pause ;;
      8) system_tools_menu; pause ;;
      9) ensure_server_address; generate_outputs "$STATE_FILE" || true; pause ;;
      10) uninstall_all ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

show_help() {
  cat <<EOF
${PROGRAM} ${VERSION}

用法：
  ${PROGRAM}                 打开交互菜单
  ${PROGRAM} install-core    安装/更新 Sing-box 最新稳定版
  ${PROGRAM} install-core VERSION
  ${PROGRAM} update-manager  更新 MB-Singbox 管理器
  ${PROGRAM} check           检查当前服务端配置
  ${PROGRAM} render          重新生成服务端与桌面端配置
  ${PROGRAM} status          查看状态
  ${PROGRAM} version

状态文件：${STATE_FILE}
服务端配置：${SERVER_CONFIG}
桌面配置：${CLIENT_DIR}
EOF
}

main() {
  local command="${1:-menu}"
  case "$command" in
    menu) main_menu ;;
    install-core) require_root; shift; install_or_update_core "${1:-}" ;;
    update-manager) update_manager ;;
    check) require_root; check_configuration ;;
    render)
      require_root; require_core; init_state
      local candidate
      candidate="$(mktemp "${ROOT_DIR}/.server.XXXXXX.json")" || return 1
      render_server_config "$STATE_FILE" "$candidate" && "$SINGBOX_BIN" check -c "$candidate" && install -m 0600 "$candidate" "$SERVER_CONFIG" && generate_outputs "$STATE_FILE"
      rm -f "$candidate"
      ;;
    status) require_root; init_state; show_status_line; list_nodes ;;
    version|--version|-v) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|--help|-h) show_help ;;
    *) error "未知命令：${command}"; show_help; return 2 ;;
  esac
}

if [[ "${MB_SINGBOX_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
