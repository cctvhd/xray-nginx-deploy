#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xray-nginx-deploy 主入口
# GitHub: https://github.com/cctvhd/xray-nginx-deploy
# 运行: bash <(curl -fsSL https://raw.githubusercontent.com/cctvhd/xray-nginx-deploy/main/install.sh)
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

# ── 读取状态值 ───────────────────────────────────────────────
get_state() {
    local key="$1"
    local default="${2:-}"
    grep "^${key}=" "$STATE_FILE" 2>/dev/null | \
        head -1 | cut -d= -f2- | \
        sed "s/^['\"]//;s/['\"]$//" || echo "$default"
}

# ── 保存状态值 ───────────────────────────────────────────────
save_state() {
    local key="$1"
    local value="$2"
    local escaped
    escaped=$(echo "$value" | sed "s/'/'\\\\''/g")
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}='${escaped}'|" "$STATE_FILE"
    else
        echo "${key}='${escaped}'" >> "$STATE_FILE"
    fi
}

# ── 获取步骤状态 ─────────────────────────────────────────────
get_step() {
    get_state "$1" "0"
}

# ── 初始化状态文件 ───────────────────────────────────────────
init_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'ENV'
# xray-nginx-deploy 状态文件
# 自动生成，请勿手动编辑关键字段

# 系统信息
OS_ID=''
OS_NAME=''
PKG_MANAGER=''
BBR_VERSION=''

# 硬件配置
HW_CPU_CORES=''
HW_MEM_GB=''
HW_BANDWIDTH=''
HW_DUAL_STACK=''
HW_DISK_TYPE=''

# xray 网络参数（由 system 模块计算）
XRAY_PADDING=''
XRAY_WINDOW_CLAMP=''

# 域名信息（由 cert 模块写入）
XHTTP_DOMAIN=''
GRPC_DOMAIN=''
REALITY_DOMAIN=''
ANYTLS_DOMAIN=''
ALL_DOMAINS=''
CDN_DOMAINS=''
DIRECT_DOMAINS=''
XHTTP_PATH=''

# Xray 参数（由 xray 模块写入）
XRAY_UUID=''
XRAY_PUBLIC_KEY=''
XRAY_PRIVATE_KEY=''
REALITY_DEST=''
REALITY_SNI=''
REALITY_SHORT_ID=''
REALITY_SPIDER_X=''

# Sing-Box 参数
SINGBOX_PASSWORD=''
WARP_PROXY_PORT='40000'

# 安装状态
INST_SYSTEM='0'
INST_UNBOUND='0'
INST_NGINX='0'
INST_CERT='0'
INST_XRAY='0'
INST_SINGBOX='0'
INST_WARP='0'

# 配置状态
CONF_NGINX='0'
CONF_XRAY='0'
CONF_SINGBOX='0'
CONF_WARP='0'
ENV
        log_info "状态文件已创建: $STATE_FILE"
    fi

    # 读取基础变量
    OS_ID=$(get_state "OS_ID")
    OS_NAME=$(get_state "OS_NAME")
    PKG_MANAGER=$(get_state "PKG_MANAGER")
    HW_CPU_CORES=$(get_state "HW_CPU_CORES")
    HW_MEM_GB=$(get_state "HW_MEM_GB")
    HW_BANDWIDTH=$(get_state "HW_BANDWIDTH")
    HW_DUAL_STACK=$(get_state "HW_DUAL_STACK")
    HW_DISK_TYPE=$(get_state "HW_DISK_TYPE")
    XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
    GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
    REALITY_DOMAIN=$(get_state "REALITY_DOMAIN")
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    XRAY_UUID=$(get_state "XRAY_UUID")
    XRAY_PUBLIC_KEY=$(get_state "XRAY_PUBLIC_KEY")
    SINGBOX_PASSWORD=$(get_state "SINGBOX_PASSWORD")
    XRAY_PADDING=$(get_state "XRAY_PADDING")
    XRAY_WINDOW_CLAMP=$(get_state "XRAY_WINDOW_CLAMP")
    WARP_PROXY_PORT=$(get_state "WARP_PROXY_PORT" "40000")
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

