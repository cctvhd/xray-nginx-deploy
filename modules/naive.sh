#!/usr/bin/env bash
# ============================================================
# modules/naive.sh
# NaïveProxy 安装模块
# 从 klzgrad/naiveproxy GitHub releases 下载二进制
# ============================================================

log_step() { echo -e "\e[36m[STEP]\e[0m $*"; }
log_info()  { echo -e "\e[32m[INFO]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*"; }

install_naive() {
    log_step "安装 NaïveProxy（klzgrad/naiveproxy）..."

    local arch
    arch=$(uname -m)
    local release_arch
    case "$arch" in
        x86_64)  release_arch="x64" ;;
        aarch64) release_arch="arm64" ;;
        arm64)   release_arch="arm64" ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac

    local latest_release
    log_info "获取最新版本号..."
    latest_release=$(curl -fsSL \
        "https://api.github.com/repos/klzgrad/naiveproxy/releases/latest" \
        2>/dev/null | grep '"tag_name"' | cut -d '"' -f 4)

    if [[ -z "$latest_release" ]]; then
        log_error "无法获取 naiveproxy 最新版本号，请检查网络或 GitHub API 限速"
        exit 1
    fi
    log_info "最新版本: ${latest_release}"

    local download_url
    download_url="https://github.com/klzgrad/naiveproxy/releases/download/${latest_release}/naiveproxy-${latest_release}-linux-${release_arch}.tar.xz"
    log_info "下载地址: ${download_url}"

    local tmpdir
    tmpdir=$(mktemp -d)
    local tarball="${tmpdir}/naiveproxy.tar.xz"

    log_info "下载中..."
    curl -fsSL "$download_url" -o "$tarball" || {
        log_error "下载失败"
        rm -rf "$tmpdir"
        exit 1
    }

    log_info "解压中..."
    tar -xJf "$tarball" -C "$tmpdir" || {
        log_error "解压失败"
        rm -rf "$tmpdir"
        exit 1
    }

    local caddy_bin
    caddy_bin=$(find "$tmpdir" -name 'caddy' -type f -perm /111 2>/dev/null | head -1)
    if [[ -z "$caddy_bin" ]]; then
        caddy_bin=$(find "$tmpdir" -name 'naive' -type f -perm /111 2>/dev/null | head -1)
    fi
    if [[ -z "$caddy_bin" ]]; then
        log_error "未找到 caddy/naive 二进制文件"
        rm -rf "$tmpdir"
        exit 1
    fi

    cp "$caddy_bin" /usr/local/bin/caddy-naive
    chmod +x /usr/local/bin/caddy-naive
    rm -rf "$tmpdir"

    if ! command -v caddy-naive &>/dev/null; then
        log_error "NaïveProxy 安装失败"
        exit 1
    fi

    log_info "NaïveProxy 安装成功: ${latest_release}"
}

# ── 模块入口 ─────────────────────────────────────────────────
run_naive() {
    log_step "========== NaïveProxy 安装 =========="
    install_naive
    log_info "========== NaïveProxy 安装完成 =========="
}

# ── 直接执行入口 ─────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ $EUID -ne 0 ]] && { echo "必须使用 root 权限运行"; exit 1; }
    run_naive
fi