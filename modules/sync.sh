#!/usr/bin/env bash
# ============================================================
# modules/sync.sh
# 关联参数同步模块：二次配置时恢复 state，并按需刷新相关服务配置
# ============================================================

sync_restore_domain_arrays() {
    local all_str cdn_str direct_str
    all_str=$(get_state "ALL_DOMAINS")
    cdn_str=$(get_state "CDN_DOMAINS")
    direct_str=$(get_state "DIRECT_DOMAINS")

    ALL_DOMAINS=()
    CDN_DOMAINS=()
    DIRECT_DOMAINS=()

    if [[ -n "$all_str" ]]; then
        read -ra ALL_DOMAINS <<< "$all_str"
    fi
    if [[ -n "$cdn_str" ]]; then
        read -ra CDN_DOMAINS <<< "$cdn_str"
    fi
    if [[ -n "$direct_str" ]]; then
        read -ra DIRECT_DOMAINS <<< "$direct_str"
    fi

    XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
    GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
    REALITY_DOMAIN=$(get_state "REALITY_DOMAIN")
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    XHTTP_PATH=$(get_state "XHTTP_PATH")

    local sn_str
    sn_str=$(get_state "REALITY_SERVER_NAMES")
    REALITY_SERVER_NAMES=()
    if [[ -n "$sn_str" ]]; then
        read -ra REALITY_SERVER_NAMES <<< "$sn_str"
    fi
}

sync_hydrate_client_state() {
    local xray_config="/usr/local/etc/xray/config.json"
    local sb_config="/etc/sing-box/config.json"

    if [[ -f "$xray_config" ]]; then
        local xray_kv
        xray_kv=$(python3 - "$xray_config" <<'PY' 2>/dev/null || true
import json, sys
path = sys.argv[1]
with open(path) as f:
    c = json.load(f)

def emit(k, v):
    if v is not None and v != "":
        print(f"{k}={v}")

for inbound in c.get("inbounds", []):
    protocol = inbound.get("protocol")
    stream = inbound.get("streamSettings", {})
    network = stream.get("network")
    settings = inbound.get("settings", {})
    clients = settings.get("clients") or []
    if protocol == "vless" and clients:
        emit("XRAY_UUID", clients[0].get("id"))
        break

for inbound in c.get("inbounds", []):
    stream = inbound.get("streamSettings", {})
    if stream.get("network") == "xhttp":
        xs = stream.get("xhttpSettings", {})
        extra = xs.get("extra", {})
        emit("XHTTP_PATH", xs.get("path"))
        emit("XHTTP_PADDING", extra.get("xPaddingBytes"))
        break

for inbound in c.get("inbounds", []):
    stream = inbound.get("streamSettings", {})
    if stream.get("security") == "reality":
        rs = stream.get("realitySettings", {})
        names = rs.get("serverNames") or []
        short_ids = rs.get("shortIds") or []
        emit("REALITY_DEST", rs.get("dest"))
        emit("REALITY_SNI", names[0] if names else "")
        emit("REALITY_SERVER_NAMES", " ".join(names))
        emit("REALITY_SHORT_ID", next((sid for sid in short_ids if sid), short_ids[0] if short_ids else ""))
        emit("REALITY_SPIDER_X", rs.get("spiderX"))
        break
PY
)
        while IFS='=' read -r key value; do
            [[ -n "${key:-}" ]] || continue
            [[ -n "${key:-}" ]] && save_state "$key" "$value"
        done <<< "$xray_kv"
    fi

    if [[ -f "$sb_config" ]]; then
        local sb_kv
        sb_kv=$(python3 - "$sb_config" <<'PY' 2>/dev/null || true
import json, sys
path = sys.argv[1]
with open(path) as f:
    c = json.load(f)

for inbound in c.get("inbounds", []):
    if inbound.get("type") == "anytls":
        users = inbound.get("users") or []
        tls = inbound.get("tls") or {}
        if users:
            print(f"SINGBOX_PASSWORD={users[0].get('password', '')}")
        if tls.get("server_name"):
            print(f"ANYTLS_DOMAIN={tls.get('server_name')}")
        break
PY
)
        while IFS='=' read -r key value; do
            [[ -n "${key:-}" ]] || continue
            [[ -n "${key:-}" ]] && save_state "$key" "$value"
        done <<< "$sb_kv"
    fi
}

sync_refresh_nginx_routes() {
    local source="${1:-关联模块}"

    if [[ "$(get_step CONF_NGINX)" != "1" ]] && ! command -v nginx &>/dev/null; then
        log_warn "Nginx 未配置，跳过 ${source} 后置同步"
        return 0
    fi

    log_step "同步 Nginx 与 ${source} 关联路由参数..."
    sync_restore_domain_arrays
    load_module nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    if [[ -n "${GRPC_DOMAIN:-}" ]]; then
        generate_fake_site "/var/www/${GRPC_DOMAIN}" "${GRPC_DOMAIN}"
    fi
    generate_trap_cert
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    generate_fallback_conf
    generate_servers_conf
    generate_nginx_conf
    reload_nginx
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater
    save_state "CONF_NGINX" "1"
}

sync_before_client_links() {
    log_step "同步客户端链接参数..."
    sync_hydrate_client_state
    sync_restore_domain_arrays
}
