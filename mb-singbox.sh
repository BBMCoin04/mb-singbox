#!/usr/bin/env bash
# mb-singbox: state-driven sing-box manager for Linux VPS hosts.
# jq expressions intentionally use single quotes so jq expands their $variables.
# shellcheck disable=SC2016

set -uo pipefail
umask 077

VERSION="0.7.3"
PROGRAM="mb-singbox"
MANAGER_UPDATE_APPLIED=0
INSTALL_PATH="${MB_SINGBOX_INSTALL_PATH:-/usr/local/sbin/mb-singbox}"
QUICK_PATH="${MB_SINGBOX_QUICK_PATH:-/usr/local/bin/mb-singbox}"
LEGACY_QUICK_PATH="${MB_SINGBOX_LEGACY_QUICK_PATH:-/usr/local/bin/singbox}"
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
ACME_CERT_ROOT="${MB_SINGBOX_ACME_CERT_ROOT:-/etc/acme/certs}"
SINGBOX_HOME="${MB_SINGBOX_CORE_DIR:-/usr/local/lib/mb-singbox}"
SINGBOX_BIN="${MB_SINGBOX_BIN:-${SINGBOX_HOME}/sing-box}"
SERVICE_FILE="${MB_SINGBOX_SERVICE_FILE:-/etc/systemd/system/mb-singbox.service}"
SERVICE_NAME="mb-singbox.service"
MAIN_SERVICE_DESCRIPTION="MB sing-box proxy service"
PORT_HOPPING_NFT_FILE="${MB_SINGBOX_PORT_HOPPING_NFT_FILE:-${ROOT_DIR}/port-hopping.nft}"
PORT_HOPPING_SERVICE_FILE="${MB_SINGBOX_PORT_HOPPING_SERVICE_FILE:-/etc/systemd/system/mb-singbox-port-hopping.service}"
PORT_HOPPING_SERVICE_NAME="mb-singbox-port-hopping.service"
PORT_HOPPING_SERVICE_DESCRIPTION="MB sing-box Hysteria2 port hopping"
PORT_HOPPING_NFT_TABLE="mb_singbox_port_hopping"
DEFAULT_REALITY_TARGET="apple.com"
CLOUDFLARED_BIN="${MB_SINGBOX_CLOUDFLARED_BIN:-${SINGBOX_HOME}/cloudflared}"
ARGO_SERVICE_FILE="${MB_SINGBOX_ARGO_SERVICE_FILE:-/etc/systemd/system/mb-singbox-argo.service}"
ARGO_SERVICE_NAME="mb-singbox-argo.service"
ARGO_NAMED_DESCRIPTION="MB sing-box Cloudflare Named Tunnel"
ARGO_QUICK_DESCRIPTION="MB sing-box Cloudflare Quick Tunnel"
ARGO_TOKEN_FILE="${ROOT_DIR}/argo-token"
BBR_FILE="${MB_SINGBOX_BBR_FILE:-/etc/sysctl.d/99-mb-singbox-bbr.conf}"
LOCK_FILE="${MB_SINGBOX_LOCK_FILE:-/run/lock/mb-singbox.lock}"
BACKUP_KEEP="${MB_SINGBOX_BACKUP_KEEP:-20}"
MANAGED_MARKER_NAME=".mb-singbox-managed"
LOCK_HELD=0
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

