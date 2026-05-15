#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xray-nginx-deploy main entry
# GitHub: https://github.com/cctvhd/xray-nginx-deploy
# ============================================================

BASE_URL="https://raw.githubusercontent.com/cctvhd/xray-nginx-deploy/feature/hysteria2-naive"
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"
STATE_DIR="/etc/xray-deploy"
STATE_FILE="${STATE_DIR}/config.env"
LOCAL_MODULES_DIR="${STATE_DIR}/modules"

ALL_MODULES=(system unbound nginx cert xray singbox hysteria2 naive warp client sync uninstall)

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
    sed -i "/^${key}=/d" "$STATE_FILE" 2>/dev/null || true
    echo "${key}='${escaped}'" >> "$STATE_FILE"
}

get_step() {
    get_state "$1" "0"
}

# ── 模块加载：本地缓存 → 脚本同级目录 → 远程下载并缓存 ─────
load_module() {
    local module="$1"
    local cached_path="${LOCAL_MODULES_DIR}/${module}.sh"
    local local_path="${MODULES_DIR}/${module}.sh"
    local remote_url="${BASE_URL}/modules/${module}.sh"

    if [[ -f "$cached_path" ]]; then
        # shellcheck source=/dev/null
        source "$cached_path"
    elif [[ -f "$local_path" ]]; then
        # shellcheck source=/dev/null
        source "$local_path"
    else
        log_info "下载模块 ${module}.sh ..."
        mkdir -p "$LOCAL_MODULES_DIR"
        chmod 700 "$LOCAL_MODULES_DIR"
        if curl -fsSL "$remote_url" -o "$cached_path" 2>/dev/null; then
            chmod 600 "$cached_path"
            log_info "模块 ${module}.sh 已缓存至 ${cached_path}"
            # shellcheck source=/dev/null
            source "$cached_path"
        else
            log_warn "下载失败，尝试直接执行远程模块..."
            # shellcheck source=/dev/null
            source <(curl -fsSL "$remote_url")
        fi
    fi
}

# ── 同步/更新所有模块到本地缓存 ─────────────────────────────
sync_modules() {
    log_step "同步模块到本地缓存 (${LOCAL_MODULES_DIR})..."
    mkdir -p "$LOCAL_MODULES_DIR"
    chmod 700 "$LOCAL_MODULES_DIR"

    local ok=0 fail=0
    for module in "${ALL_MODULES[@]}"; do
        local cached_path="${LOCAL_MODULES_DIR}/${module}.sh"
        local remote_url="${BASE_URL}/modules/${module}.sh"
        echo -n "  ${module}.sh ... "
        if curl -fsSL "$remote_url" -o "$cached_path" 2>/dev/null; then
            chmod 600 "$cached_path"
            echo -e "${GREEN}OK${NC}"
            (( ok++ )) || true
        else
            echo -e "${RED}失败${NC}"
            (( fail++ )) || true
        fi
    done

    echo ""
    log_info "同步完成：成功 ${ok} 个，失败 ${fail} 个"
    if [[ $fail -gt 0 ]]; then
        log_warn "失败的模块将在使用时实时从远程加载"
    fi
    log_info "本地缓存目录: ${LOCAL_MODULES_DIR}"
    log_info "如需强制更新，再次选择 s 即可覆盖所有缓存"
}

# ── 根据实际服务状态自动补全 state ──────────────────────────
_sync_inst_state() {
    command -v nginx    &>/dev/null && [[ "$(get_step INST_NGINX)"   != "1" ]] && save_state "INST_NGINX"   "1" || true
    command -v xray     &>/dev/null && [[ "$(get_step INST_XRAY)"    != "1" ]] && save_state "INST_XRAY"    "1" || true
    command -v sing-box   &>/dev/null && [[ "$(get_step INST_SINGBOX)"   != "1" ]] && save_state "INST_SINGBOX"   "1" || true
    command -v hysteria   &>/dev/null && [[ "$(get_step INST_HYSTERIA2)" != "1" ]] && save_state "INST_HYSTERIA2" "1" || true
    command -v caddy-naive &>/dev/null && [[ "$(get_step INST_NAIVE)"    != "1" ]] && save_state "INST_NAIVE"    "1" || true
    command -v wgcf       &>/dev/null && [[ "$(get_step INST_WARP)"      != "1" ]] && save_state "INST_WARP"      "1" || true
    command -v unbound  &>/dev/null && [[ "$(get_step INST_UNBOUND)" != "1" ]] && save_state "INST_UNBOUND" "1" || true
    systemctl is-active --quiet nginx    2>/dev/null && [[ -f /etc/nginx/conf.d/servers.conf ]] && [[ "$(get_step CONF_NGINX)"   != "1" ]] && save_state "CONF_NGINX"   "1" || true
    systemctl is-active --quiet xray     2>/dev/null && [[ -f /usr/local/etc/xray/config.json ]]    && [[ "$(get_step CONF_XRAY)"    != "1" ]] && save_state "CONF_XRAY"    "1" || true
    systemctl is-active --quiet sing-box 2>/dev/null && [[ -f /etc/sing-box/config.json ]]          && [[ "$(get_step CONF_SINGBOX)"   != "1" ]] && save_state "CONF_SINGBOX"   "1" || true
    systemctl is-active --quiet hysteria-server 2>/dev/null && [[ -f /etc/hysteria/config.yaml ]]   && [[ "$(get_step CONF_HYSTERIA2)" != "1" ]] && save_state "CONF_HYSTERIA2" "1" || true
    systemctl is-active --quiet caddy-naive 2>/dev/null && [[ -f /etc/caddy-naive/Caddyfile ]]       && [[ "$(get_step CONF_NAIVE)"     != "1" ]] && save_state "CONF_NAIVE"     "1" || true
    [[ -f /etc/wgcf/wgcf-profile.conf ]] && [[ -n "$(get_state WGCF_PRIVATE_KEY)" ]] && \
        [[ "$(get_step CONF_WARP)" != "1" ]] && save_state "CONF_WARP" "1" || true
    _sync_cert_state
}

