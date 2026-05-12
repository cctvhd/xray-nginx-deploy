#!/usr/bin/env bash
# ============================================================
# modules/naive.sh
# NaïveProxy 安装模块
# 从 klzgrad/naiveproxy GitHub releases 下载二进制
# ============================================================

install_naive() {
    log_step "安装 NaïveProxy（klzgrad/naiveproxy）..."

    local arch
    arch=$(uname -m)
    local release_arch
    case "$arch" in
        x86_64)  release_arch="x64" ;;
        aarch64) release_arch="arm64" ;;
        arm64)   release_arch="arm64" ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac

    local latest_release
    log_info "获取最新版本号..."
    latest_release=$(curl -fsSL \
        "https://api.github.com/repos/klzgrad/naiveproxy/releases/latest" \
        2>/dev/null | grep '"tag_name"' | cut -d '"' -f 4)

    if [[ -z "$latest_release" ]]; then
        log_error "无法获取 naiveproxy 最新版本号，请检查网络或 GitHub API 限速"
        exit 1
    fi
    log_info "最新版本: ${latest_release}"

    local download_url
    download_url="https://github.com/klzgrad/naiveproxy/releases/download/${latest_release}/naiveproxy-${latest_release}-linux-${release_arch}.tar.xz"
    log_info "下载地址: ${download_url}"

    local tmpdir
    tmpdir=$(mktemp -d)
    local tarball="${tmpdir}/naiveproxy.tar.xz"

    log_info "下载中..."
    curl -fsSL "$download_url" -o "$tarball" || {
        log_error "下载失败"
        rm -rf "$tmpdir"
        exit 1
    }

    log_info "解压中..."
    tar -xJf "$tarball" -C "$tmpdir" || {
        log_error "解压失败"
        rm -rf "$tmpdir"
        exit 1
    }

    local caddy_bin
    caddy_bin=$(find "$tmpdir" -name 'caddy' -type f -perm /111 2>/dev/null | head -1)
    if [[ -z "$caddy_bin" ]]; then
        caddy_bin=$(find "$tmpdir" -name 'naive' -type f -perm /111 2>/dev/null | head -1)
    fi
    if [[ -z "$caddy_bin" ]]; then
        log_error "未找到 caddy/naive 二进制文件"
        rm -rf "$tmpdir"
        exit 1
    fi

    cp "$caddy_bin" /usr/local/bin/caddy-naive
    chmod +x /usr/local/bin/caddy-naive
    rm -rf "$tmpdir"

    if ! command -v caddy-naive &>/dev/null; then
        log_error "NaïveProxy 安装失败"
        exit 1
    fi

    log_info "NaïveProxy 安装成功: ${latest_release}"

    # ── 创建 systemd service ──────────────────────────────────
    if ! id -u caddy-naive &>/dev/null; then
        useradd -r -d /var/lib/caddy-naive -s /sbin/nologin caddy-naive
        log_info "已创建系统用户 caddy-naive"
    fi
    mkdir -p /var/lib/caddy-naive /etc/caddy-naive
    chown -R caddy-naive:caddy-naive /var/lib/caddy-naive /etc/caddy-naive

    cat > /etc/systemd/system/caddy-naive.service << 'SVC'
[Unit]
Description=NaïveProxy (Caddy with forwardproxy)
Documentation=https://github.com/klzgrad/naiveproxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy-naive
Group=caddy-naive
# TODO: 配置模块实现后更新 ExecStart
ExecStart=/usr/local/bin/caddy-naive run --config /etc/caddy-naive/Caddyfile
ExecReload=/usr/local/bin/caddy-naive reload --config /etc/caddy-naive/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    systemctl enable caddy-naive
    log_info "已生成 /etc/systemd/system/caddy-naive.service（已 enable）"
}

