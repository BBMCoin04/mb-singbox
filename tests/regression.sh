#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/mb-singbox-regression.XXXXXX)"
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
export MB_SINGBOX_LOCK_FILE="$TEST_ROOT/mb-singbox.lock"
export MB_SINGBOX_QUICK_PATH="$TEST_ROOT/bin/singbox"

# shellcheck disable=SC1091
source "$PROJECT_DIR/mb-singbox.sh"

# Keep this test deterministic while still verifying address/SNI separation.
select_preferred_address() { printf 'www.cloudflare.com'; }

ensure_directories
extracted="$(download_core "${1:-1.13.14}")"
install -m 0755 "$extracted" "$SINGBOX_BIN"
rm -rf "$(dirname "$(dirname "$extracted")")"

for rule_name in geosite-cn geoip-cn; do
  case "$rule_name" in
    geosite-cn) rule_url="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" ;;
    geoip-cn) rule_url="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" ;;
  esac
  curl --proto '=https' --tlsv1.2 -fsSL "$rule_url" -o "$TEST_ROOT/${rule_name}.srs"
  "$SINGBOX_BIN" rule-set decompile "$TEST_ROOT/${rule_name}.srs" -o "$TEST_ROOT/${rule_name}.json"
  jq -e '(.version >= 1) and (.rules|length > 0)' "$TEST_ROOT/${rule_name}.json" >/dev/null
done

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj '/CN=proxy.example.com' \
  -keyout "$TEST_ROOT/key.pem" -out "$TEST_ROOT/fullchain.pem" >/dev/null 2>&1

keys="$($SINGBOX_BIN generate reality-keypair)"
private_key="$(awk '/PrivateKey:/ {print $2}' <<<"$keys")"
public_key="$(awk '/PublicKey:/ {print $2}' <<<"$keys")"

jq -n \
  --arg cert "$TEST_ROOT/fullchain.pem" \
  --arg key "$TEST_ROOT/key.pem" \
  --arg private_key "$private_key" \
  --arg public_key "$public_key" \
  '{
    schema: 1,
    server_address: "203.0.113.10",
    created_at: "2026-07-27T00:00:00Z",
    firewall_managed: false,
    nodes: [
      {
        id:"reality-test",name:"Reality Test",type:"reality",port:443,
        uuid:"11111111-1111-4111-8111-111111111111",
        server_name:"www.microsoft.com",private_key:$private_key,
        public_key:$public_key,short_id:"0123456789abcdef"
      },
      {
        id:"hy2-test",name:"Hysteria2 Test",type:"hysteria2",port:443,
        password:"hy2-password",obfs_password:"hy2-obfs",tls_domain:"proxy.example.com",
        certificate_path:$cert,key_path:$key
      },
      {
        id:"tuic-test",name:"TUIC Test",type:"tuic",port:8443,
        uuid:"22222222-2222-4222-8222-222222222222",password:"tuic-password",
        tls_domain:"proxy.example.com",certificate_path:$cert,key_path:$key
      },
      {
        id:"anytls-test",name:"AnyTLS Test",type:"anytls",port:8443,
        password:"anytls-password",tls_domain:"proxy.example.com",
        certificate_path:$cert,key_path:$key
      },
      {
        id:"vmess-test",name:"VMess Test",type:"vmess",port:2087,
        uuid:"33333333-3333-4333-8333-333333333333",path:"/vmess-test",
        tls_domain:"proxy.example.com",certificate_path:$cert,key_path:$key
      }
    ],
    argo:{enabled:true,mode:"named",node_id:"vmess-test",hostname:"backup.example.com",origin_port:23456,provisioned:true,verified:true,tunnel_id:"6e001ae0-26fb-407a-9540-80d5df60e54d",public_port:2096},
    client:{preferred_enabled:true,preferred_addresses:["www.cloudflare.com"]}
  }' > "$STATE_FILE"
chmod 0600 "$STATE_FILE"

render_server_config "$STATE_FILE" "$SERVER_CONFIG"
"$SINGBOX_BIN" check -c "$SERVER_CONFIG"
generate_outputs "$STATE_FILE"

checked=0
while IFS= read -r config; do
  "$SINGBOX_BIN" check -c "$config"
  checked=$((checked + 1))
done < <(find "$CLIENT_DIR" -type f -name '*.json' | sort)

[[ "$checked" -eq 3 ]]
[[ "$(find "$CLIENT_DIR" -maxdepth 1 -type f -name '*.json' | wc -l)" -eq 3 ]]
[[ "$(grep -c '^[a-z0-9].*://' "$LINK_DIR/all.txt")" -eq 6 ]]
if grep -R -F -- "$private_key" "$CLIENT_DIR" "$LINK_DIR" "$QR_DIR" >/dev/null; then
  printf 'Reality private key leaked into client outputs.\n' >&2
  exit 1
fi
jq -e '.inbounds|length == 6' "$SERVER_CONFIG" >/dev/null
jq -e '[.inbounds[] | select(.type=="vless" or .type=="anytls" or (.type=="vmess" and .listen=="::")) | .tcp_fast_open] | all' "$SERVER_CONFIG" >/dev/null
desktop_tun="$CLIENT_DIR/sing-box-windows-tun.json"
desktop_proxy="$CLIENT_DIR/sing-box-windows-system-proxy.json"
router_tun="$CLIENT_DIR/sing-box-router-tun.json"
jq -e '.outbounds|map(.tag)|index("proxy") != null' "$desktop_tun" >/dev/null
jq -e '.route.rules[0].action=="sniff" and .route.rules[1].action=="hijack-dns"' "$desktop_tun" >/dev/null
jq -e '.route.rule_set|map(.tag)|sort == ["geoip-cn","geosite-cn"]' "$desktop_tun" >/dev/null
jq -e '.dns.servers|map(.tag)|sort == ["dns-direct","dns-remote"]' "$desktop_tun" >/dev/null
jq -e '.experimental.cache_file.enabled==true and .inbounds[0].strict_route==true' "$desktop_tun" >/dev/null
jq -e '[.. | objects | keys[]] | any(.=="geoip" or .=="geosite" or .=="inet4_address" or .=="address_resolver" or .=="dns_mode") | not' "$desktop_tun" >/dev/null
jq -e '.inbounds|length==1 and .[0].type=="mixed" and .[0].set_system_proxy==true' "$desktop_proxy" >/dev/null
jq -e '.inbounds|length==1 and .[0].type=="tun" and .[0].auto_redirect==true and .[0].stack=="system"' "$router_tun" >/dev/null
jq -e '.experimental.cache_file.path=="/tmp/mb-singbox-cache.db"' "$router_tun" >/dev/null
jq -e 'first(.outbounds[] | select(.tag=="node-vmess-test")) | .server=="www.cloudflare.com" and .server_port==2087 and .tls.server_name=="proxy.example.com" and .transport.headers.Host=="proxy.example.com" and .tls.utls.fingerprint=="chrome"' "$router_tun" >/dev/null
jq -e 'first(.outbounds[] | select(.tag=="node-vmess-test-argo")) | .server=="www.cloudflare.com" and .server_port==2096 and .tls.server_name=="backup.example.com" and .transport.headers.Host=="backup.example.com" and .tls.utls.fingerprint=="chrome"' "$router_tun" >/dev/null

printf 'Regression passed: server + %d aggregate desktop/router configs, modern DNS/route rules, preferred VMess/Argo addresses, 6 links.\n' "$checked"