_sync_cert_state() {
    [[ "$(get_step INST_CERT)" == "1" ]] && return 0

    local CF_DOMAIN_MAP="/etc/cloudflare/domain_map.conf"
    [[ -f "$CF_DOMAIN_MAP" ]] || return 0

    local xhttp grpc reality anytls
    xhttp=$(   grep "^XHTTP_DOMAIN="   "$CF_DOMAIN_MAP" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true )
    grpc=$(    grep "^GRPC_DOMAIN="    "$CF_DOMAIN_MAP" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true )
    reality=$( grep "^REALITY_DOMAIN=" "$CF_DOMAIN_MAP" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true )
    anytls=$(  grep "^ANYTLS_DOMAIN="  "$CF_DOMAIN_MAP" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true )

    local cert_ok=false
    for d in "$xhttp" "$grpc" "$reality" "$anytls"; do
        [[ -z "$d" ]] && continue
        local root
        root=$(echo "$d" | awk -F. '{print $(NF-1)"."$NF}')
        if [[ -f "/etc/letsencrypt/live/${root}/fullchain.pem" ]]; then
            cert_ok=true
            break
        fi
    done

    $cert_ok || return 0

    [[ -n "$xhttp"   ]] && save_state "XHTTP_DOMAIN"   "$xhttp"
    [[ -n "$grpc"    ]] && save_state "GRPC_DOMAIN"     "$grpc"
    [[ -n "$reality" ]] && save_state "REALITY_DOMAIN"  "$reality"
    [[ -n "$anytls"  ]] && save_state "ANYTLS_DOMAIN"   "$anytls"

    local cur_all
    cur_all=$(get_state "ALL_DOMAINS")
    if [[ -z "$cur_all" ]]; then
        local all_d="" cdn_d="" direct_d=""
        [[ -n "$xhttp"   ]] && all_d+=" $xhttp"   && cdn_d+=" $xhttp"
        [[ -n "$grpc"    ]] && all_d+=" $grpc"     && cdn_d+=" $grpc"
        [[ -n "$reality" ]] && all_d+=" $reality"  && direct_d+=" $reality"
        [[ -n "$anytls"  ]] && all_d+=" $anytls"   && direct_d+=" $anytls"
        save_state "ALL_DOMAINS"    "${all_d# }"
        save_state "CDN_DOMAINS"    "${cdn_d# }"
        save_state "DIRECT_DOMAINS" "${direct_d# }"
    fi

    save_state "INST_CERT" "1"
    log_info "已自动同步证书状态（检测到有效的 Let's Encrypt 证书）"

    [[ -n "$xhttp"   ]] && XHTTP_DOMAIN="$xhttp"
    [[ -n "$grpc"    ]] && GRPC_DOMAIN="$grpc"
    [[ -n "$reality" ]] && REALITY_DOMAIN="$reality"
    [[ -n "$anytls"  ]] && ANYTLS_DOMAIN="$anytls"
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
NAIVE_DOMAIN=''
NAIVE_USER=''
NAIVE_PASS=''
ALL_DOMAINS=''
CDN_DOMAINS=''
DIRECT_DOMAINS=''
XHTTP_PATH=''

XRAY_UUID=''
XRAY_PUBLIC_KEY=''
XRAY_PRIVATE_KEY=''
REALITY_DEST=''
REALITY_SNI=''
REALITY_SERVER_NAMES=''
REALITY_SHORT_ID=''
REALITY_SPIDER_X=''

SINGBOX_PASSWORD=''

HYSTERIA2_DOMAIN=''
HYSTERIA2_PASSWORD=''

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
INST_HYSTERIA2='0'
INST_NAIVE='0'
INST_WARP='0'

CONF_NGINX='0'
CONF_XRAY='0'
CONF_SINGBOX='0'
CONF_HYSTERIA2='0'
CONF_NAIVE='0'
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
    HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    XRAY_UUID=$(get_state "XRAY_UUID")
    XRAY_PUBLIC_KEY=$(get_state "XRAY_PUBLIC_KEY")
    SINGBOX_PASSWORD=$(get_state "SINGBOX_PASSWORD")
    XRAY_PADDING=$(get_state "XRAY_PADDING")

    # ── BUG FIX：恢复 REALITY_SERVER_NAMES 数组 ──────────────
    # 原代码只保存了 REALITY_SNI（第一个元素），导致 do_conf_nginx
    # 调用 generate_sni_map 时数组为空，stream map 缺失公共域名路由。
    local _reality_sn_str
    _reality_sn_str=$(get_state "REALITY_SERVER_NAMES")
    REALITY_SERVER_NAMES=()
    if [[ -n "$_reality_sn_str" ]]; then
        read -ra REALITY_SERVER_NAMES <<< "$_reality_sn_str"
    fi

    WGCF_PRIVATE_KEY=$(get_state "WGCF_PRIVATE_KEY")
    WGCF_PEER_PUBKEY=$(get_state "WGCF_PEER_PUBKEY")
    WGCF_ADDRESS=$(get_state "WGCF_ADDRESS")
    WGCF_ENDPOINT=$(get_state "WGCF_ENDPOINT")
    WGCF_ENDPOINT_HOST=$(get_state "WGCF_ENDPOINT_HOST")
    WGCF_ENDPOINT_PORT=$(get_state "WGCF_ENDPOINT_PORT")

    _sync_inst_state
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
    load_module sync
    sync_restore_domain_arrays
}