confirm_default_yes() {
  local prompt="$1" answer
  read -r -p "${prompt} [Y/n]: " answer
  [[ ! "$answer" =~ ^[Nn]$ ]]
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

canonical_path() {
  readlink -m -- "$1" 2>/dev/null
}

safe_managed_root() {
  local path canonical
  path="$1"
  [[ "$path" == /* && ! "$path" =~ [[:space:]] ]] || return 1
  canonical="$(canonical_path "$path")" || return 1
  case "$canonical" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/var/log)
      return 1
      ;;
  esac
}

path_is_within() {
  local child parent
  child="$(canonical_path "$1")" || return 1
  parent="$(canonical_path "$2")" || return 1
  [[ "$child" == "$parent"/* ]]
}

validate_managed_layout() {
  safe_managed_root "$ROOT_DIR" || { error "拒绝使用危险的状态目录：${ROOT_DIR}"; return 1; }
  safe_managed_root "$LOG_DIR" || { error "拒绝使用危险的日志目录：${LOG_DIR}"; return 1; }
  safe_managed_root "$SINGBOX_HOME" || { error "拒绝使用危险的内核目录：${SINGBOX_HOME}"; return 1; }
  path_is_within "$STATE_FILE" "$ROOT_DIR" || { error "状态文件必须位于 ${ROOT_DIR} 内。"; return 1; }
  path_is_within "$SERVER_CONFIG" "$ROOT_DIR" || { error "服务端配置必须位于 ${ROOT_DIR} 内。"; return 1; }
  path_is_within "$CLIENT_DIR" "$ROOT_DIR" || { error "客户端目录必须位于 ${ROOT_DIR} 内。"; return 1; }
  path_is_within "$LINK_DIR" "$ROOT_DIR" || { error "链接目录必须位于 ${ROOT_DIR} 内。"; return 1; }
  path_is_within "$QR_DIR" "$ROOT_DIR" || { error "二维码目录必须位于 ${ROOT_DIR} 内。"; return 1; }
  path_is_within "$BACKUP_DIR" "$ROOT_DIR" || { error "备份目录必须位于 ${ROOT_DIR} 内。"; return 1; }
  path_is_within "$PORT_HOPPING_NFT_FILE" "$ROOT_DIR" || { error "端口跳跃规则文件必须位于 ${ROOT_DIR} 内。"; return 1; }
  [[ "$INSTALL_PATH" == /* && "$(basename "$INSTALL_PATH")" == "mb-singbox" ]] || { error "管理器安装路径必须是绝对路径，并以 mb-singbox 结尾。"; return 1; }
  [[ "$QUICK_PATH" == /* && "$(basename "$QUICK_PATH")" == "mb-singbox" ]] || { error "主命令路径必须是绝对路径，并以 mb-singbox 结尾。"; return 1; }
  [[ "$LEGACY_QUICK_PATH" == /* && "$(basename "$LEGACY_QUICK_PATH")" == "singbox" ]] || { error "兼容命令路径必须是绝对路径，并以 singbox 结尾。"; return 1; }
  if [[ -e "$INSTALL_PATH" || -L "$INSTALL_PATH" ]]; then
    [[ -f "$INSTALL_PATH" && ! -L "$INSTALL_PATH" ]] || { error "管理器安装目标必须是普通文件：${INSTALL_PATH}"; return 1; }
  fi
  [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] && (( BACKUP_KEEP >= 1 && BACKUP_KEEP <= 100 )) || {
    error "MB_SINGBOX_BACKUP_KEEP 必须是 1 到 100。"
    return 1
  }
}

safe_to_remove_managed_root() {
  local canonical
  canonical="$(canonical_path "$1")" || return 1
  safe_managed_root "$canonical" && [[ "$(basename "$canonical")" == "mb-singbox" ]]
}

write_managed_marker() {
  local marker="${1}/${MANAGED_MARKER_NAME}"
  printf 'mb-singbox managed directory\n' > "$marker" || return 1
  chmod 0600 "$marker"
}

managed_marker_valid() {
  [[ -f "${1}/${MANAGED_MARKER_NAME}" ]] &&
    grep -Eq '^(mb-singbox|MB-Singbox|MB sing-box 管理器) managed directory$' "${1}/${MANAGED_MARKER_NAME}"
}

ensure_directories() {
  validate_managed_layout || return 1
  install -d -m 0700 "$ROOT_DIR" "$CLIENT_DIR" "$LINK_DIR" "$QR_DIR" "$BACKUP_DIR" "$LOG_DIR" || return 1
  install -d -m 0755 "$SINGBOX_HOME" "$(dirname "$LOCK_FILE")" || return 1
  write_managed_marker "$ROOT_DIR" || return 1
  write_managed_marker "$LOG_DIR" || return 1
  write_managed_marker "$SINGBOX_HOME" || return 1
}

atomic_install_file() {
  local source="$1" target="$2" mode="$3" temporary
  temporary="$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX")" || return 1
  if ! install -m "$mode" "$source" "$temporary" || ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

write_jq_candidate() {
  local target="$1"
  shift
  if ! jq "$@" > "$target" || [[ ! -s "$target" ]]; then
    rm -f -- "$target"
    error "生成候选状态失败，原配置未修改。"
    return 1
  fi
}

acquire_lock() {
  (( LOCK_HELD == 0 )) || { error "管理器内部发生重复加锁。"; return 1; }
  validate_managed_layout || return 1
  install -d -m 0755 "$(dirname "$LOCK_FILE")" || return 1
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    exec 9>&-
    error "另一个 MB sing-box 管理器操作正在进行。"
    return 1
  fi
  LOCK_HELD=1
  if ! ensure_directories; then
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&-
    LOCK_HELD=0
    return 1
  fi
}

release_lock() {
  (( LOCK_HELD )) || return 0
  flock -u 9 >/dev/null 2>&1 || true
  exec 9>&-
  LOCK_HELD=0
}

with_lock() {
  local rc
  acquire_lock || return 1
  "$@"
  rc=$?
  release_lock
  return "$rc"
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
  local domain="${1,,}" final_label
  (( ${#domain} <= 253 )) || return 1
  [[ "$domain" == *.* ]] || return 1
  final_label="${domain##*.}"
  [[ "$final_label" == *[a-z]* ]] || return 1
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

validate_ipv4() {
  local value="$1" octet
  local -a octets=()
  IFS='.' read -r -a octets <<< "$value"
  (( ${#octets[@]} == 4 )) || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && (( 10#$octet <= 255 )) || return 1
  done
}

count_ipv6_groups() {
  local side="$1" group
  local -a groups=()
  [[ -n "$side" ]] || { printf '0'; return 0; }
  IFS=':' read -r -a groups <<< "$side"
  (( ${#groups[@]} > 0 )) || return 1
  for group in "${groups[@]}"; do
    [[ "$group" =~ ^[0-9a-f]{1,4}$ ]] || return 1
  done
  printf '%d' "${#groups[@]}"
}

validate_ipv6() {
  local value="${1,,}" left right left_count right_count group_count ipv4_tail
  [[ "$value" == *:* && "$value" != *'%'* ]] || return 1
  if [[ "$value" == *.* ]]; then
    ipv4_tail="${value##*:}"
    validate_ipv4 "$ipv4_tail" || return 1
    value="${value%:*}:0:0"
  fi
  [[ "$value" =~ ^[0-9a-f:]+$ && "$value" != *:::* ]] || return 1

  if [[ "$value" == *::* ]]; then
    [[ "${value#*::}" != *::* ]] || return 1
    left="${value%%::*}"
    right="${value#*::}"
    left_count="$(count_ipv6_groups "$left")" || return 1
    right_count="$(count_ipv6_groups "$right")" || return 1
    (( left_count + right_count < 8 ))
  else
    [[ "$value" != :* && "$value" != *: ]] || return 1
    group_count="$(count_ipv6_groups "$value")" || return 1
    (( group_count == 8 ))
  fi
}

validate_host() {
  local host="$1"
  validate_domain "$host" || validate_ipv4 "$host" || validate_ipv6 "$host"
}

validate_name() {
  [[ -n "$1" && ${#1} -le 48 && ! "$1" =~ [[:cntrl:]] ]]
}

validate_websocket_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~!$\&\'\(\)\*+,\;=:@%/-]+$ ]]
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
  local state="$1" server address item domain path
  jq -e '
    def text: type == "string";
    def nonempty: text and length > 0;
    def port: type == "number" and . == floor and . >= 1 and . <= 65535;
    def safe_name: nonempty and length <= 48 and (test("[\u0000-\u001f\u007f]") | not);
    def common_node:
      type == "object" and
      (.id | nonempty and test("^[a-z0-9][a-z0-9-]{0,63}$")) and
      (.name | safe_name) and
      (.port | port);
    def tls_node:
      (.tls_domain | nonempty) and
      (.certificate_path | nonempty and startswith("/")) and
      (.key_path | nonempty and startswith("/"));
    def valid_hopping:
      (.port_hopping // {enabled:false,start:0,end:0,hop_interval:30}) as $hop |
      ($hop | type == "object") and
      ($hop.enabled | type == "boolean") and
      ($hop.start | type == "number" and . == floor and . >= 0 and . <= 65535) and
      ($hop.end | type == "number" and . == floor and . >= 0 and . <= 65535) and
      ($hop.hop_interval | type == "number" and . == floor and . >= 5 and . <= 86400) and
      (if $hop.enabled then $hop.start >= 1 and $hop.start < $hop.end else $hop.start == 0 and $hop.end == 0 end);
    def valid_node:
      common_node and
      if .type == "reality" then
        (.uuid | nonempty) and (.server_name | nonempty) and
        (.private_key | nonempty) and (.public_key | nonempty) and (.short_id | nonempty)
      elif .type == "hysteria2" then
        tls_node and (.password | nonempty) and (.obfs_password | nonempty) and valid_hopping
      elif .type == "tuic" then
        tls_node and (.uuid | nonempty) and (.password | nonempty)
      elif .type == "anytls" then
        tls_node and (.password | nonempty)
      elif .type == "vmess" then
        tls_node and (.uuid | nonempty) and (.path | nonempty and startswith("/"))
      else false
      end;
    . as $root |
    .schema == 1 and
    (.server_address | text) and
    (.firewall_managed | type == "boolean") and
    ((.firewall_mode // (if .firewall_managed then "managed" else "external" end)) |
      . == "external" or . == "permissive" or . == "managed") and
    (.nodes | type == "array" and all(.[]; valid_node)) and
    (([.nodes[].id] | length) == ([.nodes[].id] | unique | length)) and
    (([.nodes[] | ((if .type == "hysteria2" or .type == "tuic" then "udp:" else "tcp:" end) + (.port | tostring))] | length) ==
     ([.nodes[] | ((if .type == "hysteria2" or .type == "tuic" then "udp:" else "tcp:" end) + (.port | tostring))] | unique | length)) and
    (all(.nodes[];
      . as $node |
      if $node.type == "hysteria2" and ($node.port_hopping.enabled // false) then
        all($root.nodes[];
          . as $other |
          if $other.type == "hysteria2" or $other.type == "tuic" then
            $other.port < $node.port_hopping.start or $other.port > $node.port_hopping.end
          else true end) and
        all($root.nodes[];
          . as $other |
          if $other.id != $node.id and $other.type == "hysteria2" and ($other.port_hopping.enabled // false) then
            $other.port_hopping.end < $node.port_hopping.start or
            $other.port_hopping.start > $node.port_hopping.end
          else true end)
      else true end)) and
    (.argo | type == "object") and
    (.argo.enabled | type == "boolean") and
    (.argo.mode | text) and (.argo.node_id | text) and (.argo.hostname | text) and
    (.argo.origin_port | type == "number" and . == floor and . >= 0 and . <= 65535) and
    ((.argo.provisioned // false) | type == "boolean") and
    ((.argo.verified // false) | type == "boolean") and
    ((.argo.tunnel_id // "") | text) and
    ((.argo.public_port // 2096) | port) and
    (if .argo.enabled then
      .argo.origin_port > 0 and any(.nodes[]; .id == $root.argo.node_id and .type == "vmess")
     else true end) and
    ((has("client") | not) or .client == null or
      ((.client | type == "object") and
       ((.client | has("preferred_enabled") | not) or (.client.preferred_enabled | type == "boolean")) and
       ((.client.preferred_addresses // []) | type == "array" and all(.[]; nonempty)) and
       ((.client.preferred_results // {}) | type == "object") and
       ((.client.preferred_last_probe_at // "") | text) and
       ((.client.mihomo // null) as $mihomo |
         $mihomo == null or
         (($mihomo | type == "object") and
          ($mihomo.proxy_username | nonempty and test("^[A-Za-z0-9._-]{1,32}$")) and
          ($mihomo.proxy_password | nonempty and length <= 128) and
          ($mihomo.controller_secret | text and test("^[a-f0-9]{64}$"))))))
  ' "$state" >/dev/null 2>&1 || return 1

  server="$(jq -r '.server_address' "$state")" || return 1
  [[ -z "$server" ]] || validate_host "$server" || return 1
  while IFS=$'\t' read -r item domain path; do
    case "$item" in
      reality) validate_domain "$domain" || return 1 ;;
      tls) validate_domain "$domain" || return 1 ;;
      vmess) validate_domain "$domain" && validate_websocket_path "$path" || return 1 ;;
    esac
  done < <(jq -r '.nodes[] | if .type == "reality" then ["reality",.server_name,""] elif .type == "vmess" then ["vmess",.tls_domain,.path] else ["tls",.tls_domain,""] end | @tsv' "$state")
  while IFS= read -r address; do
    [[ -z "$address" ]] || validate_domain "$address" || validate_ipv4 "$address" || return 1
  done < <(jq -r '.client.preferred_addresses[]? // empty' "$state")
  address="$(jq -r '.argo.hostname // ""' "$state")" || return 1
  [[ -z "$address" ]] || validate_domain "$address"
}

state_consistent() {
  local state="$1"
  jq -e '
    . as $root |
    ((.firewall_mode == "managed") == .firewall_managed) and
    (.argo.mode == "" or .argo.mode == "named" or .argo.mode == "quick") and
    (if (.argo.verified // false) then (.argo.provisioned // false) else true end) and
    (if .argo.enabled then
      (.argo.mode == "named" or .argo.mode == "quick") and
      .argo.origin_port > 0 and
      any(.nodes[]; .id == $root.argo.node_id and .type == "vmess") and
      (if .argo.mode == "named" then (.argo.hostname | length) > 0 else true end) and
      all(.nodes[];
        if .type == "reality" or .type == "anytls" or .type == "vmess" then
          .port != $root.argo.origin_port
        else true end)
     else
      .argo.mode == "" and .argo.origin_port == 0 and
      (.argo.verified // false) == false
     end)
  ' "$state" >/dev/null 2>&1
}

state_candidate_valid() {
  state_valid "$1" && state_consistent "$1"
}

init_state() {
  local normalized migration_backup="" mihomo_proxy_password="" mihomo_controller_secret=""
  ensure_directories || return 1
  if [[ -s "$STATE_FILE" ]]; then
    mihomo_proxy_password="$(jq -r '.client.mihomo.proxy_password // empty' "$STATE_FILE" 2>/dev/null || true)"
    mihomo_controller_secret="$(jq -r '.client.mihomo.controller_secret // empty' "$STATE_FILE" 2>/dev/null || true)"
  fi
  [[ -n "$mihomo_proxy_password" ]] || mihomo_proxy_password="$(random_password)" || return 1
  [[ "$mihomo_controller_secret" =~ ^[a-f0-9]{64}$ ]] || mihomo_controller_secret="$(openssl rand -hex 32)" || return 1
  if [[ -e "$STATE_FILE" ]]; then
    [[ -s "$STATE_FILE" ]] || {
      error "状态文件为空，拒绝自动覆盖：${STATE_FILE}"
      return 1
    }
    state_valid "$STATE_FILE" || {
      error "状态文件格式不正确：${STATE_FILE}"
      return 1
    }
    normalized="$(mktemp "${ROOT_DIR}/.state-normalize.XXXXXX.json")" || return 1
    if ! jq --arg mihomo_password "$mihomo_proxy_password" --arg mihomo_secret "$mihomo_controller_secret" '
      .firewall_mode //= (if .firewall_managed then "managed" else "external" end) |
      .argo.provisioned //= false |
      .argo.verified //= false |
      .argo.tunnel_id //= "" |
      .argo.public_port //= 2096 |
      .nodes |= map(if .type == "hysteria2" then .port_hopping //= {enabled:false,start:0,end:0,hop_interval:30} else . end) |
      .client //= {} |
      .client.preferred_enabled = (if (.client | has("preferred_enabled")) then .client.preferred_enabled else true end) |
      .client.preferred_addresses //= [
        "cfip.1323123.xyz",
        "cf.877771.xyz",
        "cloudflare.182682.xyz",
        "www.cloudflare.com",
        "one.one.one.one"
      ] |
      .client.preferred_results //= {} |
      .client.preferred_last_probe_at //= "" |
      .client.mihomo //= {} |
      .client.mihomo.proxy_username //= "mihomo" |
      .client.mihomo.proxy_password //= $mihomo_password |
      .client.mihomo.controller_secret //= $mihomo_secret
    ' "$STATE_FILE" > "$normalized" || ! state_valid "$normalized"; then
      rm -f -- "$normalized"
      error "状态迁移失败，原文件保持不变：${STATE_FILE}"
      return 1
    fi
    if ! cmp -s "$STATE_FILE" "$normalized"; then
      migration_backup="$(mktemp -d "${BACKUP_DIR}/state-before-0.7.3-$(date +%Y%m%d-%H%M%S).XXXXXX")" || {
        rm -f -- "$normalized"
        return 1
      }
      chmod 0700 "$migration_backup" || { rm -rf -- "$migration_backup"; rm -f -- "$normalized"; return 1; }
      if ! cp -a -- "$STATE_FILE" "$migration_backup/state.json" ||
         ! atomic_install_file "$normalized" "$STATE_FILE" 0600; then
        rm -f -- "$normalized"
        error "无法原子更新状态文件，原文件保持不变；迁移备份：${migration_backup}"
        return 1
      fi
      ok "旧状态已原子迁移；迁移前备份：${migration_backup}"
    fi
    rm -f -- "$normalized"
    if ! state_consistent "$STATE_FILE"; then
      warn "现有状态存在跨字段不一致；本次未自动修改，请运行 doctor 检查。"
    fi
    return 0
  fi

  normalized="$(mktemp "${ROOT_DIR}/.state-initial.XXXXXX.json")" || return 1
  if ! jq -n --arg now "$(date -u +%FT%TZ)" --arg mihomo_password "$mihomo_proxy_password" --arg mihomo_secret "$mihomo_controller_secret" '{
    schema: 1,
    server_address: "",
    created_at: $now,
    firewall_managed: false,
    firewall_mode: "external",
    nodes: [],
    argo: {
      enabled: false,
      mode: "",
      node_id: "",
      hostname: "",
      origin_port: 0,
      provisioned: false,
      verified: false,
      tunnel_id: "",
      public_port: 2096
    },
    client: {
      preferred_enabled: true,
      preferred_addresses: [
        "cfip.1323123.xyz",
        "cf.877771.xyz",
        "cloudflare.182682.xyz",
        "www.cloudflare.com",
        "one.one.one.one"
      ],
      preferred_results: {},
      preferred_last_probe_at: "",
      mihomo: {
        proxy_username: "mihomo",
        proxy_password: $mihomo_password,
        controller_secret: $mihomo_secret
      }
    }
  }' > "$normalized" || ! state_valid "$normalized" || ! atomic_install_file "$normalized" "$STATE_FILE" 0600; then
    rm -f -- "$normalized"
    error "无法创建初始状态文件。"
    return 1
  fi
  rm -f -- "$normalized"
}

install_dependencies() {
  local missing=() command_name package_manager=""
  for command_name in curl jq openssl tar flock ss; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  (( ${#missing[@]} == 0 )) || warn "缺少必要命令：${missing[*]}，准备安装依赖。"

  if (( ${#missing[@]} > 0 )); then
    if command -v apt-get >/dev/null 2>&1; then
      package_manager=apt
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq openssl tar util-linux iproute2 libc-bin
    elif command -v dnf >/dev/null 2>&1; then
      package_manager=dnf
      dnf install -y ca-certificates curl jq openssl tar util-linux iproute glibc-common
    elif command -v yum >/dev/null 2>&1; then
      package_manager=yum
      yum install -y ca-certificates curl jq openssl tar util-linux iproute glibc-common
    else
      error "无法识别受支持的包管理器，请手动安装：curl jq openssl tar util-linux iproute2"
      return 1
    fi || return 1
  elif command -v apt-get >/dev/null 2>&1; then
    package_manager=apt
  elif command -v dnf >/dev/null 2>&1; then
    package_manager=dnf
  elif command -v yum >/dev/null 2>&1; then
    package_manager=yum
  fi

  for command_name in curl jq openssl tar flock ss; do
    command -v "$command_name" >/dev/null 2>&1 || {
      error "安装依赖后仍缺少命令：${command_name}"
      return 1
    }
  done

  if ! command -v qrencode >/dev/null 2>&1; then
    case "$package_manager" in
      apt) DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode >/dev/null 2>&1 || true ;;
      dnf) dnf install -y qrencode >/dev/null 2>&1 || true ;;
      yum) yum install -y qrencode >/dev/null 2>&1 || true ;;
    esac
    command -v qrencode >/dev/null 2>&1 || warn "未安装 qrencode，将跳过二维码生成，其他功能不受影响。"
  fi
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

version_at_least() {
  local current="$1" minimum="$2"
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$minimum" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$(printf '%s\n' "$minimum" "$current" | sort -V | head -n 1)" == "$minimum" ]]
}

download_core() {
  local version="${1:-}" arch archive_url release_json temp_dir archive expected actual extracted
  [[ -n "$version" ]] || version="$(latest_stable_version)" || {
    error "无法取得 sing-box 最新稳定版。"
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

  info "正在读取 sing-box ${version} 官方 Release 元数据..." >&2
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL \
    "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${version}" -o "$release_json"; then
    rm -rf "$temp_dir"
    error "无法取得 sing-box Release 元数据。"
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

  info "正在下载 sing-box ${version} (${arch})..." >&2
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$archive_url" -o "$temp_dir/$archive"; then
    rm -rf "$temp_dir"
    error "sing-box 下载失败。"
    return 1
  fi
  actual="$(sha256sum "$temp_dir/$archive" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$temp_dir"
    error "sing-box SHA-256 校验失败，拒绝安装。"
    return 1
  fi
  if ! tar -xzf "$temp_dir/$archive" -C "$temp_dir"; then
    rm -rf "$temp_dir"
    error "sing-box 压缩包无法解压。"
    return 1
  fi
  extracted="$temp_dir/sing-box-${version}-linux-${arch}/sing-box"
  if [[ ! -x "$extracted" ]]; then
    rm -rf "$temp_dir"
    error "压缩包中没有找到 sing-box 二进制。"
    return 1
  fi
  printf '%s\n' "$extracted"
}

port_hopping_enabled_in_state() {
  jq -e 'any(.nodes[]; .type == "hysteria2" and (.port_hopping.enabled // false))' "$1" >/dev/null 2>&1
}

warn_if_legacy_iptables() {
  local version
  command -v iptables >/dev/null 2>&1 || return 0
  version="$(iptables --version 2>/dev/null || true)"
  if [[ "$version" == *legacy* ]]; then
    warn "检测到 iptables-legacy；Hysteria2 端口跳跃使用 nftables NAT，请启用后检查计数器和实际 UDP 连通性。"
  fi
}

ensure_nft_available() {
  if ! command -v nft >/dev/null 2>&1; then
    info "端口跳跃需要 nftables，正在安装 nftables。"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y nftables
    elif command -v yum >/dev/null 2>&1; then
      yum install -y nftables
    else
      error "无法自动安装 nftables，请先安装 nft 命令。"
      return 1
    fi || return 1
  fi
  command -v nft >/dev/null 2>&1 || { error "安装后仍找不到 nft 命令。"; return 1; }
  warn_if_legacy_iptables
}

render_port_hopping_nft() {
  local state="$1" output="$2" table_name="${3:-$PORT_HOPPING_NFT_TABLE}"
  local id start end target
  {
    printf 'table inet %s {\n' "$table_name"
    printf '  chain prerouting {\n'
    printf '    type nat hook prerouting priority dstnat; policy accept;\n'
    while IFS=$'\t' read -r id start end target; do
      printf '    udp dport %s-%s counter redirect to :%s comment "mb-singbox %s"\n' "$start" "$end" "$target" "$id"
    done < <(jq -r '.nodes[] | select(.type == "hysteria2" and (.port_hopping.enabled // false)) | [.id,.port_hopping.start,.port_hopping.end,.port] | @tsv' "$state")
    printf '  }\n'
    printf '}\n'
  } > "$output"
}

check_port_hopping_rules() {
  local state="$1" temporary table_name
  port_hopping_enabled_in_state "$state" || return 0
  ensure_nft_available || return 1
  temporary="$(mktemp /tmp/mb-singbox-port-hopping-check.XXXXXX.nft)" || return 1
  table_name="${PORT_HOPPING_NFT_TABLE}_check_${BASHPID}_${RANDOM}"
  if ! render_port_hopping_nft "$state" "$temporary" "$table_name" || ! nft -c -f "$temporary"; then
    rm -f -- "$temporary"
    error "Hysteria2 端口跳跃 nftables 规则校验失败。"
    return 1
  fi
  rm -f -- "$temporary"
}

check_installed_port_hopping_rules() {
  local temporary
  if ! port_hopping_enabled_in_state "$STATE_FILE"; then
    return 0
  fi
  [[ -s "$PORT_HOPPING_NFT_FILE" ]] || { error "端口跳跃规则文件缺失：${PORT_HOPPING_NFT_FILE}"; return 1; }
  temporary="$(mktemp /tmp/mb-singbox-port-hopping-current.XXXXXX.nft)" || return 1
  render_port_hopping_nft "$STATE_FILE" "$temporary" || { rm -f -- "$temporary"; return 1; }
  if ! cmp -s "$temporary" "$PORT_HOPPING_NFT_FILE"; then
    rm -f -- "$temporary"
    error "已安装的端口跳跃规则与当前状态不一致，请运行 mb-singbox render。"
    return 1
  fi
  rm -f -- "$temporary"
}

clear_port_hopping_rules() {
  command -v nft >/dev/null 2>&1 || return 0
  if nft list table inet "$PORT_HOPPING_NFT_TABLE" >/dev/null 2>&1; then
    nft delete table inet "$PORT_HOPPING_NFT_TABLE"
  fi
}

apply_port_hopping_rules() {
  command -v nft >/dev/null 2>&1 || { error "端口跳跃服务找不到 nft 命令。"; return 1; }
  clear_port_hopping_rules || return 1
  [[ -s "$PORT_HOPPING_NFT_FILE" ]] || return 0
  if ! nft -f "$PORT_HOPPING_NFT_FILE"; then
    clear_port_hopping_rules >/dev/null 2>&1 || true
    return 1
  fi
}

render_port_hopping_service_file() {
  local output="$1"
  cat > "$output" <<EOF
[Unit]
Description=${PORT_HOPPING_SERVICE_DESCRIPTION}
Wants=network-online.target
After=network-online.target
Before=${SERVICE_NAME}
PartOf=${SERVICE_NAME}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_PATH} port-hopping-apply
ExecReload=${INSTALL_PATH} port-hopping-apply
ExecStop=${INSTALL_PATH} port-hopping-clear
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
}

sync_port_hopping_runtime() {
  if port_hopping_enabled_in_state "$STATE_FILE"; then
    ensure_nft_available || return 1
    systemctl enable "$PORT_HOPPING_SERVICE_NAME" >/dev/null || return 1
    systemctl restart "$PORT_HOPPING_SERVICE_NAME" || return 1
    systemctl is-active --quiet "$PORT_HOPPING_SERVICE_NAME"
  else
    systemctl disable --now "$PORT_HOPPING_SERVICE_NAME" >/dev/null 2>&1 || true
    clear_port_hopping_rules
  fi
}

stop_port_hopping_service() {
  systemctl disable --now "$PORT_HOPPING_SERVICE_NAME" >/dev/null 2>&1 || true
  clear_port_hopping_rules >/dev/null 2>&1 || true
}

install_port_hopping_file_for_state() {
  local state="$1" rendered="$2"
  if port_hopping_enabled_in_state "$state"; then
    atomic_install_file "$rendered" "$PORT_HOPPING_NFT_FILE" 0600
  else
    rm -f -- "$PORT_HOPPING_NFT_FILE"
  fi
}

restore_optional_file() {
  local backup="$1" existed="$2" target="$3" mode="$4"
  if (( existed )); then
    atomic_install_file "$backup" "$target" "$mode"
  else
    rm -f -- "$target"
  fi
}

write_service_file() {
  local main_candidate hopping_candidate main_backup hopping_backup hopping_dependency=""
  local main_existed=0 hopping_existed=0 commit_started=0 rc=0
  main_candidate="$(mktemp /tmp/mb-singbox-service.XXXXXX)" || return 1
  hopping_candidate="$(mktemp /tmp/mb-singbox-port-hopping-service.XXXXXX)" || { rm -f -- "$main_candidate"; return 1; }
  main_backup="$(mktemp /tmp/mb-singbox-service-backup.XXXXXX)" || { rm -f -- "$main_candidate" "$hopping_candidate"; return 1; }
  hopping_backup="$(mktemp /tmp/mb-singbox-port-hopping-service-backup.XXXXXX)" || {
    rm -f -- "$main_candidate" "$hopping_candidate" "$main_backup"
    return 1
  }
  if port_hopping_enabled_in_state "$STATE_FILE"; then
    hopping_dependency=$'Requires='"${PORT_HOPPING_SERVICE_NAME}"$'\nAfter='"${PORT_HOPPING_SERVICE_NAME}"
  fi
  cat > "$main_candidate" <<EOF
[Unit]
Description=${MAIN_SERVICE_DESCRIPTION}
Wants=network-online.target
After=network-online.target nss-lookup.target
${hopping_dependency}
[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${SERVER_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  render_port_hopping_service_file "$hopping_candidate" || rc=1
  if (( rc == 0 )) && [[ -f "$SERVICE_FILE" ]]; then
    if cp -a -- "$SERVICE_FILE" "$main_backup"; then main_existed=1; else rc=1; fi
  fi
  if (( rc == 0 )) && [[ -f "$PORT_HOPPING_SERVICE_FILE" ]]; then
    if cp -a -- "$PORT_HOPPING_SERVICE_FILE" "$hopping_backup"; then hopping_existed=1; else rc=1; fi
  fi
  if (( rc == 0 )); then
    commit_started=1
    atomic_install_file "$main_candidate" "$SERVICE_FILE" 0644 || rc=1
  fi
  if (( rc == 0 )); then
    atomic_install_file "$hopping_candidate" "$PORT_HOPPING_SERVICE_FILE" 0644 || rc=1
  fi
  if (( rc == 0 )); then
    systemctl daemon-reload || rc=1
  fi
  if (( rc != 0 && commit_started )); then
    restore_optional_file "$main_backup" "$main_existed" "$SERVICE_FILE" 0644 || true
    restore_optional_file "$hopping_backup" "$hopping_existed" "$PORT_HOPPING_SERVICE_FILE" 0644 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f -- "$main_candidate" "$hopping_candidate" "$main_backup" "$hopping_backup"
  (( rc == 0 ))
}

unit_description() {
  [[ -f "$1" ]] || return 1
  awk -F= '/^Description=/{sub(/^Description=/, ""); print; exit}' "$1"
}

expected_argo_description() {
  case "$(jq -r '.argo.mode // ""' "$STATE_FILE" 2>/dev/null)" in
    named) printf '%s\n' "$ARGO_NAMED_DESCRIPTION" ;;
    quick) printf '%s\n' "$ARGO_QUICK_DESCRIPTION" ;;
    *) return 1 ;;
  esac
}

UNIT_DESCRIPTION_CHANGED=0
refresh_unit_description() {
  local file="$1" expected="$2" current temporary
  [[ -f "$file" ]] || return 0
  current="$(unit_description "$file" 2>/dev/null || true)"
  [[ "$current" != "$expected" ]] || return 0
  temporary="$(mktemp "$(dirname "$file")/.$(basename "$file").description.XXXXXX")" || return 1
  if ! awk -v description="$expected" '
    BEGIN {updated=0}
    /^Description=/ {
      if (!updated) {print "Description=" description; updated=1}
      next
    }
    {print}
    END {if (!updated) exit 42}
  ' "$file" > "$temporary" || ! atomic_install_file "$temporary" "$file" 0644; then
    rm -f -- "$temporary"
    return 1
  fi
  rm -f -- "$temporary"
  UNIT_DESCRIPTION_CHANGED=1
}

refresh_service_metadata() {
  local argo_description=""
  UNIT_DESCRIPTION_CHANGED=0
  refresh_unit_description "$SERVICE_FILE" "$MAIN_SERVICE_DESCRIPTION" || return 1
  if [[ -f "$ARGO_SERVICE_FILE" ]]; then
    argo_description="$(expected_argo_description 2>/dev/null || true)"
    [[ -z "$argo_description" ]] || refresh_unit_description "$ARGO_SERVICE_FILE" "$argo_description" || return 1
  fi
  if (( UNIT_DESCRIPTION_CHANGED )); then
    systemctl daemon-reload || return 1
    ok "systemd 服务描述已迁移为统一名称；运行中的服务未重启。"
  fi
}

restore_core_binary() {
  local backup="$1"
  if [[ -n "$backup" && -x "$backup" ]]; then
    atomic_install_file "$backup" "$SINGBOX_BIN" 0755
  else
    rm -f -- "$SINGBOX_BIN"
  fi
}

CORE_TRANSACTION_BACKUP=""
CORE_TRANSACTION_SERVICE_BACKUP=""
CORE_TRANSACTION_HOPPING_BACKUP=""
CORE_TRANSACTION_TEMP_ROOT=""
CORE_TRANSACTION_SERVICE_EXISTED=0
CORE_TRANSACTION_HOPPING_EXISTED=0
CORE_TRANSACTION_SERVICE_ACTIVE=0

clear_core_transaction() {
  trap - HUP INT TERM
  CORE_TRANSACTION_BACKUP=""
  CORE_TRANSACTION_SERVICE_BACKUP=""
  CORE_TRANSACTION_HOPPING_BACKUP=""
  CORE_TRANSACTION_TEMP_ROOT=""
  CORE_TRANSACTION_SERVICE_EXISTED=0
  CORE_TRANSACTION_HOPPING_EXISTED=0
  CORE_TRANSACTION_SERVICE_ACTIVE=0
}

interrupt_core_transaction() {
  local code="$1"
  trap - HUP INT TERM
  restore_core_binary "$CORE_TRANSACTION_BACKUP" || true
  restore_optional_file "$CORE_TRANSACTION_SERVICE_BACKUP" "$CORE_TRANSACTION_SERVICE_EXISTED" "$SERVICE_FILE" 0644 || true
  restore_optional_file "$CORE_TRANSACTION_HOPPING_BACKUP" "$CORE_TRANSACTION_HOPPING_EXISTED" "$PORT_HOPPING_SERVICE_FILE" 0644 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  if (( CORE_TRANSACTION_SERVICE_ACTIVE )); then
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  else
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$CORE_TRANSACTION_TEMP_ROOT"
  rm -f -- "$CORE_TRANSACTION_BACKUP" "$CORE_TRANSACTION_SERVICE_BACKUP" "$CORE_TRANSACTION_HOPPING_BACKUP"
  release_lock
  exit "$code"
}

arm_core_transaction() {
  CORE_TRANSACTION_BACKUP="$1"
  CORE_TRANSACTION_SERVICE_BACKUP="$2"
  CORE_TRANSACTION_HOPPING_BACKUP="$3"
  CORE_TRANSACTION_TEMP_ROOT="$4"
  CORE_TRANSACTION_SERVICE_EXISTED="$5"
  CORE_TRANSACTION_HOPPING_EXISTED="$6"
  CORE_TRANSACTION_SERVICE_ACTIVE="$7"
  trap 'interrupt_core_transaction 129' HUP
  trap 'interrupt_core_transaction 130' INT
  trap 'interrupt_core_transaction 143' TERM
}

install_or_update_core() {
  local requested="${1:-}" current="" extracted version backup="" temp_root
  local service_backup="" hopping_service_backup=""
  local service_was_active=0 service_file_existed=0 hopping_service_file_existed=0
  require_root
  require_systemd || return 1
  install_dependencies || return 1
  init_state || return 1

  current="$(current_core_version 2>/dev/null || true)"
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && service_was_active=1
  extracted="$(download_core "$requested")" || return 1
  temp_root="$(dirname "$(dirname "$extracted")")"
  version="$($extracted version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
  [[ -n "$version" ]] || {
    rm -rf -- "$temp_root"
    error "无法读取下载内核的版本。"
    return 1
  }
  if [[ "$(printf '%s\n' "1.13.0" "$version" | sort -V | head -n 1)" != "1.13.0" ]]; then
    rm -rf -- "$temp_root"
    error "MB sing-box 管理器 ${VERSION} 最低支持 sing-box 1.13.0，拒绝安装 ${version}。"
    return 1
  fi
  if [[ -s "$SERVER_CONFIG" ]] && ! "$extracted" check -c "$SERVER_CONFIG"; then
    rm -rf -- "$temp_root"
    error "现有服务端配置未通过 sing-box ${version} 检查，不会更新内核。"
    return 1
  fi

  ensure_directories || { rm -rf -- "$temp_root"; return 1; }
  if [[ -x "$SINGBOX_BIN" ]]; then
    backup="$(mktemp "${SINGBOX_HOME}/.sing-box.previous.XXXXXX")" || { rm -rf -- "$temp_root"; return 1; }
    cp -a -- "$SINGBOX_BIN" "$backup" || { rm -f -- "$backup"; rm -rf -- "$temp_root"; return 1; }
  fi
  service_backup="$(mktemp /tmp/mb-singbox-core-service-backup.XXXXXX)" || {
    rm -f -- "$backup"; rm -rf -- "$temp_root"; return 1
  }
  hopping_service_backup="$(mktemp /tmp/mb-singbox-core-hopping-service-backup.XXXXXX)" || {
    rm -f -- "$backup" "$service_backup"; rm -rf -- "$temp_root"; return 1
  }
  if [[ -f "$SERVICE_FILE" ]]; then
    service_file_existed=1
    cp -a -- "$SERVICE_FILE" "$service_backup" || {
      rm -f -- "$backup" "$service_backup" "$hopping_service_backup"; rm -rf -- "$temp_root"; return 1
    }
  fi
  if [[ -f "$PORT_HOPPING_SERVICE_FILE" ]]; then
    hopping_service_file_existed=1
    cp -a -- "$PORT_HOPPING_SERVICE_FILE" "$hopping_service_backup" || {
      rm -f -- "$backup" "$service_backup" "$hopping_service_backup"; rm -rf -- "$temp_root"; return 1
    }
  fi
  arm_core_transaction "$backup" "$service_backup" "$hopping_service_backup" "$temp_root" \
    "$service_file_existed" "$hopping_service_file_existed" "$service_was_active"

  if ! atomic_install_file "$extracted" "$SINGBOX_BIN" 0755; then
    clear_core_transaction
    rm -f -- "$backup" "$service_backup" "$hopping_service_backup"
    rm -rf -- "$temp_root"
    error "无法原子安装 sing-box 内核。"
    return 1
  fi
  rm -rf -- "$temp_root"
  if ! write_service_file; then
    restore_core_binary "$backup" || true
    clear_core_transaction
    rm -f -- "$backup" "$service_backup" "$hopping_service_backup"
    error "systemd 服务文件更新失败，已恢复旧内核和旧服务文件。"
    return 1
  fi

  if [[ -s "$SERVER_CONFIG" && "$service_was_active" == "1" ]]; then
    if ! systemctl restart "$SERVICE_NAME" || ! systemctl is-active --quiet "$SERVICE_NAME"; then
      restore_core_binary "$backup" || true
      restore_optional_file "$service_backup" "$service_file_existed" "$SERVICE_FILE" 0644 || true
      restore_optional_file "$hopping_service_backup" "$hopping_service_file_existed" "$PORT_HOPPING_SERVICE_FILE" 0644 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl restart "$SERVICE_NAME" || true
      clear_core_transaction
      rm -f -- "$backup" "$service_backup" "$hopping_service_backup"
      error "新内核启动失败，已恢复旧内核和旧服务文件。"
      return 1
    fi
  elif [[ -s "$SERVER_CONFIG" ]]; then
    info "服务更新前处于停止状态，本次不会自动启动。"
  fi
  clear_core_transaction
  rm -f -- "$backup" "$service_backup" "$hopping_service_backup"
  ok "sing-box ${version} 已安装到 ${SINGBOX_BIN}"
  [[ -n "$current" ]] && info "更新前版本：${current}"
}

require_core() {
  if [[ ! -x "$SINGBOX_BIN" ]]; then
    error "尚未安装 sing-box 内核，请先选择 '安装/更新 sing-box'。"
    return 1
  fi
}

render_server_config() {
  local state="$1" output="$2"
  jq 'def inbound:
    if .type == "reality" then {
      type: "vless", tag: ("in-" + .id), listen: "::", listen_port: .port,
      reuse_addr: true, tcp_fast_open: true,
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
      reuse_addr: true,
      users: [{name: .name, password: .password}],
      obfs: {type: "salamander", password: .obfs_password},
      tls: {enabled: true, certificate_path: .certificate_path, key_path: .key_path}
    }
    elif .type == "tuic" then {
      type: "tuic", tag: ("in-" + .id), listen: "::", listen_port: .port,
      reuse_addr: true,
      users: [{name: .name, uuid: .uuid, password: .password}],
      congestion_control: "bbr", zero_rtt_handshake: false, heartbeat: "10s",
      tls: {enabled: true, alpn: ["h3"], certificate_path: .certificate_path, key_path: .key_path}
    }
    elif .type == "anytls" then {
      type: "anytls", tag: ("in-" + .id), listen: "::", listen_port: .port,
      reuse_addr: true, tcp_fast_open: true,
      users: [{name: .name, password: .password}],
      tls: {enabled: true, certificate_path: .certificate_path, key_path: .key_path}
    }
    elif .type == "vmess" then {
      type: "vmess", tag: ("in-" + .id), listen: "::", listen_port: .port,
      reuse_addr: true, tcp_fast_open: true,
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
  local connect_address="${4:-$argo_hostname}" argo_port="${5:-2096}" variant="${6:-}"
  jq -n --argjson n "$node_json" --arg server "$server_address" --arg argo "$argo_hostname" \
    --arg connect "$connect_address" --argjson argo_port "$argo_port" --arg variant "$variant" '
    if $argo != "" then {
      type: "vmess", tag: ("node-" + $n.id + "-argo" + (if $variant == "" then "" else "-" + $variant end)), server: $connect, server_port: $argo_port,
      connect_timeout: "10s", tcp_fast_open: true,
      uuid: $n.uuid, security: "auto", alter_id: 0, network: "tcp",
      tls: {
        enabled: true, server_name: $argo,
        utls: {enabled: true, fingerprint: "chrome"}
      },
      transport: {type: "ws", path: $n.path, headers: {Host: $argo}}
    }
    elif $n.type == "reality" then {
      type: "vless", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      connect_timeout: "10s", tcp_fast_open: true,
      uuid: $n.uuid, flow: "xtls-rprx-vision", network: "tcp",
      tls: {
        enabled: true, server_name: $n.server_name,
        utls: {enabled: true, fingerprint: "chrome"},
        reality: {enabled: true, public_key: $n.public_key, short_id: $n.short_id}
      }
    }
    elif $n.type == "hysteria2" then
      ({
        type: "hysteria2", tag: ("node-" + $n.id), server: $server,
        connect_timeout: "10s",
        password: $n.password,
        obfs: {type: "salamander", password: $n.obfs_password},
        tls: {enabled: true, server_name: $n.tls_domain}
      } +
      (if ($n.port_hopping.enabled // false) then {
        server_ports: [(($n.port_hopping.start | tostring) + ":" + ($n.port_hopping.end | tostring))],
        hop_interval: (($n.port_hopping.hop_interval | tostring) + "s")
      } else {server_port: $n.port} end))
    elif $n.type == "tuic" then {
      type: "tuic", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      connect_timeout: "10s",
      uuid: $n.uuid, password: $n.password,
      congestion_control: "bbr", udp_relay_mode: "native", zero_rtt_handshake: false,
      tls: {enabled: true, server_name: $n.tls_domain, alpn: ["h3"]}
    }
    elif $n.type == "anytls" then {
      type: "anytls", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      connect_timeout: "10s",
      password: $n.password,
      tls: {
        enabled: true, server_name: $n.tls_domain,
        utls: {enabled: true, fingerprint: "chrome"}
      }
    }
    elif $n.type == "vmess" then {
      type: "vmess", tag: ("node-" + $n.id), server: $server, server_port: $n.port,
      connect_timeout: "10s", tcp_fast_open: true,
      uuid: $n.uuid, security: "auto", alter_id: 0, network: "tcp",
      tls: {
        enabled: true, server_name: $n.tls_domain,
        utls: {enabled: true, fingerprint: "chrome"}
      },
      transport: {type: "ws", path: $n.path, headers: {Host: $n.tls_domain}}
    }
    else error("unknown node type")
    end'
}

make_mihomo_proxy_json() {
  local node_json="$1" server_address="$2" argo_hostname="${3:-}"
  local connect_address="${4:-$argo_hostname}" argo_port="${5:-2096}" variant="${6:-}"
  jq -n --argjson n "$node_json" --arg server "$server_address" --arg argo "$argo_hostname" \
    --arg connect "$connect_address" --argjson argo_port "$argo_port" --arg variant "$variant" '
    if $argo != "" then {
      name: ($n.name + "-Argo" + (if $variant == "preferred" then "-Preferred" else "" end) + " [" + $n.id + "]"),
      _tier: "emergency", type: "vmess", server: $connect, port: $argo_port,
      uuid: $n.uuid, alterId: 0, cipher: "auto", udp: true,
      tls: true, servername: $argo, "client-fingerprint": "chrome", "skip-cert-verify": false,
      network: "ws", "ws-opts": {path: $n.path, headers: {Host: $argo}}
    }
    elif $n.type == "reality" then {
      name: ($n.name + " [" + $n.id + "]"), _tier: "main",
      type: "vless", server: $server, port: $n.port, uuid: $n.uuid,
      network: "tcp", tls: true, udp: true, flow: "xtls-rprx-vision",
      servername: $n.server_name, "client-fingerprint": "chrome", "skip-cert-verify": false,
      "reality-opts": {"public-key": $n.public_key, "short-id": $n.short_id}
    }
    elif $n.type == "hysteria2" then
      ({
        name: ($n.name + " [" + $n.id + "]"), _tier: "main",
        type: "hysteria2", server: $server, password: $n.password, udp: true,
        obfs: "salamander", "obfs-password": $n.obfs_password,
        sni: $n.tls_domain, "skip-cert-verify": false, alpn: ["h3"]
      } +
      (if ($n.port_hopping.enabled // false) then {
        ports: (($n.port_hopping.start | tostring) + "-" + ($n.port_hopping.end | tostring)),
        "hop-interval": $n.port_hopping.hop_interval
      } else {port: $n.port} end))
    elif $n.type == "tuic" then {
      name: ($n.name + " [" + $n.id + "]"), _tier: "backup",
      type: "tuic", server: $server, port: $n.port,
      uuid: $n.uuid, password: $n.password, udp: true,
      "udp-relay-mode": "native", "congestion-controller": "bbr", "reduce-rtt": false,
      alpn: ["h3"], sni: $n.tls_domain, "skip-cert-verify": false
    }
    elif $n.type == "anytls" then {
      name: ($n.name + " [" + $n.id + "]"), _tier: "backup",
      type: "anytls", server: $server, port: $n.port,
      password: $n.password, udp: true, "client-fingerprint": "chrome",
      sni: $n.tls_domain, "skip-cert-verify": false,
      "idle-session-check-interval": 30, "idle-session-timeout": 30, "min-idle-session": 0
    }
    elif $n.type == "vmess" then empty
    else error("unsupported mihomo node type")
    end'
}

yaml_quote() {
  jq -nr --arg value "$1" '$value | @json'
}

render_mihomo_proxy_yaml() {
  local proxy="$1" type
  type="$(jq -r '.type' <<<"$proxy")"
  printf '  - name: %s\n' "$(jq -r '.name | @json' <<<"$proxy")"
  printf '    type: %s\n' "$type"
  printf '    server: %s\n' "$(jq -r '.server | @json' <<<"$proxy")"
  case "$type" in
    vless)
      printf '    port: %s\n' "$(jq -r '.port' <<<"$proxy")"
      printf '    uuid: %s\n' "$(jq -r '.uuid | @json' <<<"$proxy")"
      printf '    network: tcp\n    tls: true\n    udp: true\n    flow: xtls-rprx-vision\n'
      printf '    servername: %s\n' "$(jq -r '.servername | @json' <<<"$proxy")"
      printf '    client-fingerprint: chrome\n    skip-cert-verify: false\n'
      printf '    reality-opts:\n'
      printf '      public-key: %s\n' "$(jq -r '."reality-opts"."public-key" | @json' <<<"$proxy")"
      printf '      short-id: %s\n' "$(jq -r '."reality-opts"."short-id" | @json' <<<"$proxy")"
      ;;
    hysteria2)
      if jq -e 'has("ports")' <<<"$proxy" >/dev/null; then
        printf '    ports: %s\n' "$(jq -r '.ports | @json' <<<"$proxy")"
        printf '    hop-interval: %s\n' "$(jq -r '."hop-interval"' <<<"$proxy")"
      else
        printf '    port: %s\n' "$(jq -r '.port' <<<"$proxy")"
      fi
      printf '    password: %s\n' "$(jq -r '.password | @json' <<<"$proxy")"
      printf '    udp: true\n    obfs: salamander\n'
      printf '    obfs-password: %s\n' "$(jq -r '."obfs-password" | @json' <<<"$proxy")"
      printf '    sni: %s\n' "$(jq -r '.sni | @json' <<<"$proxy")"
      printf '    alpn: [h3]\n    skip-cert-verify: false\n'
      ;;
    tuic)
      printf '    port: %s\n' "$(jq -r '.port' <<<"$proxy")"
      printf '    uuid: %s\n' "$(jq -r '.uuid | @json' <<<"$proxy")"
      printf '    password: %s\n' "$(jq -r '.password | @json' <<<"$proxy")"
      printf '    udp: true\n    udp-relay-mode: native\n    congestion-controller: bbr\n    reduce-rtt: false\n'
      printf '    sni: %s\n' "$(jq -r '.sni | @json' <<<"$proxy")"
      printf '    alpn: [h3]\n    skip-cert-verify: false\n'
      ;;
    anytls)
      printf '    port: %s\n' "$(jq -r '.port' <<<"$proxy")"
      printf '    password: %s\n' "$(jq -r '.password | @json' <<<"$proxy")"
      printf '    udp: true\n    client-fingerprint: chrome\n'
      printf '    sni: %s\n' "$(jq -r '.sni | @json' <<<"$proxy")"
      printf '    skip-cert-verify: false\n'
      printf '    idle-session-check-interval: 30\n    idle-session-timeout: 30\n    min-idle-session: 0\n'
      ;;
    vmess)
      printf '    port: %s\n' "$(jq -r '.port' <<<"$proxy")"
      printf '    uuid: %s\n' "$(jq -r '.uuid | @json' <<<"$proxy")"
      printf '    alterId: 0\n    cipher: auto\n    udp: true\n    tls: true\n'
      printf '    servername: %s\n' "$(jq -r '.servername | @json' <<<"$proxy")"
      printf '    client-fingerprint: chrome\n    skip-cert-verify: false\n    network: ws\n'
      printf '    ws-opts:\n      path: %s\n' "$(jq -r '."ws-opts".path | @json' <<<"$proxy")"
      printf '      headers:\n        Host: %s\n' "$(jq -r '."ws-opts".headers.Host | @json' <<<"$proxy")"
      ;;
    *) error "无法渲染 Mihomo 节点类型：${type}"; return 1 ;;
  esac
}

emit_mihomo_health_group() {
  local name="$1" type="$2" hidden="$3"
  shift 3
  printf '  - name: %s\n    type: %s\n    proxies:\n' "$(yaml_quote "$name")" "$type"
  local proxy_name
  for proxy_name in "$@"; do
    printf '      - %s\n' "$(yaml_quote "$proxy_name")"
  done
  printf '    url: https://www.gstatic.com/generate_204\n'
  printf '    interval: 600\n    lazy: true\n    timeout: 5000\n    max-failed-times: 3\n    expected-status: 204\n'
  [[ "$hidden" != "true" ]] || printf '    hidden: true\n'
}

render_mihomo_config() {
  local state="$1" proxies_file="$2" output="$3"
  local proxy_username proxy_password controller_secret proxy
  local -a main_names=() backup_names=() emergency_names=() all_names=() tier_groups=()
  state_valid "$state" || { error "拒绝从无效状态生成 Mihomo 配置。"; return 1; }
  jq -e 'type == "array" and length > 0' "$proxies_file" >/dev/null || return 1

  proxy_username="$(jq -r '.client.mihomo.proxy_username // empty' "$state")"
  proxy_password="$(jq -r '.client.mihomo.proxy_password // empty' "$state")"
  controller_secret="$(jq -r '.client.mihomo.controller_secret // empty' "$state")"
  if [[ ! "$proxy_username" =~ ^[A-Za-z0-9._-]{1,32}$ || -z "$proxy_password" || ! "$controller_secret" =~ ^[a-f0-9]{64}$ ]]; then
    error "Mihomo 认证信息尚未初始化，请先运行状态迁移。"
    return 1
  fi
  mapfile -t main_names < <(jq -r '.[] | select(._tier == "main") | .name' "$proxies_file")
  mapfile -t backup_names < <(jq -r '.[] | select(._tier == "backup") | .name' "$proxies_file")
  mapfile -t emergency_names < <(jq -r '.[] | select(._tier == "emergency") | .name' "$proxies_file")
  mapfile -t all_names < <(jq -r '.[] | select(._tier == "main"), select(._tier == "backup"), select(._tier == "emergency") | .name' "$proxies_file")

  (( ${#main_names[@]} == 0 )) || tier_groups+=("主力测速")
  (( ${#backup_names[@]} == 0 )) || tier_groups+=("备用测速")
  (( ${#emergency_names[@]} == 0 )) || tier_groups+=("应急通道")
  (( ${#tier_groups[@]} > 0 && ${#all_names[@]} > 0 )) || return 1

  {
    cat <<EOF
# Generated by MB sing-box manager. Optimized for Mihomo/Nikki on OpenWrt.
# Reality and Hysteria2 are primary; TUIC and AnyTLS are backup; Argo is emergency only.

mixed-port: 7890
redir-port: 7892
tproxy-port: 7893
allow-lan: true
bind-address: "*"
lan-allowed-ips:
  - 127.0.0.0/8
  - 10.0.0.0/8
  - 100.64.0.0/10
  - 169.254.0.0/16
  - 172.16.0.0/12
  - 192.168.0.0/16
  - ::1/128
  - fc00::/7
  - fe80::/10
authentication:
  - $(yaml_quote "${proxy_username}:${proxy_password}")
skip-auth-prefixes:
  - 127.0.0.0/8
  - ::1/128

mode: rule
log-level: info
ipv6: false
unified-delay: true
tcp-concurrent: true
find-process-mode: off
keep-alive-idle: 30
keep-alive-interval: 30
disable-keep-alive: false

external-controller: 127.0.0.1:9090
secret: $(yaml_quote "$controller_secret")

profile:
  store-selected: true
  store-fake-ip: true

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
  skip-dst-address:
    - 127.0.0.0/8
    - 10.0.0.0/8
    - 100.64.0.0/10
    - 169.254.0.0/16
    - 172.16.0.0/12
    - 192.168.0.0/16
    - ::1/128
    - fc00::/7
    - fe80::/10

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  prefer-h3: false
  respect-rules: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter-mode: rule
  fake-ip-filter:
    - RULE-SET,private-domain,real-ip
    - DOMAIN,localhost,real-ip
    - DOMAIN-SUFFIX,lan,real-ip
    - DOMAIN-SUFFIX,local,real-ip
    - DOMAIN-SUFFIX,home.arpa,real-ip
    - DOMAIN-SUFFIX,msftconnecttest.com,real-ip
    - DOMAIN-SUFFIX,msftncsi.com,real-ip
    - MATCH,fake-ip
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  proxy-server-nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  direct-nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  direct-nameserver-follow-policy: false
  nameserver:
    - "https://1.1.1.1/dns-query#故障转移"
    - "https://8.8.8.8/dns-query#故障转移"
  nameserver-policy:
    "rule-set:private-domain":
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query
    "rule-set:cn-domain":
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query
    "rule-set:geolocation-not-cn":
      - "https://1.1.1.1/dns-query#故障转移"
      - "https://8.8.8.8/dns-query#故障转移"

proxies:
EOF
    while IFS= read -r proxy; do
      render_mihomo_proxy_yaml "$proxy" || return 1
    done < <(jq -c '.[]' "$proxies_file")

    printf '\nproxy-groups:\n'
    (( ${#main_names[@]} == 0 )) || emit_mihomo_health_group "主力测速" url-test true "${main_names[@]}"
    (( ${#backup_names[@]} == 0 )) || emit_mihomo_health_group "备用测速" url-test true "${backup_names[@]}"
    (( ${#emergency_names[@]} == 0 )) || emit_mihomo_health_group "应急通道" fallback true "${emergency_names[@]}"
    emit_mihomo_health_group "自动选择" fallback false "${tier_groups[@]}"
    emit_mihomo_health_group "故障转移" fallback false "${all_names[@]}"

    printf '  - name: %s\n    type: select\n    proxies:\n' "$(yaml_quote "手动选择")"
    printf '      - %s\n      - %s\n' "$(yaml_quote "自动选择")" "$(yaml_quote "故障转移")"
    for proxy in "${all_names[@]}"; do
      printf '      - %s\n' "$(yaml_quote "$proxy")"
    done
    printf '      - DIRECT\n'

    cat <<'EOF'

rule-providers:
  private-domain:
    type: http
    behavior: domain
    format: mrs
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/private.mrs
    path: ./ruleset/private-domain.mrs
    interval: 86400
    proxy: 故障转移
  cn-domain:
    type: http
    behavior: domain
    format: mrs
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs
    path: ./ruleset/cn-domain.mrs
    interval: 86400
    proxy: 故障转移
  geolocation-not-cn:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/geolocation-!cn.mrs"
    path: ./ruleset/geolocation-not-cn.mrs
    interval: 86400
    proxy: 故障转移
  private-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/private.mrs
    path: ./ruleset/private-ip.mrs
    interval: 86400
    proxy: 故障转移
  cn-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs
    path: ./ruleset/cn-ip.mrs
    interval: 86400
    proxy: 故障转移

rules:
  - RULE-SET,private-domain,DIRECT
  - RULE-SET,cn-domain,DIRECT
  - RULE-SET,geolocation-not-cn,手动选择
  - RULE-SET,private-ip,DIRECT,no-resolve
  - RULE-SET,cn-ip,DIRECT,no-resolve
  - MATCH,手动选择
EOF
  } > "$output"
}

validate_mihomo_config() {
  local config="$1" check_output rc=0
  [[ -s "$config" ]] || { error "Mihomo 配置为空：${config}"; return 1; }
  if grep -Eq 'CHANGE_ME|global-client-fingerprint' "$config"; then
    error "Mihomo 配置包含占位符或已移除字段。"
    return 1
  fi
  for required in '^proxies:' '^proxy-groups:' '^rule-providers:' '^rules:'; do
    grep -Eq "$required" "$config" || { error "Mihomo 配置缺少必要部分：${required}"; return 1; }
  done

  if command -v mihomo >/dev/null 2>&1; then
    check_output="$(mktemp /tmp/mb-singbox-mihomo-check.XXXXXX)" || return 1
    mihomo -t -f "$config" > "$check_output" 2>&1 || rc=$?
    if (( rc != 0 )) || grep -Eq 'level=(error|"error")|configuration is removed' "$check_output"; then
      cat "$check_output" >&2
      rm -f -- "$check_output"
      error "Mihomo 配置未通过本机内核检查。"
      return 1
    fi
    rm -f -- "$check_output"
  fi
}

render_client_config() {
  local outbounds_file="$1" output="$2"
  jq -n --slurpfile proxies "$outbounds_file" '
    ($proxies[0]) as $p |
    ($p | map(.tag)) as $tags |
    {
      http_clients: [
        {
          tag: "rule-set-download",
          domain_resolver: {server: "dns-bootstrap", strategy: "prefer_ipv4"}
        }
      ],
      log: {level: "info", timestamp: true},
      dns: {
        servers: [
          {
            type: "udp", tag: "dns-bootstrap", server: "223.5.5.5"
          },
          {
            type: "https", tag: "dns-direct", server: "dns.alidns.com",
            path: "/dns-query",
            domain_resolver: {server: "dns-bootstrap", strategy: "prefer_ipv4"}
          },
          {
            type: "https", tag: "dns-remote", server: "dns.google",
            path: "/dns-query", detour: "manual",
            domain_resolver: {server: "dns-direct", strategy: "prefer_ipv4"}
          },
          {
            type: "fakeip", tag: "dns-fakeip",
            inet4_range: "198.18.0.0/15", inet6_range: "fc00::/18"
          }
        ],
        rules: [
          {
            domain_suffix: [".lan", ".local", ".localhost", ".localdomain"],
            action: "route", server: "dns-direct"
          },
          {rule_set: "geosite-geolocation-cn", action: "route", server: "dns-direct"},
          {query_type: ["A", "AAAA"], action: "route", server: "dns-fakeip"}
        ],
        final: "dns-remote",
        strategy: "prefer_ipv4",
        reverse_mapping: true
      },
      inbounds: [
        {
          type: "tun", tag: "tun-in",
          address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
          auto_route: true, strict_route: true,
          stack: "mixed", dns_mode: "hijack"
        }
      ],
      outbounds: ($p + [
        {
          type: "urltest", tag: "auto", outbounds: $tags,
          url: "https://www.gstatic.com/generate_204",
          interval: "3m", tolerance: 50, idle_timeout: "30m",
          interrupt_exist_connections: false
        },
        {
          type: "selector", tag: "manual", outbounds: (["auto"] + $tags),
          default: "auto", interrupt_exist_connections: false
        },
        {type: "direct", tag: "direct"}
      ]),
      route: {
        rules: [
          {inbound: "tun-in", action: "sniff"},
          {
            type: "logical", mode: "or",
            rules: [{port: 53}, {protocol: "dns"}],
            action: "hijack-dns"
          },
          {ip_is_private: true, action: "route", outbound: "direct"},
          {
            domain_suffix: [".lan", ".local", ".localhost", ".localdomain"],
            action: "route", outbound: "direct"
          },
          {rule_set: "geosite-geolocation-cn", action: "route", outbound: "direct"},
          {
            type: "logical", mode: "and",
            rules: [
              {rule_set: "geoip-cn"},
              {rule_set: "geosite-geolocation-!cn", invert: true}
            ],
            action: "route", outbound: "direct"
          }
        ],
        rule_set: [
          {
            type: "remote", tag: "geosite-geolocation-cn", format: "binary",
            url: "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-geolocation-cn.srs",
            update_interval: "1d"
          },
          {
            type: "remote", tag: "geosite-geolocation-!cn", format: "binary",
            url: "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-geolocation-!cn.srs",
            update_interval: "1d"
          },
          {
            type: "remote", tag: "geoip-cn", format: "binary",
            url: "https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs",
            update_interval: "1d"
          }
        ],
        final: "manual",
        auto_detect_interface: true,
        default_domain_resolver: {server: "dns-direct", strategy: "prefer_ipv4"},
        default_http_client: "rule-set-download"
      },
      experimental: {
        cache_file: {
          enabled: true, path: "cache.db",
          store_fakeip: true, store_dns: true
        }
      }
    }' > "$output"
}

node_share_link() {
  local node_json="$1" server="$2" argo_hostname="${3:-}"
  local connect_address="${4:-$argo_hostname}" argo_port="${5:-2096}" variant_label="${6:-}"
  local type name port uri_host uuid password tls_domain path short_id public_key obfs vmess_json profile_name mport_query
  type="$(jq -r '.type' <<<"$node_json")"
  name="$(jq -r '.name' <<<"$node_json")"
  port="$(jq -r '.port' <<<"$node_json")"
  uri_host="$(format_uri_host "$server")"

  if [[ -n "$argo_hostname" ]]; then
    uuid="$(jq -r '.uuid' <<<"$node_json")"
    path="$(jq -r '.path' <<<"$node_json")"
    profile_name="${name}-Argo${variant_label:+-${variant_label}}"
    vmess_json="$(jq -nc --arg ps "$profile_name" --arg add "$connect_address" --arg port "$argo_port" --arg id "$uuid" --arg host "$argo_hostname" --arg path "$path" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
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
      mport_query=""
      if jq -e '.port_hopping.enabled // false' <<<"$node_json" >/dev/null; then
        mport_query="&mport=$(jq -r '.port_hopping | "\(.start)-\(.end)"' <<<"$node_json")"
      fi
      printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=0&obfs=salamander&obfs-password=%s%s#%s\n' \
        "$(urlencode "$password")" "$uri_host" "$port" "$(urlencode "$tls_domain")" "$(urlencode "$obfs")" "$mport_query" "$(urlencode "$name")"
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

probe_preferred_address() {
  local candidate="$1" hostname="$2" port="$3" path="$4" headers
  headers="$(mktemp /tmp/mb-cf-address.XXXXXX)" || return 1
  curl --proto '=https' --tlsv1.2 --http1.1 -sS --connect-timeout 2 --max-time 4 \
    --connect-to "${hostname}:${port}:${candidate}:${port}" \
    -D "$headers" -o /dev/null \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://${hostname}:${port}${path}" >/dev/null 2>&1 || true
  if grep -qE '^HTTP/[0-9.]+ 101([[:space:]]|$)' "$headers"; then
    rm -f "$headers"
    return 0
  fi
  rm -f "$headers"
  return 1
}

saved_preferred_address() {
  local state="$1" key="$2" hostname="$3" port="$4" path="$5" fallback="${6:-}"
  jq -er --arg key "$key" --arg hostname "$hostname" --argjson port "$port" --arg path "$path" '
    select(.client.preferred_enabled != false) |
    (.client.preferred_results[$key] // {}) as $result |
    select(
      $result.status == "passed" and
      $result.hostname == $hostname and
      $result.port == $port and
      $result.path == $path and
      any(.client.preferred_addresses[]?; . == $result.address)
    ) |
    $result.address
  ' "$state" 2>/dev/null || printf '%s' "$fallback"
}

probe_preferred_target() {
  local state="$1" hostname="$2" port="$3" path="$4" fallback="$5" checked_at="$6"
  local candidate index attempts=0 selected="" reason="" attempt_results='[]' passed=false
  local -a candidates=()
  while IFS= read -r candidate; do
    if validate_domain "$candidate" || validate_ipv4 "$candidate"; then
      candidates+=("$candidate")
    fi
  done < <(jq -r '.client.preferred_addresses[]? // empty' "$state")

  while (( ${#candidates[@]} > 0 && attempts < 3 )); do
    index=$((RANDOM % ${#candidates[@]}))
    candidate="${candidates[$index]}"
    unset 'candidates[index]'
    candidates=("${candidates[@]}")
    attempts=$((attempts + 1))
    if probe_preferred_address "$candidate" "$hostname" "$port" "$path"; then
      attempt_results="$(jq -c --arg address "$candidate" '. + [{address:$address,passed:true}]' <<<"$attempt_results")"
      selected="$candidate"
      passed=true
      info "VMess 优选地址已实测通过：${candidate}:${port}（SNI/Host：${hostname}）" >&2
      break
    fi
    attempt_results="$(jq -c --arg address "$candidate" '. + [{address:$address,passed:false}]' <<<"$attempt_results")"
  done

  if [[ "$passed" != "true" ]]; then
    selected="$fallback"
    if (( attempts == 0 )); then
      reason="候选地址池为空"
    else
      reason="本次测试的 ${attempts} 个候选均未通过 TLS/WebSocket 校验"
    fi
    warn "${reason}，保留标准地址 ${fallback}:${port}。" >&2
  fi

  jq -nc --arg address "$selected" --arg hostname "$hostname" --argjson port "$port" \
    --arg path "$path" --arg checked_at "$checked_at" --arg reason "$reason" \
    --argjson passed "$passed" --argjson attempts "$attempt_results" '{
      status:(if $passed then "passed" else "fallback" end),
      address:$address,hostname:$hostname,port:$port,path:$path,
      checked_at:$checked_at,fallback_reason:$reason,attempts:$attempts
    }'
}

refresh_preferred_results() {
  local candidate next node_json id key hostname port path fallback result checked_at
  jq -e '.client.preferred_enabled != false' "$STATE_FILE" >/dev/null || {
    error "优选地址当前已关闭，请先启用。"
    return 1
  }
  candidate="$(mktemp "${ROOT_DIR}/.state-preferred.XXXXXX.json")" || return 1
  checked_at="$(date -u +%FT%TZ)"
  if ! jq --arg checked_at "$checked_at" '.client.preferred_results={} | .client.preferred_last_probe_at=$checked_at' "$STATE_FILE" > "$candidate"; then
    rm -f -- "$candidate"
    return 1
  fi

  while IFS= read -r node_json; do
    id="$(jq -r '.id' <<<"$node_json")"
    key="vmess:${id}"
    hostname="$(jq -r '.tls_domain' <<<"$node_json")"
    port="$(jq -r '.port' <<<"$node_json")"
    path="$(jq -r '.path' <<<"$node_json")"
    fallback="$(jq -r '.server_address' "$candidate")"
    result="$(probe_preferred_target "$candidate" "$hostname" "$port" "$path" "$fallback" "$checked_at")" || { rm -f -- "$candidate"; return 1; }
    next="${candidate}.next"
    if ! jq --arg key "$key" --argjson result "$result" '.client.preferred_results[$key]=$result' "$candidate" > "$next" || ! mv -f -- "$next" "$candidate"; then
      rm -f -- "$candidate" "$next"
      return 1
    fi
  done < <(jq -c '.nodes[] | select(.type == "vmess")' "$candidate")

  if jq -e '.argo.enabled and (.argo.hostname // "") != ""' "$candidate" >/dev/null; then
    id="$(jq -r '.argo.node_id' "$candidate")"
    key="argo:${id}"
    hostname="$(jq -r '.argo.hostname' "$candidate")"
    port="$(jq -r '.argo.public_port // 2096' "$candidate")"
    path="$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .path' "$candidate")"
    result="$(probe_preferred_target "$candidate" "$hostname" "$port" "$path" "$hostname" "$checked_at")" || { rm -f -- "$candidate"; return 1; }
    next="${candidate}.next"
    if ! jq --arg key "$key" --argjson result "$result" '.client.preferred_results[$key]=$result' "$candidate" > "$next" || ! mv -f -- "$next" "$candidate"; then
      rm -f -- "$candidate" "$next"
      return 1
    fi
  fi

  if ! save_client_settings "$candidate" "优选地址结果已保存；普通配置重建将复用本次结果。"; then
    rm -f -- "$candidate"
    return 1
  fi
  rm -f -- "$candidate"
}

swap_generated_outputs() {
  local temp_root="$1" suffix index rollback_index
  local -a sources destinations old_paths had_old
  suffix="rollback.${BASHPID}.${RANDOM}"
  sources=("$temp_root/clients" "$temp_root/links" "$temp_root/qrcodes")
  destinations=("$CLIENT_DIR" "$LINK_DIR" "$QR_DIR")
  old_paths=("${CLIENT_DIR}.${suffix}" "${LINK_DIR}.${suffix}" "${QR_DIR}.${suffix}")
  had_old=(0 0 0)

  for index in 0 1 2; do
    if [[ -e "${destinations[$index]}" ]]; then
      if ! mv -- "${destinations[$index]}" "${old_paths[$index]}"; then
        for (( rollback_index = index - 1; rollback_index >= 0; rollback_index-- )); do
          if (( had_old[rollback_index] )); then
            mv -- "${old_paths[$rollback_index]}" "${destinations[$rollback_index]}" || true
          fi
        done
        return 1
      fi
      had_old[$index]=1
    fi
  done

  for index in 0 1 2; do
    if ! mv -- "${sources[$index]}" "${destinations[$index]}"; then
      for (( rollback_index = 0; rollback_index < index; rollback_index++ )); do
        rm -rf -- "${destinations[$rollback_index]}"
      done
      for rollback_index in 0 1 2; do
        if (( had_old[rollback_index] )); then
          mv -- "${old_paths[$rollback_index]}" "${destinations[$rollback_index]}" || true
        fi
      done
      return 1
    fi
  done
  rm -rf -- "${old_paths[@]}"
}

generate_outputs() {
  local state="$1" temp_root server client_server node_json id name link link_file argo_hostname="" outbound mihomo_proxy
  local preferred_key="" argo_preferred_address="" argo_path="" argo_port=2096
  local core_version
  ensure_directories || return 1
  state_valid "$state" || { error "拒绝从无效状态生成客户端配置。"; return 1; }
  core_version="$(current_core_version)" || { error "无法读取 sing-box 内核版本。"; return 1; }
  temp_root="$(mktemp -d "${ROOT_DIR}/.outputs.XXXXXX")" || return 1
  if ! install -d -m 0700 "$temp_root/clients" "$temp_root/links" "$temp_root/qrcodes"; then
    rm -rf -- "$temp_root"
    return 1
  fi
  server="$(jq -r '.server_address' "$state")"
  if [[ -z "$server" && "$(jq '.nodes|length' "$state")" -gt 0 ]]; then
    rm -rf "$temp_root"
    error "尚未设置客户端连接使用的服务器地址。"
    return 1
  fi

  printf '[]\n' > "$temp_root/all-outbounds.json" || { rm -rf -- "$temp_root"; return 1; }
  printf '[]\n' > "$temp_root/all-mihomo-proxies.json" || { rm -rf -- "$temp_root"; return 1; }
  while IFS= read -r node_json; do
    id="$(jq -r '.id' <<<"$node_json")"
    name="$(jq -r '.name' <<<"$node_json")"
    client_server="$server"
    if [[ "$(jq -r '.type' <<<"$node_json")" == "vmess" ]]; then
      preferred_key="vmess:${id}"
      client_server="$(saved_preferred_address "$state" "$preferred_key" "$(jq -r '.tls_domain' <<<"$node_json")" "$(jq -r '.port' <<<"$node_json")" "$(jq -r '.path' <<<"$node_json")" "$server")"
    fi
    link="$(node_share_link "$node_json" "$client_server")"
    link_file="$temp_root/links/${id}.txt"
    printf '%s\n' "$link" > "$link_file"
    printf '%s\n' "$name" >> "$temp_root/links/all.txt"
    printf '%s\n\n' "$link" >> "$temp_root/links/all.txt"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -o "$temp_root/qrcodes/${id}.png" -s 6 -m 2 "$link" || true
    fi
    outbound="$(make_outbound_json "$node_json" "$client_server")" || { rm -rf -- "$temp_root"; return 1; }
    if ! jq --argjson outbound "$outbound" '. + [$outbound]' "$temp_root/all-outbounds.json" > "$temp_root/all-outbounds.next" ||
       ! mv -f -- "$temp_root/all-outbounds.next" "$temp_root/all-outbounds.json"; then
      rm -rf -- "$temp_root"
      return 1
    fi
    mihomo_proxy="$(make_mihomo_proxy_json "$node_json" "$client_server")" || { rm -rf -- "$temp_root"; return 1; }
    if [[ -n "$mihomo_proxy" ]] &&
       { ! jq --argjson proxy "$mihomo_proxy" '. + [$proxy]' "$temp_root/all-mihomo-proxies.json" > "$temp_root/all-mihomo-proxies.next" ||
         ! mv -f -- "$temp_root/all-mihomo-proxies.next" "$temp_root/all-mihomo-proxies.json"; }; then
      rm -rf -- "$temp_root"
      return 1
    fi
  done < <(jq -c '.nodes[]' "$state")

  if jq -e '.argo.enabled and (.argo.hostname != "")' "$state" >/dev/null; then
    argo_hostname="$(jq -r '.argo.hostname' "$state")"
    argo_port="$(jq -r '.argo.public_port // 2096' "$state")"
    node_json="$(jq -c --arg id "$(jq -r '.argo.node_id' "$state")" '.nodes[] | select(.id == $id)' "$state")"
    if [[ -n "$node_json" ]]; then
      id="$(jq -r '.id' <<<"$node_json")"
      name="$(jq -r '.name' <<<"$node_json")"
      argo_path="$(jq -r '.path' <<<"$node_json")"

      link="$(node_share_link "$node_json" "$server" "$argo_hostname" "$argo_hostname" "$argo_port")"
      printf '%s\n' "$link" > "$temp_root/links/${id}-argo.txt"
      printf '%s-Argo-Standard\n%s\n\n' "$name" "$link" >> "$temp_root/links/all.txt"
      command -v qrencode >/dev/null 2>&1 && qrencode -o "$temp_root/qrcodes/${id}-argo.png" -s 6 -m 2 "$link" || true
      outbound="$(make_outbound_json "$node_json" "$server" "$argo_hostname" "$argo_hostname" "$argo_port")" || { rm -rf -- "$temp_root"; return 1; }
      if ! jq --argjson outbound "$outbound" '. + [$outbound]' "$temp_root/all-outbounds.json" > "$temp_root/all-outbounds.next" ||
         ! mv -f -- "$temp_root/all-outbounds.next" "$temp_root/all-outbounds.json"; then
        rm -rf -- "$temp_root"
        return 1
      fi
      mihomo_proxy="$(make_mihomo_proxy_json "$node_json" "$server" "$argo_hostname" "$argo_hostname" "$argo_port")" || { rm -rf -- "$temp_root"; return 1; }
      if ! jq --argjson proxy "$mihomo_proxy" '. + [$proxy]' "$temp_root/all-mihomo-proxies.json" > "$temp_root/all-mihomo-proxies.next" ||
         ! mv -f -- "$temp_root/all-mihomo-proxies.next" "$temp_root/all-mihomo-proxies.json"; then
        rm -rf -- "$temp_root"
        return 1
      fi

      preferred_key="argo:${id}"
      argo_preferred_address="$(saved_preferred_address "$state" "$preferred_key" "$argo_hostname" "$argo_port" "$argo_path")"
      if [[ -n "$argo_preferred_address" && "$argo_preferred_address" != "$argo_hostname" ]]; then
        link="$(node_share_link "$node_json" "$server" "$argo_hostname" "$argo_preferred_address" "$argo_port" "Preferred")"
        printf '%s\n' "$link" > "$temp_root/links/${id}-argo-preferred.txt"
        printf '%s-Argo-Preferred\n%s\n\n' "$name" "$link" >> "$temp_root/links/all.txt"
        command -v qrencode >/dev/null 2>&1 && qrencode -o "$temp_root/qrcodes/${id}-argo-preferred.png" -s 6 -m 2 "$link" || true
        outbound="$(make_outbound_json "$node_json" "$server" "$argo_hostname" "$argo_preferred_address" "$argo_port" "preferred")" || { rm -rf -- "$temp_root"; return 1; }
        if ! jq --argjson outbound "$outbound" '. + [$outbound]' "$temp_root/all-outbounds.json" > "$temp_root/all-outbounds.next" ||
           ! mv -f -- "$temp_root/all-outbounds.next" "$temp_root/all-outbounds.json"; then
          rm -rf -- "$temp_root"
          return 1
        fi
        mihomo_proxy="$(make_mihomo_proxy_json "$node_json" "$server" "$argo_hostname" "$argo_preferred_address" "$argo_port" "preferred")" || { rm -rf -- "$temp_root"; return 1; }
        if ! jq --argjson proxy "$mihomo_proxy" '. + [$proxy]' "$temp_root/all-mihomo-proxies.json" > "$temp_root/all-mihomo-proxies.next" ||
           ! mv -f -- "$temp_root/all-mihomo-proxies.next" "$temp_root/all-mihomo-proxies.json"; then
          rm -rf -- "$temp_root"
          return 1
        fi
      fi
    fi
  fi

  if [[ "$(jq 'length' "$temp_root/all-outbounds.json")" -gt 0 ]]; then
    render_client_config "$temp_root/all-outbounds.json" "$temp_root/clients/sing-box-desktop.json" || { rm -rf "$temp_root"; return 1; }
  fi
  if [[ "$(jq 'length' "$temp_root/all-mihomo-proxies.json")" -gt 0 ]]; then
    render_mihomo_config "$state" "$temp_root/all-mihomo-proxies.json" "$temp_root/clients/mihomo-nikki.yaml" || { rm -rf "$temp_root"; return 1; }
    validate_mihomo_config "$temp_root/clients/mihomo-nikki.yaml" || { rm -rf "$temp_root"; return 1; }
  fi
  rm -f "$temp_root/all-outbounds.json" "$temp_root/all-mihomo-proxies.json"

  local client_config client_name client_min_version
  while IFS= read -r client_config; do
    client_name="$(basename "$client_config")"
    client_min_version="1.14.0"
    if version_at_least "$core_version" "$client_min_version"; then
      if ! "$SINGBOX_BIN" check -c "$client_config" >/dev/null; then
        error "客户端候选配置未通过 sing-box 检查：${client_name}"
        rm -rf "$temp_root"
        return 1
      fi
    elif ! jq -e 'type == "object"' "$client_config" >/dev/null; then
      error "客户端候选配置不是有效的 JSON 对象：${client_name}"
      rm -rf "$temp_root"
      return 1
    else
      warn "${client_name} 使用 sing-box ${client_min_version}+ 的 Desktop 功能；当前服务端内核 ${core_version} 仅完成 JSON 语法检查，不影响 V2rayN 分享链接。"
    fi
  done < <(find "$temp_root/clients" -type f -name '*.json' -print)

  if ! chmod -R go-rwx "$temp_root/clients" "$temp_root/links" "$temp_root/qrcodes" ||
     ! swap_generated_outputs "$temp_root"; then
    rm -rf -- "$temp_root"
    error "客户端输出替换失败，已恢复原目录。"
    return 1
  fi
  rm -rf -- "$temp_root"
}

backup_current() {
  local target item
  target="$(mktemp -d "${BACKUP_DIR}/$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
  chmod 0700 "$target" || { rm -rf -- "$target"; return 1; }
  [[ -s "$STATE_FILE" ]] || { rm -rf -- "$target"; return 1; }
  cp -a -- "$STATE_FILE" "$target/state.json" || { rm -rf -- "$target"; return 1; }
  [[ ! -s "$SERVER_CONFIG" ]] || cp -a -- "$SERVER_CONFIG" "$target/server.json" || { rm -rf -- "$target"; return 1; }
  [[ ! -f "$SERVICE_FILE" ]] || cp -a -- "$SERVICE_FILE" "$target/service.unit" || { rm -rf -- "$target"; return 1; }
  [[ ! -s "$PORT_HOPPING_NFT_FILE" ]] || cp -a -- "$PORT_HOPPING_NFT_FILE" "$target/port-hopping.nft" || { rm -rf -- "$target"; return 1; }
  [[ ! -f "$PORT_HOPPING_SERVICE_FILE" ]] || cp -a -- "$PORT_HOPPING_SERVICE_FILE" "$target/port-hopping.service" || { rm -rf -- "$target"; return 1; }
  for item in clients links qrcodes; do
    case "$item" in
      clients) [[ ! -d "$CLIENT_DIR" ]] || cp -a -- "$CLIENT_DIR" "$target/$item" || { rm -rf -- "$target"; return 1; } ;;
      links) [[ ! -d "$LINK_DIR" ]] || cp -a -- "$LINK_DIR" "$target/$item" || { rm -rf -- "$target"; return 1; } ;;
      qrcodes) [[ ! -d "$QR_DIR" ]] || cp -a -- "$QR_DIR" "$target/$item" || { rm -rf -- "$target"; return 1; } ;;
    esac
  done
  printf '%s\n' "$target"
}

restore_backup() {
  local backup="$1" temp_root
  [[ -s "$backup/state.json" ]] || return 1
  atomic_install_file "$backup/state.json" "$STATE_FILE" 0600 || return 1
  if [[ -s "$backup/server.json" ]]; then
    atomic_install_file "$backup/server.json" "$SERVER_CONFIG" 0600 || return 1
  else
    rm -f -- "$SERVER_CONFIG" || return 1
  fi
  if [[ -s "$backup/service.unit" ]]; then
    atomic_install_file "$backup/service.unit" "$SERVICE_FILE" 0644 || return 1
  else
    rm -f -- "$SERVICE_FILE" || return 1
  fi
  if [[ -s "$backup/port-hopping.nft" ]]; then
    atomic_install_file "$backup/port-hopping.nft" "$PORT_HOPPING_NFT_FILE" 0600 || return 1
  else
    rm -f -- "$PORT_HOPPING_NFT_FILE" || return 1
  fi
  if [[ -s "$backup/port-hopping.service" ]]; then
    atomic_install_file "$backup/port-hopping.service" "$PORT_HOPPING_SERVICE_FILE" 0644 || return 1
  else
    rm -f -- "$PORT_HOPPING_SERVICE_FILE" || return 1
  fi

  temp_root="$(mktemp -d "${ROOT_DIR}/.restore.XXXXXX")" || return 1
  install -d -m 0700 "$temp_root/clients" "$temp_root/links" "$temp_root/qrcodes" || { rm -rf -- "$temp_root"; return 1; }
  [[ ! -d "$backup/clients" ]] || { rm -rf -- "$temp_root/clients"; cp -a -- "$backup/clients" "$temp_root/clients"; } || { rm -rf -- "$temp_root"; return 1; }
  [[ ! -d "$backup/links" ]] || { rm -rf -- "$temp_root/links"; cp -a -- "$backup/links" "$temp_root/links"; } || { rm -rf -- "$temp_root"; return 1; }
  [[ ! -d "$backup/qrcodes" ]] || { rm -rf -- "$temp_root/qrcodes"; cp -a -- "$backup/qrcodes" "$temp_root/qrcodes"; } || { rm -rf -- "$temp_root"; return 1; }
  swap_generated_outputs "$temp_root" || { rm -rf -- "$temp_root"; return 1; }
  rm -rf -- "$temp_root"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

prune_backups() {
  local index
  local -a backups=()
  mapfile -t backups < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
  for (( index = BACKUP_KEEP; index < ${#backups[@]}; index++ )); do
    rm -rf -- "${backups[$index]}"
  done
}

APPLY_TRANSACTION_BACKUP=""
APPLY_TRANSACTION_CANDIDATE=""
APPLY_TRANSACTION_CONFIG=""
APPLY_TRANSACTION_HOPPING=""
APPLY_TRANSACTION_SERVICE_ACTIVE=0
APPLY_TRANSACTION_SERVICE_ENABLED=0

clear_apply_transaction() {
  trap - HUP INT TERM
  APPLY_TRANSACTION_BACKUP=""
  APPLY_TRANSACTION_CANDIDATE=""
  APPLY_TRANSACTION_CONFIG=""
  APPLY_TRANSACTION_HOPPING=""
  APPLY_TRANSACTION_SERVICE_ACTIVE=0
  APPLY_TRANSACTION_SERVICE_ENABLED=0
}

interrupt_apply_transaction() {
  local code="$1"
  trap - HUP INT TERM
  rm -f -- "$APPLY_TRANSACTION_CANDIDATE" "$APPLY_TRANSACTION_CONFIG" "$APPLY_TRANSACTION_HOPPING"
  if [[ -n "$APPLY_TRANSACTION_BACKUP" && -d "$APPLY_TRANSACTION_BACKUP" ]]; then
    restore_backup "$APPLY_TRANSACTION_BACKUP" || true
    sync_port_hopping_runtime >/dev/null 2>&1 || true
    if (( APPLY_TRANSACTION_SERVICE_ACTIVE )); then
      systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if (( APPLY_TRANSACTION_SERVICE_ENABLED )); then
      systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
  fi
  release_lock
  exit "$code"
}

arm_apply_transaction() {
  APPLY_TRANSACTION_BACKUP="$1"
  APPLY_TRANSACTION_CANDIDATE="$2"
  APPLY_TRANSACTION_CONFIG="$3"
  APPLY_TRANSACTION_HOPPING="$4"
  APPLY_TRANSACTION_SERVICE_ACTIVE="$5"
  APPLY_TRANSACTION_SERVICE_ENABLED="$6"
  trap 'interrupt_apply_transaction 129' HUP
  trap 'interrupt_apply_transaction 130' INT
  trap 'interrupt_apply_transaction 143' TERM
}

apply_candidate_state() {
  local candidate="$1" candidate_config candidate_hopping backup
  local service_was_active=0 service_was_enabled=0
  require_core || return 1
  state_candidate_valid "$candidate" || {
    error "候选状态格式或跨字段一致性不正确。"
    return 1
  }
  validate_state_certificates "$candidate" || return 1
  check_port_hopping_rules "$candidate" || return 1
  candidate_config="$(mktemp "${ROOT_DIR}/.server.XXXXXX.json")" || return 1
  candidate_hopping="$(mktemp "${ROOT_DIR}/.port-hopping.XXXXXX.nft")" || { rm -f -- "$candidate_config"; return 1; }
  if port_hopping_enabled_in_state "$candidate"; then
    render_port_hopping_nft "$candidate" "$candidate_hopping" || { rm -f -- "$candidate_config" "$candidate_hopping"; return 1; }
  else
    : > "$candidate_hopping"
  fi
  render_server_config "$candidate" "$candidate_config" || {
    rm -f -- "$candidate_config" "$candidate_hopping"
    error "生成服务端候选配置失败。"
    return 1
  }
  if ! "$SINGBOX_BIN" check -c "$candidate_config"; then
    rm -f -- "$candidate_config" "$candidate_hopping"
    error "候选配置未通过 sing-box 检查，不会替换现有配置。"
    return 1
  fi
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && service_was_active=1
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && service_was_enabled=1
  backup="$(backup_current)" || { rm -f -- "$candidate_config" "$candidate_hopping"; return 1; }
  arm_apply_transaction "$backup" "$candidate" "$candidate_config" "$candidate_hopping" "$service_was_active" "$service_was_enabled"
  if ! generate_outputs "$candidate"; then
    clear_apply_transaction
    rm -f -- "$candidate_config" "$candidate_hopping"
    rm -rf -- "$backup"
    error "客户端配置生成失败，不会替换现有状态。"
    return 1
  fi
  if ! atomic_install_file "$candidate" "$STATE_FILE" 0600 ||
     ! atomic_install_file "$candidate_config" "$SERVER_CONFIG" 0600 ||
     ! install_port_hopping_file_for_state "$candidate" "$candidate_hopping"; then
    rm -f -- "$candidate_config" "$candidate_hopping"
    restore_backup "$backup" || warn "自动恢复不完整，请检查备份：${backup}"
    sync_port_hopping_runtime >/dev/null 2>&1 || true
    clear_apply_transaction
    error "状态、服务端配置或端口跳跃规则替换失败，已恢复。"
    return 1
  fi
  rm -f -- "$candidate_config" "$candidate_hopping"
  if ! write_service_file; then
    restore_backup "$backup" || warn "自动恢复不完整，请检查备份：${backup}"
    sync_port_hopping_runtime >/dev/null 2>&1 || true
    clear_apply_transaction
    error "写入 systemd 服务失败，已恢复。"
    return 1
  fi
  if ! sync_port_hopping_runtime; then
    restore_backup "$backup" || warn "自动恢复不完整，请检查备份：${backup}"
    sync_port_hopping_runtime >/dev/null 2>&1 || true
    clear_apply_transaction
    error "端口跳跃规则未能生效，已恢复原配置。"
    return 1
  fi

  if [[ "$(jq '.nodes|length' "$STATE_FILE")" -eq 0 ]]; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    clear_apply_transaction
    prune_backups
    ok "状态已更新；当前没有节点，服务保持停止。"
    return 0
  fi

  if systemctl enable "$SERVICE_NAME" && systemctl restart "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; then
    clear_apply_transaction
    prune_backups
    ok "服务端配置已通过检查并生效。"
    return 0
  fi

  error "新配置启动失败，正在恢复上一个状态。"
  restore_backup "$backup" || warn "自动恢复不完整，请检查备份：${backup}"
  sync_port_hopping_runtime >/dev/null 2>&1 || warn "原端口跳跃规则恢复失败，请运行 mb-singbox render。"
  if (( service_was_active )); then
    systemctl restart "$SERVICE_NAME" || true
  else
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  if (( service_was_enabled )); then
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  else
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  clear_apply_transaction
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
  if ! jq --arg value "$input" '.server_address = $value' "$STATE_FILE" > "$candidate" ||
     ! save_client_settings "$candidate" "客户端连接地址已设为 ${input}。"; then
    rm -f -- "$candidate"
    return 1
  fi
  rm -f -- "$candidate"
}

port_in_state() {
  local port="$1" network="$2"
  jq -e --argjson port "$port" --arg network "$network" '
    any(.nodes[];
      (.port == $port and
       (if $network == "udp" then (.type == "hysteria2" or .type == "tuic") else (.type == "reality" or .type == "anytls" or .type == "vmess") end)) or
      ($network == "udp" and .type == "hysteria2" and (.port_hopping.enabled // false) and
       $port >= .port_hopping.start and $port <= .port_hopping.end)
    ) or (.argo.enabled and $network == "tcp" and .argo.origin_port == $port)
  ' "$STATE_FILE" >/dev/null
}

port_listening() {
  local port="$1" network="$2"
  if [[ "$network" == "udp" ]]; then
    ss -H -lun 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" {found=1} END {exit !found}'
  else
    ss -H -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" {found=1} END {exit !found}'
  fi
}

pick_unused_tcp_port() {
  local excluded="${1:-0}" candidate attempt
  for (( attempt = 0; attempt < 50; attempt++ )); do
    candidate=$((30000 + RANDOM % 30000))
    if (( candidate != excluded )) && ! port_listening "$candidate" tcp; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

wait_for_tcp_listener() {
  local pid="$1" port="$2" attempt
  for (( attempt = 0; attempt < 50; attempt++ )); do
    kill -0 "$pid" 2>/dev/null || return 1
    port_listening "$port" tcp && return 0
    sleep 0.1
  done
  return 1
}

reality_target_compatible() (
  local node_json="$1" target server_port socks_port temp_dir test_node outbound
  local server_pid="" client_pid="" rc=1
  target="$(jq -r '.server_name' <<<"$node_json")"
  server_port="$(pick_unused_tcp_port)" || return 1
  socks_port="$(pick_unused_tcp_port "$server_port")" || return 1
  temp_dir="$(mktemp -d /tmp/mb-reality-check.XXXXXX)" || return 1
  cleanup_reality_probe() {
    [[ -n "$client_pid" ]] && kill "$client_pid" 2>/dev/null || true
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    [[ -n "$client_pid" ]] && wait "$client_pid" 2>/dev/null || true
    [[ -n "$server_pid" ]] && wait "$server_pid" 2>/dev/null || true
    rm -rf "$temp_dir"
  }
  trap cleanup_reality_probe EXIT
  trap 'exit 130' HUP INT TERM

  test_node="$(jq --argjson port "$server_port" '.port=$port' <<<"$node_json")"
  jq -n --argjson node "$test_node" '{nodes:[$node],argo:{enabled:false}}' > "$temp_dir/state.json"
  render_server_config "$temp_dir/state.json" "$temp_dir/server.json" || return 1
  jq '(.inbounds[] | select(.type == "vless")).listen = "127.0.0.1" | .log.level = "error"' \
    "$temp_dir/server.json" > "$temp_dir/server.next" || return 1
  mv "$temp_dir/server.next" "$temp_dir/server.json"

  outbound="$(make_outbound_json "$test_node" "127.0.0.1")" || return 1
  jq -n --argjson outbound "$outbound" --argjson port "$socks_port" '{
    log: {level:"error",timestamp:true},
    inbounds: [{type:"mixed",tag:"check-in",listen:"127.0.0.1",listen_port:$port}],
    outbounds: [$outbound],
    route: {final:$outbound.tag}
  }' > "$temp_dir/client.json"

  "$SINGBOX_BIN" check -c "$temp_dir/server.json" >/dev/null || return 1
  "$SINGBOX_BIN" check -c "$temp_dir/client.json" >/dev/null || return 1
  "$SINGBOX_BIN" run -c "$temp_dir/server.json" > "$temp_dir/server.log" 2>&1 &
  server_pid=$!
  wait_for_tcp_listener "$server_pid" "$server_port" || return 1
  "$SINGBOX_BIN" run -c "$temp_dir/client.json" > "$temp_dir/client.log" 2>&1 &
  client_pid=$!
  wait_for_tcp_listener "$client_pid" "$socks_port" || return 1

  if curl --socks5-hostname "127.0.0.1:${socks_port}" --connect-timeout 5 --max-time 10 \
    -sSI "https://${target}/" >/dev/null 2> "$temp_dir/curl.log"; then
    rc=0
  elif grep -Eq 'processed invalid connection|reality verification failed' \
    "$temp_dir/server.log" "$temp_dir/client.log" 2>/dev/null; then
    warn "Reality 握手目标 ${target} 未通过真实协议校验。"
  else
    warn "无法通过临时 Reality 隧道访问 ${target}:443。"
  fi
  return "$rc"
)

choose_port() {
  local network="$1" default="$2" input
  while true; do
    read -r -p "监听端口 [${default}]：" input
    input="${input:-$default}"
    if ! validate_port "$input"; then
      error "端口必须是 1 到 65535 的整数。"
    elif port_in_state "$input" "$network"; then
      error "${network^^} ${input} 已被另一个 mb-singbox 节点使用。"
    elif port_listening "$input" "$network"; then
      error "系统中已有程序监听 ${network^^} ${input}。"
    else
      printf '%s' "$input"
      return 0
    fi
  done
}

validate_certificate_bundle() {
  local domain="$1" cert_file="$2" key_file="$3" leaf_file cert_hash key_hash end_date resolved
  [[ "$cert_file" == /* && -s "$cert_file" ]] || { error "完整证书链不存在或为空：${cert_file}"; return 1; }
  [[ "$key_file" == /* && -s "$key_file" ]] || { error "私钥不存在或为空：${key_file}"; return 1; }
  for resolved in "$(readlink -f -- "$cert_file" 2>/dev/null)" "$(readlink -f -- "$key_file" 2>/dev/null)"; do
    case "$resolved" in
      /home/*|/root/*|/run/user/*)
        error "systemd 安全策略无法读取 Home 目录中的证书，请将证书放到 /etc/acme/certs 或其他系统目录。"
        return 1
        ;;
    esac
  done
  if ! openssl x509 -in "$cert_file" -noout >/dev/null 2>&1; then
    error "无法解析证书文件：${cert_file}"
    return 1
  fi
  if ! openssl pkey -in "$key_file" -noout >/dev/null 2>&1; then
    error "无法解析私钥文件：${key_file}"
    return 1
  fi

  cert_hash="$(openssl x509 -in "$cert_file" -pubkey -noout | openssl pkey -pubin -outform der | sha256sum | awk '{print $1}')" || return 1
  key_hash="$(openssl pkey -in "$key_file" -pubout -outform der | sha256sum | awk '{print $1}')" || return 1
  if [[ "$cert_hash" != "$key_hash" ]]; then
    error "${domain} 的证书与私钥不匹配。"
    return 1
  fi

  end_date="$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2-)"
  if ! openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1; then
    error "${domain} 的证书已经过期：${end_date}"
    return 1
  fi
  if ! openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:' ||
     ! openssl x509 -in "$cert_file" -noout -checkhost "$domain" >/dev/null 2>&1; then
    error "证书 SAN 不包含 SNI 域名 ${domain}。"
    return 1
  fi

  leaf_file="$(mktemp /tmp/mb-cert-leaf.XXXXXX.pem)" || return 1
  awk '/-----BEGIN CERTIFICATE-----/{count++} count==1{print} /-----END CERTIFICATE-----/ && count==1{exit}' "$cert_file" > "$leaf_file"
  if ! openssl verify -purpose sslserver -untrusted "$cert_file" "$leaf_file" >/dev/null 2>&1; then
    rm -f "$leaf_file"
    error "${domain} 的完整证书链无法验证到系统信任根。"
    return 1
  fi
  rm -f "$leaf_file"

  if ! openssl x509 -in "$cert_file" -noout -checkend 2592000 >/dev/null 2>&1; then
    warn "${domain} 的证书将在 30 天内到期：${end_date}"
  fi
}

validate_state_certificates() {
  local state="$1" item
  while IFS= read -r item; do
    validate_certificate_bundle \
      "$(jq -r '.tls_domain' <<<"$item")" \
      "$(jq -r '.certificate_path' <<<"$item")" \
      "$(jq -r '.key_path' <<<"$item")" || return 1
  done < <(jq -c '[.nodes[] | select(.type != "reality") | {tls_domain,certificate_path,key_path}] | unique[]' "$state")
}

CERT_DOMAIN=""
CERT_FILE=""
KEY_FILE=""
select_certificate() {
  local -a domains=()
  local cert domain index choice manual
  shopt -s nullglob
  for cert in "$ACME_CERT_ROOT"/*/fullchain.pem; do
    domain="$(basename "$(dirname "$cert")")"
    [[ -s "$cert" && -s "${ACME_CERT_ROOT}/${domain}/key.pem" ]] && domains+=("$domain")
  done
  shopt -u nullglob

  printf '\nTLS 证书：\n'
  if (( ${#domains[@]} > 0 )); then
    if (( ${#domains[@]} == 1 )); then
      CERT_DOMAIN="${domains[0]}"
      CERT_FILE="${ACME_CERT_ROOT}/${CERT_DOMAIN}/fullchain.pem"
      KEY_FILE="${ACME_CERT_ROOT}/${CERT_DOMAIN}/key.pem"
      info "自动选择唯一的 MB-ACME 证书：${CERT_DOMAIN}"
    else
      for index in "${!domains[@]}"; do
        printf '  %d. %s\n' "$((index + 1))" "${domains[$index]}"
      done
      printf '  m. 手动输入证书路径\n'
      read -r -p "请选择：" choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#domains[@]} )); then
        CERT_DOMAIN="${domains[$((choice - 1))]}"
        CERT_FILE="${ACME_CERT_ROOT}/${CERT_DOMAIN}/fullchain.pem"
        KEY_FILE="${ACME_CERT_ROOT}/${CERT_DOMAIN}/key.pem"
      elif [[ "$choice" == "m" || "$choice" == "M" ]]; then
        manual=1
      else
        error "无效选项。"
        return 1
      fi
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
  validate_certificate_bundle "$CERT_DOMAIN" "$CERT_FILE" "$KEY_FILE" || return 1
  ok "已选择并验证证书：${CERT_DOMAIN}"
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
  read -r -p "Reality 握手域名 [${DEFAULT_REALITY_TARGET}]：" target
  target="${target:-$DEFAULT_REALITY_TARGET}"
  target="${target,,}"
  validate_domain "$target" || { error "握手域名格式不正确。"; return 1; }
  uuid="$(new_uuid)"
  keys="$($SINGBOX_BIN generate reality-keypair)" || return 1
  private_key="$(awk '/PrivateKey:/ {print $2}' <<<"$keys")"
  public_key="$(awk '/PublicKey:/ {print $2}' <<<"$keys")"
  [[ -n "$private_key" && -n "$public_key" ]] || { error "Reality 密钥生成失败。"; return 1; }
  short_id="$(openssl rand -hex 8)"
  node="$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg server_name "$target" --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" '{id:$id,name:$name,type:"reality",port:$port,uuid:$uuid,server_name:$server_name,private_key:$private_key,public_key:$public_key,short_id:$short_id}')"
  info "正在对 ${target}:443 执行临时 Reality 端到端校验..."
  reality_target_compatible "$node" || {
    error "该握手目标与当前网络或 sing-box 内核不兼容，节点未创建。"
    return 1
  }
  ok "Reality 握手目标已通过端到端校验。"
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  write_jq_candidate "$candidate" --argjson node "$node" '.nodes += [$node]' "$STATE_FILE" || return 1
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
    hysteria2) default_name="Hysteria2"; default_port=443; network=udp ;;
    tuic) default_name="TUIC"; default_port=8443; network=udp ;;
    anytls) default_name="AnyTLS"; default_port=8443; network=tcp ;;
    vmess) default_name="VMess-WS"; default_port=2087; network=tcp ;;
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
      node="$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg password "$password" --arg obfs "$obfs" --arg domain "$CERT_DOMAIN" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{id:$id,name:$name,type:"hysteria2",port:$port,password:$password,obfs_password:$obfs,tls_domain:$domain,certificate_path:$cert,key_path:$key,port_hopping:{enabled:false,start:0,end:0,hop_interval:30}}')"
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
  write_jq_candidate "$candidate" --argjson node "$node" '.nodes += [$node]' "$STATE_FILE" || return 1
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
  local id="$1" node name type port link_file argo_link_file argo_preferred_link_file
  node="$(jq -c --arg id "$id" '.nodes[] | select(.id == $id)' "$STATE_FILE")"
  [[ -n "$node" ]] || return 1
  name="$(jq -r '.name' <<<"$node")"
  type="$(jq -r '.type' <<<"$node")"
  port="$(jq -r '.port' <<<"$node")"
  link_file="${LINK_DIR}/${id}.txt"
  argo_link_file="${LINK_DIR}/${id}-argo.txt"
  argo_preferred_link_file="${LINK_DIR}/${id}-argo-preferred.txt"
  printf '\n%s节点详情%s\n' "$C_BOLD" "$C_RESET"
  printf '名称：%s\n协议：%s\n端口：%s\n' "$name" "$type" "$port"
  if [[ "$type" == "hysteria2" ]]; then
    if jq -e '.port_hopping.enabled // false' <<<"$node" >/dev/null; then
      printf '端口跳跃：已开启，UDP %s-%s，间隔 %s 秒\n' \
        "$(jq -r '.port_hopping.start' <<<"$node")" "$(jq -r '.port_hopping.end' <<<"$node")" "$(jq -r '.port_hopping.hop_interval' <<<"$node")"
    else
      printf '端口跳跃：未开启\n'
    fi
  fi
  printf '官方 Desktop TUN：%s/sing-box-desktop.json\n' "$CLIENT_DIR"
  [[ ! -s "$CLIENT_DIR/mihomo-nikki.yaml" ]] || printf 'Mihomo/Nikki YAML：%s/mihomo-nikki.yaml\n' "$CLIENT_DIR"
  if [[ -s "$link_file" ]]; then
    printf '\n直连分享链接：\n'
    cat "$link_file"
    if command -v qrencode >/dev/null 2>&1 && [[ -t 1 ]]; then
      printf '\n'
      qrencode -t ANSIUTF8 -m 1 "$(cat "$link_file")" || true
    fi
  fi
  if [[ -s "$argo_link_file" ]]; then
    printf '\nArgo 标准应急链接（固定域名）：\n'
    cat "$argo_link_file"
    if command -v qrencode >/dev/null 2>&1 && [[ -t 1 ]]; then
      printf '\n'
      qrencode -t ANSIUTF8 -m 1 "$(cat "$argo_link_file")" || true
    fi
  fi
  if [[ -s "$argo_preferred_link_file" ]]; then
    printf '\nArgo 优选链接（固定 SNI/Host）：\n'
    cat "$argo_preferred_link_file"
    if command -v qrencode >/dev/null 2>&1 && [[ -t 1 ]]; then
      printf '\n'
      qrencode -t ANSIUTF8 -m 1 "$(cat "$argo_preferred_link_file")" || true
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
  jq -r '.nodes | to_entries[] | [
    (.key+1|tostring), .value.name, .value.type,
    ((.value.port|tostring) + (if .value.type=="hysteria2" and (.value.port_hopping.enabled // false) then "+" + (.value.port_hopping.start|tostring) + "-" + (.value.port_hopping.end|tostring) else "" end)),
    (if (.value.type=="hysteria2" or .value.type=="tuic") then "UDP" else "TCP" end), .value.id
  ] | @tsv' "$STATE_FILE" | \
    awk -F '\t' '{printf "%2s. %-18s  %-10s  %-17s/%-3s  ID=%s\n", $1, $2, $3, $4, $5, $6}'
  printf '\n客户端总配置：\n  Desktop TUN：%s/sing-box-desktop.json\n' "$CLIENT_DIR"
  [[ ! -s "$CLIENT_DIR/mihomo-nikki.yaml" ]] || printf '  Mihomo/Nikki：%s/mihomo-nikki.yaml\n' "$CLIENT_DIR"
  printf '全部分享链接：%s/all.txt\n' "$LINK_DIR"
  if jq -e '.argo.enabled' "$STATE_FILE" >/dev/null; then
    printf 'Argo：%s，%s，%s\n' \
      "$(jq -r '.argo.mode // "未知模式"' "$STATE_FILE")" \
      "$(jq -r '.argo.hostname // "等待域名"' "$STATE_FILE")" \
      "$(jq -r 'if (.argo.verified // false) then "已验证" else "待验证" end' "$STATE_FILE")"
  fi
}

select_node_id() {
  local prompt="$1" choice count
  count="$(jq '.nodes|length' "$STATE_FILE")"
  (( count > 0 )) || return 1
  while true; do
    read -r -p "${prompt}（输入 0 返回）：" choice
    [[ "$choice" == "0" ]] && return 2
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      jq -r --argjson index "$((choice - 1))" '.nodes[$index].id' "$STATE_FILE"
      return 0
    fi
    error "请选择 1 到 ${count}，或输入 0 返回。"
  done
}

view_node_menu() {
  local id rc
  list_nodes
  [[ "$(jq '.nodes|length' "$STATE_FILE")" -gt 0 ]] || return 0
  id="$(select_node_id "选择要查看的节点编号")"
  rc=$?
  (( rc == 2 )) && return 0
  (( rc == 0 )) || return "$rc"
  show_node_result "$id"
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
        (.id != $id and .port == $port and
         (if $network == "udp" then (.type=="hysteria2" or .type=="tuic") else (.type=="reality" or .type=="anytls" or .type=="vmess") end)) or
        ($network == "udp" and .type == "hysteria2" and (.port_hopping.enabled // false) and
         $port >= .port_hopping.start and $port <= .port_hopping.end)
      ) or (.argo.enabled and $network=="tcp" and .argo.origin_port==$port)
    ' "$STATE_FILE" >/dev/null; then
      error "${network^^} ${input} 已被另一个 mb-singbox 入站使用。"
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
  write_jq_candidate "$candidate" --arg id "$id" "$@" "(.nodes[] | select(.id == \$id)) |= (${filter})" "$STATE_FILE" || return 1
  if apply_candidate_state "$candidate"; then
    rm -f "$candidate"
    sync_firewall_if_managed
    ok "节点配置已更新。"
  else
    rm -f "$candidate"
    return 1
  fi
}

hopping_range_in_state() {
  local start="$1" end="$2" excluded_id="$3"
  jq -e --arg id "$excluded_id" --argjson start "$start" --argjson end "$end" '
    any(.nodes[];
      ((.type == "hysteria2" or .type == "tuic") and .port >= $start and .port <= $end) or
      (.id != $id and .type == "hysteria2" and (.port_hopping.enabled // false) and
       .port_hopping.start <= $end and .port_hopping.end >= $start)
    )
  ' "$STATE_FILE" >/dev/null
}

udp_range_has_listener() {
  local start="$1" end="$2"
  ss -H -lun 2>/dev/null | awk -v start="$start" -v end="$end" '
    {
      endpoint=$4
      sub(/^.*:/, "", endpoint)
      if (endpoint ~ /^[0-9]+$/ && endpoint >= start && endpoint <= end) found=1
    }
    END {exit !found}
  '
}

validate_hopping_range() {
  local start="$1" end="$2" node_id="$3"
  if ! validate_port "$start" || ! validate_port "$end" || (( start >= end )); then
    error "端口范围必须是两个递增的 1 到 65535 整数。"
    return 1
  fi
  if hopping_range_in_state "$start" "$end" "$node_id"; then
    error "UDP ${start}-${end} 与现有节点端口或端口跳跃范围冲突。"
    return 1
  fi
  if udp_range_has_listener "$start" "$end"; then
    error "UDP ${start}-${end} 中已有系统程序监听端口。"
    return 1
  fi
}

pick_hopping_range() {
  local node_id="$1" start end random_hex
  for _ in {1..100}; do
    random_hex="$(openssl rand -hex 4)" || return 1
    start=$((20000 + 16#$random_hex % 39001))
    end=$((start + 999))
    if validate_hopping_range "$start" "$end" "$node_id" 2>/dev/null; then
      printf '%s\t%s\n' "$start" "$end"
      return 0
    fi
  done
  error "尝试 100 次后仍无法找到可用的 1000 端口 UDP 范围。"
  return 1
}

read_hopping_range() {
  local node_id="$1" input start end
  while true; do
    read -r -p "请输入 UDP 端口范围（例如 20000-20999，输入 0 返回）：" input
    [[ "$input" == "0" ]] && return 2
    if [[ "$input" =~ ^([0-9]{1,5})[-:]([0-9]{1,5})$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if validate_hopping_range "$start" "$end" "$node_id"; then
        printf '%s\t%s\n' "$start" "$end"
        return 0
      fi
    else
      error "格式不正确，请使用 起始端口-结束端口。"
    fi
  done
}

port_hopping_client_notice() {
  info "分享链接、二维码、Desktop JSON 和 Mihomo/Nikki YAML 已刷新。"
  warn "已导入客户端中的旧配置不会自动更新，请重新导入或重新下载配置。"
}

set_hysteria2_port_hopping() {
  local id="$1" start="$2" end="$3"
  warn "将开放并转发 UDP ${start}-${end}；云厂商安全组也必须放行该范围。"
  confirm "确认启用此端口跳跃范围？" || return 0
  if apply_node_field_update "$id" '.port_hopping={enabled:true,start:$start,end:$end,hop_interval:30}' \
      --argjson start "$start" --argjson end "$end"; then
    start="$(jq -r --arg id "$id" '.nodes[] | select(.id==$id) | .port_hopping.start' "$STATE_FILE")"
    end="$(jq -r --arg id "$id" '.nodes[] | select(.id==$id) | .port_hopping.end' "$STATE_FILE")"
    ok "Hysteria2 端口跳跃已启用：UDP ${start}-${end}，间隔 30 秒。"
    port_hopping_client_notice
  else
    return 1
  fi
}

edit_hysteria2_port_hopping() {
  local id="$1" enabled choice range start end rc
  enabled="$(jq -r --arg id "$id" '.nodes[] | select(.id==$id) | (.port_hopping.enabled // false)' "$STATE_FILE")"
  printf '\nHysteria2 端口跳跃：\n'
  if [[ "$enabled" == "true" ]]; then
    printf '  当前：已开启，UDP %s-%s，间隔 %s 秒\n' \
      "$(jq -r --arg id "$id" '.nodes[] | select(.id==$id) | .port_hopping.start' "$STATE_FILE")" \
      "$(jq -r --arg id "$id" '.nodes[] | select(.id==$id) | .port_hopping.end' "$STATE_FILE")" \
      "$(jq -r --arg id "$id" '.nodes[] | select(.id==$id) | .port_hopping.hop_interval' "$STATE_FILE")"
    printf '  1. 重新随机范围\n  2. 自定义范围\n  3. 关闭端口跳跃\n  0. 返回\n'
  else
    printf '  当前：未开启（节点继续使用单端口）\n'
    printf '  1. 自动开启（随机 1000 个连续高位端口）\n  2. 自定义范围\n  0. 返回\n'
  fi
  read -r -p "请选择：" choice
  case "$choice" in
    1)
      range="$(pick_hopping_range "$id")" || return 1
      IFS=$'\t' read -r start end <<<"$range"
      set_hysteria2_port_hopping "$id" "$start" "$end"
      ;;
    2)
      range="$(read_hopping_range "$id")"
      rc=$?
      (( rc == 2 )) && return 0
      (( rc == 0 )) || return "$rc"
      IFS=$'\t' read -r start end <<<"$range"
      set_hysteria2_port_hopping "$id" "$start" "$end"
      ;;
    3)
      [[ "$enabled" == "true" ]] || { error "无效选项。"; return 1; }
      warn "关闭后，已导入客户端中的多端口配置将无法继续使用。"
      confirm "确认关闭端口跳跃并恢复单端口输出？" || return 0
      if apply_node_field_update "$id" '.port_hopping={enabled:false,start:0,end:0,hop_interval:30}'; then
        ok "Hysteria2 端口跳跃已关闭，客户端输出已恢复单端口。"
        port_hopping_client_notice
      else
        return 1
      fi
      ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

edit_node() {
  local id node type network choice value port rc
  require_root
  require_core || return 1
  init_state || return 1
  list_nodes
  [[ "$(jq '.nodes|length' "$STATE_FILE")" -gt 0 ]] || return 0
  id="$(select_node_id "选择要修改的节点编号")"
  rc=$?
  (( rc == 2 )) && return 0
  (( rc == 0 )) || return "$rc"
  node="$(jq -c --arg id "$id" '.nodes[] | select(.id==$id)' "$STATE_FILE")"
  type="$(jq -r '.type' <<<"$node")"
  case "$type" in hysteria2|tuic) network=udp ;; *) network=tcp ;; esac

  printf '\n修改节点：%s (%s)\n' "$(jq -r '.name' <<<"$node")" "$type"
  printf '  1. 修改显示名称\n'
  printf '  2. 修改监听端口\n'
  [[ "$type" != "reality" ]] && printf '  3. 更换 TLS 证书\n'
  [[ "$type" == "reality" ]] && printf '  4. 修改 Reality 握手域名\n'
  [[ "$type" == "vmess" ]] && printf '  4. 修改 WebSocket 路径\n'
  printf '  5. 重新生成认证凭据\n'
  [[ "$type" == "hysteria2" ]] && printf '  6. 端口跳跃设置\n'
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
        local test_node
        test_node="$(jq --arg value "$value" '.server_name=$value' <<<"$node")"
        info "正在对 ${value}:443 执行临时 Reality 端到端校验..."
        reality_target_compatible "$test_node" || {
          error "该握手目标与当前网络或 sing-box 内核不兼容，配置未修改。"
          return 1
        }
        ok "Reality 握手目标已通过端到端校验。"
        apply_node_field_update "$id" '.server_name=$value' --arg value "$value"
      elif [[ "$type" == "vmess" ]]; then
        read -r -p "新的 WebSocket 路径（必须以 / 开头）：" value
        validate_websocket_path "$value" || { error "WebSocket 路径只允许 URL 安全字符，并且必须以 / 开头。"; return 1; }
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
    6)
      [[ "$type" == "hysteria2" ]] || { error "该节点没有此选项。"; return 1; }
      edit_hysteria2_port_hopping "$id"
      ;;
    0) return 0 ;;
    *) error "无效选项。"; return 1 ;;
  esac
}

delete_node() {
  local id candidate argo_bound=0 rc
  require_root
  init_state || return 1
  list_nodes
  [[ "$(jq '.nodes|length' "$STATE_FILE")" -gt 0 ]] || return 0
  id="$(select_node_id "选择要删除的节点编号")"
  rc=$?
  (( rc == 2 )) && return 0
  (( rc == 0 )) || return "$rc"
  jq -e --arg id "$id" '.argo.enabled and .argo.node_id == $id' "$STATE_FILE" >/dev/null && argo_bound=1
  warn "将删除节点 ${id} 的服务端配置、客户端 JSON/YAML、链接和二维码。"
  (( argo_bound )) && warn "该节点绑定了 Argo，Argo 本地服务也会停止；不会删除 Cloudflare 远程 Tunnel。"
  confirm "确定删除？" || return 0
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  jq --arg id "$id" '
    .nodes |= map(select(.id != $id)) |
    if .argo.node_id == $id then .argo = {enabled:false,mode:"",node_id:"",hostname:"",origin_port:0,provisioned:false,verified:false,tunnel_id:"",public_port:2096} else . end
  ' "$STATE_FILE" > "$candidate"
  if apply_candidate_state "$candidate"; then
    rm -f -- "$candidate"
    (( argo_bound )) && stop_argo_service
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
  if ! atomic_install_file "$temp_dir/$asset" "$CLOUDFLARED_BIN" 0755; then
    rm -rf -- "$temp_dir"
    error "cloudflared 原子安装失败。"
    return 1
  fi
  rm -rf -- "$temp_dir"
  ok "cloudflared 已安装。"
}

write_argo_service() {
  local mode="$1" origin_port="$2" temporary
  temporary="$(mktemp /tmp/mb-singbox-argo-service.XXXXXX)" || return 1
  if [[ "$mode" == "named" ]]; then
    cat > "$temporary" <<EOF
[Unit]
Description=${ARGO_NAMED_DESCRIPTION}
Wants=network-online.target ${SERVICE_NAME}
After=network-online.target ${SERVICE_NAME}

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --no-autoupdate run --token-file ${ARGO_TOKEN_FILE}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
  else
    cat > "$temporary" <<EOF
[Unit]
Description=${ARGO_QUICK_DESCRIPTION}
Wants=network-online.target ${SERVICE_NAME}
After=network-online.target ${SERVICE_NAME}

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --no-autoupdate --url http://127.0.0.1:${origin_port}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
  fi
  if ! atomic_install_file "$temporary" "$ARGO_SERVICE_FILE" 0644; then
    rm -f -- "$temporary"
    return 1
  fi
  rm -f -- "$temporary"
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

decode_tunnel_token() {
  local token="$1" normalized padding
  normalized="${token//-/+}"
  normalized="${normalized//_/\/}"
  padding=$(( (4 - ${#normalized} % 4) % 4 ))
  while (( padding-- > 0 )); do normalized+="="; done
  printf '%s' "$normalized" | base64 -d 2>/dev/null | jq -ce '
    select((.a|type)=="string" and (.t|type)=="string" and (.s|type)=="string") |
    {account_id:.a,tunnel_id:.t}
  '
}

CF_API_TOKEN=""
cloudflare_api_request() {
  local method="$1" url="$2" data_file="$3" response_file="$4" curl_options rc
  local -a retry_options=()
  [[ "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || return 1
  [[ "$method" == "POST" ]] || retry_options=(--retry 2 --retry-delay 1)
  curl_options="$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$CF_API_TOKEN")"
  if [[ -n "$data_file" ]]; then
    printf '%s' "$curl_options" | curl --config - --proto '=https' --tlsv1.2 "${retry_options[@]}" -sS \
      -X "$method" --data-binary "@${data_file}" -o "$response_file" -w '%{http_code}' "$url" > "${response_file}.status"
  else
    printf '%s' "$curl_options" | curl --config - --proto '=https' --tlsv1.2 "${retry_options[@]}" -sS \
      -X "$method" -o "$response_file" -w '%{http_code}' "$url" > "${response_file}.status"
  fi
  rc="${PIPESTATUS[1]}"
  unset curl_options
  (( rc == 0 )) || return "$rc"
  [[ "$(cat "${response_file}.status")" =~ ^2[0-9][0-9]$ ]] && jq -e '.success == true' "$response_file" >/dev/null 2>&1
}

cloudflare_error_text() {
  jq -r '[.errors[]?.message, .messages[]?.message] | map(select(. != null and . != "")) | join("；") | if .=="" then "Cloudflare API 请求失败" else . end' "$1" 2>/dev/null || printf 'Cloudflare API 请求失败'
}

CF_TRANSACTION_TUNNEL_URL=""
CF_TRANSACTION_ROLLBACK_PAYLOAD=""
CF_TRANSACTION_ROLLBACK_RESPONSE=""
CF_TRANSACTION_TEMP_DIR=""

clear_cloudflare_transaction() {
  trap - HUP INT TERM
  CF_TRANSACTION_TUNNEL_URL=""
  CF_TRANSACTION_ROLLBACK_PAYLOAD=""
  CF_TRANSACTION_ROLLBACK_RESPONSE=""
  CF_TRANSACTION_TEMP_DIR=""
}

interrupt_cloudflare_transaction() {
  local code="$1"
  trap - HUP INT TERM
  cloudflare_api_request PUT "$CF_TRANSACTION_TUNNEL_URL" "$CF_TRANSACTION_ROLLBACK_PAYLOAD" "$CF_TRANSACTION_ROLLBACK_RESPONSE" || true
  rm -rf -- "$CF_TRANSACTION_TEMP_DIR"
  CF_API_TOKEN=""
  release_lock
  exit "$code"
}

arm_cloudflare_transaction() {
  CF_TRANSACTION_TUNNEL_URL="$1"
  CF_TRANSACTION_ROLLBACK_PAYLOAD="$2"
  CF_TRANSACTION_ROLLBACK_RESPONSE="$3"
  CF_TRANSACTION_TEMP_DIR="$4"
  trap 'interrupt_cloudflare_transaction 129' HUP
  trap 'interrupt_cloudflare_transaction 130' INT
  trap 'interrupt_cloudflare_transaction 143' TERM
}

provision_named_tunnel() {
  local hostname="$1" origin_port="$2" tunnel_token="$3" token_meta account_id tunnel_id zone_id temp_dir
  local current_config config_payload config_response rollback_payload rollback_response
  local dns_response dns_payload dns_write_response record_count record_id="" record_type="" api_token
  local tunnel_url
  confirm_default_yes "是否由脚本自动配置 Public Hostname、Tunnel ingress 和 DNS？" || return 2
  token_meta="$(decode_tunnel_token "$tunnel_token")" || {
    error "无法从 Tunnel Token 读取 Account ID 和 Tunnel ID。"
    return 1
  }
  account_id="$(jq -r '.account_id' <<<"$token_meta")"
  tunnel_id="$(jq -r '.tunnel_id' <<<"$token_meta")"
  [[ "$account_id" =~ ^[A-Za-z0-9_-]{16,64}$ && "$tunnel_id" =~ ^[0-9a-fA-F-]{36}$ ]] || {
    error "Tunnel Token 中的账户或 Tunnel 标识格式不正确。"
    return 1
  }

  printf '\n自动配置需要最小权限 Cloudflare API Token：\n'
  printf '  Account -> Cloudflare Tunnel -> Edit\n'
  printf '  Zone    -> DNS -> Edit\n'
  read -r -s -p "Cloudflare API Token（仅本次使用，输入不可见）：" api_token
  printf '\n'
  [[ "$api_token" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || { error "API Token 格式不正确。"; return 1; }
  read -r -p "DNS Zone ID：" zone_id
  [[ "$zone_id" =~ ^[0-9a-fA-F]{32}$ ]] || { error "Zone ID 应为 32 位十六进制字符串。"; return 1; }
  CF_API_TOKEN="$api_token"
  unset api_token

  temp_dir="$(mktemp -d "${ROOT_DIR}/.cf-api.XXXXXX")" || { CF_API_TOKEN=""; return 1; }
  current_config="$temp_dir/current-config.json"
  config_payload="$temp_dir/config-payload.json"
  config_response="$temp_dir/config-response.json"
  rollback_payload="$temp_dir/rollback-payload.json"
  rollback_response="$temp_dir/rollback-response.json"
  dns_response="$temp_dir/dns-response.json"
  dns_payload="$temp_dir/dns-payload.json"
  dns_write_response="$temp_dir/dns-write-response.json"
  tunnel_url="https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations"

  info "正在预检 Tunnel ingress 和目标 DNS 记录..."
  if ! cloudflare_api_request GET "$tunnel_url" "" "$current_config"; then
    error "读取 Tunnel 配置失败：$(cloudflare_error_text "$current_config")"
    rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
  fi
  if ! cloudflare_api_request GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=$(urlencode "$hostname")&per_page=100" "" "$dns_response"; then
    error "读取 DNS 记录失败：$(cloudflare_error_text "$dns_response")"
    rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
  fi
  record_count="$(jq -er '.result | length' "$dns_response")" || {
    error "无法解析目标 DNS 记录。"
    rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
  }
  if (( record_count > 1 )); then
    error "${hostname} 存在多条同名 DNS 记录，拒绝自动选择或覆盖。"
    rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
  fi
  if (( record_count == 1 )); then
    record_id="$(jq -r '.result[0].id' "$dns_response")"
    record_type="$(jq -r '.result[0].type' "$dns_response")"
    if [[ "$record_type" != "CNAME" ]]; then
      error "${hostname} 已存在 ${record_type} 记录，脚本不会破坏性转换记录类型。"
      rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
    fi
  fi

  if ! jq '{config:(.result.config // {})}' "$current_config" > "$rollback_payload" ||
     ! jq --arg hostname "$hostname" --arg service "http://127.0.0.1:${origin_port}" '
       (.result.config // {}) as $config |
       ($config.ingress // []) as $ingress |
       ($ingress | to_entries |
         map(select((.value.hostname // "") == "" and (.value.path // "") == "")) |
         if length > 0 then .[-1].key else null end) as $catchall_index |
       (if $catchall_index == null then {service:"http_status:404"} else $ingress[$catchall_index] end) as $catchall |
       ($config | .ingress = (
         ([$ingress | to_entries[] |
           select(.key != ($catchall_index // -1)) |
           .value |
           select((.hostname // "") != $hostname)]) +
         [{hostname:$hostname,service:$service},$catchall]
       )) |
       {config:.}
     ' "$current_config" > "$config_payload" ||
     ! jq -e '.config.ingress | type == "array" and length >= 2' "$config_payload" >/dev/null; then
    error "生成 Tunnel ingress 候选配置失败，远端未修改。"
    rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
  fi

  arm_cloudflare_transaction "$tunnel_url" "$rollback_payload" "$rollback_response" "$temp_dir"
  if ! cloudflare_api_request PUT "$tunnel_url" "$config_payload" "$config_response"; then
    clear_cloudflare_transaction
    cloudflare_api_request PUT "$tunnel_url" "$rollback_payload" "$rollback_response" || warn "Tunnel ingress 更新结果不确定，且原配置恢复请求失败。"
    error "更新 Tunnel ingress 失败：$(cloudflare_error_text "$config_response")"
    rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
  fi

  info "正在创建或更新 ${hostname} 的 Tunnel DNS 记录..."
  jq -n --arg name "$hostname" --arg content "${tunnel_id}.cfargotunnel.com" '{type:"CNAME",name:$name,content:$content,proxied:true,ttl:1}' > "$dns_payload"
  if (( record_count == 0 )); then
    if ! cloudflare_api_request POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" "$dns_payload" "$dns_write_response"; then
      clear_cloudflare_transaction
      cloudflare_api_request PUT "$tunnel_url" "$rollback_payload" "$rollback_response" || warn "DNS 创建失败，且 Tunnel ingress 自动恢复失败。"
      error "创建 DNS 记录失败：$(cloudflare_error_text "$dns_write_response")"
      rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
    fi
  elif ! cloudflare_api_request PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" "$dns_payload" "$dns_write_response"; then
    clear_cloudflare_transaction
    cloudflare_api_request PUT "$tunnel_url" "$rollback_payload" "$rollback_response" || warn "DNS 更新失败，且 Tunnel ingress 自动恢复失败。"
    error "更新 DNS 记录失败：$(cloudflare_error_text "$dns_write_response")"
    rm -rf "$temp_dir"; CF_API_TOKEN=""; return 1
  fi

  clear_cloudflare_transaction
  rm -rf "$temp_dir"
  CF_API_TOKEN=""
  ARGO_TUNNEL_ID="$tunnel_id"
  ok "Cloudflare Public Hostname、ingress 和 DNS 已自动配置。"
}

verify_argo_endpoint() {
  local hostname="$1" path="$2" port="${3:-2096}" headers status
  headers="$(mktemp /tmp/mb-argo-verify.XXXXXX)" || return 1
  for _ in {1..12}; do
    : > "$headers"
    curl --proto '=https' --tlsv1.2 --http1.1 -sS --connect-timeout 5 --max-time 5 \
      -D "$headers" -o /dev/null \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      "https://${hostname}:${port}${path}" >/dev/null 2>&1 || true
    if grep -qE '^HTTP/[0-9.]+ 101([[:space:]]|$)' "$headers"; then
      rm -f "$headers"
      return 0
    fi
    sleep 3
  done
  status="$(awk '/^HTTP\// {code=$2} END {print code}' "$headers")"
  rm -f "$headers"
  if [[ -n "$status" ]]; then
    warn "Argo WebSocket 验证未通过，最后 HTTP 状态：${status}"
  else
    warn "Argo WebSocket 验证未收到 HTTP 响应。"
  fi
  return 1
}

set_argo_status() {
  local provisioned="$1" verified="$2" tunnel_id="${3:-}" candidate
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  if ! jq --argjson provisioned "$provisioned" --argjson verified "$verified" --arg tunnel_id "$tunnel_id" '
    .argo.provisioned=$provisioned | .argo.verified=$verified |
    if $tunnel_id != "" then .argo.tunnel_id=$tunnel_id else . end
  ' "$STATE_FILE" > "$candidate" || ! state_candidate_valid "$candidate" ||
     ! atomic_install_file "$candidate" "$STATE_FILE" 0600; then
    rm -f -- "$candidate"
    return 1
  fi
  rm -f -- "$candidate"
}

verify_current_argo() {
  local hostname node_id path port
  jq -e '.argo.enabled and (.argo.hostname // "") != ""' "$STATE_FILE" >/dev/null || { error "当前 Argo 没有可验证的公网域名。"; return 1; }
  hostname="$(jq -r '.argo.hostname' "$STATE_FILE")"
  node_id="$(jq -r '.argo.node_id' "$STATE_FILE")"
  path="$(jq -r --arg id "$node_id" '.nodes[] | select(.id==$id) | .path' "$STATE_FILE")"
  port="$(jq -r '.argo.public_port // 2096' "$STATE_FILE")"
  info "正在验证 wss://${hostname}:${port}${path}..."
  if verify_argo_endpoint "$hostname" "$path" "$port"; then
    set_argo_status true true "$(jq -r '.argo.tunnel_id // ""' "$STATE_FILE")" || return 1
    ok "Argo 公网 WebSocket 已验证可用。"
  else
    set_argo_status "$(jq -r '.argo.provisioned // false' "$STATE_FILE")" false "$(jq -r '.argo.tunnel_id // ""' "$STATE_FILE")" || true
    return 1
  fi
}

ARGO_TUNNEL_ID=""
configure_argo() {
  local -a vmess_ids=()
  local line index choice id mode hostname token origin candidate rollback path provision_rc tunnel_id=""
  local provisioned=false verified=false
  require_root
  require_core || return 1
  init_state || return 1
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
      [[ "$token" =~ ^[A-Za-z0-9._=-]{40,4096}$ ]] || { error "Tunnel Token 格式不正确。"; return 1; }
      printf '%s' "$token" > "$ARGO_TOKEN_FILE" || return 1
      chmod 0600 "$ARGO_TOKEN_FILE" || { rm -f -- "$ARGO_TOKEN_FILE"; return 1; }
      ;;
    2) mode="quick"; hostname="" ;;
    *) error "无效选项。"; return 1 ;;
  esac
  origin="$(random_local_port)" || { rm -f -- "$ARGO_TOKEN_FILE"; error "无法分配 Argo 本地端口。"; return 1; }
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || { rm -f -- "$ARGO_TOKEN_FILE"; return 1; }
  if ! write_jq_candidate "$candidate" --arg mode "$mode" --arg id "$id" --arg hostname "$hostname" --argjson origin "$origin" '.argo={enabled:true,mode:$mode,node_id:$id,hostname:$hostname,origin_port:$origin,provisioned:false,verified:false,tunnel_id:"",public_port:2096}' "$STATE_FILE"; then
    rm -f -- "$ARGO_TOKEN_FILE"
    return 1
  fi
  if ! apply_candidate_state "$candidate"; then
    rm -f "$candidate" "$ARGO_TOKEN_FILE"
    return 1
  fi
  rm -f -- "$candidate"
  if ! write_argo_service "$mode" "$origin"; then
    rollback="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || { rm -f -- "$ARGO_TOKEN_FILE"; return 1; }
    if jq '.argo={enabled:false,mode:"",node_id:"",hostname:"",origin_port:0,provisioned:false,verified:false,tunnel_id:"",public_port:2096}' "$STATE_FILE" > "$rollback"; then
      apply_candidate_state "$rollback" || true
    fi
    rm -f -- "$rollback" "$ARGO_TOKEN_FILE"
    error "Argo systemd 服务写入失败，已撤销本地配置。"
    return 1
  fi
  if ! systemctl enable --now "$ARGO_SERVICE_NAME" || ! systemctl is-active --quiet "$ARGO_SERVICE_NAME"; then
    error "Argo 服务启动失败，正在撤销本地 Argo 配置。"
    stop_argo_service
    rollback="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
    if jq '.argo={enabled:false,mode:"",node_id:"",hostname:"",origin_port:0,provisioned:false,verified:false,tunnel_id:"",public_port:2096}' "$STATE_FILE" > "$rollback"; then
      apply_candidate_state "$rollback" || true
    fi
    rm -f -- "$rollback"
    return 1
  fi
  path="$(jq -r --arg id "$id" '.nodes[] | select(.id==$id) | .path' "$STATE_FILE")"
  if [[ "$mode" == "quick" ]]; then
    hostname="$(wait_quick_hostname)" || {
      warn "Quick Tunnel 已启动，但暂未从日志取得随机域名。稍后可在 Argo 菜单刷新。"
      return 0
    }
    candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
    write_jq_candidate "$candidate" --arg hostname "$hostname" '.argo.hostname=$hostname | .argo.provisioned=true' "$STATE_FILE" || return 1
    if ! save_client_settings "$candidate" "Quick Tunnel 域名已保存。"; then
      rm -f -- "$candidate"
      return 1
    fi
    rm -f -- "$candidate"
    provisioned=true
  else
    ARGO_TUNNEL_ID=""
    provision_named_tunnel "$hostname" "$origin" "$token"
    provision_rc=$?
    if (( provision_rc == 0 )); then
      provisioned=true
      tunnel_id="$ARGO_TUNNEL_ID"
    else
      printf '\n自动配置未完成。手动配置时 Public Hostname 必须指向：\n  http://127.0.0.1:%s\n' "$origin"
    fi
  fi
  unset token

  if [[ "$provisioned" == "true" ]]; then
    info "正在验证 wss://${hostname}:2096${path}，首次 DNS 生效可能需要几十秒..."
    if verify_argo_endpoint "$hostname" "$path" 2096; then
      verified=true
    fi
  fi
  set_argo_status "$provisioned" "$verified" "$tunnel_id" || {
    warn "Argo 状态写入失败，请重新进入菜单检查。"
    return 1
  }
  generate_outputs "$STATE_FILE" || warn "Argo 状态已保存，但客户端配置生成失败。"
  if [[ "$verified" == "true" ]]; then
    ok "Argo 已自动配置并验证可用：${hostname}"
  else
    warn "Argo 本地连接器已运行，但公网 WebSocket 尚未验证；不会把它标记为完成。"
  fi
}

refresh_quick_argo() {
  local hostname candidate
  jq -e '.argo.enabled and .argo.mode=="quick"' "$STATE_FILE" >/dev/null || { error "当前未启用 Quick Tunnel。"; return 1; }
  hostname="$(wait_quick_hostname)" || { error "仍未从 cloudflared 日志取得随机域名。"; return 1; }
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  write_jq_candidate "$candidate" --arg hostname "$hostname" '.argo.hostname=$hostname | .argo.provisioned=true | .argo.verified=false' "$STATE_FILE" || return 1
  if ! save_client_settings "$candidate" "Quick Tunnel 域名已更新：${hostname}"; then
    rm -f -- "$candidate"
    return 1
  fi
  rm -f -- "$candidate"
  verify_current_argo
}

disable_argo() {
  local candidate
  jq -e '.argo.enabled' "$STATE_FILE" >/dev/null || { info "Argo 当前未启用。"; return 0; }
  warn "将停止并删除 MB sing-box 管理器的本地 cloudflared 服务。"
  warn "Cloudflare 账户中的 Named Tunnel 不会被删除。"
  confirm "确定停用 Argo？" || return 0
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  write_jq_candidate "$candidate" '.argo={enabled:false,mode:"",node_id:"",hostname:"",origin_port:0,provisioned:false,verified:false,tunnel_id:"",public_port:2096}' "$STATE_FILE" || return 1
  if apply_candidate_state "$candidate"; then
    rm -f -- "$candidate"
    stop_argo_service
    ok "Argo 已停用。"
  else
    rm -f "$candidate"
    return 1
  fi
}

argo_menu() {
  local choice
  with_lock init_state || return 1
  while true; do
    printf '\nArgo（仅 VMess-WebSocket）：\n'
    if jq -e '.argo.enabled' "$STATE_FILE" >/dev/null; then
      printf '状态：已启用，模式=%s，域名=%s，源站=127.0.0.1:%s，边缘端口=%s，公网=%s\n' \
        "$(jq -r '.argo.mode' "$STATE_FILE")" "$(jq -r '.argo.hostname // "等待中"' "$STATE_FILE")" \
        "$(jq -r '.argo.origin_port' "$STATE_FILE")" "$(jq -r '.argo.public_port // 2096' "$STATE_FILE")" \
        "$(jq -r 'if (.argo.verified // false) then "已验证" else "待验证" end' "$STATE_FILE")"
    else
      printf '状态：未启用\n'
    fi
    printf '  1. 配置 Argo\n  2. 刷新 Quick Tunnel 域名\n  3. 验证 Argo 公网 WebSocket\n  4. 停用 Argo\n  5. 查看 cloudflared 日志\n  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) with_lock configure_argo ;;
      2) with_lock refresh_quick_argo ;;
      3) with_lock verify_current_argo ;;
      4) with_lock disable_argo ;;
      5) journalctl -u "$ARGO_SERVICE_NAME" -n 100 --no-pager ;;
      0) return 0 ;;
      *) error "无效选项。" ;;
    esac
    pause
  done
}

ufw_is_active() {
  command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'
}

firewalld_is_active() {
  command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null
}

firewall_mode_label() {
  jq -r '
    (.firewall_mode // (if .firewall_managed then "managed" else "external" end)) as $mode |
    if $mode == "permissive" then "宽松模式"
    elif $mode == "managed" then "节点端口收紧模式"
    else "外部管理"
    end
  ' "$STATE_FILE" 2>/dev/null || printf '未知'
}

save_firewall_mode() {
  local mode="$1" managed="$2" candidate
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  if ! jq --arg mode "$mode" --argjson managed "$managed" \
      '.firewall_mode=$mode | .firewall_managed=$managed' "$STATE_FILE" > "$candidate" ||
     ! state_candidate_valid "$candidate" || ! atomic_install_file "$candidate" "$STATE_FILE" 0600; then
    rm -f -- "$candidate"
    return 1
  fi
  rm -f -- "$candidate"
}

configure_permissive_firewall() {
  local ufw_was_active=0 firewalld_was_active=0
  warn "宽松模式会停用 UFW 和 firewalld，主机入站端口将不再由它们限制。"
  warn "不会清空 iptables/nftables，也不会破坏 Docker 创建的 NAT、转发和容器网络规则。"
  warn "云厂商安全组仍需在控制台单独放行。"
  confirm "确认切换到防火墙宽松模式？" || return 0

  ufw_is_active && ufw_was_active=1
  firewalld_is_active && firewalld_was_active=1
  if (( ufw_was_active )) && ! ufw --force disable; then
    error "UFW 停用失败，宽松模式未生效。"
    return 1
  fi
  if (( firewalld_was_active )) && ! systemctl disable --now firewalld; then
    (( ufw_was_active )) && ufw --force enable >/dev/null 2>&1 || true
    error "firewalld 停用失败，已尝试恢复 UFW。"
    return 1
  fi
  if ! save_firewall_mode permissive false; then
    (( ufw_was_active )) && ufw --force enable >/dev/null 2>&1 || true
    (( firewalld_was_active )) && systemctl enable --now firewalld >/dev/null 2>&1 || true
    error "宽松模式状态保存失败，已尝试恢复原防火墙状态。"
    return 1
  fi
  ok "防火墙宽松模式已启用；UFW/firewalld 不再限制节点或 Docker 入站端口。"
}

remove_managed_ufw_rules() {
  local numbers number
  command -v ufw >/dev/null 2>&1 || return 0
  numbers="$(LC_ALL=C ufw status numbered 2>/dev/null |
    sed -nE '/#[[:space:]]*(mb-singbox|MB-Singbox)/s/^\[[[:space:]]*([0-9][0-9]*)\].*/\1/p' | sort -rn)"
  while IFS= read -r number; do
    [[ -z "$number" ]] || ufw --force delete "$number" >/dev/null || return 1
  done <<<"$numbers"
}

desired_ufw_rules() {
  local type port hop_start hop_end hop_enabled protocol
  while IFS=$'\t' read -r type port hop_start hop_end hop_enabled; do
    case "$type" in
      hysteria2|tuic) protocol=udp ;;
      *) protocol=tcp ;;
    esac
    printf '%s\t%s\tmb-singbox %s %s\n' "$protocol" "$port" "${protocol^^}" "$port"
    if [[ "$type" == "hysteria2" && "$hop_enabled" == "true" ]]; then
      printf 'udp\t%s:%s\tmb-singbox Hysteria2 hopping %s-%s\n' "$hop_start" "$hop_end" "$hop_start" "$hop_end"
    fi
  done < <(jq -r '.nodes[] | [.type,.port,(.port_hopping.start // 0),(.port_hopping.end // 0),(.port_hopping.enabled // false)] | @tsv' "$STATE_FILE")
}

add_desired_ufw_rules() {
  local protocol port comment
  while IFS=$'\t' read -r protocol port comment; do
    [[ -z "$protocol" ]] || ufw allow "${port}/${protocol}" comment "$comment" >/dev/null || return 1
  done < <(desired_ufw_rules)
}

remove_obsolete_ufw_rules() {
  local line number rule wanted desired numbers=""
  local -a desired_rules=()
  mapfile -t desired_rules < <(desired_ufw_rules | awk -F '\t' '{print $2 "/" $1}')
  while IFS= read -r line; do
    [[ "$line" == *"# mb-singbox"* || "$line" == *"# MB-Singbox"* ]] || continue
    number="$(sed -n 's/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' <<<"$line")"
    rule="$(sed -n 's/^\[[[:space:]]*[0-9][0-9]*\][[:space:]]*\([^[:space:]]*\).*/\1/p' <<<"$line")"
    wanted=0
    if [[ "$line" == *"# mb-singbox"* ]]; then
      for desired in "${desired_rules[@]}"; do
        [[ "$rule" == "$desired" ]] && { wanted=1; break; }
      done
    fi
    [[ -z "$number" ]] || (( wanted )) || numbers+="${number}"$'\n'
  done < <(LC_ALL=C ufw status numbered 2>/dev/null)
  while IFS= read -r number; do
    [[ -z "$number" ]] || ufw --force delete "$number" >/dev/null || return 1
  done < <(printf '%s' "$numbers" | sort -rn)
}

sync_ufw_rules() {
  ufw_is_active || { error "UFW 尚未启用。"; return 1; }
  add_desired_ufw_rules || { error "新增 UFW 规则失败，原规则未删除。"; return 1; }
  remove_obsolete_ufw_rules || return 1
  ok "UFW 已同步当前节点需要的 TCP/UDP 端口。"
}

detect_ssh_ports() {
  local server_port candidate seen="," connection="${SSH_CONNECTION:-}"
  local -a connection_parts=()
  if [[ -n "$connection" ]]; then
    read -r -a connection_parts <<< "$connection"
    server_port="${connection_parts[3]:-}"
    if validate_port "$server_port"; then
      printf '%s\n' "$server_port"
      seen+=",${server_port},"
    fi
  fi
  if command -v sshd >/dev/null 2>&1; then
    while IFS= read -r candidate; do
      if validate_port "$candidate" && [[ "$seen" != *",${candidate},"* ]]; then
        printf '%s\n' "$candidate"
        seen+=",${candidate},"
      fi
    done < <(sshd -T 2>/dev/null | awk '$1=="port" {print $2}')
  fi
}

fallback_to_permissive_firewall() {
  local reason="$1"
  warn "${reason}；按可用性优先策略自动退回宽松模式。"
  if ufw_is_active && ! ufw --force disable; then
    error "UFW 同步失败且无法停用，请立即检查节点端口和 SSH 连通性。"
    return 1
  fi
  if firewalld_is_active && ! systemctl disable --now firewalld; then
    error "firewalld 无法停用，请立即检查节点端口。"
    return 1
  fi
  if ! save_firewall_mode permissive false; then
    error "防火墙已尝试放宽，但状态保存失败，请重新进入防火墙菜单检查。"
    return 1
  fi
  warn "当前已是宽松模式，节点端口不再受 UFW/firewalld 限制。"
}

sync_firewall_if_managed() {
  jq -e '.firewall_managed' "$STATE_FILE" >/dev/null 2>&1 || return 0
  sync_ufw_rules || fallback_to_permissive_firewall "自动同步 UFW 节点端口失败"
}

install_ufw_safely() {
  local simulation removals
  command -v apt-get >/dev/null 2>&1 || return 1
  simulation="$(mktemp /tmp/mb-singbox-ufw-simulation.XXXXXX)" || return 1
  if ! apt-get update || ! DEBIAN_FRONTEND=noninteractive apt-get -s install -y ufw > "$simulation"; then
    rm -f -- "$simulation"
    error "UFW 安装预演失败，未修改防火墙。"
    return 1
  fi
  removals="$(awk '/^Remv / {print}' "$simulation")"
  if [[ -n "$removals" ]]; then
    warn "安装 UFW 将移除以下软件包："
    printf '%s\n' "$removals"
    confirm "确认接受上述软件包移除并继续安装 UFW？" || { rm -f -- "$simulation"; return 1; }
  fi
  rm -f -- "$simulation"
  DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
}

configure_ufw() {
  local ssh_port firewalld_was_active=0
  local -a ssh_ports=()
  if ! command -v ufw >/dev/null 2>&1; then
    confirm "系统没有 UFW，是否安装并进入节点端口收紧模式？" || return 0
    if ! command -v apt-get >/dev/null 2>&1 || ! install_ufw_safely; then
      error "UFW 未安装；防火墙状态保持不变。"
      return 1
    fi
  fi

  mapfile -t ssh_ports < <(detect_ssh_ports)
  if (( ${#ssh_ports[@]} == 0 )); then
    error "无法从当前 SSH 会话或 sshd 有效配置可靠识别 SSH 端口，拒绝启用默认拒绝入站。"
    info "请先确认 SSH_CONNECTION 或 sshd -T 能返回当前监听端口，再重新进入收紧模式。"
    return 1
  fi

  firewalld_is_active && firewalld_was_active=1
  warn "节点端口收紧模式会把 UFW 默认入站策略设为拒绝。"
  warn "将保留现有 UFW 规则，并先放行 SSH TCP：${ssh_ports[*]} 以及当前全部节点端口。"
  warn "Docker 发布端口通常由 Docker 自己的规则处理；脚本不会清空或重写 Docker 链。"
  (( firewalld_was_active )) && warn "当前 firewalld 正在运行；确认后将停用它，避免与 UFW 同时管理。"
  confirm "确认进入节点端口收紧模式？" || return 0

  for ssh_port in "${ssh_ports[@]}"; do
    ufw allow "${ssh_port}/tcp" comment "SSH before mb-singbox" >/dev/null || return 1
  done
  add_desired_ufw_rules || { error "节点规则添加失败，不会启用 UFW。"; return 1; }
  ufw default deny incoming >/dev/null || return 1
  ufw default allow outgoing >/dev/null || return 1
  if (( firewalld_was_active )) && ! systemctl disable --now firewalld; then
    error "firewalld 停用失败，不会启用 UFW。"
    return 1
  fi
  if ! ufw_is_active && ! ufw --force enable; then
    (( firewalld_was_active )) && systemctl enable --now firewalld >/dev/null 2>&1 || true
    return 1
  fi
  if ! sync_ufw_rules; then
    fallback_to_permissive_firewall "节点端口收紧模式配置失败" || true
    return 1
  fi
  if ! save_firewall_mode managed true; then
    fallback_to_permissive_firewall "节点端口收紧状态保存失败" || true
    return 1
  fi
  ok "节点端口收紧模式已启用；节点增删后会自动同步 UFW 端口，失败时自动退回宽松模式。"
}

disable_ufw_management() {
  warn "将停止自动管理并删除 mb-singbox 节点规则，但不会启用或停用 UFW/firewalld。"
  confirm "确定改为外部管理防火墙？" || return 0
  if ! remove_managed_ufw_rules; then
    warn "部分 UFW 规则删除失败，管理状态保持不变。"
    return 1
  fi
  save_firewall_mode external false || {
    error "防火墙管理状态保存失败。"
    return 1
  }
  ok "防火墙已改为外部管理。"
}

show_bbr_status() {
  printf '当前拥塞控制：%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  printf '可用算法：%s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf '未知')"
  printf '默认队列：%s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知')"
  [[ -f "$BBR_FILE" ]] && printf 'MB sing-box 管理器的 BBR：已配置\n' || printf 'MB sing-box 管理器的 BBR：未配置\n'
}

enable_bbr() {
  local candidate previous=""
  if ! modprobe tcp_bbr 2>/dev/null && ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    error "当前内核不支持 BBR；脚本不会替换内核。"
    return 1
  fi
  candidate="$(mktemp /tmp/mb-singbox-bbr.XXXXXX)" || return 1
  cat > "$candidate" <<'EOF'
# Managed by MB sing-box 管理器.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  if [[ -f "$BBR_FILE" ]]; then
    previous="$(mktemp /tmp/mb-singbox-bbr-previous.XXXXXX)" || { rm -f -- "$candidate"; return 1; }
    cp -a -- "$BBR_FILE" "$previous" || { rm -f -- "$candidate" "$previous"; return 1; }
  fi
  if ! atomic_install_file "$candidate" "$BBR_FILE" 0644; then
    rm -f -- "$candidate" "$previous"
    return 1
  fi
  rm -f -- "$candidate"
  if sysctl --system >/dev/null && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
    rm -f -- "$previous"
    ok "BBR + fq 已启用。它只直接作用于 TCP，不加速 Hysteria2/TUIC 的 QUIC 拥塞控制。"
  else
    if [[ -s "$previous" ]]; then
      atomic_install_file "$previous" "$BBR_FILE" 0644 || true
    else
      rm -f -- "$BBR_FILE"
    fi
    rm -f -- "$previous"
    sysctl --system >/dev/null 2>&1 || true
    error "BBR 应用失败，已恢复原配置。"
    return 1
  fi
}

disable_bbr() {
  local previous
  [[ -f "$BBR_FILE" ]] || { info "MB sing-box 管理器没有创建 BBR 配置。"; return 0; }
  warn "将删除 ${BBR_FILE} 并重新加载系统全部 sysctl 配置。"
  confirm "确认关闭 MB sing-box 管理器配置的 BBR？" || return 0
  previous="$(mktemp /tmp/mb-singbox-bbr-disable.XXXXXX)" || return 1
  if ! cp -a -- "$BBR_FILE" "$previous" || ! rm -f -- "$BBR_FILE"; then
    rm -f -- "$previous"
    error "无法备份或删除 BBR 配置。"
    return 1
  fi
  if ! sysctl --system >/dev/null; then
    if atomic_install_file "$previous" "$BBR_FILE" 0644; then
      rm -f -- "$previous"
    else
      warn "BBR 配置自动恢复失败；临时备份保留在 ${previous}"
    fi
    sysctl --system >/dev/null 2>&1 || true
    error "重新加载 sysctl 失败，已尝试恢复原 BBR 配置。"
    return 1
  fi
  rm -f -- "$previous"
  ok "已删除 MB sing-box 管理器的 BBR 配置，并成功重新加载系统 sysctl 配置。"
  show_bbr_status
}

http_probe() {
  local name="$1" url="$2" code
  if ! code="$(curl --proto '=https' --tlsv1.2 -L -o /dev/null -sS --connect-timeout 8 --max-time 15 -w '%{http_code}' "$url" 2>/dev/null)"; then
    code="000"
  fi
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

CLIENT_TRANSACTION_BACKUP=""
CLIENT_TRANSACTION_CANDIDATE=""

clear_client_transaction() {
  trap - HUP INT TERM
  CLIENT_TRANSACTION_BACKUP=""
  CLIENT_TRANSACTION_CANDIDATE=""
}

interrupt_client_transaction() {
  local code="$1"
  trap - HUP INT TERM
  rm -f -- "$CLIENT_TRANSACTION_CANDIDATE"
  if [[ -n "$CLIENT_TRANSACTION_BACKUP" && -d "$CLIENT_TRANSACTION_BACKUP" ]]; then
    restore_backup "$CLIENT_TRANSACTION_BACKUP" || true
  fi
  release_lock
  exit "$code"
}

arm_client_transaction() {
  CLIENT_TRANSACTION_BACKUP="$1"
  CLIENT_TRANSACTION_CANDIDATE="$2"
  trap 'interrupt_client_transaction 129' HUP
  trap 'interrupt_client_transaction 130' INT
  trap 'interrupt_client_transaction 143' TERM
}

save_client_settings() {
  local candidate="$1" success_message="${2:-客户端设置已保存。}" backup
  state_candidate_valid "$candidate" || { error "客户端候选状态无效或跨字段不一致。"; return 1; }
  backup="$(backup_current)" || return 1
  arm_client_transaction "$backup" "$candidate"
  if [[ "$(jq '.nodes|length' "$candidate")" -gt 0 ]] && [[ -x "$SINGBOX_BIN" ]]; then
    if ! generate_outputs "$candidate"; then
      clear_client_transaction
      rm -rf -- "$backup"
      error "客户端设置未能生成有效配置，原状态保持不变。"
      return 1
    fi
  fi
  if ! atomic_install_file "$candidate" "$STATE_FILE" 0600; then
    restore_backup "$backup" || warn "客户端状态自动恢复不完整，请检查备份：${backup}"
    clear_client_transaction
    error "客户端状态保存失败，已恢复原状态。"
    return 1
  fi
  clear_client_transaction
  prune_backups
  ok "$success_message"
}

toggle_preferred_addresses() {
  local candidate
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  if ! write_jq_candidate "$candidate" '.client.preferred_enabled = ((.client.preferred_enabled != false) | not)' "$STATE_FILE" ||
     ! save_client_settings "$candidate"; then
    rm -f -- "$candidate"
    return 1
  fi
  rm -f -- "$candidate"
}

set_preferred_addresses() {
  local addresses="$1" candidate
  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  if ! write_jq_candidate "$candidate" --argjson addresses "$addresses" '.client.preferred_addresses=$addresses | .client.preferred_results={} | .client.preferred_last_probe_at=""' "$STATE_FILE" ||
     ! save_client_settings "$candidate"; then
    rm -f -- "$candidate"
    return 1
  fi
  rm -f -- "$candidate"
}

reset_preferred_addresses() {
  set_preferred_addresses '["cfip.1323123.xyz","cf.877771.xyz","cloudflare.182682.xyz","www.cloudflare.com","one.one.one.one"]'
}

client_settings_menu() {
  local choice input address addresses
  local -a raw_addresses=() valid_addresses=()
  require_core || return 1
  with_lock init_state || return 1
  while true; do
    printf '\n客户端与 VMess/Argo 优选地址：\n'
    printf '状态：%s\n' "$(jq -r 'if (.client.preferred_enabled != false) then "已启用" else "已关闭" end' "$STATE_FILE")"
    printf '候选池（仅在手动实测时随机检查最多 3 个）：\n'
    jq -r '.client.preferred_addresses[]? | "  - " + .' "$STATE_FILE"
    if [[ "$(jq -r '.client.preferred_last_probe_at // ""' "$STATE_FILE")" != "" ]]; then
      printf '上次实测：%s\n' "$(jq -r '.client.preferred_last_probe_at' "$STATE_FILE")"
      jq -r '.client.preferred_results | to_entries[]? | "  " + .key + "：" + .value.status + "，地址=" + .value.address + (if .value.fallback_reason == "" then "" else "，原因=" + .value.fallback_reason end)' "$STATE_FILE"
    else
      printf '上次实测：无\n'
    fi
    printf '  1. 启用/关闭 VMess/Argo 优选地址\n'
    printf '  2. 替换候选地址池\n'
    printf '  3. 恢复内置候选地址池\n'
    printf '  4. 重新实测、保存结果并生成客户端配置\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1)
        with_lock toggle_preferred_addresses
        pause
        ;;
      2)
        printf '输入域名或 IPv4，多个地址用英文逗号分隔。\n'
        read -r -p "候选地址：" input
        IFS=',' read -r -a raw_addresses <<<"$input"
        valid_addresses=()
        for address in "${raw_addresses[@]}"; do
          address="$(trim "${address,,}")"
          if validate_domain "$address" || validate_ipv4 "$address"; then
            valid_addresses+=("$address")
          elif [[ -n "$address" ]]; then
            error "候选地址格式不正确：${address}"
          fi
        done
        if (( ${#valid_addresses[@]} == 0 )); then
          error "没有可保存的候选地址。"
          pause
          continue
        fi
        addresses="$(jq -cn --args '$ARGS.positional' "${valid_addresses[@]}")"
        with_lock set_preferred_addresses "$addresses"
        pause
        ;;
      3)
        with_lock reset_preferred_addresses
        pause
        ;;
      4)
        with_lock refresh_preferred_results
        pause
        ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

firewall_menu() {
  local choice
  while true; do
    printf '\n防火墙模式：%s\n' "$(firewall_mode_label)"
    if ufw_is_active; then printf 'UFW：运行中\n'; else printf 'UFW：未运行或未安装\n'; fi
    if firewalld_is_active; then printf 'firewalld：运行中\n'; else printf 'firewalld：未运行或未安装\n'; fi
    printf 'Docker：保留其 iptables/nftables、NAT 和转发规则\n'
    printf '  1. 宽松模式（停用 UFW/firewalld）\n'
    printf '  2. 节点端口收紧模式（UFW：SSH + 当前节点）\n'
    printf '  3. 立即同步节点 UFW 规则\n'
    printf '  4. 改为外部管理防火墙\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) with_lock configure_permissive_firewall ;;
      2) with_lock configure_ufw ;;
      3)
        if jq -e '.firewall_managed' "$STATE_FILE" >/dev/null 2>&1; then
          with_lock sync_ufw_rules
        else
          error "当前不是节点端口收紧模式。"
        fi
        ;;
      4) with_lock disable_ufw_management ;;
      0) return 0 ;;
      *) error "无效选项。" ;;
    esac
    pause
  done
}

system_tools_menu() {
  local choice
  while true; do
    printf '\n系统工具：\n'
    show_bbr_status
    printf '防火墙：%s\n' "$(firewall_mode_label)"
    printf '  1. 启用 BBR + fq\n  2. 关闭 MB sing-box 管理器配置的 BBR\n  3. 防火墙宽松/收紧设置\n  4. AI 服务可用性检测\n  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) with_lock enable_bbr ;;
      2) with_lock disable_bbr ;;
      3) firewall_menu ;;
      4) check_ai_access ;;
      0) return 0 ;;
      *) error "无效选项。" ;;
    esac
    pause
  done
}

regenerate_all_configs() {
  local candidate candidate_config candidate_hopping runtime_unchanged=0
  require_core || return 1
  init_state || return 1
  validate_state_certificates "$STATE_FILE" || return 1
  check_port_hopping_rules "$STATE_FILE" || return 1

  candidate_config="$(mktemp "${ROOT_DIR}/.server-check.XXXXXX.json")" || return 1
  candidate_hopping="$(mktemp "${ROOT_DIR}/.hopping-check.XXXXXX.nft")" || { rm -f -- "$candidate_config"; return 1; }
  if ! render_server_config "$STATE_FILE" "$candidate_config" ||
     ! "$SINGBOX_BIN" check -c "$candidate_config"; then
    rm -f -- "$candidate_config" "$candidate_hopping"
    error "重新生成的服务端配置未通过检查。"
    return 1
  fi
  if port_hopping_enabled_in_state "$STATE_FILE"; then
    if ! render_port_hopping_nft "$STATE_FILE" "$candidate_hopping"; then
      rm -f -- "$candidate_config" "$candidate_hopping"
      return 1
    fi
  else
    : > "$candidate_hopping"
  fi

  if [[ -s "$SERVER_CONFIG" ]] && cmp -s "$candidate_config" "$SERVER_CONFIG"; then
    if port_hopping_enabled_in_state "$STATE_FILE"; then
      cmp -s "$candidate_hopping" "$PORT_HOPPING_NFT_FILE" && runtime_unchanged=1
    elif [[ ! -e "$PORT_HOPPING_NFT_FILE" ]]; then
      runtime_unchanged=1
    fi
  fi
  rm -f -- "$candidate_config" "$candidate_hopping"

  if (( runtime_unchanged )); then
    if generate_outputs "$STATE_FILE"; then
      ok "客户端 JSON/YAML 已刷新；服务端配置未变化，未重启任何服务。"
      return 0
    fi
    error "客户端配置重新生成失败，原输出保持不变。"
    return 1
  fi

  candidate="$(mktemp "${ROOT_DIR}/.state.XXXXXX.json")" || return 1
  cp -a "$STATE_FILE" "$candidate" || { rm -f -- "$candidate"; return 1; }
  if apply_candidate_state "$candidate"; then
    rm -f -- "$candidate"
    sync_firewall_if_managed
    ok "服务端配置发生变化，已重新生成并应用全部配置。"
  else
    rm -f -- "$candidate"
    return 1
  fi
}

check_configuration() {
  require_core || return 1
  [[ -s "$SERVER_CONFIG" ]] || { error "尚未生成服务端配置。"; return 1; }
  if [[ -s "$STATE_FILE" ]]; then
    validate_state_certificates "$STATE_FILE" || return 1
    check_port_hopping_rules "$STATE_FILE" || return 1
    check_installed_port_hopping_rules || return 1
  fi
  "$SINGBOX_BIN" check -c "$SERVER_CONFIG"
}

show_current_service_errors() {
  local invocation logs
  invocation="$(systemctl show "$SERVICE_NAME" -p InvocationID --value 2>/dev/null || true)"
  if [[ -z "$invocation" ]]; then
    warn "当前服务没有可查询的 systemd Invocation ID。"
    return 0
  fi
  logs="$(journalctl -u "$SERVICE_NAME" "_SYSTEMD_INVOCATION_ID=${invocation}" --no-pager 2>/dev/null | grep -E 'ERROR|WARN|FATAL' || true)"
  if [[ -n "$logs" ]]; then
    printf '%s\n' "$logs" | tail -n 50
  else
    ok "本次服务启动后没有 ERROR/WARN/FATAL 日志。"
  fi
}

start_proxy_service() {
  if check_configuration && systemctl enable --now "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "${SERVICE_NAME} 已启动并设为开机自启。"
  else
    error "${SERVICE_NAME} 启动失败。"
    return 1
  fi
}

stop_proxy_service() {
  if systemctl stop "$SERVICE_NAME"; then
    ok "${SERVICE_NAME} 已停止。"
  else
    error "${SERVICE_NAME} 停止失败。"
    return 1
  fi
}

restart_proxy_service() {
  if check_configuration && systemctl restart "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "${SERVICE_NAME} 已重启并保持运行。"
  else
    error "${SERVICE_NAME} 重启失败。"
    return 1
  fi
}

service_menu() {
  local choice
  while true; do
    printf '\n服务管理：\n'
    systemctl --no-pager --full status "$SERVICE_NAME" --lines=0 2>/dev/null || true
    printf '  1. 启动\n  2. 停止\n  3. 重启\n  4. 配置检查\n  5. 最近 50 行日志\n  6. 实时日志\n  7. 本次启动后的错误日志\n  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) with_lock start_proxy_service ;;
      2) with_lock stop_proxy_service ;;
      3) with_lock restart_proxy_service ;;
      4)
        if check_configuration; then
          ok "sing-box 服务端配置检查通过。"
        fi
        ;;
      5) journalctl -u "$SERVICE_NAME" -n 50 --no-pager ;;
      6)
        printf '正在跟踪实时日志，按 Ctrl+C 返回菜单。\n'
        journalctl -u "$SERVICE_NAME" -f --no-pager || true
        ;;
      7) show_current_service_errors ;;
      0) return 0 ;;
      *) error "无效选项。" ;;
    esac
    pause
  done
}

