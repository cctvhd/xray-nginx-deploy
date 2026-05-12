#!/usr/bin/env bash
# ============================================================
# modules/hysteria2.sh
# Hysteria2 安装模块
# 官方脚本: https://get.hy2.sh/
# ============================================================

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
