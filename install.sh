#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xray-nginx-deploy 主入口
# GitHub: https://github.com/cctvhd/xray-nginx-deploy
# ============================================================

BASE_URL="https://raw.githubusercontent.com/cctvhd/xray-nginx-deploy/main"
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"
STATE_FILE="/etc/xray-deploy/config.env"
STATE_DIR="/etc/xray-deploy"

# ── 颜色定义 ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

# ── 检查 root 权限 ───────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# ── 初始化状态目录 ───────────────────────────────────────────
init_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    # 如果状态文件不存在则创建
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'ENV'
# ============================================================
# xray-nginx-deploy 状态文件
# 各模块共享的配置参数
# ============================================================

# 系统信息（由 system 模块写入）
OS_ID=""
OS_NAME=""
PKG_MANAGER=""
BBR_VERSION=""

# 域名信息（由 cert 模块写入）
XHTTP_DOMAIN=""
GRPC_DOMAIN=""
REALITY_DOMAIN=""
ANYTLS_DOMAIN=""
ALL_DOMAINS=""
CDN_DOMAINS=""
DIRECT_DOMAINS=""

# Xray 参数（由 xray 模块写入）
XRAY_UUID=""
XRAY_PUBLIC_KEY=""
XRAY_PRIVATE_KEY=""
XHTTP_PATH=""
REALITY_DEST=""
REALITY_SNI=""
REALITY_SHORT_ID=""
REALITY_SPIDER_X=""

# Sing-Box 参数（由 singbox 模块写入）
SINGBOX_PASSWORD=""

# 安装状态标记
STEP_SYSTEM=0
STEP_UNBOUND=0
STEP_NGINX_INSTALL=0
STEP_CERT=0
STEP_NGINX_CONFIG=0
STEP_XRAY=0
STEP_SINGBOX=0
ENV
        log_info "状态文件已创建: $STATE_FILE"
    fi

    # 加载状态文件
    source "$STATE_FILE"
}

# ── 保存状态 ─────────────────────────────────────────────────
save_state() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
    else
        echo "${key}=${value}" >> "$STATE_FILE"
    fi
}

# ── 加载模块（本地或远程）───────────────────────────────────
load_module() {
    local module="$1"
    local local_path="${MODULES_DIR}/${module}.sh"
    local remote_url="${BASE_URL}/modules/${module}.sh"

    if [[ -f "$local_path" ]]; then
        # shellcheck source=/dev/null
        source "$local_path"
    else
        source <(curl -fsSL "$remote_url")
    fi
}

# ── 显示当前安装状态 ─────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${BLUE}── 当前安装状态 ──────────────────────────${NC}"

    local steps=(
        "STEP_SYSTEM:系统初始化"
        "STEP_UNBOUND:Unbound DNS"
        "STEP_NGINX_INSTALL:Nginx 安装"
        "STEP_CERT:SSL 证书"
        "STEP_NGINX_CONFIG:Nginx 配置"
        "STEP_XRAY:Xray"
        "STEP_SINGBOX:Sing-Box"
    )

    for item in "${steps[@]}"; do
        local key="${item%%:*}"
        local name="${item##*:}"
        local val
        val=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | \
              cut -d= -f2 || echo "0")

        if [[ "$val" == "1" ]]; then
            echo -e "  ${GREEN}[✓]${NC} ${name}"
        else
            echo -e "  ${RED}[✗]${NC} ${name}"
        fi
    done

    echo ""

    # 显示关键域名信息
    if [[ -n "${XHTTP_DOMAIN:-}" ]]; then
        echo -e "  xhttp 域名:   ${CYAN}${XHTTP_DOMAIN}${NC}"
    fi
    if [[ -n "${GRPC_DOMAIN:-}" ]]; then
        echo -e "  gRPC  域名:   ${CYAN}${GRPC_DOMAIN}${NC}"
    fi
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        echo -e "  Reality 域名: ${CYAN}${REALITY_DOMAIN}${NC}"
    fi
    if [[ -n "${ANYTLS_DOMAIN:-}" ]]; then
        echo -e "  AnyTLS 域名:  ${CYAN}${ANYTLS_DOMAIN}${NC}"
    fi
    echo -e "${BLUE}──────────────────────────────────────────${NC}"
    echo ""
}

