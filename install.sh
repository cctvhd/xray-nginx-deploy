#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xray-nginx-deploy 主入口
# ============================================================

BASE_URL="https://raw.githubusercontent.com/cctvhd/xray-nginx-deploy/main"
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $*"; }

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# 加载模块（本地或远程）
load_module() {
    local module="$1"
    local local_path="${MODULES_DIR}/${module}.sh"
    local remote_url="${BASE_URL}/modules/${module}.sh"

    if [[ -f "$local_path" ]]; then
        source "$local_path"
    else
        source <(curl -fsSL "$remote_url")
    fi
}

# 主菜单
main_menu() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}     Xray + Nginx + Sing-Box 部署工具  ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "  1. 全量安装（推荐）"
    echo "  2. 仅优化系统参数"
    echo "  3. 仅安装/配置 Nginx"
    echo "  4. 仅申请 SSL 证书"
    echo "  5. 仅安装/配置 Xray"
    echo "  6. 仅安装/配置 Sing-Box"
    echo "  7. 生成客户端连接"
    echo "  0. 退出"
    echo ""
    read -rp "请选择 [0-7]: " choice

    case "$choice" in
        1) full_install ;;
        2) load_module system   && run_system ;;
        3) load_module nginx    && run_nginx ;;
        4) load_module cert     && run_cert ;;
        5) load_module xray     && run_xray ;;
        6) load_module singbox  && run_singbox ;;
        7) load_module client   && run_client ;;
        0) exit 0 ;;
        *) log_error "无效选择"; main_menu ;;
    esac
}

# 全量安装流程
full_install() {
    log_step "开始全量安装..."
    echo ""

    load_module system
    run_system

    load_module cert
    run_cert

    load_module nginx
    run_nginx

    read -rp "是否安装配置 Xray？[Y/n]: " install_xray
    if [[ "${install_xray,,}" != "n" ]]; then
        load_module xray
        run_xray
    fi

    read -rp "是否安装配置 Sing-Box？[Y/n]: " install_singbox
    if [[ "${install_singbox,,}" != "n" ]]; then
        load_module singbox
        run_singbox
    fi

    load_module client
    run_client

    log_info "全量安装完成！"
}

# ============================================================
# 入口
# ============================================================
check_root
main_menu
