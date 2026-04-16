#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xray-nginx-deploy 主入口
# GitHub: https://github.com/cctvhd/xray-nginx-deploy
# ============================================================

BASE_URL="https://raw.githubusercontent.com/cctvhd/xray-nginx-deploy/main"
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"
STATE_DIR="/etc/xray-deploy"
STATE_FILE="${STATE_DIR}/config.env"

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

# ── 读取状态值（安全方式，不 source 文件）───────────────────
get_state() {
    local key="$1"
    local default="${2:-}"
    grep "^${key}=" "$STATE_FILE" 2>/dev/null | \
        head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || \
        echo "$default"
}

# ── 保存状态（转义特殊字符）─────────────────────────────────
save_state() {
    local key="$1"
    local value="$2"

    # 转义值中的特殊字符，用单引号包裹
    local escaped
    escaped=$(echo "$value" | sed "s/'/'\\\\''/g")

    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}='${escaped}'|" "$STATE_FILE"
    else
        echo "${key}='${escaped}'" >> "$STATE_FILE"
    fi
}

# ── 初始化状态目录 ───────────────────────────────────────────
init_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'ENV'
OS_ID=''
OS_NAME=''
PKG_MANAGER=''
BBR_VERSION=''
XHTTP_DOMAIN=''
GRPC_DOMAIN=''
REALITY_DOMAIN=''
ANYTLS_DOMAIN=''
ALL_DOMAINS=''
CDN_DOMAINS=''
DIRECT_DOMAINS=''
XHTTP_PATH=''
XRAY_UUID=''
XRAY_PUBLIC_KEY=''
XRAY_PRIVATE_KEY=''
REALITY_DEST=''
REALITY_SNI=''
REALITY_SHORT_ID=''
REALITY_SPIDER_X=''
SINGBOX_PASSWORD=''
STEP_SYSTEM='0'
STEP_UNBOUND='0'
STEP_NGINX_INSTALL='0'
STEP_CERT='0'
STEP_NGINX_CONFIG='0'
STEP_XRAY='0'
STEP_SINGBOX='0'
ENV
        log_info "状态文件已创建: $STATE_FILE"
    fi

    # 读取基础变量（安全方式）
    OS_ID=$(get_state "OS_ID")
    OS_NAME=$(get_state "OS_NAME")
    PKG_MANAGER=$(get_state "PKG_MANAGER")
    XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
    GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
    REALITY_DOMAIN=$(get_state "REALITY_DOMAIN")
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    XRAY_UUID=$(get_state "XRAY_UUID")
    XRAY_PUBLIC_KEY=$(get_state "XRAY_PUBLIC_KEY")
    SINGBOX_PASSWORD=$(get_state "SINGBOX_PASSWORD")
}

# ── 获取步骤状态 ─────────────────────────────────────────────
get_step() {
    get_state "$1" "0"
}

# ── 检查步骤依赖 ─────────────────────────────────────────────
check_step() {
    local step_var="$1"
    local step_name="$2"
    local val
    val=$(get_step "$step_var")

    if [[ "$val" != "1" ]]; then
        log_warn "建议先完成：${step_name}"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return 1
    fi
    return 0
}

# ── 加载模块 ─────────────────────────────────────────────────
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

# ── 加载系统信息 ─────────────────────────────────────────────
load_os_info() {
    if [[ -n "$OS_ID" ]]; then
        case "$OS_ID" in
            ubuntu|debian)
                PKG_UPDATE="apt-get update -y"
                PKG_INSTALL="apt-get install -y"
                ;;
            centos|rhel|rocky|almalinux)
                PKG_UPDATE="dnf makecache -y"
                PKG_INSTALL="dnf install -y"
                ;;
        esac
    else
        load_module system
        detect_os
    fi
}

# ── 恢复域名数组 ─────────────────────────────────────────────
restore_domain_arrays() {
    local all_str cdn_str direct_str
    all_str=$(get_state "ALL_DOMAINS")
    cdn_str=$(get_state "CDN_DOMAINS")
    direct_str=$(get_state "DIRECT_DOMAINS")

    ALL_DOMAINS=()
    CDN_DOMAINS=()
    DIRECT_DOMAINS=()

    [[ -n "$all_str"    ]] && read -ra ALL_DOMAINS    <<< "$all_str"
    [[ -n "$cdn_str"    ]] && read -ra CDN_DOMAINS    <<< "$cdn_str"
    [[ -n "$direct_str" ]] && read -ra DIRECT_DOMAINS <<< "$direct_str"

    XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
    GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
    REALITY_DOMAIN=$(get_state "REALITY_DOMAIN")
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
}

# ── 显示当前状态 ─────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${BLUE}── 当前安装状态 ──────────────────────────${NC}"

    local steps=(
        "STEP_SYSTEM:1. 系统初始化"
        "STEP_UNBOUND:2. Unbound DNS"
        "STEP_NGINX_INSTALL:3. Nginx 安装"
        "STEP_CERT:4. SSL 证书"
        "STEP_NGINX_CONFIG:5. Nginx 配置"
        "STEP_XRAY:6. Xray"
        "STEP_SINGBOX:7. Sing-Box"
    )

    for item in "${steps[@]}"; do
        local key="${item%%:*}"
        local name="${item##*:}"
        local val
        val=$(get_step "$key")
        if [[ "$val" == "1" ]]; then
            echo -e "  ${GREEN}[✓]${NC} ${name}"
        else
            echo -e "  ${RED}[✗]${NC} ${name}"
        fi
    done

    echo ""
    [[ -n "$XHTTP_DOMAIN"   ]] && \
        echo -e "  xhttp 域名:   ${CYAN}${XHTTP_DOMAIN}${NC}"
    [[ -n "$GRPC_DOMAIN"    ]] && \
        echo -e "  gRPC  域名:   ${CYAN}${GRPC_DOMAIN}${NC}"
    [[ -n "$REALITY_DOMAIN" ]] && \
        echo -e "  Reality 域名: ${CYAN}${REALITY_DOMAIN}${NC}"
    [[ -n "$ANYTLS_DOMAIN"  ]] && \
        echo -e "  AnyTLS 域名:  ${CYAN}${ANYTLS_DOMAIN}${NC}"

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
    echo -e "  再次运行: ${CYAN}bash <(curl -fsSL ${BASE_URL}/install.sh)${NC}"
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
        9) show_status
           read -rp "按回车返回菜单..." _
           main_menu ;;
        0) full_install ;;
        q|Q) exit 0 ;;
        *) log_error "无效选择"
           sleep 1
           main_menu ;;
    esac
}

