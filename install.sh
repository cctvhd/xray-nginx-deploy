#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xray-nginx-deploy main entry
# GitHub: https://github.com/cctvhd/xray-nginx-deploy
# ============================================================

BASE_URL="https://raw.githubusercontent.com/cctvhd/xray-nginx-deploy/main"
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"
STATE_DIR="/etc/xray-deploy"
STATE_FILE="${STATE_DIR}/config.env"

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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

get_state() {
    local key="$1"
    local default="${2:-}"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "$default"
        return
    fi

    local value
    value=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | \
        head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)

    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

save_state() {
    local key="$1"
    local value="$2"
    local escaped

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    touch "$STATE_FILE"
    chmod 600 "$STATE_FILE"

    escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
    # 先删除所有该 key 的行（防止重复行），再追加一行
    sed -i "/^${key}=/d" "$STATE_FILE" 2>/dev/null || true
    echo "${key}='${escaped}'" >> "$STATE_FILE"
}

get_step() {
    get_state "$1" "0"
}

# ── 根据实际服务状态自动补全 state ──────────────────────────
_sync_inst_state() {
    command -v nginx    &>/dev/null && [[ "$(get_step INST_NGINX)"   != "1" ]] && save_state "INST_NGINX"   "1" || true
    command -v xray     &>/dev/null && [[ "$(get_step INST_XRAY)"    != "1" ]] && save_state "INST_XRAY"    "1" || true
    command -v sing-box &>/dev/null && [[ "$(get_step INST_SINGBOX)" != "1" ]] && save_state "INST_SINGBOX" "1" || true
    command -v wgcf     &>/dev/null && [[ "$(get_step INST_WARP)"    != "1" ]] && save_state "INST_WARP"    "1" || true
    command -v unbound  &>/dev/null && [[ "$(get_step INST_UNBOUND)" != "1" ]] && save_state "INST_UNBOUND" "1" || true
    systemctl is-active --quiet nginx    2>/dev/null && [[ "$(get_step CONF_NGINX)"   != "1" ]] && save_state "CONF_NGINX"   "1" || true
    systemctl is-active --quiet xray     2>/dev/null && [[ "$(get_step CONF_XRAY)"    != "1" ]] && save_state "CONF_XRAY"    "1" || true
    systemctl is-active --quiet sing-box 2>/dev/null && [[ "$(get_step CONF_SINGBOX)" != "1" ]] && save_state "CONF_SINGBOX" "1" || true
    [[ -f /etc/wgcf/wgcf-profile.conf ]] && [[ -n "$(get_state WGCF_PRIVATE_KEY)" ]] && \
        [[ "$(get_step CONF_WARP)" != "1" ]] && save_state "CONF_WARP" "1" || true
}

init_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'ENV'
# xray-nginx-deploy state file
OS_ID=''
OS_NAME=''
PKG_MANAGER=''
BBR_VERSION=''

HW_CPU_CORES=''
HW_MEM_GB=''
HW_BANDWIDTH=''
HW_DUAL_STACK=''
HW_DISK_TYPE=''
UNBOUND_SERVICE_NAME=''

XRAY_PADDING=''

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

WGCF_PRIVATE_KEY=''
WGCF_PEER_PUBKEY=''
WGCF_ADDRESS=''
WGCF_ENDPOINT=''
WGCF_ENDPOINT_HOST=''
WGCF_ENDPOINT_PORT=''

INST_SYSTEM='0'
INST_UNBOUND='0'
INST_NGINX='0'
INST_CERT='0'
INST_XRAY='0'
INST_SINGBOX='0'
INST_WARP='0'

