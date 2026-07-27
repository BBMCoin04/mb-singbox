#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/mb-singbox-behavior.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export MB_SINGBOX_NO_MAIN=1
export MB_SINGBOX_ROOT="$TEST_ROOT/root"
export MB_SINGBOX_STATE_FILE="$TEST_ROOT/root/state.json"
export MB_SINGBOX_SERVER_CONFIG="$TEST_ROOT/root/server.json"
export MB_SINGBOX_CLIENT_DIR="$TEST_ROOT/root/clients"
export MB_SINGBOX_LINK_DIR="$TEST_ROOT/root/links"
export MB_SINGBOX_QR_DIR="$TEST_ROOT/root/qrcodes"
export MB_SINGBOX_BACKUP_DIR="$TEST_ROOT/root/backups"
export MB_SINGBOX_LOG_DIR="$TEST_ROOT/log"
export MB_SINGBOX_CORE_DIR="$TEST_ROOT/core"
export MB_SINGBOX_BIN="$TEST_ROOT/core/sing-box"
export MB_SINGBOX_LOCK_FILE="$TEST_ROOT/lock"
export MB_SINGBOX_INSTALL_PATH="$TEST_ROOT/bin/mb-singbox"
export MB_SINGBOX_QUICK_PATH="$TEST_ROOT/bin/singbox"

# shellcheck disable=SC1091
source "$PROJECT_DIR/mb-singbox.sh"
ensure_directories
install_manager_binary
[[ "$(readlink -f "$MB_SINGBOX_QUICK_PATH")" == "$MB_SINGBOX_INSTALL_PATH" ]]
[[ "$(MB_SINGBOX_NO_MAIN=0 "$MB_SINGBOX_QUICK_PATH" version)" == "mb-singbox 0.3.0" ]]

# Nested version input must accept 0 and return to the parent menu.
printf '2\n0\n0\n' | maintenance_menu >/dev/null

# Existing state files are enriched without losing nodes or Argo identity.
jq -n '{schema:1,server_address:"203.0.113.10",created_at:"2026-07-27T00:00:00Z",firewall_managed:false,nodes:[{id:"node-1",name:"Node One",type:"vmess",port:443}],argo:{enabled:true,mode:"named",node_id:"node-1",hostname:"argo.example.com",origin_port:23456}}' > "$STATE_FILE"
init_state
jq -e '.nodes|length==1' "$STATE_FILE" >/dev/null
jq -e '.argo.mode=="named" and .argo.provisioned==false and .argo.verified==false and .argo.tunnel_id=="" and .argo.public_port==2096' "$STATE_FILE" >/dev/null
jq -e '.client.preferred_enabled==true and (.client.preferred_addresses|length)==5' "$STATE_FILE" >/dev/null
[[ "$(printf '1\n' | select_node_id 'Select')" == "node-1" ]]

# Tunnel tokens are decoded without writing the secret into state.
tunnel_token="$(printf '{"a":"0123456789abcdef0123456789abcdef","t":"6e001ae0-26fb-407a-9540-80d5df60e54d","s":"secret"}' | base64 -w0)"
decode_tunnel_token "$tunnel_token" | jq -e '.account_id=="0123456789abcdef0123456789abcdef" and .tunnel_id=="6e001ae0-26fb-407a-9540-80d5df60e54d"' >/dev/null

# Mock Cloudflare API responses and capture writes.
cloudflare_api_request() {
  local method="$1" url="$2" data_file="$3" response_file="$4"
  case "$method $url" in
    "GET "*"/configurations")
      jq -n '{success:true,result:{config:{ingress:[{hostname:"existing.example.com",service:"http://127.0.0.1:9000"},{service:"http_status:404"}],warp_routing:{enabled:false}}}}' > "$response_file"
      ;;
    "PUT "*"/configurations")
      cp "$data_file" "$TEST_ROOT/captured-ingress.json"
      jq -n '{success:true,result:{}}' > "$response_file"
      ;;
    "GET "*"/dns_records?"*)
      jq -n '{success:true,result:[]}' > "$response_file"
      ;;
    "POST "*"/dns_records")
      cp "$data_file" "$TEST_ROOT/captured-dns.json"
      jq -n '{success:true,result:{id:"dns-record"}}' > "$response_file"
      ;;
    *)
      printf 'Unexpected mock request: %s %s\n' "$method" "$url" >&2
      return 1
      ;;
  esac
  printf '200' > "${response_file}.status"
}

provision_named_tunnel "argo.example.com" 35578 "$tunnel_token" >/dev/null <<< $'\napi-token-for-test\n0123456789abcdef0123456789abcdef\n'
[[ "$ARGO_TUNNEL_ID" == "6e001ae0-26fb-407a-9540-80d5df60e54d" ]]
[[ -z "$CF_API_TOKEN" ]]
jq -e '.config.warp_routing.enabled==false' "$TEST_ROOT/captured-ingress.json" >/dev/null
jq -e '.config.ingress|length==3' "$TEST_ROOT/captured-ingress.json" >/dev/null
jq -e 'any(.config.ingress[]; .hostname?=="existing.example.com")' "$TEST_ROOT/captured-ingress.json" >/dev/null
jq -e 'any(.config.ingress[]; .hostname?=="argo.example.com" and .service=="http://127.0.0.1:35578")' "$TEST_ROOT/captured-ingress.json" >/dev/null
jq -e '.config.ingress[-1].service=="http_status:404"' "$TEST_ROOT/captured-ingress.json" >/dev/null
jq -e '.type=="CNAME" and .name=="argo.example.com" and .content=="6e001ae0-26fb-407a-9540-80d5df60e54d.cfargotunnel.com" and .proxied==true' "$TEST_ROOT/captured-dns.json" >/dev/null

# Public readiness is based on a real WebSocket 101 response, not connector process state alone.
# shellcheck disable=SC2329
curl() {
  local headers="" previous=""
  for argument in "$@"; do
    if [[ "$previous" == "-D" ]]; then headers="$argument"; break; fi
    previous="$argument"
  done
  printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n' > "$headers"
}
verify_argo_endpoint "argo.example.com" "/vmess" 2096 >/dev/null

# Preferred address selection only accepts candidates that pass the strict probe.
probe_preferred_address() { [[ "$1" == "www.cloudflare.com" ]]; }
jq '.client.preferred_addresses=["bad.example.com","www.cloudflare.com"]' "$STATE_FILE" > "$TEST_ROOT/preferred-state.json"
RANDOM=1
[[ "$(select_preferred_address "$TEST_ROOT/preferred-state.json" "argo.example.com" 2096 "/vmess")" == "www.cloudflare.com" ]]

# Manager update directly validates and atomically installs the downloaded main script.
require_root() { :; }
# shellcheck disable=SC2329
curl() {
  local output="" previous=""
  for argument in "$@"; do
    if [[ "$previous" == "-o" ]]; then output="$argument"; break; fi
    previous="$argument"
  done
  [[ -n "$output" ]] || return 1
  cp "$PROJECT_DIR/mb-singbox.sh" "$output"
}
unset MB_SINGBOX_NO_MAIN
update_manager >/dev/null
[[ "$($INSTALL_PATH version)" == "mb-singbox 0.3.0" ]]

printf 'Behavior passed: menu return, state migration, preferred address, Cloudflare provisioning, manager update.\n'