# ── 主菜单 ───────────────────────────────────────────────────
main_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Xray + Nginx + Sing-Box 部署工具     ║${NC}"
    echo -e "${BLUE}║   GitHub: cctvhd/xray-nginx-deploy     ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"

    show_status

    echo "  部署步骤："
    echo "  ┌─────────────────────────────────────┐"
    echo "  │  1. 系统初始化与优化                │"
    echo "  │  2. 安装配置 Unbound 本地递归 DNS   │"
    echo "  │  3. 安装 Nginx                      │"
    echo "  │  4. 申请 SSL 证书                   │"
    echo "  │  5. 配置 Nginx                      │"
    echo "  │  6. 安装配置 Xray                   │"
    echo "  │  7. 安装配置 Sing-Box               │"
    echo "  ├─────────────────────────────────────┤"
    echo "  │  8. 生成客户端连接链接              │"
    echo "  │  9. 查看当前状态                    │"
    echo "  ├─────────────────────────────────────┤"
    echo "  │  0. 全量一键安装 (步骤 1-7)         │"
    echo "  │  q. 退出                            │"
    echo "  └─────────────────────────────────────┘"
    echo ""
    read -rp "  请选择 [0-9/q]: " choice
    echo ""

    case "$choice" in
        1) step_system ;;
        2) step_unbound ;;
        3) step_nginx_install ;;
        4) step_cert ;;
        5) step_nginx_config ;;
        6) step_xray ;;
        7) step_singbox ;;
        8) step_client ;;
        9) show_status; read -rp "按回车返回菜单..." _; main_menu ;;
        0) full_install ;;
        q|Q) exit 0 ;;
        *) log_error "无效选择，请重新输入"
           sleep 1
           main_menu ;;
    esac
}