CONF_NGINX='0'
CONF_XRAY='0'
CONF_SINGBOX='0'
CONF_WARP='0'
ENV
        chmod 600 "$STATE_FILE"
        log_info "状态文件已创建: $STATE_FILE"
    fi

    OS_ID=$(get_state "OS_ID")
    OS_NAME=$(get_state "OS_NAME")
    PKG_MANAGER=$(get_state "PKG_MANAGER")
    HW_CPU_CORES=$(get_state "HW_CPU_CORES")
    HW_MEM_GB=$(get_state "HW_MEM_GB")
    HW_BANDWIDTH=$(get_state "HW_BANDWIDTH")
    HW_DUAL_STACK=$(get_state "HW_DUAL_STACK")
    HW_DISK_TYPE=$(get_state "HW_DISK_TYPE")
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")
    XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
    GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
    REALITY_DOMAIN=$(get_state "REALITY_DOMAIN")
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    XRAY_UUID=$(get_state "XRAY_UUID")
    XRAY_PUBLIC_KEY=$(get_state "XRAY_PUBLIC_KEY")
    SINGBOX_PASSWORD=$(get_state "SINGBOX_PASSWORD")
    XRAY_PADDING=$(get_state "XRAY_PADDING")

    # WARP / wgcf 凭证（供 xray.sh / singbox.sh 的 generate_*_config 直接使用）
    WGCF_PRIVATE_KEY=$(get_state "WGCF_PRIVATE_KEY")
    WGCF_PEER_PUBKEY=$(get_state "WGCF_PEER_PUBKEY")
    WGCF_ADDRESS=$(get_state "WGCF_ADDRESS")
    WGCF_ENDPOINT=$(get_state "WGCF_ENDPOINT")
    WGCF_ENDPOINT_HOST=$(get_state "WGCF_ENDPOINT_HOST")
    WGCF_ENDPOINT_PORT=$(get_state "WGCF_ENDPOINT_PORT")

    # 根据实际服务状态自动补全 state（解决手动配置后状态栏不正常问题）
    _sync_inst_state
}

load_module() {
    local module="$1"
    local local_path="${MODULES_DIR}/${module}.sh"
    local remote_url="${BASE_URL}/modules/${module}.sh"

    if [[ -f "$local_path" ]]; then
        # shellcheck source=/dev/null
        source "$local_path"
    else
        # shellcheck source=/dev/null
        source <(curl -fsSL "$remote_url")
    fi
}

load_os_info() {
    if [[ -n "${OS_ID:-}" ]]; then
        case "$OS_ID" in
            ubuntu|debian)
                PKG_UPDATE="apt-get update -y"
                PKG_INSTALL="apt-get install -y"
                ;;
            centos|rhel|rocky|almalinux|fedora)
                PKG_UPDATE="dnf makecache -y"
                PKG_INSTALL="dnf install -y"
                ;;
        esac
        return
    fi

    load_module system
    detect_os
}

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

refresh_unbound_after_cert() {
    if ! command -v unbound &>/dev/null; then
        return 0
    fi

    load_module unbound

    if ! check_unbound_installed; then
        log_warn "Unbound 已安装但当前未运行，跳过自动刷新，请先执行步骤 2 修复 Unbound"
        return 0
    fi

    restore_domain_arrays
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")
    if refresh_unbound_generated_config; then
        log_info "Unbound 配置已按当前设置刷新"
    else
        log_warn "Unbound 配置刷新失败，请先根据上面的诊断信息修复后再执行步骤 2"
    fi
}