refresh_unbound_after_cert() {
    if ! command -v unbound &>/dev/null; then
        return 0
    fi

    load_module unbound

    restore_domain_arrays
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")
    if refresh_unbound_generated_config; then
        log_info "Unbound 配置已按当前设置刷新"
    else
        log_warn "Unbound 配置刷新失败，请先根据上面的诊断信息修复后再执行步骤 2"
    fi
}

show_status() {
    local s_system s_unbound s_nginx s_cert s_xray s_singbox s_hysteria2 s_naive s_warp
    local c_nginx c_xray c_singbox c_hysteria2 c_naive c_warp

    { [[ "$(get_step INST_SYSTEM)"  == "1" ]] || \
      sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q 'bbr'; } \
      && s_system="OK"  || s_system="--"

    { [[ "$(get_step INST_UNBOUND)" == "1" ]] || \
      command -v unbound &>/dev/null; } \
      && s_unbound="OK" || s_unbound="--"

    { [[ "$(get_step INST_NGINX)"   == "1" ]] || \
      command -v nginx &>/dev/null; } \
      && s_nginx="OK"   || s_nginx="--"

    { [[ "$(get_step INST_CERT)" == "1" ]] || \
      find /etc/letsencrypt/live -name 'fullchain.pem' -quit 2>/dev/null | grep -q .; } \
      && s_cert="OK" || s_cert="--"

    { [[ "$(get_step INST_XRAY)"    == "1" ]] || \
      command -v xray &>/dev/null; } \
      && s_xray="OK"    || s_xray="--"

    { [[ "$(get_step INST_SINGBOX)" == "1" ]] || \
      command -v sing-box &>/dev/null; } \
      && s_singbox="OK" || s_singbox="--"

    { [[ "$(get_step INST_HYSTERIA2)" == "1" ]] || \
      command -v hysteria &>/dev/null; } \
      && s_hysteria2="OK" || s_hysteria2="--"

    { [[ "$(get_step INST_NAIVE)" == "1" ]] || \
      command -v caddy-naive &>/dev/null; } \
      && s_naive="OK" || s_naive="--"

    { [[ "$(get_step INST_WARP)"    == "1" ]] || \
      command -v wgcf &>/dev/null; } \
      && s_warp="OK"    || s_warp="--"

    { [[ "$(get_step CONF_NGINX)"   == "1" ]] || \
      ( systemctl is-active --quiet nginx 2>/dev/null && [[ -f /etc/nginx/conf.d/servers.conf ]] ); } \
      && c_nginx="OK"   || c_nginx="--"

    { [[ "$(get_step CONF_XRAY)"    == "1" ]] || \
      ( systemctl is-active --quiet xray 2>/dev/null && [[ -f /usr/local/etc/xray/config.json ]] ); } \
      && c_xray="OK"    || c_xray="--"

    { [[ "$(get_step CONF_SINGBOX)" == "1" ]] || \
      ( systemctl is-active --quiet sing-box 2>/dev/null && [[ -f /etc/sing-box/config.json ]] ); } \
      && c_singbox="OK" || c_singbox="--"

    { [[ "$(get_step CONF_HYSTERIA2)" == "1" ]] || \
      ( systemctl is-active --quiet hysteria-server 2>/dev/null && [[ -f /etc/hysteria/config.yaml ]] ); } \
      && c_hysteria2="OK" || c_hysteria2="--"

    { [[ "$(get_step CONF_NAIVE)" == "1" ]] || \
      ( systemctl is-active --quiet caddy-naive 2>/dev/null && [[ -f /etc/caddy-naive/Caddyfile ]] ); } \
      && c_naive="OK" || c_naive="--"

    { [[ "$(get_step CONF_WARP)"    == "1" ]] || \
      [[ -f /etc/wgcf/wgcf-profile.conf ]]; } \
      && c_warp="OK"    || c_warp="--"

    local cached_count=0
    for m in "${ALL_MODULES[@]}"; do
        [[ -f "${LOCAL_MODULES_DIR}/${m}.sh" ]] && (( cached_count++ )) || true
    done
    local total_modules=${#ALL_MODULES[@]}

    echo ""
    echo -e "${BLUE}================ 当前状态 ================${NC}"
    echo "  [安装]"
    printf "    %-20s %s\n" "System"   "${s_system}"
    printf "    %-20s %s\n" "Unbound"  "${s_unbound}"
    printf "    %-20s %s\n" "Nginx"    "${s_nginx}"
    printf "    %-20s %s\n" "Cert"     "${s_cert}"
    printf "    %-20s %s\n" "Xray"     "${s_xray}"
    printf "    %-20s %s\n" "Sing-Box"  "${s_singbox}"
    printf "    %-20s %s\n" "Hysteria2" "${s_hysteria2}"
    printf "    %-20s %s\n" "NaiveProxy" "${s_naive}"
    printf "    %-20s %s\n" "WARP"      "${s_warp}"

    echo ""
    echo "  [配置]"
    printf "    %-20s %s\n" "Nginx"    "${c_nginx}"
    printf "    %-20s %s\n" "Xray"     "${c_xray}"
    printf "    %-20s %s\n" "Sing-Box"  "${c_singbox}"
    printf "    %-20s %s\n" "Hysteria2" "${c_hysteria2}"
    printf "    %-20s %s\n" "NaiveProxy" "${c_naive}"
    printf "    %-20s %s\n" "WARP"      "${c_warp}"

    echo ""
    echo "  [域名]"
    [[ -n "${XHTTP_DOMAIN:-}"   ]] && echo "    xhttp   : ${XHTTP_DOMAIN}"
    [[ -n "${GRPC_DOMAIN:-}"    ]] && echo "    gRPC    : ${GRPC_DOMAIN}"
    [[ -n "${REALITY_DOMAIN:-}" ]] && echo "    Reality : ${REALITY_DOMAIN}"
    [[ -n "${ANYTLS_DOMAIN:-}"  ]] && echo "    AnyTLS  : ${ANYTLS_DOMAIN}"
    [[ -n "${HYSTERIA2_DOMAIN:-}"  ]] && echo "  Hysteria2  : ${HYSTERIA2_DOMAIN}"
    [[ -n "${NAIVE_DOMAIN:-}"  ]]     && echo "  NaiveProxy : ${NAIVE_DOMAIN}"

    if [[ -n "${HW_CPU_CORES:-}" ]]; then
        echo ""
        echo "  [硬件]"
        echo "    CPU: ${HW_CPU_CORES} | MEM: ${HW_MEM_GB}GB | BW: ${HW_BANDWIDTH} | STACK: ${HW_DUAL_STACK} | DISK: ${HW_DISK_TYPE}"
    fi

    echo ""
    echo "  [模块缓存]  ${cached_count}/${total_modules} 个已缓存到本地（选 s 可同步更新）"

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
    echo "  7. 安装 Hysteria2"
    echo "  8. 安装 NaiveProxy"
    echo ""
    echo "  === 配置 ==="
    echo "  9. 配置 Nginx"
    echo "  10. 配置 Xray"
    echo "  11. 配置 Sing-Box"
    echo "  12. 配置 Hysteria2"
    echo "  13. 配置 NaiveProxy"
	echo " n. 重新配置 Nginx（先清理再生成）"
	echo " x. 重新配置 Xray（先清理再生成）"
	echo " g. 重新配置 Sing-Box（先清理再生成）"
	echo " h. 重新配置 Hysteria2（先清理再生成）"
	echo " i. 重新配置 NaiveProxy（先清理再生成）"
    echo ""
    echo "  === 其他 ==="
    echo "  a. 生成客户端链接"
    echo "  b. 查看当前状态"
    echo "  s. 同步/更新模块到本地缓存"
    echo "  w. 配置 WARP WireGuard 凭证（步骤 10/11 的前置依赖）"
    echo "  u. 卸载 / 清理模块"
    echo "  p. SELinux 管理"
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
        7) do_inst_hysteria2 ;;
        8) do_inst_naive ;;
        9) do_conf_nginx ;;
       10) do_conf_xray ;;
       11) do_conf_singbox ;;
       12) do_conf_hysteria2 ;;
       13) do_conf_naive ;;
      n|N) do_reconf_nginx ;;
      x|X) do_reconf_xray ;;
      g|G) do_reconf_singbox ;;
      h|H) do_reconf_hysteria2 ;;
      i|I) do_reconf_naive ;;
        a|A) do_client ;;
        b|B)
            show_status
            read -rp "按回车返回主菜单..." _
            main_menu
            ;;
        s|S) do_sync_modules ;;
        w|W) do_warp ;;
        u|U) do_uninstall_menu ;;
        p|P) do_selinux_mgmt ;;
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

