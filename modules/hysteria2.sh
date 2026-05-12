#!/usr/bin/env bash
# ============================================================
# modules/hysteria2.sh
# Hysteria2 安装模块
# 官方脚本: https://get.hy2.sh/
# ============================================================

install_hysteria2() {
    log_step "安装 Hysteria2（官方脚本 https://get.hy2.sh/）..."

    bash <(curl -fsSL https://get.hy2.sh/)

    if ! command -v hysteria &>/dev/null; then
        log_error "Hysteria2 安装失败"
        exit 1
    fi

    # 官方脚本默认会 enable+start hysteria-server.service，
    # 配置模块实现前先停止，避免空配置运行
    systemctl stop hysteria-server.service 2>/dev/null || true

    local hy_ver
    hy_ver=$(hysteria version 2>&1 | grep -oP '[\d.]+' | head -1)
    log_info "Hysteria2 安装成功: v${hy_ver}"
}

configure_hysteria2() {
    log_step "配置 Hysteria2..."

    # ── 1. 确定域名 ──────────────────────────────────────────
    local HY2_DOMAIN
    HY2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")

    if [[ -z "${HY2_DOMAIN}" ]]; then
        HY2_DOMAIN="${ANYTLS_DOMAIN:-}"
        [[ -n "${HY2_DOMAIN}" ]] && log_info "复用 AnyTLS 域名: ${HY2_DOMAIN}"
    fi

    if [[ -z "${HY2_DOMAIN}" ]]; then
        if [[ ${#ALL_DOMAINS[@]} -gt 0 ]]; then
            log_info "可用域名:"
            local i=1
            for d in "${ALL_DOMAINS[@]}"; do
                echo "  ${i}. ${d}"
                (( i++ ))
            done
            local sel
            read -rp "请选择 Hysteria2 域名 [1-$(( i - 1 ))]: " sel
            if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
                HY2_DOMAIN="${ALL_DOMAINS[$(( sel - 1 ))]}"
            fi
        fi
    fi

    if [[ -z "${HY2_DOMAIN}" ]]; then
        log_error "无法确定 Hysteria2 域名，请先完成证书申请（步骤 4）"
        exit 1
    fi

    save_state "HYSTERIA2_DOMAIN" "${HY2_DOMAIN}"
    log_info "Hysteria2 域名: ${HY2_DOMAIN}"

    # ── 2. 证书路径（参照 singbox.sh 三段式）────────────────
    local root_domain HY2_CERT HY2_KEY
    root_domain=$(echo "$HY2_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

    if [[ -f "/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem" ]]; then
        HY2_CERT="/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem"
        HY2_KEY="/etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem"
    elif [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
        HY2_CERT="/etc/letsencrypt/live/${root_domain}/fullchain.pem"
        HY2_KEY="/etc/letsencrypt/live/${root_domain}/privkey.pem"
    else
        read -rp "证书路径 fullchain.pem: " HY2_CERT
        read -rp "私钥路径 privkey.pem:   " HY2_KEY
    fi

    log_info "证书: ${HY2_CERT}"
    log_info "私钥: ${HY2_KEY}"

    # ── 3. 密码 ──────────────────────────────────────────────
    local HY2_PASS
    HY2_PASS=$(get_state "HYSTERIA2_PASSWORD")
    if [[ -z "${HY2_PASS}" ]]; then
        HY2_PASS=$(openssl rand -base64 18)
        save_state "HYSTERIA2_PASSWORD" "${HY2_PASS}"
        log_info "已生成新密码"
    else
        log_info "复用已有密码"
    fi

    # ── 4. 伪装 URL ──────────────────────────────────────────
    local default_masquerade="https://news.ycombinator.com/"
    local masquerade_url MASQUERADE_URL
    read -rp "伪装 URL [默认: ${default_masquerade}]: " masquerade_url
    MASQUERADE_URL="${masquerade_url:-${default_masquerade}}"
    log_info "伪装 URL: ${MASQUERADE_URL}"

    # ── 5. QUIC 窗口参数 ─────────────────────────────────────
    local rmem_max
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 4194304)

    local init_stream=$(( rmem_max / 2 ))
    local max_stream=$(( rmem_max * 2 ))
    local init_conn=$(( rmem_max * 5 ))
    local max_conn=$(( rmem_max * 10 ))

    [[ $init_stream -lt 4194304  ]] && init_stream=4194304
    [[ $max_stream  -lt 8388608  ]] && max_stream=8388608
    [[ $init_conn   -lt 10485760 ]] && init_conn=10485760
    [[ $max_conn    -lt 20971520 ]] && max_conn=20971520

    log_info "QUIC 窗口: stream=${init_stream}/${max_stream} conn=${init_conn}/${max_conn}"

    # ── 6. 写入配置文件 ──────────────────────────────────────
    mkdir -p /etc/hysteria

    cat > /etc/hysteria/config.yaml << EOF
listen: :443
tls:
  cert: /etc/hysteria/fullchain.pem
  key: /etc/hysteria/privkey.pem
auth:
  type: password
  password: ${HY2_PASS}
resolver:
  type: udp
  udp:
    addr: 127.0.0.1:53
    timeout: 4s
quic:
  initStreamReceiveWindow: ${init_stream}
  maxStreamReceiveWindow: ${max_stream}
  initConnReceiveWindow: ${init_conn}
  maxConnReceiveWindow: ${max_conn}
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
congestion:
  type: bbr
udpIdleTimeout: 60s
sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: all
  udpPorts: all
masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true
EOF

    log_info "已写入 /etc/hysteria/config.yaml"

    # ── 7. 证书复制到 /etc/hysteria/ ─────────────────────────
    mkdir -p /etc/hysteria
    cp "${HY2_CERT}" /etc/hysteria/fullchain.pem
    cp "${HY2_KEY}"  /etc/hysteria/privkey.pem
    chown hysteria:hysteria /etc/hysteria/fullchain.pem /etc/hysteria/privkey.pem
    log_info "证书已复制到 /etc/hysteria/"

    # ── 8. 写入 certbot deploy hook ────────────────────────────
    cat > /etc/letsencrypt/renewal-hooks/deploy/hysteria-cert.sh << 'HOOK'
#!/bin/bash
# Auto-generated by xray-nginx-deploy — Hysteria2 cert deploy hook
STATE_FILE="/etc/xray-deploy/config.env"

get_hy2_domain() {
    local v
    v=$(grep "^HYSTERIA2_DOMAIN=" "$STATE_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    [[ -z "$v" ]] && v=$(grep "^ANYTLS_DOMAIN=" "$STATE_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    echo "$v"
}

[[ -z "$RENEWED_DOMAINS" ]] && exit 0

DOMAIN=$(get_hy2_domain)
[[ -z "$DOMAIN" ]] && { echo "[Hysteria Hook] 无法读取域名"; exit 1; }

SRC_FULLCHAIN="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
SRC_PRIVKEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [[ -f "$SRC_FULLCHAIN" && -f "$SRC_PRIVKEY" ]]; then
    cp "$SRC_FULLCHAIN" /etc/hysteria/fullchain.pem
    cp "$SRC_PRIVKEY"   /etc/hysteria/privkey.pem
    chown hysteria:hysteria /etc/hysteria/fullchain.pem /etc/hysteria/privkey.pem
    systemctl restart hysteria-server.service
    echo "[Hysteria Hook] 证书已更新: ${DOMAIN}"
else
    echo "[Hysteria Hook] 证书文件不存在，跳过: ${DOMAIN}"
fi
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/hysteria-cert.sh
    log_info "已写入证书部署 hook"

    # ── 9. 启动服务 ──────────────────────────────────────────
    systemctl enable --now hysteria-server.service
    sleep 2
    if ! systemctl is-active --quiet hysteria-server.service; then
        log_warn "Hysteria2 服务未能正常启动，请检查："
        log_warn "  journalctl -u hysteria-server.service --no-pager -n 20"
    else
        log_info "Hysteria2 服务已启动"
    fi

    # ── 10. 客户端信息 ───────────────────────────────────────
    echo ""
    log_info "━━━ Hysteria2 客户端配置 ━━━"
    log_info "服务器： ${HY2_DOMAIN}:443"
    log_info "密码：   ${HY2_PASS}"
    log_info "TLS SNI：${HY2_DOMAIN}"
    log_info "跳过证书验证：否"
    echo ""
}

# ── 模块入口 ─────────────────────────────────────────────────
run_hysteria2() {
    log_step "========== Hysteria2 安装 =========="
    install_hysteria2
    log_info "========== Hysteria2 安装完成 =========="
}