# ── 步骤1：系统初始化 ────────────────────────────────────────
step_system() {
    load_module system
    detect_os
    detect_kernel
    upgrade_kernel
    install_base_tools
    sync_time
    optimize_sysctl
    optimize_limits

    # 保存系统信息到状态文件
    save_state "OS_ID" "$OS_ID"
    save_state "OS_NAME" "$OS_NAME"
    save_state "PKG_MANAGER" "$PKG_MANAGER"
    save_state "BBR_VERSION" "${BBR_VERSION:-bbr}"
    save_state "STEP_SYSTEM" "1"

    log_info "系统初始化完成"
    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 步骤2：Unbound ───────────────────────────────────────────
step_unbound() {
    if [[ "${STEP_SYSTEM:-0}" != "1" ]]; then
        log_warn "建议先完成步骤1（系统初始化）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_module system
    detect_os

    load_module unbound
    run_unbound

    save_state "STEP_UNBOUND" "1"
    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 步骤3：安装 Nginx ────────────────────────────────────────
step_nginx_install() {
    if [[ "${STEP_SYSTEM:-0}" != "1" ]]; then
        log_warn "建议先完成步骤1（系统初始化）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_module system
    detect_os

    load_module nginx
    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf

    save_state "STEP_NGINX_INSTALL" "1"
    log_info "Nginx 安装完成"
    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 步骤4：申请 SSL 证书 ─────────────────────────────────────
step_cert() {
    if [[ "${STEP_NGINX_INSTALL:-0}" != "1" ]]; then
        log_warn "建议先完成步骤3（安装 Nginx）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_module system
    detect_os

    load_module cert
    install_certbot
    setup_cf_accounts
    collect_domains
    request_certificates
    setup_auto_renew

    # 保存域名信息到状态文件
    save_state "XHTTP_DOMAIN"   "${XHTTP_DOMAIN:-}"
    save_state "GRPC_DOMAIN"    "${GRPC_DOMAIN:-}"
    save_state "REALITY_DOMAIN" "${REALITY_DOMAIN:-}"
    save_state "ANYTLS_DOMAIN"  "${ANYTLS_DOMAIN:-}"
    save_state "ALL_DOMAINS"    "${ALL_DOMAINS[*]:-}"
    save_state "CDN_DOMAINS"    "${CDN_DOMAINS[*]:-}"
    save_state "DIRECT_DOMAINS" "${DIRECT_DOMAINS[*]:-}"
    save_state "XHTTP_PATH"     "${XHTTP_PATH:-}"
    save_state "STEP_CERT"      "1"

    log_info "SSL 证书申请完成"
    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 步骤5：配置 Nginx ────────────────────────────────────────
step_nginx_config() {
    if [[ "${STEP_CERT:-0}" != "1" ]]; then
        log_warn "请先完成步骤4（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_module system
    detect_os

    # 从状态文件恢复域名信息
    read -ra ALL_DOMAINS    <<< "${ALL_DOMAINS:-}"
    read -ra CDN_DOMAINS    <<< "${CDN_DOMAINS:-}"
    read -ra DIRECT_DOMAINS <<< "${DIRECT_DOMAINS:-}"

    load_module nginx
    generate_fallback_conf
    generate_servers_conf
    generate_nginx_conf
    reload_nginx

    save_state "STEP_NGINX_CONFIG" "1"
    log_info "Nginx 配置完成"
    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 步骤6：安装配置 Xray ─────────────────────────────────────
step_xray() {
    if [[ "${STEP_NGINX_CONFIG:-0}" != "1" ]]; then
        log_warn "建议先完成步骤5（配置 Nginx）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_module system
    detect_os

    load_module xray
    install_xray
    generate_xray_params
    collect_reality_params
    generate_xray_config
    start_xray

    # 保存 Xray 参数到状态文件
    save_state "XRAY_UUID"        "${XRAY_UUID:-}"
    save_state "XRAY_PUBLIC_KEY"  "${XRAY_PUBLIC_KEY:-}"
    save_state "XRAY_PRIVATE_KEY" "${XRAY_PRIVATE_KEY:-}"
    save_state "XHTTP_PATH"       "${XHTTP_PATH:-}"
    save_state "REALITY_DEST"     "${REALITY_DEST:-}"
    save_state "REALITY_SNI"      "${REALITY_SERVER_NAMES[0]:-}"
    save_state "REALITY_SHORT_ID" "${REALITY_SHORT_IDS[1]:-}"
    save_state "REALITY_SPIDER_X" "${REALITY_SPIDER_X:-}"
    save_state "STEP_XRAY"        "1"

    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 步骤7：安装配置 Sing-Box ─────────────────────────────────
step_singbox() {
    if [[ "${STEP_XRAY:-0}" != "1" ]]; then
        log_warn "建议先完成步骤6（安装配置 Xray）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_module system
    detect_os

    load_module singbox
    install_singbox
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox

    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "STEP_SINGBOX"     "1"

    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 步骤8：生成客户端链接 ────────────────────────────────────
step_client() {
    load_module client
    run_client

    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 全量安装 ─────────────────────────────────────────────────
full_install() {
    log_step "开始全量安装（步骤 1-7）..."
    echo ""

    load_module system
    detect_os
    detect_kernel
    upgrade_kernel
    install_base_tools
    sync_time
    optimize_sysctl
    optimize_limits
    save_state "OS_ID"      "$OS_ID"
    save_state "OS_NAME"    "$OS_NAME"
    save_state "PKG_MANAGER" "$PKG_MANAGER"
    save_state "BBR_VERSION" "${BBR_VERSION:-bbr}"
    save_state "STEP_SYSTEM" "1"

    load_module unbound
    run_unbound
    save_state "STEP_UNBOUND" "1"

    load_module nginx
    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    save_state "STEP_NGINX_INSTALL" "1"

    load_module cert
    install_certbot
    setup_cf_accounts
    collect_domains
    request_certificates
    setup_auto_renew
    save_state "XHTTP_DOMAIN"   "${XHTTP_DOMAIN:-}"
    save_state "GRPC_DOMAIN"    "${GRPC_DOMAIN:-}"
    save_state "REALITY_DOMAIN" "${REALITY_DOMAIN:-}"
    save_state "ANYTLS_DOMAIN"  "${ANYTLS_DOMAIN:-}"
    save_state "ALL_DOMAINS"    "${ALL_DOMAINS[*]:-}"
    save_state "CDN_DOMAINS"    "${CDN_DOMAINS[*]:-}"
    save_state "DIRECT_DOMAINS" "${DIRECT_DOMAINS[*]:-}"
    save_state "STEP_CERT"      "1"

    read -ra ALL_DOMAINS    <<< "${ALL_DOMAINS:-}"
    read -ra CDN_DOMAINS    <<< "${CDN_DOMAINS:-}"
    read -ra DIRECT_DOMAINS <<< "${DIRECT_DOMAINS:-}"

    generate_fallback_conf
    generate_servers_conf
    generate_nginx_conf
    reload_nginx
    save_state "STEP_NGINX_CONFIG" "1"

    read -rp "是否安装配置 Xray？[Y/n]: " install_xray_choice
    if [[ "${install_xray_choice,,}" != "n" ]]; then
        load_module xray
        install_xray
        generate_xray_params
        collect_reality_params
        generate_xray_config
        start_xray
        save_state "XRAY_UUID"        "${XRAY_UUID:-}"
        save_state "XRAY_PUBLIC_KEY"  "${XRAY_PUBLIC_KEY:-}"
        save_state "XRAY_PRIVATE_KEY" "${XRAY_PRIVATE_KEY:-}"
        save_state "XHTTP_PATH"       "${XHTTP_PATH:-}"
        save_state "REALITY_DEST"     "${REALITY_DEST:-}"
        save_state "REALITY_SNI"      "${REALITY_SERVER_NAMES[0]:-}"
        save_state "REALITY_SHORT_ID" "${REALITY_SHORT_IDS[1]:-}"
        save_state "REALITY_SPIDER_X" "${REALITY_SPIDER_X:-}"
        save_state "STEP_XRAY"        "1"
    fi

    read -rp "是否安装配置 Sing-Box？[Y/n]: " install_sb_choice
    if [[ "${install_sb_choice,,}" != "n" ]]; then
        load_module singbox
        install_singbox
        generate_singbox_params
        collect_singbox_params
        generate_singbox_config
        start_singbox
        save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
        save_state "STEP_SINGBOX"     "1"
    fi

    load_module client
    run_client

    echo ""
    log_info "全量安装完成！"
    log_info "客户端链接已保存到: /root/xray_client_links.txt"
    echo ""
    read -rp "按回车返回菜单..." _
    main_menu
}

# ── 入口 ─────────────────────────────────────────────────────
check_root
init_state
main_menu