do_sync_modules() {
    echo ""
    log_warn "将从 GitHub 下载所有模块覆盖本地缓存，需要网络连接。"
    read -rp "确认继续？[y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        main_menu
        return
    fi
    echo ""
    sync_modules
    done_return
}

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
        save_state "WGCF_PRIVATE_KEY"   "${WGCF_PRIVATE_KEY:-}"
        save_state "WGCF_PEER_PUBKEY"   "${WGCF_PEER_PUBKEY:-}"
        save_state "WGCF_ADDRESS"       "${WGCF_ADDRESS:-}"
        save_state "WGCF_ENDPOINT"      "${WGCF_ENDPOINT:-}"
        save_state "WGCF_ENDPOINT_HOST" "${WGCF_ENDPOINT_HOST:-}"
        save_state "WGCF_ENDPOINT_PORT" "${WGCF_ENDPOINT_PORT:-}"
        save_state "INST_WARP"          "1"
        save_state "CONF_WARP"          "1"
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
    install_base_tools
    optimize_hardware_interrupts
    optimize_sysctl
    tune_system_limits
    sync_time
    setup_selinux_policy
    print_optimization_summary

    local mem_mb
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    HW_MEM_GB=${HW_MEM_GB:-$(awk -v m="$mem_mb" 'BEGIN{printf "%.1f", m/1024}')}
    HW_BANDWIDTH=${HW_BANDWIDTH:-unknown}
    HW_DUAL_STACK=${HW_DUAL_STACK:-unknown}
    HW_DISK_TYPE=${HW_DISK_TYPE:-unknown}

    BBR_VERSION=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "bbr")

    save_state "OS_ID"         "$OS_ID"
    save_state "OS_NAME"       "$OS_NAME"
    save_state "PKG_MANAGER"   "$PKG_MANAGER"
    save_state "BBR_VERSION"   "${BBR_VERSION}"
    save_state "HW_CPU_CORES"  "${HW_CPU_CORES:-$(nproc)}"
    save_state "HW_MEM_GB"     "${HW_MEM_GB}"
    save_state "HW_BANDWIDTH"  "${HW_BANDWIDTH}"
    save_state "HW_DUAL_STACK" "${HW_DUAL_STACK}"
    save_state "HW_DISK_TYPE"  "${HW_DISK_TYPE}"
    save_state "XRAY_PADDING"  "${XRAY_PADDING:-128-2048}"
    save_state "INST_SYSTEM"   "1"

    done_return
}