configure_naive() {
    log_step "配置 NaïveProxy..."

    # ── 1. 确定域名 ──────────────────────────────────────────
    local NAIVE_DOMAIN
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")

    if [[ -z "${NAIVE_DOMAIN}" ]]; then
        NAIVE_DOMAIN="${ANYTLS_DOMAIN:-}"
        [[ -n "${NAIVE_DOMAIN}" ]] && log_info "复用 AnyTLS 域名: ${NAIVE_DOMAIN}"
    fi

    if [[ -z "${NAIVE_DOMAIN}" ]]; then
        if [[ ${#ALL_DOMAINS[@]} -gt 0 ]]; then
            log_info "可用域名:"
            local i=1
            for d in "${ALL_DOMAINS[@]}"; do
                echo "  ${i}. ${d}"
                (( i++ ))
            done
            local sel
            read -rp "请选择 NaïveProxy 域名 [1-$(( i - 1 ))]: " sel
            if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
                NAIVE_DOMAIN="${ALL_DOMAINS[$(( sel - 1 ))]}"
            fi
        fi
    fi

    if [[ -z "${NAIVE_DOMAIN}" ]]; then
        log_error "无法确定 NaïveProxy 域名，请先完成证书申请（步骤 4）"
        exit 1
    fi

    save_state "NAIVE_DOMAIN" "${NAIVE_DOMAIN}"
    log_info "NaïveProxy 域名: ${NAIVE_DOMAIN}"

    # ── 2. 证书路径（singbox.sh 三段式）──────────────────────
    local root_domain NAIVE_CERT NAIVE_KEY
    root_domain=$(echo "$NAIVE_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

    if [[ -f "/etc/letsencrypt/live/${NAIVE_DOMAIN}/fullchain.pem" ]]; then
        NAIVE_CERT="/etc/letsencrypt/live/${NAIVE_DOMAIN}/fullchain.pem"
        NAIVE_KEY="/etc/letsencrypt/live/${NAIVE_DOMAIN}/privkey.pem"
    elif [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
        NAIVE_CERT="/etc/letsencrypt/live/${root_domain}/fullchain.pem"
        NAIVE_KEY="/etc/letsencrypt/live/${root_domain}/privkey.pem"
    else
        read -rp "证书路径 fullchain.pem: " NAIVE_CERT
        read -rp "私钥路径 privkey.pem:   " NAIVE_KEY
    fi

    log_info "证书: ${NAIVE_CERT}"
    log_info "私钥: ${NAIVE_KEY}"

    # ── 3. 认证信息 ──────────────────────────────────────────
    local NAIVE_USER
    NAIVE_USER=$(get_state "NAIVE_USER")
    if [[ -z "${NAIVE_USER}" ]]; then
        NAIVE_USER="naive"
        save_state "NAIVE_USER" "${NAIVE_USER}"
        log_info "默认用户名: ${NAIVE_USER}"
    else
        log_info "复用已有用户名: ${NAIVE_USER}"
    fi

    local NAIVE_PASS
    NAIVE_PASS=$(get_state "NAIVE_PASS")
    if [[ -z "${NAIVE_PASS}" ]]; then
        NAIVE_PASS=$(openssl rand -base64 18)
        save_state "NAIVE_PASS" "${NAIVE_PASS}"
        log_info "已生成新密码"
    else
        log_info "复用已有密码"
    fi

    # ── 4. 写入 Caddyfile ────────────────────────────────────
    mkdir -p /etc/caddy-naive

    cat > /etc/caddy-naive/Caddyfile << EOF
{
    admin off
}

:8444 {
    tls ${NAIVE_CERT} ${NAIVE_KEY}
    route {
        forward_proxy {
            basic_auth ${NAIVE_USER} ${NAIVE_PASS}
            hide_ip
            hide_via
            probe_resistance
        }
        reverse_proxy https://news.ycombinator.com {
            header_up Host {upstream_hostport}
        }
    }
}
EOF

    log_info "已写入 /etc/caddy-naive/Caddyfile"

    # ── 5. 证书复制 ──────────────────────────────────────────
    cp "${NAIVE_CERT}" /etc/caddy-naive/fullchain.pem
    cp "${NAIVE_KEY}"  /etc/caddy-naive/privkey.pem
    chown -R caddy-naive:caddy-naive /etc/caddy-naive
    log_info "证书已复制到 /etc/caddy-naive/"

    # ── 6. 写入 certbot deploy hook ──────────────────────────
    cat > /etc/letsencrypt/renewal-hooks/deploy/naive-cert.sh << 'HOOK'
#!/bin/bash
# Auto-generated by xray-nginx-deploy — NaïveProxy cert deploy hook
STATE_FILE="/etc/xray-deploy/config.env"

get_naive_domain() {
    local v
    v=$(grep "^NAIVE_DOMAIN=" "$STATE_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    [[ -z "$v" ]] && v=$(grep "^ANYTLS_DOMAIN=" "$STATE_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    echo "$v"
}

[[ -z "$RENEWED_DOMAINS" ]] && exit 0

DOMAIN=$(get_naive_domain)
[[ -z "$DOMAIN" ]] && { echo "[Naive Hook] 无法读取域名"; exit 1; }

SRC_FULLCHAIN="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
SRC_PRIVKEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [[ -f "$SRC_FULLCHAIN" && -f "$SRC_PRIVKEY" ]]; then
    cp "$SRC_FULLCHAIN" /etc/caddy-naive/fullchain.pem
    cp "$SRC_PRIVKEY"   /etc/caddy-naive/privkey.pem
    chown -R caddy-naive:caddy-naive /etc/caddy-naive
    systemctl restart caddy-naive.service
    echo "[Naive Hook] 证书已更新: ${DOMAIN}"
else
    echo "[Naive Hook] 证书文件不存在，跳过: ${DOMAIN}"
fi
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/naive-cert.sh
    log_info "已写入证书部署 hook"

    # ── 7. 启动服务 ──────────────────────────────────────────
    systemctl enable --now caddy-naive.service
    sleep 2
    if ! systemctl is-active --quiet caddy-naive.service; then
        log_warn "NaïveProxy 服务未能正常启动，请检查："
        log_warn "  journalctl -u caddy-naive.service --no-pager -n 20"
    else
        log_info "NaïveProxy 服务已启动"
    fi

    # ── 8. 客户端信息 ────────────────────────────────────────
    echo ""
    log_info "━━━ NaiveProxy 客户端配置 ━━━"
    log_info "服务器：  ${NAIVE_DOMAIN}:443"
    log_info "用户名：  ${NAIVE_USER}"
    log_info "密码：    ${NAIVE_PASS}"
    log_info "协议：    HTTPS"
    echo ""
}

# ── 模块入口 ─────────────────────────────────────────────────
run_naive() {
    log_step "========== NaïveProxy 安装 =========="
    install_naive
    log_info "========== NaïveProxy 安装完成 =========="
}