install_quick_command() {
  install -d -m 0755 "$(dirname "$QUICK_PATH")" "$(dirname "$LEGACY_QUICK_PATH")" || return 1
  if [[ -e "$QUICK_PATH" || -L "$QUICK_PATH" ]]; then
    if [[ "$(readlink -f "$QUICK_PATH" 2>/dev/null || true)" != "$INSTALL_PATH" ]]; then
      error "主命令路径已被其他程序占用：${QUICK_PATH}"
      return 1
    fi
  else
    ln -s "$INSTALL_PATH" "$QUICK_PATH" || return 1
  fi

  if [[ -e "$LEGACY_QUICK_PATH" || -L "$LEGACY_QUICK_PATH" ]]; then
    if [[ "$(readlink -f "$LEGACY_QUICK_PATH" 2>/dev/null || true)" != "$INSTALL_PATH" ]]; then
      warn "兼容命令已被其他程序占用，将只使用 ${QUICK_PATH}：${LEGACY_QUICK_PATH}"
    fi
  elif ! ln -s "$INSTALL_PATH" "$LEGACY_QUICK_PATH"; then
    warn "兼容命令创建失败；主命令 ${QUICK_PATH} 不受影响。"
  fi
}

install_manager_binary() {
  local installed_version=""
  install -d -m 0755 "$(dirname "$INSTALL_PATH")" || return 1
  if [[ "$SELF_PATH" == "$INSTALL_PATH" ]]; then
    chmod 0755 "$INSTALL_PATH" || return 1
  elif [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]]; then
    if [[ -x "$INSTALL_PATH" ]]; then
      installed_version="$("$INSTALL_PATH" version 2>/dev/null | awk '{print $2; exit}' || true)"
    fi
    if [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
       [[ "$(printf '%s\n' "$VERSION" "$installed_version" | sort -V | head -n 1)" == "$VERSION" ]] &&
       [[ "$installed_version" != "$VERSION" ]]; then
      warn "固定管理器 ${installed_version} 新于当前脚本 ${VERSION}，不会用旧脚本覆盖。"
    else
      atomic_install_file "$SELF_PATH" "$INSTALL_PATH" 0755 || return 1
    fi
  else
    error "当前脚本来自临时数据流，无法安装固定副本。请使用 install.sh。"
    return 1
  fi
  install_quick_command || return 1
}