do_inst_unbound() {
    load_os_info
    load_module unbound
    restore_domain_arrays
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")

    if [[ -z "$(get_state "ALL_DOMAINS")" ]]; then
        log_info "提示：尚未申请证书，域名解析配置将在步骤 4 完成后自动更新"
    fi

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

    XHTTP_DOMAIN="${XHTTP_DOMAIN:-}"
    GRPC_DOMAIN="${GRPC_DOMAIN:-}"
    REALITY_DOMAIN="${REALITY_DOMAIN:-}"
    ANYTLS_DOMAIN="${ANYTLS_DOMAIN:-}"



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

    log_info "Xray 安装完成，请继续执行步骤 10"
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

    log_info "Sing-Box 安装完成，请继续执行步骤 11"
    done_return
}

do_inst_hysteria2() {
    load_os_info
    load_module hysteria2

    if command -v hysteria &>/dev/null; then
        local ver reinstall
        ver=$(hysteria version 2>&1 | grep -oP '[\d.]+' | head -1 || true)
        log_info "Hysteria2 已安装: v${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_HYSTERIA2" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_hysteria2
    save_state "INST_HYSTERIA2" "1"

    log_info "Hysteria2 安装完成"
    done_return
}

do_inst_naive() {
    load_os_info
    load_module naive

    if command -v caddy-naive &>/dev/null; then
        local ver reinstall
        ver=$(caddy-naive version 2>&1 | head -1 || true)
        log_info "NaiveProxy 已安装: ${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_NAIVE" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_naive
    save_state "INST_NAIVE" "1"

    log_info "NaiveProxy 安装完成"
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

    local cert_ready=false
    [[ "$(get_step INST_CERT)" == "1" ]] && cert_ready=true
    find /etc/letsencrypt/live -name 'fullchain.pem' -quit 2>/dev/null | grep -q . && cert_ready=true

    if ! $cert_ready; then
        log_warn "未检测到有效 SSL 证书，请先完成步骤 4（申请 SSL 证书）"
        done_return
        return
    fi

    load_os_info
    restore_domain_arrays   # 内含 REALITY_SERVER_NAMES 恢复

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
    generate_trap_cert
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

refresh_nginx_after_xray() {
    load_module sync
    sync_refresh_nginx_routes "Xray"
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
        log_warn "建议先完成步骤 9（配置 Nginx）"
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

    save_state "XRAY_UUID"             "${XRAY_UUID:-}"
    save_state "XRAY_PUBLIC_KEY"       "${XRAY_PUBLIC_KEY:-}"
    save_state "XRAY_PRIVATE_KEY"      "${XRAY_PRIVATE_KEY:-}"
    save_state "XHTTP_PATH"            "${XHTTP_PATH:-}"
    save_state "REALITY_DEST"          "${REALITY_DEST:-}"
    save_state "REALITY_SNI"           "${REALITY_SERVER_NAMES[0]:-}"
    # ── BUG FIX：保存完整 serverNames 数组供 nginx 生成 SNI map 使用 ──
    save_state "REALITY_SERVER_NAMES"  "${REALITY_SERVER_NAMES[*]:-}"
    save_state "REALITY_SHORT_ID"      "${REALITY_SHORT_IDS[1]:-}"
    save_state "REALITY_SHORT_IDS" "${REALITY_SHORT_IDS[*]:-}"
    save_state "REALITY_SPIDER_X"      "${REALITY_SPIDER_X:-}"
    save_state "CONF_XRAY"             "1"

    refresh_nginx_after_xray

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
        log_info "提示：Nginx 尚未配置（步骤 9），443 SNI 分流暂不可用；"
        log_info "      Sing-Box 本身可正常启动，待 Nginx 配置完成后流量即自动接通。"
    fi

    load_os_info
    restore_domain_arrays
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")

    _ensure_wgcf

    load_module singbox
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox

    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "ANYTLS_DOMAIN"     "${ANYTLS_DOMAIN:-}"
    save_state "CONF_SINGBOX"     "1"

    sync_refresh_nginx_routes "Sing-Box"

    done_return
}

do_conf_hysteria2() {
    if [[ "$(get_step INST_HYSTERIA2)" != "1" ]] && ! command -v hysteria &>/dev/null; then
        log_warn "请先完成步骤 7（安装 Hysteria2）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi
    if command -v hysteria &>/dev/null && [[ "$(get_step INST_HYSTERIA2)" != "1" ]]; then
        save_state "INST_HYSTERIA2" "1"
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "建议先完成步骤 4（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_os_info
    restore_domain_arrays
    load_module hysteria2
    configure_hysteria2

    save_state "CONF_HYSTERIA2" "1"

    done_return
}

do_reconf_hysteria2() {
    read -rp "将清理 Hysteria2 配置并重新生成，确认继续吗？[y/N]: " c
    [[ "${c,,}" != "y" ]] && main_menu && return

    load_module uninstall

    log_step "清理 Hysteria2 配置文件..."
    rm -f /etc/hysteria/config.yaml
    save_state "CONF_HYSTERIA2" "0"
    log_info "Hysteria2 配置清理完成，开始重新生成..."

    do_conf_hysteria2
}

do_conf_naive() {
    if [[ "$(get_step INST_NAIVE)" != "1" ]] && ! command -v caddy-naive &>/dev/null; then
        log_warn "请先完成步骤 8（安装 NaiveProxy）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi
    if command -v caddy-naive &>/dev/null && [[ "$(get_step INST_NAIVE)" != "1" ]]; then
        save_state "INST_NAIVE" "1"
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "建议先完成步骤 4（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && main_menu && return
    fi

    load_os_info
    restore_domain_arrays
    load_module naive
    configure_naive

    save_state "CONF_NAIVE" "1"

    if systemctl is-active --quiet nginx; then
        sync_refresh_nginx_routes "NaiveProxy"
    fi

    done_return
}

do_reconf_naive() {
    read -rp "将清理 NaiveProxy 配置并重新生成，确认继续吗？[y/N]: " c
    [[ "${c,,}" != "y" ]] && main_menu && return

    load_module uninstall

    log_step "清理 NaiveProxy 配置文件..."
    rm -f /etc/caddy-naive/Caddyfile
    save_state "CONF_NAIVE" "0"
    log_info "NaiveProxy 配置清理完成，开始重新生成..."

    do_conf_naive
}

do_client() {
    load_module sync
    sync_before_client_links
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
    echo "  7. 清理 Hysteria2"
    echo "  8. 清理 NaiveProxy"
    echo "  9. 清理 Cloudflare WARP"
    echo "  10. 清理全部"
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
        7) cleanup_hysteria2_module ;;
        8) cleanup_naive_module ;;
        9) cleanup_warp_module ;;
       10)
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
    install_base_tools
    optimize_hardware_interrupts
    optimize_sysctl
    tune_system_limits
    sync_time
    setup_selinux_policy
    print_optimization_summary

    local mem_mb
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    HW_MEM_GB=${HW_MEM_GB:-$(awk -v m="$mem_mb" 'BEGIN{printf "%.1f", m/1024}')}
    HW_BANDWIDTH=${HW_BANDWIDTH:-unknown}
    HW_DUAL_STACK=${HW_DUAL_STACK:-unknown}
    HW_DISK_TYPE=${HW_DISK_TYPE:-unknown}
    BBR_VERSION=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "bbr")

    save_state "OS_ID"         "$OS_ID"
    save_state "OS_NAME"       "$OS_NAME"
    save_state "PKG_MANAGER"   "$PKG_MANAGER"
    save_state "BBR_VERSION"   "${BBR_VERSION}"
    save_state "HW_CPU_CORES"  "${HW_CPU_CORES:-$(nproc)}"
    save_state "HW_MEM_GB"     "${HW_MEM_GB}"
    save_state "HW_BANDWIDTH"  "${HW_BANDWIDTH}"
    save_state "HW_DUAL_STACK" "${HW_DUAL_STACK}"
    save_state "HW_DISK_TYPE"  "${HW_DISK_TYPE}"
    save_state "XRAY_PADDING"  "${XRAY_PADDING:-128-2048}"
    save_state "INST_SYSTEM"   "1"

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



    restore_domain_arrays
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    if [[ -z "${XHTTP_PATH}" ]]; then
        XHTTP_PATH="/$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
        save_state "XHTTP_PATH" "${XHTTP_PATH}"
        log_info "生成 XHTTP_PATH: ${XHTTP_PATH}"
    else
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    fi

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
    save_state "XRAY_UUID"            "${XRAY_UUID:-}"
    save_state "XRAY_PUBLIC_KEY"      "${XRAY_PUBLIC_KEY:-}"
    save_state "XRAY_PRIVATE_KEY"     "${XRAY_PRIVATE_KEY:-}"
    save_state "XHTTP_PATH"           "${XHTTP_PATH:-}"
    save_state "REALITY_DEST"         "${REALITY_DEST:-}"
    save_state "REALITY_SNI"          "${REALITY_SERVER_NAMES[0]:-}"
    save_state "REALITY_SERVER_NAMES" "${REALITY_SERVER_NAMES[*]:-}"
    save_state "REALITY_SHORT_IDS" "${REALITY_SHORT_IDS[*]:-}"
    save_state "REALITY_SHORT_ID"     "${REALITY_SHORT_IDS[1]:-}"
    save_state "REALITY_SPIDER_X"     "${REALITY_SPIDER_X:-}"
    save_state "CONF_XRAY"            "1"

    # nginx 在 xray 之后生成，确保 REALITY_SERVER_NAMES 已保存
    load_module nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    if [[ -n "${GRPC_DOMAIN:-}" ]]; then
        generate_fake_site "/var/www/${GRPC_DOMAIN}" "${GRPC_DOMAIN}"
    fi
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    generate_trap_cert
    generate_fallback_conf
    generate_servers_conf
    generate_nginx_conf
    reload_nginx
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater
    save_state "CONF_NGINX" "1"

    load_module singbox
    install_singbox
    save_state "INST_SINGBOX" "1"

    restore_domain_arrays
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox
    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "ANYTLS_DOMAIN"     "${ANYTLS_DOMAIN:-}"
    save_state "CONF_SINGBOX"     "1"

    sync_refresh_nginx_routes "Sing-Box"

    log_info "全流程安装完成"
}