# ── 加载系统基础信息 ─────────────────────────────────────────
load_os_info() {
    if [[ -n "${OS_ID:-}" ]]; then
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

# ── 显示安装状态 ─────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${BLUE}── 安装状态 ───────────────────────────────${NC}"

    local inst_items=(
        "INST_SYSTEM:系统初始化"
        "INST_UNBOUND:Unbound DNS"
        "INST_NGINX:Nginx"
        "INST_CERT:SSL 证书"
        "INST_XRAY:Xray"
        "INST_SINGBOX:Sing-Box"
        "INST_WARP:Cloudflare WARP"
    )

    echo -e "  ${CYAN}[ 安装 ]${NC}"
    for item in "${inst_items[@]}"; do
        local key="${item%%:*}"
        local name="${item##*:}"
        local val
        val=$(get_step "$key")
        if [[ "$val" == "1" ]]; then
            echo -e "    ${GREEN}[✓]${NC} ${name}"
        else
            echo -e "    ${RED}[✗]${NC} ${name}"
        fi
    done

    echo ""
    echo -e "  ${CYAN}[ 配置 ]${NC}"
    local conf_items=(
        "CONF_NGINX:Nginx 配置"
        "CONF_XRAY:Xray 配置"
        "CONF_SINGBOX:Sing-Box 配置"
        "CONF_WARP:WARP 配置"
    )
    for item in "${conf_items[@]}"; do
        local key="${item%%:*}"
        local name="${item##*:}"
        local val
        val=$(get_step "$key")
        if [[ "$val" == "1" ]]; then
            echo -e "    ${GREEN}[✓]${NC} ${name}"
        else
            echo -e "    ${RED}[✗]${NC} ${name}"
        fi
    done

    echo ""
    echo -e "  ${CYAN}[ 域名信息 ]${NC}"
    [[ -n "${XHTTP_DOMAIN:-}"   ]] && \
        echo -e "    xhttp:   ${CYAN}${XHTTP_DOMAIN}${NC}"
    [[ -n "${GRPC_DOMAIN:-}"    ]] && \
        echo -e "    gRPC:    ${CYAN}${GRPC_DOMAIN}${NC}"
    [[ -n "${REALITY_DOMAIN:-}" ]] && \
        echo -e "    Reality: ${CYAN}${REALITY_DOMAIN}${NC}"
    [[ -n "${ANYTLS_DOMAIN:-}"  ]] && \
        echo -e "    AnyTLS:  ${CYAN}${ANYTLS_DOMAIN}${NC}"

    [[ -n "${HW_CPU_CORES:-}" ]] && {
        echo ""
        echo -e "  ${CYAN}[ 硬件配置 ]${NC}"
        echo -e "    CPU: ${HW_CPU_CORES}核 | 内存: ${HW_MEM_GB}GB | 带宽: ${HW_BANDWIDTH} | IPv6: ${HW_DUAL_STACK} | 磁盘: ${HW_DISK_TYPE}"
    }

    echo -e "${BLUE}──────────────────────────────────────────${NC}"
    echo ""
}

# ── 主菜单 ───────────────────────────────────────────────────
main_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    Xray + Nginx + Sing-Box 部署工具        ║${NC}"
    echo -e "${BLUE}║    GitHub: cctvhd/xray-nginx-deploy        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

    show_status

    echo -e "  ${CYAN}=== 安装 ===${NC}"
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │  1. 系统初始化与优化                    │"
    echo "  │  2. 安装 Unbound（仅安装，手动配置）    │"
    echo "  │  3. 安装 Nginx                          │"
    echo "  │  4. 申请 SSL 证书                       │"
    echo "  │  5. 安装 Xray                           │"
    echo "  │  6. 安装 Sing-Box                       │"
    echo "  ├─────────────────────────────────────────┤"
    echo -e "  │  ${CYAN}=== 配置 ===${NC}                           │"
    echo "  │  7. 配置 Nginx                          │"
    echo "  │  8. 配置 Xray                           │"
    echo "  │  9. 配置 Sing-Box                       │"
    echo "  ├─────────────────────────────────────────┤"
    echo -e "  │  ${CYAN}=== 其他 ===${NC}                           │"
    echo "  │  a. 生成客户端连接链接                  │"
    echo "  │  b. 查看当前状态                        │"
    echo "  │  w. 安装/配置 Cloudflare WARP          │"
    echo "  ├─────────────────────────────────────────┤"
    echo "  │  0. 全量一键安装 (步骤 1-6)             │"
    echo "  │  q. 退出                                │"
    echo "  └─────────────────────────────────────────┘"
    echo ""
    echo -e "  再次运行: ${CYAN}bash <(curl -fsSL ${BASE_URL}/install.sh)${NC}"
    echo ""
    read -rp "  请选择: " choice
    echo ""

    case "$choice" in
        1) do_inst_system ;;
        2) do_inst_unbound ;;
        3) do_inst_nginx ;;
        4) do_inst_cert ;;
        5) do_inst_xray ;;
        6) do_inst_singbox ;;
        7) do_conf_nginx ;;
        8) do_conf_xray ;;
        9) do_conf_singbox ;;
        a|A) do_client ;;
        b|B) show_status
             read -rp "按回车返回菜单..." _
             main_menu ;;
        w|W) do_warp ;;
        0) do_full_install ;;
        q|Q) exit 0 ;;
        *) log_error "无效选择"
           sleep 1
           main_menu ;;
    esac
}