show_status() {
    local s_system s_unbound s_nginx s_cert s_xray s_singbox s_warp
    local c_nginx c_xray c_singbox c_warp

    # 安装状态：state=1 OR 实际检测到，取其一即为 OK
    { [[ "$(get_step INST_SYSTEM)"  == "1" ]] || \
      sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q 'bbr'; } \
      && s_system="OK"  || s_system="--"

    { [[ "$(get_step INST_UNBOUND)" == "1" ]] || \
      command -v unbound &>/dev/null; } \
      && s_unbound="OK" || s_unbound="--"

    { [[ "$(get_step INST_NGINX)"   == "1" ]] || \
      command -v nginx &>/dev/null; } \
      && s_nginx="OK"   || s_nginx="--"

    { [[ "$(get_step INST_CERT)"    == "1" ]] || \
      find /etc/ssl/xray-deploy -name '*.pem' -quit 2>/dev/null | grep -q . || \
      find "${HOME}/.acme.sh" -name '*.cer' -quit 2>/dev/null | grep -q .; } \
      && s_cert="OK"    || s_cert="--"

    { [[ "$(get_step INST_XRAY)"    == "1" ]] || \
      command -v xray &>/dev/null; } \
      && s_xray="OK"    || s_xray="--"

    { [[ "$(get_step INST_SINGBOX)" == "1" ]] || \
      command -v sing-box &>/dev/null; } \
      && s_singbox="OK" || s_singbox="--"

    { [[ "$(get_step INST_WARP)"    == "1" ]] || \
      command -v wgcf &>/dev/null; } \
      && s_warp="OK"    || s_warp="--"

    # 配置状态：state=1 OR 服务正在运行，取其一即为 OK
    { [[ "$(get_step CONF_NGINX)"   == "1" ]] || \
      systemctl is-active --quiet nginx 2>/dev/null; } \
      && c_nginx="OK"   || c_nginx="--"

    { [[ "$(get_step CONF_XRAY)"    == "1" ]] || \
      systemctl is-active --quiet xray 2>/dev/null; } \
      && c_xray="OK"    || c_xray="--"

    { [[ "$(get_step CONF_SINGBOX)" == "1" ]] || \
      systemctl is-active --quiet sing-box 2>/dev/null; } \
      && c_singbox="OK" || c_singbox="--"

    { [[ "$(get_step CONF_WARP)"    == "1" ]] || \
      [[ -f /etc/wgcf/wgcf-profile.conf ]]; } \
      && c_warp="OK"    || c_warp="--"

    echo ""
    echo -e "${BLUE}================ 当前状态 ================${NC}"
    echo "  [安装]"
    printf "    %-20s %s\n" "System"   "${s_system}"
    printf "    %-20s %s\n" "Unbound"  "${s_unbound}"
    printf "    %-20s %s\n" "Nginx"    "${s_nginx}"
    printf "    %-20s %s\n" "Cert"     "${s_cert}"
    printf "    %-20s %s\n" "Xray"     "${s_xray}"
    printf "    %-20s %s\n" "Sing-Box" "${s_singbox}"
    printf "    %-20s %s\n" "WARP"     "${s_warp}"

    echo ""
    echo "  [配置]"
    printf "    %-20s %s\n" "Nginx"    "${c_nginx}"
    printf "    %-20s %s\n" "Xray"     "${c_xray}"
    printf "    %-20s %s\n" "Sing-Box" "${c_singbox}"
    printf "    %-20s %s\n" "WARP"     "${c_warp}"

    echo ""
    echo "  [域名]"
    [[ -n "${XHTTP_DOMAIN:-}"   ]] && echo "    xhttp   : ${XHTTP_DOMAIN}"
    [[ -n "${GRPC_DOMAIN:-}"    ]] && echo "    gRPC    : ${GRPC_DOMAIN}"
    [[ -n "${REALITY_DOMAIN:-}" ]] && echo "    Reality : ${REALITY_DOMAIN}"
    [[ -n "${ANYTLS_DOMAIN:-}"  ]] && echo "    AnyTLS  : ${ANYTLS_DOMAIN}"

    if [[ -n "${HW_CPU_CORES:-}" ]]; then
        echo ""
        echo "  [硬件]"
        echo "    CPU: ${HW_CPU_CORES} | MEM: ${HW_MEM_GB}GB | BW: ${HW_BANDWIDTH} | STACK: ${HW_DUAL_STACK} | DISK: ${HW_DISK_TYPE}"
    fi

    echo -e "${BLUE}==========================================${NC}"
    echo ""
}

main_menu() {
    clear
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}   Xray + Nginx + Sing-Box 部署工具${NC}"
    echo -e "${BLUE}   GitHub: cctvhd/xray-nginx-deploy${NC}"
    echo -e "${BLUE}==========================================${NC}"

    show_status

    echo "  === 安装 ==="
    echo "  1. 系统初始化与优化"
    echo "  2. 安装并配置 Unbound"
    echo "  3. 安装 Nginx"
    echo "  4. 申请 SSL 证书"
    echo "  5. 安装 Xray"
    echo "  6. 安装 Sing-Box"
    echo ""
    echo "  === 配置 ==="
    echo "  7. 配置 Nginx"
    echo "  8. 配置 Xray"
    echo "  9. 配置 Sing-Box"
    echo ""
    echo "  === 其他 ==="
    echo "  a. 生成客户端链接"
    echo "  b. 查看当前状态"
    echo "  w. 配置 WARP WireGuard 凭证（步骤 8/9 的前置依赖）"
    echo "  u. 卸载 / 清理模块"
    echo "  r. 全部重装（先清理再执行 1-9）"
    echo "  0. 全流程一键安装（步骤 1-9）"
    echo "  q. 退出"
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
        b|B)
            show_status
            read -rp "按回车返回主菜单..." _
            main_menu
            ;;
        w|W) do_warp ;;
        u|U) do_uninstall_menu ;;
        r|R) do_reinstall_all ;;
        0) do_full_install ;;
        q|Q) exit 0 ;;
        *)
            log_error "无效选择"
            sleep 1
            main_menu
            ;;
    esac
}