update_manager() {
  local stamp api_url raw_url candidate backup new_version download_source=""
  MANAGER_UPDATE_APPLIED=0
  require_root
  command -v curl >/dev/null 2>&1 || install_dependencies || return 1
  stamp="$(date +%s)"
  api_url="https://api.github.com/repos/${MANAGER_REPO}/contents/mb-singbox.sh"
  raw_url="${MANAGER_RAW_BASE}/mb-singbox.sh?ts=${stamp}"
  candidate="$(mktemp /tmp/mb-singbox-update.XXXXXX.sh)" || return 1
  backup="$(mktemp /tmp/mb-singbox-backup.XXXXXX.sh)" || { rm -f "$candidate"; return 1; }

  info "正在从 ${MANAGER_REPO}@${MANAGER_REF} 检查管理器更新..."
  if curl --proto '=https' --tlsv1.2 --retry 2 --retry-delay 1 -fsSL \
      -H 'Accept: application/vnd.github.raw+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'Cache-Control: no-cache' \
      --get --data-urlencode "ref=${MANAGER_REF}" --data-urlencode "ts=${stamp}" \
      "$api_url" -o "$candidate" &&
     [[ -s "$candidate" ]] && bash -n "$candidate" && grep -q '^PROGRAM="mb-singbox"$' "$candidate"; then
    download_source="GitHub API"
  else
    warn "GitHub API 下载失败，正在尝试 raw.githubusercontent.com。"
    if curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$raw_url" -o "$candidate" &&
       [[ -s "$candidate" ]] && bash -n "$candidate" && grep -q '^PROGRAM="mb-singbox"$' "$candidate"; then
      download_source="GitHub Raw"
    else
      rm -f "$candidate" "$backup"
      error "无法下载 MB sing-box 管理器主程序。请确认仓库和分支已经发布。"
      return 1
    fi
  fi
  info "更新源：${download_source}"
  if [[ ! -s "$candidate" ]] || ! bash -n "$candidate" || ! grep -q '^PROGRAM="mb-singbox"$' "$candidate"; then
    rm -f "$candidate" "$backup"
    error "下载内容未通过程序标识和 Bash 语法检查。"
    return 1
  fi
  new_version="$(awk -F '"' '/^VERSION="[0-9]/ {print $2; exit}' "$candidate")"
  [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    rm -f "$candidate" "$backup"
    error "无法识别下载版本，拒绝更新。"
    return 1
  }
  if [[ "$new_version" == "$VERSION" ]]; then
    rm -f "$candidate" "$backup"
    if [[ "$download_source" == "GitHub API" ]]; then
      ok "当前已是最新版：${VERSION}"
      return 0
    fi
    warn "Raw 下载结果与当前版本相同，但 GitHub API 不可用，无法确认远端最新版；未覆盖本地文件。"
    return 1
  fi
  if [[ "$(printf '%s\n' "$VERSION" "$new_version" | sort -V | head -n 1)" != "$VERSION" ]]; then
    rm -f "$candidate" "$backup"
    error "远程版本 ${new_version} 低于当前版本 ${VERSION}，拒绝降级。"
    return 1
  fi

  if [[ -f "$INSTALL_PATH" ]] && ! cp -a -- "$INSTALL_PATH" "$backup"; then
    rm -f -- "$candidate" "$backup"
    return 1
  fi
  if ! atomic_install_file "$candidate" "$INSTALL_PATH" 0755; then
    rm -f -- "$candidate" "$backup"
    error "管理器原子替换失败，原版本保持不变。"
    return 1
  fi
  rm -f -- "$candidate"
  if [[ "$("$INSTALL_PATH" version 2>/dev/null)" != "mb-singbox ${new_version}" ]]; then
    [[ ! -s "$backup" ]] || atomic_install_file "$backup" "$INSTALL_PATH" 0755 || true
    rm -f -- "$backup"
    error "更新后的管理器自检失败，已恢复旧版本。"
    return 1
  fi
  rm -f -- "$backup"
  install_quick_command || warn "管理器已更新，但主命令或兼容命令检查失败。"
  MANAGER_UPDATE_APPLIED=1
  ok "MB sing-box 管理器已更新：${VERSION} -> ${new_version}"
}

