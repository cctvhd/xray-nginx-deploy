#!/usr/bin/env bash
# ============================================================
# modules/system.sh
# 系统识别 + 内核优化 + BBR/BBRv3 配置
# ============================================================

# ── 系统识别 ────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID,,}"
        OS_VERSION="${VERSION_ID%%.*}"
        OS_NAME="$PRETTY_NAME"
    else
        log_error "无法识别操作系统"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_UPDATE="apt-get update -y"
            PKG_INSTALL="apt-get install -y"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf makecache -y"
            PKG_INSTALL="dnf install -y"
            ;;
        *)
            log_error "不支持的系统: $OS_NAME"
            exit 1
            ;;
    esac

    log_info "检测到系统: $OS_NAME"
}

# ── 内核版本检测 ─────────────────────────────────────────────
detect_kernel() {
    KERNEL_VERSION=$(uname -r)
    KERNEL_MAJOR=$(uname -r | cut -d. -f1)
    KERNEL_MINOR=$(uname -r | cut -d. -f2)
    log_info "当前内核: $KERNEL_VERSION"

    # BBRv3 需要内核 6.4+
    if [[ $KERNEL_MAJOR -gt 6 ]] || \
       [[ $KERNEL_MAJOR -eq 6 && $KERNEL_MINOR -ge 4 ]]; then
        BBR_VERSION="bbrv3"
        log_info "内核支持 BBRv3"
    elif [[ $KERNEL_MAJOR -ge 5 ]]; then
        BBR_VERSION="bbr"
        log_info "内核支持 BBR"
    else
        BBR_VERSION="none"
        log_warn "内核版本过低，建议升级到 5.x 以上"
    fi
}

# ── 升级内核（可选）─────────────────────────────────────────
upgrade_kernel() {
    if [[ "$BBR_VERSION" == "bbrv3" ]]; then
        log_info "当前内核已支持 BBRv3，无需升级"
        return
    fi

    echo ""
    read -rp "当前内核不支持 BBRv3，是否升级内核？[y/N]: " upgrade
    if [[ "${upgrade,,}" != "y" ]]; then
        log_warn "跳过内核升级，将使用 BBR"
        return
    fi

    case "$OS_ID" in
        ubuntu|debian)
            log_step "安装 mainline 内核..."
            $PKG_INSTALL linux-generic-hwe-$(lsb_release -rs) 2>/dev/null || \
            $PKG_INSTALL linux-image-generic
            log_warn "内核升级完成，需要重启后再运行脚本"
            read -rp "是否立即重启？[Y/n]: " reboot_now
            if [[ "${reboot_now,,}" != "n" ]]; then
                reboot
            fi
            exit 0
            ;;
        centos|rhel|rocky|almalinux)
            log_step "安装 elrepo mainline 内核..."
            $PKG_INSTALL elrepo-release 2>/dev/null || \
            rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
            $PKG_INSTALL https://www.elrepo.org/elrepo-release-$(rpm -E %rhel).noarch.rpm 2>/dev/null || true
            $PKG_INSTALL --enablerepo=elrepo-kernel kernel-ml
            grub2-set-default 0
            log_warn "内核升级完成，需要重启后再运行脚本"
            read -rp "是否立即重启？[Y/n]: " reboot_now
            if [[ "${reboot_now,,}" != "n" ]]; then
                reboot
            fi
            exit 0
            ;;
    esac
}

# ── 系统参数优化 ─────────────────────────────────────────────
optimize_sysctl() {
    log_step "优化系统内核参数..."

    local sysctl_conf="/etc/sysctl.d/99-xray-optimize.conf"

    # 根据 BBR 版本选择拥塞控制
    local congestion="bbr"

    cat > "$sysctl_conf" << SYSCTL
# ============================================================
# xray-nginx-deploy 系统优化参数
# 生成时间: $(date)
# 内核版本: $KERNEL_VERSION
# BBR版本:  $BBR_VERSION
# ============================================================

# ── TCP 拥塞控制 ──────────────────────────────────────────────
net.core.default_qdisc              = fq
net.ipv4.tcp_congestion_control     = ${congestion}

# ── TCP 缓冲区（16MB）────────────────────────────────────────
net.core.rmem_max                   = 16777216
net.core.wmem_max                   = 16777216
net.core.rmem_default               = 262144
net.core.wmem_default               = 262144
net.ipv4.tcp_rmem                   = 4096 87380 16777216
net.ipv4.tcp_wmem                   = 4096 65536 16777216
net.ipv4.tcp_mem                    = 786432 1048576 26777216

# ── TCP 性能优化 ──────────────────────────────────────────────
net.ipv4.tcp_fastopen               = 3
net.ipv4.tcp_mtu_probing            = 1
net.ipv4.tcp_slow_start_after_idle  = 0
net.ipv4.tcp_notsent_lowat          = 16384
net.ipv4.tcp_tw_reuse               = 1
net.ipv4.tcp_fin_timeout            = 30
net.ipv4.tcp_keepalive_time         = 300
net.ipv4.tcp_keepalive_intvl        = 30
net.ipv4.tcp_keepalive_probes       = 3
net.ipv4.tcp_max_syn_backlog        = 8192
net.ipv4.tcp_max_tw_buckets         = 2000000
net.ipv4.tcp_syncookies             = 1

# ── 网络连接优化 ──────────────────────────────────────────────
net.core.somaxconn                  = 32768
net.core.netdev_max_backlog         = 32768
net.ipv4.ip_local_port_range        = 1024 65535

# ── 文件描述符 ────────────────────────────────────────────────
fs.file-max                         = 1000000
fs.nr_open                          = 1000000
SYSCTL

    sysctl -p "$sysctl_conf" >/dev/null 2>&1
    log_info "系统内核参数优化完成"
}

# ── 文件描述符限制 ───────────────────────────────────────────
optimize_limits() {
    log_step "优化文件描述符限制..."

    cat > /etc/security/limits.d/99-xray.conf << LIMITS
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
LIMITS

    # systemd 限制
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-xray.conf << SYSTEMD
[Manager]
DefaultLimitNOFILE=1000000
SYSTEMD

    systemctl daemon-reexec 2>/dev/null || true
    log_info "文件描述符限制优化完成"
}

# ── 安装基础工具 ─────────────────────────────────────────────
install_base_tools() {
    log_step "安装基础工具..."
    $PKG_UPDATE >/dev/null 2>&1

    local tools="curl wget unzip socat git lsof net-tools"

    case "$OS_ID" in
        ubuntu|debian)
            tools="$tools ca-certificates gnupg2 lsb-release"
            ;;
        centos|rhel|rocky|almalinux)
            tools="$tools ca-certificates epel-release"
            ;;
    esac

    $PKG_INSTALL $tools >/dev/null 2>&1
    log_info "基础工具安装完成"
}

# ── 时区同步 ─────────────────────────────────────────────────
sync_time() {
    log_step "同步系统时间..."
    case "$OS_ID" in
        ubuntu|debian)
            $PKG_INSTALL chrony >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux)
            $PKG_INSTALL chrony >/dev/null 2>&1
            ;;
    esac
    systemctl enable --now chronyd 2>/dev/null || \
    systemctl enable --now chrony  2>/dev/null || true
    chronyc makestep 2>/dev/null || true
    log_info "时间同步完成: $(date)"
}

# ── 模块入口 ─────────────────────────────────────────────────
run_system() {
    log_step "========== 系统初始化 =========="
    detect_os
    detect_kernel
    upgrade_kernel
    install_base_tools
    sync_time
    optimize_sysctl
    optimize_limits
    log_info "========== 系统初始化完成 =========="
}