# ── WGCF 凭证保障：若变量为空则先从 state 恢复，仍空则触发 run_warp ──────
_ensure_wgcf() {
    [[ -z "${WGCF_PRIVATE_KEY:-}"   ]] && WGCF_PRIVATE_KEY=$(get_state "WGCF_PRIVATE_KEY")
    [[ -z "${WGCF_PEER_PUBKEY:-}"   ]] && WGCF_PEER_PUBKEY=$(get_state "WGCF_PEER_PUBKEY")
    [[ -z "${WGCF_ADDRESS:-}"       ]] && WGCF_ADDRESS=$(get_state "WGCF_ADDRESS")
    [[ -z "${WGCF_ENDPOINT:-}"      ]] && WGCF_ENDPOINT=$(get_state "WGCF_ENDPOINT")
    [[ -z "${WGCF_ENDPOINT_HOST:-}" ]] && WGCF_ENDPOINT_HOST=$(get_state "WGCF_ENDPOINT_HOST")
    [[ -z "${WGCF_ENDPOINT_PORT:-}" ]] && WGCF_ENDPOINT_PORT=$(get_state "WGCF_ENDPOINT_PORT")

    if [[ -z "${WGCF_PRIVATE_KEY:-}" ]]; then
        log_warn "未找到 WARP WireGuard 凭证，自动执行 WARP 配置（菜单选项 w）..."
        load_os_info
        load_module warp
        run_warp
        WGCF_PRIVATE_KEY=$(get_state "WGCF_PRIVATE_KEY")
        WGCF_PEER_PUBKEY=$(get_state "WGCF_PEER_PUBKEY")
        WGCF_ADDRESS=$(get_state "WGCF_ADDRESS")
        WGCF_ENDPOINT=$(get_state "WGCF_ENDPOINT")
        WGCF_ENDPOINT_HOST=$(get_state "WGCF_ENDPOINT_HOST")
        WGCF_ENDPOINT_PORT=$(get_state "WGCF_ENDPOINT_PORT")
        save_state "INST_WARP" "1"
        save_state "CONF_WARP" "1"
    fi
}

done_return() {
    echo ""
    read -rp "按回车返回主菜单..." _
    init_state
    main_menu
}

do_inst_system() {
    load_module system
    detect_os
    detect_kernel
    upgrade_kernel
    collect_hardware_info
    load_kernel_modules
    tune_system_limits
    install_base_tools
    sync_time

    save_state "OS_ID"        "$OS_ID"
    save_state "OS_NAME"      "$OS_NAME"
    save_state "PKG_MANAGER"  "$PKG_MANAGER"
    save_state "BBR_VERSION"  "${BBR_VERSION:-bbr}"
    save_state "HW_CPU_CORES" "$HW_CPU_CORES"
    save_state "HW_MEM_GB"    "$HW_MEM_GB"
    save_state "HW_BANDWIDTH" "$HW_BANDWIDTH"
    save_state "HW_DUAL_STACK" "$HW_DUAL_STACK"
    save_state "HW_DISK_TYPE" "$HW_DISK_TYPE"
    save_state "XRAY_PADDING" "${XRAY_PADDING:-128-2048}"
    save_state "INST_SYSTEM"  "1"

    done_return
}

do_inst_unbound() {
    load_os_info
    load_module unbound
    restore_domain_arrays
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")
    run_unbound

    save_state "HW_DUAL_STACK"        "${HW_DUAL_STACK:-}"
    save_state "UNBOUND_SERVICE_NAME" "${UNBOUND_SERVICE_NAME:-}"
    save_state "INST_UNBOUND"         "1"
    done_return
}

do_inst_nginx() {
    load_os_info
    load_module nginx

    if command -v nginx &>/dev/null; then
        local ver reinstall
        ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1 || true)
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

    if [[ "$(get_step INST_UNBOUND)" == "1" ]] || command -v unbound &>/dev/null; then
        refresh_unbound_after_cert
    fi

    done_return
}