maintenance_menu() {
  local choice version_input
  while true; do
    printf '\n安装/更新：\n'
    printf '当前管理器：%s\n' "$VERSION"
    printf '当前内核：%s\n' "$(current_core_version 2>/dev/null || printf '未安装')"
    printf '  1. 安装/更新 sing-box 最新稳定版\n  2. 安装指定 sing-box 稳定版本\n  3. 更新 MB sing-box 管理器\n  4. 重新生成并应用全部配置\n  5. 运行安装诊断\n  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) with_lock install_or_update_core; pause ;;
      2)
        read -r -p "版本号（例如 1.13.14；输入 0 返回）：" version_input
        [[ "$version_input" == "0" ]] && continue
        with_lock install_or_update_core "$version_input"
        pause
        ;;
      3)
        if with_lock update_manager; then
          if (( MANAGER_UPDATE_APPLIED )); then
            info "按 Enter 键重新载入最新版菜单。"
            pause
            exec "$INSTALL_PATH" </dev/tty >/dev/tty 2>/dev/tty
          else
            pause
          fi
        else
          pause
        fi
        ;;
      4)
        with_lock regenerate_all_configs
        pause
        ;;
      5) doctor; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

uninstall_all() {
  require_root
  init_state || return 1
  validate_managed_layout || return 1
  printf '\n%s彻底卸载范围%s\n' "$C_BOLD" "$C_RESET"
  printf '将删除：MB sing-box 管理器服务、内核、状态、服务端/客户端配置、链接、二维码、备份、日志、cloudflared 本地服务、Hysteria2 端口跳跃规则、UFW 自建规则和 BBR sysctl 文件。\n'
  printf '不会删除：MB-ACME、/etc/acme/certs、Cloudflare 远程 Named Tunnel、系统其他 UFW/sysctl 配置。\n'
  warn "该操作不可恢复，客户端配置和节点密钥也会被删除。"
  confirm "确认彻底卸载 MB sing-box 管理器？" || return 0
  read -r -p "请输入 DELETE 确认：" _confirm_word
  [[ "$_confirm_word" == "DELETE" ]] || { info "已取消。"; return 0; }

  safe_to_remove_managed_root "$ROOT_DIR" && safe_to_remove_managed_root "$LOG_DIR" && safe_to_remove_managed_root "$SINGBOX_HOME" &&
    managed_marker_valid "$ROOT_DIR" && managed_marker_valid "$LOG_DIR" && managed_marker_valid "$SINGBOX_HOME" || {
    error "受管目录路径或标记不安全，拒绝递归删除。请手动检查安装目录。"
    return 1
  }
  stop_argo_service
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  stop_port_hopping_service
  rm -f -- "$SERVICE_FILE" "$PORT_HOPPING_SERVICE_FILE" "$PORT_HOPPING_NFT_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  remove_managed_ufw_rules || warn "部分 UFW 规则未能自动删除。"
  rm -f -- "$BBR_FILE"
  sysctl --system >/dev/null 2>&1 || true
  rm -rf -- "$ROOT_DIR" "$LOG_DIR" "$SINGBOX_HOME"
  if [[ -L "$QUICK_PATH" && "$(readlink -f "$QUICK_PATH" 2>/dev/null || true)" == "$INSTALL_PATH" ]]; then
    rm -f "$QUICK_PATH"
  fi
  if [[ -L "$LEGACY_QUICK_PATH" && "$(readlink -f "$LEGACY_QUICK_PATH" 2>/dev/null || true)" == "$INSTALL_PATH" ]]; then
    rm -f "$LEGACY_QUICK_PATH"
  fi
  rm -f "$INSTALL_PATH"
  ok "MB sing-box 管理器本地资源已彻底卸载。"
  exit 0
}

