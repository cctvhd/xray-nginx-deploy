#!/usr/bin/env bash
# ============================================================
# modules/client.sh
# 生成客户端连接链接
# ============================================================

# ── 读取已有配置参数 ─────────────────────────────────────────
load_existing_params() {
    local xray_config="/usr/local/etc/xray/config.json"
    local sb_config="/etc/sing-box/config.json"

    # 从 xray config 读取参数
    if [[ -f "$xray_config" ]]; then
        XRAY_UUID=$(grep -oP '"id":\s*"\K[^"]+' "$xray_config" | head -1)
        XHTTP_PATH=$(grep -oP '"path":\s*"\K[^"]+' "$xray_config" | head -1)
        XHTTP_DOMAIN=$(grep -oP '"host":\s*"\K[^"]+' "$xray_config" | head -1)
        XRAY_PUBLIC_KEY=$(grep -oP '"privateKey":\s*"\K[^"]+' "$xray_config" | head -1)
        REALITY_DEST=$(grep -oP '"dest":\s*"\K[^"]+' "$xray_config" | head -1)

        # 读取第一个非空 shortId
        REALITY_SHORT_ID=$(python3 -c "
import json
with open('${xray_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('streamSettings', {}).get('security') == 'reality':
        ids = inb['streamSettings']['realitySettings']['shortIds']
        print(next((i for i in ids if i), ids[0] if ids else ''))
        break
" 2>/dev/null || echo "")

        # 读取第一个 serverName
        REALITY_SNI=$(python3 -c "
import json
with open('${xray_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('streamSettings', {}).get('security') == 'reality':
        sns = inb['streamSettings']['realitySettings']['serverNames']
        print(sns[0] if sns else '')
        break
" 2>/dev/null || echo "")

        # 公钥需要从私钥推导
        if [[ -n "${XRAY_PUBLIC_KEY:-}" ]]; then
            local keypair
            keypair=$(xray x25519 -i "$XRAY_PUBLIC_KEY" 2>/dev/null)
            XRAY_PUBLIC_KEY=$(echo "$keypair" | grep -i "public\|password" | awk '{print $NF}')
        fi

        # gRPC 域名从 nginx 配置读取
        GRPC_DOMAIN=$(grep -oP 'server_name\s+\K\S+' \
            /etc/nginx/conf.d/servers.conf 2>/dev/null | \
            grep -v "^\." | sed -n '2p' | tr -d ';')
    fi

    # 从 sing-box config 读取参数
    if [[ -f "$sb_config" ]]; then
        SINGBOX_PASSWORD=$(python3 -c "
import json
with open('${sb_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('type') == 'anytls':
        print(inb['users'][0]['password'])
        break
" 2>/dev/null || echo "")

        ANYTLS_DOMAIN=$(python3 -c "
import json
with open('${sb_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('type') == 'anytls':
        print(inb['tls']['server_name'])
        break
" 2>/dev/null || echo "")
    fi
}

# ── 获取服务器IP ─────────────────────────────────────────────
get_server_ip() {
    SERVER_IP=$(curl -fsSL -4 https://api.ipify.org 2>/dev/null || \
                curl -fsSL -4 https://ip.sb 2>/dev/null || \
                hostname -I | awk '{print $1}')
    log_info "服务器IP: ${SERVER_IP}"
}

# ── 生成 xhttp CDN 节点链接 ──────────────────────────────────
gen_xhttp_url() {
    if [[ -z "${XHTTP_DOMAIN:-}" ]] || [[ -z "${XRAY_UUID:-}" ]]; then
        return
    fi

    local path_encoded
    path_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${XHTTP_PATH}'))
" 2>/dev/null || echo "${XHTTP_PATH}")

    XHTTP_URL="vless://${XRAY_UUID}@${XHTTP_DOMAIN}:443?\
encryption=none\
&security=tls\
&sni=${XHTTP_DOMAIN}\
&fp=chrome\
&type=xhttp\
&path=${path_encoded}\
&host=${XHTTP_DOMAIN}\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('xhttp-CDN-${XHTTP_DOMAIN}'))" 2>/dev/null)"
}

# ── 生成 gRPC CDN 节点链接 ───────────────────────────────────
gen_grpc_url() {
    if [[ -z "${GRPC_DOMAIN:-}" ]] || [[ -z "${XRAY_UUID:-}" ]]; then
        return
    fi

    GRPC_URL="vless://${XRAY_UUID}@${GRPC_DOMAIN}:443?\
encryption=none\
&security=tls\
&sni=${GRPC_DOMAIN}\
&fp=chrome\
&type=grpc\
&serviceName=grpc.Service\
&mode=multi\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('gRPC-CDN-${GRPC_DOMAIN}'))" 2>/dev/null)"
}

# ── 生成 Reality 直连节点链接 ────────────────────────────────
gen_reality_url() {
    if [[ -z "${REALITY_SNI:-}" ]] || [[ -z "${XRAY_UUID:-}" ]]; then
        return
    fi

    local spider_encoded
    spider_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${REALITY_SPIDER_X:-/api/health}'))
" 2>/dev/null || echo "%2Fapi%2Fhealth")

    REALITY_URL="vless://${XRAY_UUID}@${SERVER_IP}:443?\
encryption=none\
&security=reality\
&sni=${REALITY_SNI}\
&fp=chrome\
&pbk=${XRAY_PUBLIC_KEY}\
&sid=${REALITY_SHORT_ID}\
&flow=xtls-rprx-vision\
&type=tcp\
&spiderX=${spider_encoded}\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('Reality-${SERVER_IP}'))" 2>/dev/null)"
}

# ── 生成 AnyTLS 节点链接 ─────────────────────────────────────
gen_anytls_url() {
    if [[ -z "${ANYTLS_DOMAIN:-}" ]] || [[ -z "${SINGBOX_PASSWORD:-}" ]]; then
        return
    fi

    local password_encoded
    password_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${SINGBOX_PASSWORD}', safe=''))
" 2>/dev/null || echo "${SINGBOX_PASSWORD}")

    ANYTLS_URL="anytls://${password_encoded}@${ANYTLS_DOMAIN}:443?\
security=tls\
&sni=${ANYTLS_DOMAIN}\
&alpn=h2\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('AnyTLS-${ANYTLS_DOMAIN}'))" 2>/dev/null)"
}

# ── 保存并展示所有链接 ───────────────────────────────────────
show_client_links() {
    local output_file="/root/xray_client_links.txt"

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}          客户端连接链接                ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    {
        echo "# ============================================================"
        echo "# 客户端连接链接"
        echo "# 生成时间: $(date)"
        echo "# 服务器IP: ${SERVER_IP}"
        echo "# ============================================================"
        echo ""
    } > "$output_file"

    # xhttp CDN
    if [[ -n "${XHTTP_URL:-}" ]]; then
        echo -e "${GREEN}[xhttp CDN]${NC}"
        echo "$XHTTP_URL"
        echo ""
        {
            echo "# xhttp CDN"
            echo "$XHTTP_URL"
            echo ""
            echo "# xhttp Extra 参数（v2rayN XHTTP Extra 填入）"
            cat << JSON
{
    "enc": "packet",
    "xPaddingBytes": "128-2048",
    "xmux": {
        "maxConcurrency": "4-8",
        "maxConnections": 0,
        "cMaxReuseTimes": 150,
        "hMaxRequestTimes": "150-300",
        "hMaxReusableSecs": "1800-3600",
        "hKeepAlivePeriod": 60
    }
}
JSON
            echo ""
        } >> "$output_file"
    fi

    # gRPC CDN
    if [[ -n "${GRPC_URL:-}" ]]; then
        echo -e "${GREEN}[gRPC CDN]${NC}"
        echo "$GRPC_URL"
        echo ""
        {
            echo "# gRPC CDN"
            echo "$GRPC_URL"
            echo ""
        } >> "$output_file"
    fi

    # Reality 直连
    if [[ -n "${REALITY_URL:-}" ]]; then
        echo -e "${GREEN}[Reality 直连]${NC}"
        echo "$REALITY_URL"
        echo ""
        {
            echo "# Reality 直连"
            echo "$REALITY_URL"
            echo ""
        } >> "$output_file"
    fi

    # AnyTLS
    if [[ -n "${ANYTLS_URL:-}" ]]; then
        echo -e "${GREEN}[AnyTLS]${NC}"
        echo "$ANYTLS_URL"
        echo ""
        {
            echo "# AnyTLS"
            echo "$ANYTLS_URL"
            echo ""
        } >> "$output_file"
    fi

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 关键参数汇总
    {
        echo "# ============================================================"
        echo "# 关键参数汇总"
        echo "# ============================================================"
        echo "UUID:            ${XRAY_UUID:-}"
        echo "公钥(PublicKey): ${XRAY_PUBLIC_KEY:-}"
        echo "xhttp路径:       ${XHTTP_PATH:-}"
        echo "xhttp域名:       ${XHTTP_DOMAIN:-}"
        echo "gRPC域名:        ${GRPC_DOMAIN:-}"
        echo "Reality SNI:     ${REALITY_SNI:-}"
        echo "Reality ShortId: ${REALITY_SHORT_ID:-}"
        echo "AnyTLS域名:      ${ANYTLS_DOMAIN:-}"
        echo "AnyTLS密码:      ${SINGBOX_PASSWORD:-}"
    } >> "$output_file"

    log_info "所有链接已保存到: $output_file"
}

# ── 模块入口 ─────────────────────────────────────────────────
run_client() {
    log_step "========== 生成客户端链接 =========="
    load_existing_params
    get_server_ip
    gen_xhttp_url
    gen_grpc_url
    gen_reality_url
    gen_anytls_url
    show_client_links
    log_info "========== 客户端链接生成完成 =========="
}