do_inst_xray() {
    load_os_info
    load_module xray

    if command -v xray &>/dev/null; then
        local ver reinstall
        ver=$(xray version 2>&1 | grep -oP '[\d.]+' | head -1 || true)
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

    log_info "Xray 安装完成，请继续执行步骤 8"
    done_return
}

do_inst_singbox() {
    load_os_info
    load_module singbox

    if command -v sing-box &>/dev/null; then
        local ver reinstall
        ver=$(sing-box version 2>&1 | grep -oP '[\d.]+' | head -1 || true)
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

    log_info "Sing-Box 安装完成，请继续执行步骤 9"
    done_return
}

do_conf_nginx() {
    if [[ "$(get_step INST_NGINX)" != "1" ]] && ! command -v nginx &>/dev/null; then
        log_warn "请先完成步骤 3（安装 Nginx）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi
    if command -v nginx &>/dev/null && [[ "$(get_step INST_NGINX)" != "1" ]]; then
        save_state "INST_NGINX" "1"
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "请先完成步骤 4（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_os_info
    restore_domain_arrays

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
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater

    save_state "CONF_NGINX" "1"
    done_return
}

do_conf_xray() {
    if [[ "$(get_step INST_XRAY)" != "1" ]] && ! command -v xray &>/dev/null; then
        log_warn "请先完成步骤 5（安装 Xray）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi
    if command -v xray &>/dev/null && [[ "$(get_step INST_XRAY)" != "1" ]]; then
        save_state "INST_XRAY" "1"
    fi

    if [[ "$(get_step CONF_NGINX)" != "1" ]] && ! command -v nginx &>/dev/null; then
        log_warn "建议先完成步骤 7（配置 Nginx）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_os_info
    restore_domain_arrays
    XRAY_PADDING=$(get_state "XRAY_PADDING" "128-2048")

    _ensure_wgcf

    load_module xray
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

do_conf_singbox() {
    if [[ "$(get_step INST_SINGBOX)" != "1" ]] && ! command -v sing-box &>/dev/null; then
        log_warn "请先完成步骤 6（安装 Sing-Box）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi
    if command -v sing-box &>/dev/null && [[ "$(get_step INST_SINGBOX)" != "1" ]]; then
        save_state "INST_SINGBOX" "1"
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "建议先完成步骤 4（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    if [[ "$(get_step CONF_NGINX)" != "1" ]]; then
        log_info "提示：Nginx 尚未配置（步骤 7），443 SNI 分流暂不可用；"
        log_info "      Sing-Box 本身可正常启动，待 Nginx 配置完成后流量即自动接通。"
    fi

    load_os_info
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")

    _ensure_wgcf

    load_module singbox
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox

    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "CONF_SINGBOX"     "1"

    done_return
}

do_client() {
    load_module client
    run_client
    done_return
}

do_warp() {
    load_os_info
    load_module warp
    run_warp

    save_state "WGCF_PRIVATE_KEY"   "${WGCF_PRIVATE_KEY:-}"
    save_state "WGCF_PEER_PUBKEY"   "${WGCF_PEER_PUBKEY:-}"
    save_state "WGCF_ADDRESS"       "${WGCF_ADDRESS:-}"
    save_state "WGCF_ENDPOINT"      "${WGCF_ENDPOINT:-}"
    save_state "WGCF_ENDPOINT_HOST" "${WGCF_ENDPOINT_HOST:-}"
    save_state "WGCF_ENDPOINT_PORT" "${WGCF_ENDPOINT_PORT:-}"
    save_state "INST_WARP"          "1"
    save_state "CONF_WARP"          "1"

    done_return
}

do_uninstall_menu() {
    clear
    echo ""
    echo -e "${BLUE}================ 清理 / 卸载 ================${NC}"
    echo "  1. 清理 System 优化"
    echo "  2. 清理 Unbound"
    echo "  3. 清理 Nginx"
    echo "  4. 清理证书 / Cloudflare 配置"
    echo "  5. 清理 Xray"
    echo "  6. 清理 Sing-Box"
    echo "  7. 清理 Cloudflare WARP"
    echo "  8. 清理全部"
    echo "  q. 返回主菜单"
    echo ""
    read -rp "  请选择: " cleanup_choice
    echo ""

    load_module uninstall

    case "$cleanup_choice" in
        1) cleanup_system_module ;;
        2) cleanup_unbound_module ;;
        3) cleanup_nginx_module ;;
        4) cleanup_cert_module ;;
        5) cleanup_xray_module ;;
        6) cleanup_singbox_module ;;
        7) cleanup_warp_module ;;
        8)
            read -rp "这会删除本脚本生成的大部分服务、配置和证书，确认继续吗？[y/N]: " confirm_cleanup
            if [[ "${confirm_cleanup,,}" != "y" ]]; then
                main_menu
                return
            fi
            cleanup_all_modules
            rm -f "$STATE_FILE"
            init_state
            ;;
        q|Q)
            main_menu
            return
            ;;
        *)
            log_error "无效选择"
            sleep 1
            main_menu
            return
            ;;
    esac

    done_return
}