show_status_line() {
  local core service nodes argo firewall hopping
  core="$(current_core_version 2>/dev/null || printf '未安装')"
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then service="运行中"; else service="已停止"; fi
  nodes="$(jq '.nodes|length' "$STATE_FILE" 2>/dev/null || printf '0')"
  hopping="$(jq '[.nodes[] | select(.type=="hysteria2" and (.port_hopping.enabled // false))] | length' "$STATE_FILE" 2>/dev/null || printf '0')"
  if jq -e '.argo.enabled' "$STATE_FILE" >/dev/null 2>&1; then argo="已启用"; else argo="未启用"; fi
  firewall="$(firewall_mode_label)"
  printf 'sing-box：%s  服务：%s  节点：%s  Hysteria2 跳跃：%s  Argo：%s  防火墙：%s\n' "$core" "$service" "$nodes" "$hopping" "$argo" "$firewall"
}

doctor() {
  local installed_version="未安装" installed_hash="未知" remote_version="无法获取" remote_source="不可用"
  local quick_target="不存在" legacy_target="不存在" service_state="未知"
  local service_description="不存在" argo_description="不存在" expected_argo="" stamp api_url
  [[ ! -x "$INSTALL_PATH" ]] || installed_version="$("$INSTALL_PATH" version 2>/dev/null || printf '无法执行')"
  [[ ! -f "$INSTALL_PATH" ]] || installed_hash="$(sha256sum "$INSTALL_PATH" 2>/dev/null | awk '{print $1}' || printf '未知')"
  [[ ! -e "$QUICK_PATH" && ! -L "$QUICK_PATH" ]] || quick_target="$(readlink -f "$QUICK_PATH" 2>/dev/null || printf '无法解析')"
  [[ ! -e "$LEGACY_QUICK_PATH" && ! -L "$LEGACY_QUICK_PATH" ]] || legacy_target="$(readlink -f "$LEGACY_QUICK_PATH" 2>/dev/null || printf '无法解析')"
  if command -v curl >/dev/null 2>&1; then
    stamp="$(date +%s)"
    api_url="https://api.github.com/repos/${MANAGER_REPO}/contents/mb-singbox.sh"
    remote_version="$(curl --proto '=https' --tlsv1.2 -fsSL \
      -H 'Accept: application/vnd.github.raw+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'Cache-Control: no-cache' \
      --get --data-urlencode "ref=${MANAGER_REF}" --data-urlencode "ts=${stamp}" \
      "$api_url" 2>/dev/null | awk -F '"' '/^VERSION="[0-9]/{print $2; exit}' || true)"
    if [[ -n "$remote_version" ]]; then
      remote_source="GitHub API"
    else
      remote_version="$(curl --proto '=https' --tlsv1.2 -fsSL \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "${MANAGER_RAW_BASE}/mb-singbox.sh?ts=${stamp}" 2>/dev/null | \
        awk -F '"' '/^VERSION="[0-9]/{print $2; exit}' || true)"
      [[ -z "$remote_version" ]] || remote_source="GitHub Raw"
    fi
    remote_version="${remote_version:-无法获取}"
  fi

  printf '管理器当前进程：mb-singbox %s\n' "$VERSION"
  printf '固定安装文件：%s（%s）\n' "$INSTALL_PATH" "$installed_version"
  printf '主命令目标：%s -> %s\n' "$QUICK_PATH" "$quick_target"
  printf '兼容命令目标：%s -> %s\n' "$LEGACY_QUICK_PATH" "$legacy_target"
  printf '安装文件 SHA-256：%s\n' "$installed_hash"
  printf '远端 %s@%s：%s（%s）\n' "$MANAGER_REPO" "$MANAGER_REF" "$remote_version" "$remote_source"
  printf 'sing-box 内核：%s\n' "$(current_core_version 2>/dev/null || printf '未安装')"
  if [[ -s "$STATE_FILE" ]] && state_valid "$STATE_FILE"; then
    if state_consistent "$STATE_FILE"; then
      printf '状态文件：有效且跨字段一致（%s）\n' "$STATE_FILE"
    else
      printf '状态文件：格式有效，但跨字段不一致（%s）\n' "$STATE_FILE"
    fi
  else
    printf '状态文件：缺失或无效（%s）\n' "$STATE_FILE"
  fi
  service_state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  printf '服务：%s\n' "${service_state:-未知}"
  service_description="$(unit_description "$SERVICE_FILE" 2>/dev/null || printf '不存在')"
  printf '主服务描述：%s（%s）\n' "$service_description" \
    "$(if [[ "$service_description" == "$MAIN_SERVICE_DESCRIPTION" ]]; then printf '已统一'; else printf '待迁移'; fi)"
  if [[ -f "$ARGO_SERVICE_FILE" ]]; then
    argo_description="$(unit_description "$ARGO_SERVICE_FILE" 2>/dev/null || printf '不存在')"
    expected_argo="$(expected_argo_description 2>/dev/null || true)"
    printf 'Argo 服务描述：%s（%s）\n' "$argo_description" \
      "$(if [[ -n "$expected_argo" && "$argo_description" == "$expected_argo" ]]; then printf '已统一'; else printf '待迁移'; fi)"
  fi
  printf '防火墙模式：%s；UFW=%s；firewalld=%s\n' \
    "$(firewall_mode_label)" \
    "$(if ufw_is_active; then printf '运行中'; else printf '未运行'; fi)" \
    "$(if firewalld_is_active; then printf '运行中'; else printf '未运行'; fi)"
  printf '命令解析：\n'
  type -a singbox 2>/dev/null || true
  type -a mb-singbox 2>/dev/null || true
}