# ── 步骤完成返回 ─────────────────────────────────────────────
done_return() {
    echo ""
    read -rp "按回车返回菜单..." _
    # 重新读取状态
    init_state
    main_menu
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

    save_state "OS_ID"       "$OS_ID"
    save_state "OS_NAME"     "$OS_NAME"
    save_state "PKG_MANAGER" "$PKG_MANAGER"
    save_state "BBR_VERSION" "${BBR_VERSION:-bbr}"
    save_state "STEP_SYSTEM" "1"

    done_return
}

# ── 步骤2：Unbound ───────────────────────────────────────────
step_unbound() {
    check_step "STEP_SYSTEM" "步骤1（系统初始化）" || \
        { main_menu; return; }

    load_os_info
    load_module unbound
    run_unbound

    save_state "STEP_UNBOUND" "1"
    done_return
}

# ── 步骤3：安装 Nginx ────────────────────────────────────────
step_nginx_install() {
    check_step "STEP_SYSTEM" "步骤1（系统初始化）" || \
        { main_menu; return; }

    load_os_info
    load_module nginx
    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf

    save_state "STEP_NGINX_INSTALL" "1"
    done_return
}

# ── 步骤4：申请 SSL 证书 ─────────────────────────────────────
step_cert() {
    check_step "STEP_NGINX_INSTALL" "步骤3（安装 Nginx）" || \
        { main_menu; return; }

    load_os_info
    load_module cert
    run_cert

    save_state "XHTTP_DOMAIN"   "${XHTTP_DOMAIN:-}"
    save_state "GRPC_DOMAIN"    "${GRPC_DOMAIN:-}"
    save_state "REALITY_DOMAIN" "${REALITY_DOMAIN:-}"
    save_state "ANYTLS_DOMAIN"  "${ANYTLS_DOMAIN:-}"
    save_state "ALL_DOMAINS"    "${ALL_DOMAINS[*]:-}"
    save_state "CDN_DOMAINS"    "${CDN_DOMAINS[*]:-}"
    save_state "DIRECT_DOMAINS" "${DIRECT_DOMAINS[*]:-}"
    save_state "XHTTP_PATH"     "${XHTTP_PATH:-}"
    save_state "STEP_CERT"      "1"

    done_return
}

# ── 步骤5：配置 Nginx ────────────────────────────────────────
step_nginx_config() {
    check_step "STEP_CERT" "步骤4（申请 SSL 证书）" || \
        { main_menu; return; }

    load_os_info
    restore_domain_arrays

    load_module nginx
    generate_fallback_conf
    generate_servers_conf
    generate_nginx_conf
    reload_nginx

    save_state "STEP_NGINX_CONFIG" "1"
    done_return
}

# ── 步骤6：安装配置 Xray ─────────────────────────────────────
step_xray() {
    check_step "STEP_NGINX_CONFIG" "步骤5（配置 Nginx）" || \
        { main_menu; return; }

    load_os_info
    restore_domain_arrays

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

    done_return
}

# ── 步骤7：安装配置 Sing-Box ─────────────────────────────────
step_singbox() {
    check_step "STEP_XRAY" "步骤6（安装配置 Xray）" || \
        { main_menu; return; }

    load_os_info
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")

    load_module singbox
    install_singbox
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox

    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "STEP_SINGBOX"     "1"

    done_return
}

# ── 步骤8：生成客户端链接 ────────────────────────────────────
step_client() {
    load_module client
    run_client
    done_return
}

# ── 全量安装 ─────────────────────────────────────────────────
full_install() {
    log_step "开始全量安装（步骤 1-7）..."

    load_module system
    detect_os
    detect_kernel
    upgrade_kernel
    install_base_tools
    sync_time
    optimize_sysctl
    optimize_limits
    save_state "OS_ID"       "$OS_ID"
    save_state "OS_NAME"     "$OS_NAME"
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
    run_cert
    save_state "XHTTP_DOMAIN"   "${XHTTP_DOMAIN:-}"
    save_state "GRPC_DOMAIN"    "${GRPC_DOMAIN:-}"
    save_state "REALITY_DOMAIN" "${REALITY_DOMAIN:-}"
    save_state "ANYTLS_DOMAIN"  "${ANYTLS_DOMAIN:-}"
    save_state "ALL_DOMAINS"    "${ALL_DOMAINS[*]:-}"
    save_state "CDN_DOMAINS"    "${CDN_DOMAINS[*]:-}"
    save_state "DIRECT_DOMAINS" "${DIRECT_DOMAINS[*]:-}"
    save_state "XHTTP_PATH"     "${XHTTP_PATH:-}"
    save_state "STEP_CERT"      "1"

    restore_domain_arrays
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
        ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
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

    log_info "全量安装完成！"
    log_info "客户端链接已保存到: /root/xray_client_links.txt"
    done_return
}

# ── 入口 ─────────────────────────────────────────────────────
check_root
init_state
main_menu