do_full_install() {
    run_full_install_flow
    done_return
}

# ── 重新配置（先清理配置再重新生成）─────────────────────
do_reconf_nginx() {
	read -rp "将清理 Nginx 配置并重新生成，确认继续吗？[y/N]: " c
	[[ "${c,,}" != "y" ]] && main_menu && return

	load_module uninstall

	log_step "清理 Nginx 配置文件..."
	rm -f /etc/nginx/cloudflare_real_ip.conf
	rm -f /etc/nginx/conf.d/00-upstreams.conf
	rm -f /etc/nginx/conf.d/fallback.conf
	rm -f /etc/nginx/conf.d/servers.conf
	rm -f /etc/nginx/nginx.conf

	save_state "CONF_NGINX" "0"
	log_info "Nginx 配置清理完成，开始重新生成..."

	do_conf_nginx
}

do_reconf_xray() {
	read -rp "将清理 Xray 配置并重新生成，确认继续吗？[y/N]: " c
	[[ "${c,,}" != "y" ]] && main_menu && return

	load_module uninstall

	log_step "清理 Xray 配置文件..."
	rm -f /usr/local/etc/xray/config.json

	save_state "XRAY_UUID"            ""
	save_state "XRAY_PUBLIC_KEY"      ""
	save_state "XRAY_PRIVATE_KEY"     ""
	save_state "REALITY_DEST"         ""
	save_state "REALITY_SNI"          ""
	save_state "REALITY_SERVER_NAMES" ""
	save_state "REALITY_SHORT_ID"     ""
	save_state "REALITY_SHORT_IDS"    ""
	save_state "REALITY_SPIDER_X"     ""
	save_state "CONF_XRAY" "0"
	log_info "Xray 配置清理完成，开始重新生成..."

	do_conf_xray
}