prepare_main_menu() {
  init_state || return 1
  install_manager_binary || return 1
}

status_command() {
  init_state || return 1
  show_status_line
  list_nodes
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
  printf '%sMB sing-box 管理器 %s%s\n' "$C_BOLD" "$VERSION" "$C_RESET"
  printf '轻量、可校验的 sing-box 节点管理器\n\n'
}

main_menu() {
  local choice
  require_root
  require_systemd || return 1
  install_dependencies || return 1
  with_lock prepare_main_menu || return 1
  while true; do
    banner
    show_status_line
    printf '\n  1. 安装/更新\n'
    printf '  2. 创建节点\n'
    printf '  3. 查看节点、客户端配置与分享链接\n'
    printf '  4. 修改节点配置\n'
    printf '  5. 删除节点\n'
    printf '  6. 服务管理与日志\n'
    printf '  7. Argo 应急隧道（VMess-WS 专属）\n'
    printf '  8. BBR、防火墙宽松/收紧与 AI 检测\n'
    printf '  9. 修改客户端连接地址\n'
    printf ' 10. 客户端与 VMess/Argo 优选地址\n'
    printf ' 11. 彻底卸载\n'
    printf '  0. 退出\n'
    read -r -p "请选择：" choice
    printf '\n'
    case "$choice" in
      1) maintenance_menu ;;
      2) with_lock add_node_menu; pause ;;
      3) view_node_menu; pause ;;
      4) with_lock edit_node; pause ;;
      5) with_lock delete_node; pause ;;
      6) service_menu ;;
      7) argo_menu ;;
      8) system_tools_menu ;;
      9) with_lock ensure_server_address; pause ;;
      10) client_settings_menu ;;
      11) with_lock uninstall_all ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