# ── 完成后返回菜单 ───────────────────────────────────────────
done_return() {
    echo ""
    read -rp "按回车返回菜单..." _
    init_state
    main_menu
}

# ============================================================
# 安装模块
# ============================================================

# ── 1. 系统初始化 ────────────────────────────────────────────
do_inst_system() {
    load_module system
    detect_os
    detect_kernel
    upgrade_kernel
    collect_hardware_info
    load_kernel_modules
    optimize_sysctl
    optimize_limits
    install_base_tools
    sync_time

    save_state "OS_ID"           "$OS_ID"
    save_state "OS_NAME"         "$OS_NAME"
    save_state "PKG_MANAGER"     "$PKG_MANAGER"
    save_state "BBR_VERSION"     "${BBR_VERSION:-bbr}"
    save_state "HW_CPU_CORES"    "$HW_CPU_CORES"
    save_state "HW_MEM_GB"       "$HW_MEM_GB"
    save_state "HW_BANDWIDTH"    "$HW_BANDWIDTH"
    save_state "HW_DUAL_STACK"   "$HW_DUAL_STACK"
    save_state "HW_DISK_TYPE"    "$HW_DISK_TYPE"
    save_state "XRAY_PADDING"    "${XRAY_PADDING:-128-2048}"
    save_state "XRAY_WINDOW_CLAMP" "${XRAY_WINDOW_CLAMP:-1200}"
    save_state "INST_SYSTEM"     "1"

    done_return
}

# ── 2. 安装 Unbound（仅安装）────────────────────────────────
do_inst_unbound() {
    load_os_info
    load_module unbound

    # 检测是否已安装
    if command -v unbound &>/dev/null; then
        log_info "Unbound 已安装: $(unbound -V 2>&1 | head -1)"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_UNBOUND" "1"
            log_info "跳过安装，Unbound 配置请手动完成"
            log_info "参考配置位置: /etc/unbound/conf.d/ 或 /etc/unbound/unbound.conf.d/"
            done_return
            return
        fi
    fi

    # 只执行安装，不生成配置
    install_unbound
    install_root_hints_updater
    setup_root_hints_updater

    save_state "INST_UNBOUND" "1"

    echo ""
    log_warn "Unbound 已安装，配置请手动完成"
    log_info "参考配置："
    echo "  AlmaLinux/Rocky: /etc/unbound/conf.d/*.conf"
    echo "  Ubuntu/Debian:   /etc/unbound/unbound.conf.d/*.conf"
    echo ""
    log_info "配置完成后执行："
    echo "  unbound-checkconf"
    echo "  systemctl enable --now unbound"

    done_return
}

# ── 3. 安装 Nginx ────────────────────────────────────────────
do_inst_nginx() {
    load_os_info
    load_module nginx

    # 检测是否已安装
    if command -v nginx &>/dev/null; then
        local ver
        ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)
        log_info "Nginx 已安装: v${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_NGINX" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf

    save_state "INST_NGINX" "1"
    done_return
}

# ── 4. 申请 SSL 证书 ─────────────────────────────────────────
do_inst_cert() {
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
    save_state "INST_CERT"      "1"

    done_return
}

# ── 5. 安装 Xray ─────────────────────────────────────────────
do_inst_xray() {
    load_os_info
    load_module xray

    # 检测是否已安装
    if command -v xray &>/dev/null; then
        local ver
        ver=$(xray version 2>&1 | grep -oP '[\d.]+' | head -1)
        log_info "Xray 已安装: v${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_XRAY" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_xray
    save_state "INST_XRAY" "1"

    log_info "Xray 安装完成，请继续执行步骤 8（配置 Xray）"
    done_return
}

# ── 6. 安装 Sing-Box ─────────────────────────────────────────
do_inst_singbox() {
    load_os_info
    load_module singbox

    # 检测是否已安装
    if command -v sing-box &>/dev/null; then
        local ver
        ver=$(sing-box version 2>&1 | grep -oP '[\d.]+' | head -1)
        log_info "Sing-Box 已安装: v${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_SINGBOX" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_singbox
    save_state "INST_SINGBOX" "1"

    log_info "Sing-Box 安装完成，请继续执行步骤 9（配置 Sing-Box）"
    done_return
}

# ============================================================
# 配置模块
# ============================================================

