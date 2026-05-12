#!/usr/bin/env bash
# ============================================================
# modules/hysteria2.sh
# Hysteria2 安装模块
# 官方脚本: https://get.hy2.sh/
# ============================================================

log_step() { echo -e "\e[36m[STEP]\e[0m $*"; }
log_info()  { echo -e "\e[32m[INFO]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*"; }

install_hysteria2() {
    log_step "安装 Hysteria2（官方脚本）..."

    local official_script="https://get.hy2.sh/"

    bash -c "$(curl -fsSL "$official_script")"

    if ! command -v hysteria &>/dev/null; then
        log_error "Hysteria2 安装失败"
        exit 1
    fi

    local hy_ver
    hy_ver=$(hysteria version 2>&1 | grep -oP '[\d.]+' | head -1)
    log_info "Hysteria2 安装成功: v${hy_ver}"
}

# ── 模块入口 ─────────────────────────────────────────────────
run_hysteria2() {
    log_step "========== Hysteria2 安装 =========="
    install_hysteria2
    log_info "========== Hysteria2 安装完成 =========="
}

# ── 直接执行入口 ─────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ $EUID -ne 0 ]] && { echo "必须使用 root 权限运行"; exit 1; }
    run_hysteria2
fi