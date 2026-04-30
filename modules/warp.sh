#!/usr/bin/env bash
# ============================================================
# modules/warp.sh
# 用 wgcf 获取 WARP WireGuard 凭证
# Xray / Sing-Box 内嵌 wireguard 出站，不再启动独立代理进程
# ============================================================

WGCF_DIR="/etc/wgcf"
WGCF_PROFILE="${WGCF_DIR}/wgcf-profile.conf"

# ── 清理旧版 cloudflare-warp ─────────────────────────────────
cleanup_old_warp() {
    if ! command -v warp-cli &>/dev/null && \
       ! systemctl list-unit-files warp-svc.service &>/dev/null 2>&1; then
        log_info "未检测到旧版 Cloudflare WARP，跳过清理"
        return
    fi

    log_step "清理旧版 Cloudflare WARP 客户端..."

    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    systemctl stop    warp-svc >/dev/null 2>&1 || true
    systemctl disable warp-svc >/dev/null 2>&1 || true

    case "${OS_ID}" in
        ubuntu|debian)
            apt-get remove -y --purge cloudflare-warp >/dev/null 2>&1 || true
            apt-get autoremove -y >/dev/null 2>&1 || true
            rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                dnf remove -y cloudflare-warp >/dev/null 2>&1 || true
            else
                yum remove -y cloudflare-warp >/dev/null 2>&1 || true
            fi
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac

    rm -rf /var/lib/cloudflare-warp
    rm -f  /usr/bin/warp-cli /usr/bin/warp-taskbar

    log_info "旧版 Cloudflare WARP 清理完成"
}

# ── 安装 wgcf ────────────────────────────────────────────────
install_wgcf() {
    if command -v wgcf &>/dev/null; then
        log_info "wgcf 已安装: $(wgcf --version 2>&1 | head -1)，跳过下载"
        return
    fi

    log_step "下载 wgcf 最新版本..."

    local download_url
    download_url=$(curl -fsSL \
        https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        | grep browser_download_url \
        | cut -d '"' -f 4 \
        | grep 'linux_amd64$')

    if [[ -z "${download_url}" ]]; then
        log_error "无法获取 wgcf 下载地址，请检查网络或 GitHub API 限速"
        exit 1
    fi

    curl -fsSL "${download_url}" -o /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf

    if ! command -v wgcf &>/dev/null; then
        log_error "wgcf 安装失败"
        exit 1
    fi

    log_info "wgcf 安装成功: $(wgcf --version 2>&1 | head -1)"
}

# ── 注册并生成 WireGuard 配置 ────────────────────────────────
generate_wgcf_profile() {
    local state_file="/etc/xray-deploy/config.env"

    local saved_privkey
    saved_privkey=$(grep "^WGCF_PRIVATE_KEY=" "${state_file}" 2>/dev/null | \
        cut -d= -f2- | tr -d "'\"")

    if [[ -n "${saved_privkey}" && -f "${WGCF_PROFILE}" ]]; then
        log_info "检测到已有 wgcf 凭证，跳过注册"
        return
    fi

    log_step "注册 WARP 账号并生成 WireGuard 配置..."

    mkdir -p "${WGCF_DIR}"
    chmod 700 "${WGCF_DIR}"
    pushd "${WGCF_DIR}" >/dev/null

    wgcf register --accept-tos
    wgcf generate

    popd >/dev/null

    # wgcf-account.toml 含有 access_token，锁权限
    chmod 600 "${WGCF_DIR}/wgcf-account.toml" 2>/dev/null || true
    chmod 600 "${WGCF_PROFILE}"               2>/dev/null || true

    if [[ ! -f "${WGCF_PROFILE}" ]]; then
        log_error "wgcf-profile.conf 未生成，注册可能失败"
        exit 1
    fi

    log_info "wgcf-profile.conf 生成完成"
}

# ── 解析凭证到全局变量 ───────────────────────────────────────
parse_wgcf_credentials() {
    log_step "解析 wgcf WireGuard 凭证..."

    if [[ ! -f "${WGCF_PROFILE}" ]]; then
        log_error "找不到 ${WGCF_PROFILE}，请先运行 generate_wgcf_profile"
        exit 1
    fi

    WGCF_PRIVATE_KEY=$(awk -F' = ' '/^PrivateKey/{print $2}' "${WGCF_PROFILE}" | tr -d '[:space:]')
    WGCF_ADDRESS=$(awk -F' = ' '/^Address/{print $2}'    "${WGCF_PROFILE}" | tr -d '[:space:]')
    WGCF_PEER_PUBKEY=$(awk -F' = ' '/^PublicKey/{print $2}' "${WGCF_PROFILE}" | tr -d '[:space:]')
    WGCF_ENDPOINT=$(awk -F' = ' '/^Endpoint/{print $2}'  "${WGCF_PROFILE}" | tr -d '[:space:]')

    WGCF_ENDPOINT_HOST="${WGCF_ENDPOINT%:*}"
    WGCF_ENDPOINT_PORT="${WGCF_ENDPOINT##*:}"

    if [[ -z "${WGCF_PRIVATE_KEY}" || -z "${WGCF_PEER_PUBKEY}" ]]; then
        log_error "凭证解析失败，请检查 ${WGCF_PROFILE}"
        exit 1
    fi

    log_info "PrivateKey : ${WGCF_PRIVATE_KEY}"
    log_info "PeerPubKey : ${WGCF_PEER_PUBKEY}"
    log_info "Address    : ${WGCF_ADDRESS}"
    log_info "Endpoint   : ${WGCF_ENDPOINT}"
}

# ── 模块入口 ─────────────────────────────────────────────────
run_warp() {
    log_step "========== WARP WireGuard 凭证配置 =========="

    cleanup_old_warp
    install_wgcf
    generate_wgcf_profile
    parse_wgcf_credentials
    # 凭证持久化统一由 install.sh 的 save_state 负责（do_warp / run_full_install_flow）
    # warp.sh 不再自行写 state_file，避免格式冲突

    log_info "========== WARP 凭证配置完成 =========="
    echo ""
    log_info "凭证将由 Xray / Sing-Box 内嵌 wireguard 出站直接使用"
    log_info "无需额外代理进程，内存占用大幅降低"
    echo ""
    log_info "  PrivateKey : ${WGCF_PRIVATE_KEY}"
    log_info "  PeerPubKey : ${WGCF_PEER_PUBKEY}"
    log_info "  Address    : ${WGCF_ADDRESS}"
    log_info "  Endpoint   : ${WGCF_ENDPOINT}"
}