# ── 7. 配置 Nginx ────────────────────────────────────────────
do_conf_nginx() {
    # 检查依赖
    if [[ "$(get_step INST_NGINX)" != "1" ]]; then
        log_warn "请先完成步骤3（安装 Nginx）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "请先完成步骤4（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_os_info
    restore_domain_arrays

    # 方案A：XHTTP_PATH 为空时先生成并保存，后续复用
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    if [[ -z "${XHTTP_PATH}" ]]; then
        XHTTP_PATH="/$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
        save_state "XHTTP_PATH" "${XHTTP_PATH}"
        log_info "生成 XHTTP_PATH: ${XHTTP_PATH}"
    else
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    fi

    load_module nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    if [[ -n "${GRPC_DOMAIN:-}" ]]; then
        generate_fake_site "/var/www/${GRPC_DOMAIN}" "${GRPC_DOMAIN}"
    fi
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    generate_fallback_conf
    generate_servers_conf
    generate_nginx_conf
    reload_nginx

    save_state "CONF_NGINX" "1"
    done_return
}

# ── 8. 配置 Xray ─────────────────────────────────────────────
do_conf_xray() {
    # 检查依赖
    if [[ "$(get_step INST_XRAY)" != "1" ]]; then
        log_warn "请先完成步骤5（安装 Xray）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    if [[ "$(get_step CONF_NGINX)" != "1" ]]; then
        log_warn "建议先完成步骤7（配置 Nginx）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_os_info
    restore_domain_arrays

    # 读取硬件相关参数
    XRAY_PADDING=$(get_state "XRAY_PADDING" "128-2048")
    XRAY_WINDOW_CLAMP=$(get_state "XRAY_WINDOW_CLAMP" "1200")

    load_module xray
    # 复用已有 XHTTP_PATH，不重新生成
    local saved_path
    saved_path=$(get_state "XHTTP_PATH")
    if [[ -n "${saved_path}" ]]; then
        XHTTP_PATH="${saved_path}"
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    fi
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
    save_state "CONF_XRAY"        "1"

    done_return
}

# ── 9. 配置 Sing-Box ─────────────────────────────────────────
do_conf_singbox() {
    # 检查依赖
    if [[ "$(get_step INST_SINGBOX)" != "1" ]]; then
        log_warn "请先完成步骤6（安装 Sing-Box）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "建议先完成步骤4（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    if [[ "$(get_step CONF_NGINX)" != "1" ]]; then
        log_warn "建议先完成步骤7（配置 Nginx），AnyTLS 依赖 443 SNI 分流"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_os_info
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")

    load_module singbox
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox

    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "CONF_SINGBOX"     "1"

    done_return
}

# ── a. 生成客户端链接 ────────────────────────────────────────
do_client() {
    load_module client
    run_client
    done_return
}

# ── w. 安装/配置 Cloudflare WARP ─────────────────────────────
do_warp() {
    load_os_info
    load_module warp
    WARP_PROXY_PORT=$(get_state "WARP_PROXY_PORT" "40000")
    run_warp

    save_state "WARP_PROXY_PORT" "${WARP_PROXY_PORT:-40000}"
    save_state "INST_WARP"       "1"
    save_state "CONF_WARP"       "1"

    done_return
}

# ── 0. 全量安装 ──────────────────────────────────────────────
do_full_install() {
    log_step "开始全量安装..."
    echo ""

    # 安装阶段
    load_module system
    detect_os
    detect_kernel
    upgrade_kernel
    collect_hardware_info
    load_kernel_modules
    optimize_sysctl
    optimize_limits
    install_base_tools
    sync_time
    save_state "OS_ID"             "$OS_ID"
    save_state "OS_NAME"           "$OS_NAME"
    save_state "PKG_MANAGER"       "$PKG_MANAGER"
    save_state "BBR_VERSION"       "${BBR_VERSION:-bbr}"
    save_state "HW_CPU_CORES"      "$HW_CPU_CORES"
    save_state "HW_MEM_GB"         "$HW_MEM_GB"
    save_state "HW_BANDWIDTH"      "$HW_BANDWIDTH"
    save_state "HW_DUAL_STACK"     "$HW_DUAL_STACK"
    save_state "HW_DISK_TYPE"      "$HW_DISK_TYPE"
    save_state "XRAY_PADDING"      "${XRAY_PADDING:-128-2048}"
    save_state "XRAY_WINDOW_CLAMP" "${XRAY_WINDOW_CLAMP:-1200}"
    save_state "INST_SYSTEM"       "1"

    # Unbound 只安装不配置
    load_module unbound
    install_unbound
    save_state "INST_UNBOUND" "1"
    log_warn "Unbound 已安装，请手动配置后再继续"
    log_info "配置完成后重新运行脚本选择后续步骤"
    done_return
    return
}

# ── 入口 ─────────────────────────────────────────────────────
check_root
init_state
main_menu