do_reconf_singbox() {
	read -rp "将清理 Sing-Box 配置并重新生成，确认继续吗？[y/N]: " c
	[[ "${c,,}" != "y" ]] && main_menu && return

	load_module uninstall

	log_step "清理 Sing-Box 配置文件..."
	rm -f /etc/sing-box/config.json
	save_state "SINGBOX_PASSWORD" ""

	save_state "CONF_SINGBOX" "0"
	log_info "Sing-Box 配置清理完成，开始重新生成..."

	do_conf_singbox
}

do_selinux_mgmt() {
    clear
    echo ""
    echo -e "${BLUE}================ SELinux 管理 ================${NC}"
    echo ""

    if ! command -v getenforce >/dev/null 2>&1; then
        log_info "当前系统未安装 SELinux，无需管理"
        echo ""
        read -rp "按回车返回主菜单..." _
        main_menu
        return
    fi

    local status
    status=$(getenforce 2>/dev/null || echo "Unknown")
    echo "  当前 SELinux 状态: ${status}"

    local ports_ok=true
    if command -v semanage >/dev/null 2>&1; then
        local existing
        existing=$(semanage port -l 2>/dev/null | grep '^http_port_t' || true)
        local ports=(20443 20445 20880 18443 9443 8443)
        for port in "${ports[@]}"; do
            if ! echo "$existing" | grep -qw "\\b${port}\\b"; then
                echo "  ! 端口 ${port}/tcp 缺少 http_port_t 标签"
                ports_ok=false
            fi
        done
        $ports_ok && echo "  端口标签: 已全部配置"
    else
        echo "  ! semanage 不可用，无法检查端口标签"
        ports_ok=false
    fi

    local bool_ok=true
    if command -v getsebool >/dev/null 2>&1; then
        local hcc
        hcc=$(getsebool httpd_can_network_connect 2>/dev/null | awk '{print $NF}')
        if [[ "$hcc" != "on" ]]; then
            echo "  ! httpd_can_network_connect = ${hcc:-unknown}"
            bool_ok=false
        else
            echo "  httpd_can_network_connect: on"
        fi
    fi

    echo ""

    case "$status" in
        Enforcing)
            echo "  1. 切换到 Permissive 模式"
            echo "  q. 返回主菜单"
            echo ""
            read -rp "  请选择 [1/q]: " mgmt_choice
            case "${mgmt_choice:-}" in
                1)
                    setenforce 0 2>/dev/null && \
                        log_info "已切换到 Permissive 模式" || \
                        log_error "切换失败"
                    ;;
            esac
            ;;
        Permissive)
            if $ports_ok && $bool_ok; then
                echo "  1. 切换到 Enforcing 模式（策略已就绪）"
                echo "  q. 返回主菜单"
                echo ""
                read -rp "  请选择 [1/q]: " mgmt_choice
                case "${mgmt_choice:-}" in
                    1)
                        setenforce 1 2>/dev/null && \
                            log_info "已切换到 Enforcing 模式" || \
                            log_error "切换失败"
                        ;;
                esac
            else
                echo "  1. 切换到 Enforcing 模式（策略不完整，不建议）"
                echo "  2. 先修复缺失的 SELinux 策略再切换"
                echo "  q. 返回主菜单"
                echo ""
                read -rp "  请选择: " mgmt_choice
                case "${mgmt_choice:-}" in
                    1)
                        log_warn "端口标签或布尔值不完整，强制切换 Enforcing 可能导致服务异常"
                        read -rp "确认切换？[y/N]: " c
                        if [[ "${c,,}" == "y" ]]; then
                            setenforce 1 2>/dev/null && \
                                log_info "已切换到 Enforcing 模式" || \
                                log_error "切换失败"
                        fi
                        ;;
                    2)
                        load_module system
                        setup_selinux_policy
                        log_info "策略修复完成，请重新选择切换"
                        sleep 1
                        do_selinux_mgmt
                        return
                        ;;
                esac
            fi
            ;;
        Disabled)
            log_info "SELinux 已完全禁用，无需管理"
            ;;
    esac

    echo ""
    read -rp "按回车返回主菜单..." _
    main_menu
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
