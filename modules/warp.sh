#!/usr/bin/env bash
# ============================================================
# modules/warp.sh
# Cloudflare WARP 安装 + Proxy 模式配置
# ============================================================

ensure_warp_port() {
    WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
}

install_warp() {
    log_step "安装 Cloudflare WARP..."
    ensure_warp_port

    case "$OS_ID" in
        ubuntu|debian)
            mkdir -p /usr/share/keyrings
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
                gpg --yes --dearmor \
                    -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

            cat > /etc/apt/sources.list.d/cloudflare-client.list << REPO
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main
REPO

            apt-get update -y >/dev/null 2>&1
            apt-get install -y cloudflare-warp >/dev/null 2>&1
            ;;

        centos|rhel|rocky|almalinux)
            rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
            curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
                -o /etc/yum.repos.d/cloudflare-warp.repo

            if command -v dnf &>/dev/null; then
                dnf install -y cloudflare-warp >/dev/null 2>&1
            else
                yum install -y cloudflare-warp >/dev/null 2>&1
            fi
            ;;

        *)
            log_error "Cloudflare WARP 暂不支持当前系统: $OS_NAME"
            exit 1
            ;;
    esac

    if ! command -v warp-cli &>/dev/null; then
        log_error "Cloudflare WARP 安装失败"
        exit 1
    fi

    log_info "Cloudflare WARP 安装完成"
}

start_warp_service() {
    log_step "启动 Cloudflare WARP 守护进程..."

    systemctl enable --now warp-svc
    sleep 2

    if systemctl is-active --quiet warp-svc; then
        log_info "warp-svc 已启动"
    else
        log_error "warp-svc 启动失败，请检查 systemctl status warp-svc"
        exit 1
    fi
}

ensure_warp_registered() {
    log_step "检查 WARP 注册状态..."

    if warp-cli --accept-tos registration show >/dev/null 2>&1; then
        log_info "WARP 已注册，跳过首次注册"
        return
    fi

    log_step "首次注册 WARP..."
    warp-cli --accept-tos registration new
    log_info "WARP 首次注册完成"
}

set_warp_proxy_mode() {
    log_step "切换 WARP 为 Proxy 模式..."
    ensure_warp_port

    # 官方文档明确 Local proxy mode 需要 MASQUE。
    warp-cli --accept-tos tunnel protocol set MASQUE

    # 根据不同客户端版本兼容两套命令。
    warp-cli --accept-tos mode proxy >/dev/null 2>&1 || \
    warp-cli --accept-tos set-mode proxy >/dev/null 2>&1 || {
        log_error "切换 WARP Proxy 模式失败"
        exit 1
    }

    warp-cli --accept-tos set-proxy-port "${WARP_PROXY_PORT}" >/dev/null 2>&1 || true

    log_info "WARP 已切换到 Proxy 模式，端口: ${WARP_PROXY_PORT}"
    log_warn "如果你使用 Cloudflare One，请确认设备配置文件的 Service mode 已设置为 Local proxy mode，且 Device tunnel protocol 为 MASQUE"
}

connect_warp() {
    log_step "连接 WARP..."

    warp-cli --accept-tos connect
    sleep 3

    local status_out
    status_out=$(warp-cli --accept-tos status 2>&1 || true)
    echo "$status_out"

    if ss -lnt 2>/dev/null | grep -q ":${WARP_PROXY_PORT} "; then
        log_info "检测到本地代理监听在 127.0.0.1:${WARP_PROXY_PORT}"
    else
        log_warn "暂未检测到本地代理端口 ${WARP_PROXY_PORT} 正在监听"
        log_warn "如果你使用的是 Cloudflare One，这通常意味着设备配置文件尚未启用 Local proxy mode"
    fi
}

run_warp() {
    log_step "========== Cloudflare WARP 安装配置 =========="
    ensure_warp_port

    if ! command -v warp-cli &>/dev/null; then
        install_warp
    else
        log_info "检测到已安装 Cloudflare WARP，跳过安装"
    fi

    start_warp_service
    ensure_warp_registered
    set_warp_proxy_mode
    connect_warp

    log_info "========== Cloudflare WARP 安装配置完成 =========="
    echo ""
    log_info "本地代理地址: 127.0.0.1:${WARP_PROXY_PORT}"
    log_info "当前脚本中的 Xray / Sing-Box warp 出站默认依赖此地址"
}