run_full_install_flow() {
    log_step "开始全流程安装..."
    echo ""

    load_module system
    detect_os
    detect_kernel
    upgrade_kernel
    collect_hardware_info
    load_kernel_modules
    tune_system_limits
    install_base_tools
    sync_time

    save_state "OS_ID"        "$OS_ID"
    save_state "OS_NAME"      "$OS_NAME"
    save_state "PKG_MANAGER"  "$PKG_MANAGER"
    save_state "BBR_VERSION"  "${BBR_VERSION:-bbr}"
    save_state "HW_CPU_CORES" "$HW_CPU_CORES"
    save_state "HW_MEM_GB"    "$HW_MEM_GB"
    save_state "HW_BANDWIDTH" "$HW_BANDWIDTH"
    save_state "HW_DUAL_STACK" "$HW_DUAL_STACK"
    save_state "HW_DISK_TYPE" "$HW_DISK_TYPE"
    save_state "XRAY_PADDING" "${XRAY_PADDING:-128-2048}"
    save_state "INST_SYSTEM"  "1"

    load_module unbound
    restore_domain_arrays
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")
    run_unbound
    save_state "HW_DUAL_STACK"        "${HW_DUAL_STACK:-}"
    save_state "UNBOUND_SERVICE_NAME" "${UNBOUND_SERVICE_NAME:-}"
    save_state "INST_UNBOUND"         "1"

    load_os_info
    load_module nginx
    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    save_state "INST_NGINX" "1"

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

    if [[ "$(get_step INST_UNBOUND)" == "1" ]] || command -v unbound &>/dev/null; then
        refresh_unbound_after_cert
    fi

    restore_domain_arrays
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
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater
    save_state "CONF_NGINX" "1"

    load_module warp
    run_warp
    save_state "WGCF_PRIVATE_KEY"   "${WGCF_PRIVATE_KEY:-}"
    save_state "WGCF_PEER_PUBKEY"   "${WGCF_PEER_PUBKEY:-}"
    save_state "WGCF_ADDRESS"       "${WGCF_ADDRESS:-}"
    save_state "WGCF_ENDPOINT"      "${WGCF_ENDPOINT:-}"
    save_state "WGCF_ENDPOINT_HOST" "${WGCF_ENDPOINT_HOST:-}"
    save_state "WGCF_ENDPOINT_PORT" "${WGCF_ENDPOINT_PORT:-}"
    save_state "INST_WARP"          "1"
    save_state "CONF_WARP"          "1"

    load_module xray
    install_xray
    save_state "INST_XRAY" "1"

    XRAY_PADDING=$(get_state "XRAY_PADDING" "128-2048")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    if [[ -n "${XHTTP_PATH}" ]]; then
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

    load_module singbox
    install_singbox
    save_state "INST_SINGBOX" "1"

    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox
    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "CONF_SINGBOX"     "1"

    log_info "全流程安装完成"
}

do_full_install() {
    run_full_install_flow
    done_return
}

do_reinstall_all() {
    read -rp "这会先清理全部，再重新执行完整安装流程，确认继续吗？[y/N]: " reinstall_all
    if [[ "${reinstall_all,,}" != "y" ]]; then
        main_menu
        return
    fi

    load_module uninstall
    cleanup_all_modules
    rm -f "$STATE_FILE"
    init_state
    run_full_install_flow
    done_return
}

check_root
init_state
main_menu