show_help() {
  cat <<EOF
${PROGRAM} ${VERSION}

用法：
  mb-singbox                    打开交互菜单
  mb-singbox install-core       安装/更新 sing-box 最新稳定版
  mb-singbox install-core VERSION
  mb-singbox update-manager     更新 MB sing-box 管理器
  mb-singbox check              检查当前服务端配置
  mb-singbox render             重新生成、校验并应用全部配置
  mb-singbox status             查看状态
  mb-singbox doctor             检查版本、路径和安装状态
  mb-singbox version

兼容命令：singbox

状态文件：${STATE_FILE}
服务端配置：${SERVER_CONFIG}
客户端配置：${CLIENT_DIR}
EOF
}

main() {
  local command="${1:-menu}"
  case "$command" in
    menu) main_menu ;;
    install-core) require_root; shift; with_lock install_or_update_core "${1:-}" ;;
    update-manager) with_lock update_manager ;;
    check) require_root; check_configuration ;;
    render) require_root; with_lock regenerate_all_configs ;;
    port-hopping-apply) require_root; apply_port_hopping_rules ;;
    port-hopping-clear) require_root; clear_port_hopping_rules ;;
    status) require_root; with_lock status_command ;;
    doctor) require_root; doctor ;;
    version|--version|-v) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|--help|-h) show_help ;;
    *) error "未知命令：${command}"; show_help; return 2 ;;
  esac
}

if [[ "${MB_SINGBOX_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
