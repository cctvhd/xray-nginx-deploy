#!/usr/bin/env bash
# ============================================================
# modules/system.sh
# 系统初始化模块
# 执行顺序：
#   1.1 检测系统信息
#   1.2 询问硬件配置
#   1.3 加载内核模块
#   1.4 sysctl 优化
#   1.5 ulimit/limits 优化（三处一致）
#   1.6 安装基础工具
#   1.7 时间同步
# ============================================================

# ── 1.1 检测系统信息 ─────────────────────────────────────────
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

    log_info "操作系统: $OS_NAME"
    log_info "系统架构: $(uname -m)"
}

# ── 检测内核版本及BBR支持 ────────────────────────────────────
detect_kernel() {
    KERNEL_VERSION=$(uname -r)
    KERNEL_MAJOR=$(uname -r | cut -d. -f1)
    KERNEL_MINOR=$(uname -r | cut -d. -f2)
    log_info "内核版本: $KERNEL_VERSION"

    if [[ $KERNEL_MAJOR -gt 6 ]] || \
       [[ $KERNEL_MAJOR -eq 6 && $KERNEL_MINOR -ge 4 ]]; then
        BBR_VERSION="bbrv3"
        log_info "BBR 支持: BBRv3 (内核 >= 6.4)"
    elif [[ $KERNEL_MAJOR -ge 5 ]]; then
        BBR_VERSION="bbr"
        log_info "BBR 支持: BBR (内核 >= 5.x)"
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
    [[ "${upgrade,,}" != "y" ]] && return

    case "$OS_ID" in
        ubuntu|debian)
            log_step "安装 HWE 内核..."
            $PKG_INSTALL \
                linux-generic-hwe-$(lsb_release -rs) 2>/dev/null || \
            $PKG_INSTALL linux-image-generic
            ;;
        centos|rhel|rocky|almalinux)
            log_step "安装 elrepo mainline 内核..."
            rpm --import \
                https://www.elrepo.org/RPM-GPG-KEY-elrepo.org \
                2>/dev/null || true
            $PKG_INSTALL \
                https://www.elrepo.org/elrepo-release-$(rpm -E %rhel).el$(rpm -E %rhel).elrepo.noarch.rpm \
                2>/dev/null || true
            $PKG_INSTALL --enablerepo=elrepo-kernel kernel-ml
            grub2-set-default 0
            ;;
    esac

    log_warn "内核升级完成，需要重启后再运行脚本"
    read -rp "是否立即重启？[Y/n]: " reboot_now
    [[ "${reboot_now,,}" != "n" ]] && reboot
    exit 0
}

# ── 1.2 询问硬件配置 ─────────────────────────────────────────
collect_hardware_info() {
    echo ""
    log_step "配置服务器硬件信息"
    echo ""
    log_info "请根据实际情况填写，用于优化系统参数"
    echo ""

    # CPU 核心数
    read -rp "CPU 核心数 [如: 1, 2, 4, 8]: " HW_CPU_CORES
    while ! [[ "$HW_CPU_CORES" =~ ^[0-9]+$ ]] || \
          [[ "$HW_CPU_CORES" -lt 1 ]]; do
        log_warn "请输入有效的核心数"
        read -rp "CPU 核心数: " HW_CPU_CORES
    done

    # 内存大小
    read -rp "内存大小 GB [如: 1, 2, 4, 8, 16]: " HW_MEM_GB
    while ! [[ "$HW_MEM_GB" =~ ^[0-9]+$ ]] || \
          [[ "$HW_MEM_GB" -lt 1 ]]; do
        log_warn "请输入有效的内存大小"
        read -rp "内存大小 GB: " HW_MEM_GB
    done

    # 网口带宽
    echo "网口带宽 [如: 100m, 500m, 1g, 10g, 40g]"
    read -rp "网口带宽: " HW_BANDWIDTH
    HW_BANDWIDTH="${HW_BANDWIDTH,,}"
    while [[ -z "$HW_BANDWIDTH" ]]; do
        log_warn "请输入带宽"
        read -rp "网口带宽: " HW_BANDWIDTH
        HW_BANDWIDTH="${HW_BANDWIDTH,,}"
    done

    # 双栈
    read -rp "是否支持 IPv6 双栈？[y/N]: " hw_ipv6
    if [[ "${hw_ipv6,,}" == "y" ]]; then
        HW_DUAL_STACK="yes"
    else
        HW_DUAL_STACK="no"
    fi

    # 磁盘类型
    read -rp "磁盘类型 [ssd/hdd，默认 ssd]: " HW_DISK_TYPE
    HW_DISK_TYPE="${HW_DISK_TYPE,,}"
    [[ -z "$HW_DISK_TYPE" ]] && HW_DISK_TYPE="ssd"
    [[ "$HW_DISK_TYPE" != "ssd" && \
       "$HW_DISK_TYPE" != "hdd" ]] && HW_DISK_TYPE="ssd"

    # 汇总确认
    echo ""
    log_info "硬件配置确认："
    echo "  CPU:    ${HW_CPU_CORES} 核"
    echo "  内存:   ${HW_MEM_GB} GB"
    echo "  带宽:   ${HW_BANDWIDTH}"
    echo "  IPv6:   ${HW_DUAL_STACK}"
    echo "  磁盘:   ${HW_DISK_TYPE}"
    echo ""
    read -rp "确认以上配置？[Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        collect_hardware_info
    fi
}

# ── 根据带宽计算网络参数 ─────────────────────────────────────
calc_net_params() {
    # 解析带宽单位
    local bw="${HW_BANDWIDTH}"
    local bw_mbps=1000

    if [[ "$bw" == *"g" ]]; then
        bw_mbps=$(( ${bw%g} * 1000 ))
    elif [[ "$bw" == *"m" ]]; then
        bw_mbps=${bw%m}
    fi

    # 根据带宽计算 rmem/wmem
    # BDP = bandwidth * RTT，保守估计 RTT=300ms
    # rmem_max = bw_mbps * 1024 * 1024 / 8 * 0.3
    if [[ $bw_mbps -ge 10000 ]]; then
        # 10G+
        NET_RMEM_MAX=67108864   # 64MB
        NET_WMEM_MAX=67108864
        NET_RMEM="4096 87380 67108864"
        NET_WMEM="4096 65536 67108864"
        XRAY_PADDING="512-4096"
        XRAY_WINDOW_CLAMP=0
    elif [[ $bw_mbps -ge 1000 ]]; then
        # 1G
        NET_RMEM_MAX=16777216   # 16MB
        NET_WMEM_MAX=16777216
        NET_RMEM="4096 87380 16777216"
        NET_WMEM="4096 65536 16777216"
        XRAY_PADDING="128-2048"
        XRAY_WINDOW_CLAMP=1200
    else
        # 100M 及以下
        NET_RMEM_MAX=8388608    # 8MB
        NET_WMEM_MAX=8388608
        NET_RMEM="4096 87380 8388608"
        NET_WMEM="4096 65536 8388608"
        XRAY_PADDING="128-1024"
        XRAY_WINDOW_CLAMP=600
    fi
}

# ── 根据内存计算系统参数 ─────────────────────────────────────
calc_mem_params() {
    local mem_gb="${HW_MEM_GB}"

    if [[ $mem_gb -ge 8 ]]; then
        SYSCTL_SOMAXCONN=65535
        SYSCTL_NETDEV_BACKLOG=65536
        SYSCTL_NF_CONNTRACK=2000000
        NOFILE_LIMIT=1048576
    elif [[ $mem_gb -ge 4 ]]; then
        SYSCTL_SOMAXCONN=32768
        SYSCTL_NETDEV_BACKLOG=32768
        SYSCTL_NF_CONNTRACK=1000000
        NOFILE_LIMIT=1048576
    elif [[ $mem_gb -ge 2 ]]; then
        SYSCTL_SOMAXCONN=16384
        SYSCTL_NETDEV_BACKLOG=16384
        SYSCTL_NF_CONNTRACK=500000
        NOFILE_LIMIT=524288
    else
        # 1GB 及以下
        SYSCTL_SOMAXCONN=8192
        SYSCTL_NETDEV_BACKLOG=8192
        SYSCTL_NF_CONNTRACK=262144
        NOFILE_LIMIT=262144
    fi
}

# ── 根据磁盘类型计算 vm 参数 ─────────────────────────────────
calc_disk_params() {
    if [[ "${HW_DISK_TYPE}" == "ssd" ]]; then
        VM_DIRTY_RATIO=10
        VM_DIRTY_BACKGROUND_RATIO=5
        VM_SWAPPINESS=10
    else
        VM_DIRTY_RATIO=20
        VM_DIRTY_BACKGROUND_RATIO=10
        VM_SWAPPINESS=30
    fi
}

# ── 1.3 加载内核模块 ─────────────────────────────────────────
load_kernel_modules() {
    log_step "加载内核模块..."

    # 创建模块加载配置目录
    mkdir -p /etc/modules-load.d

    # nf_conntrack
    if ! lsmod | grep -q nf_conntrack; then
        modprobe nf_conntrack 2>/dev/null || true
    fi
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

    # tcp_bbr
    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf

    log_info "内核模块加载完成"
}

# ── 检测已有 sysctl 配置冲突 ─────────────────────────────────
check_sysctl_conflicts() {
    local params=(
        "fs.file-max"
        "fs.nr_open"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.somaxconn"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_congestion_control"
        "net.ipv4.tcp_fastopen"
        "vm.swappiness"
    )

    local conflicts=()

    for param in "${params[@]}"; do
        local found
        found=$(grep -r "^${param}\s*=" \
            /etc/sysctl.conf \
            /etc/sysctl.d/ \
            2>/dev/null | \
            grep -v "99-xray-optimize.conf" | \
            head -1)
        [[ -n "$found" ]] && conflicts+=("$found")
    done

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        echo ""
        log_warn "发现已有 sysctl 配置，将被覆盖："
        for c in "${conflicts[@]}"; do
            echo "  $c"
        done
        echo ""
        read -rp "是否继续覆盖？[Y/n]: " cont
        [[ "${cont,,}" == "n" ]] && return 1
    fi

    return 0
}

# ── 1.4 sysctl 优化 ──────────────────────────────────────────
optimize_sysctl() {
    log_step "优化系统内核参数..."

    # 先计算各项参数
    calc_net_params
    calc_mem_params
    calc_disk_params

    # 检测冲突
    check_sysctl_conflicts || return

    local sysctl_conf="/etc/sysctl.d/99-xray-optimize.conf"

    # IPv6 参数
    local ipv6_conf=""
    if [[ "${HW_DUAL_STACK}" == "yes" ]]; then
        ipv6_conf="net.ipv6.conf.all.disable_ipv6     = 0
net.ipv6.conf.default.disable_ipv6 = 0"
    else
        ipv6_conf="net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1"
    fi

    cat > "$sysctl_conf" << CONF
# ============================================================
# xray-nginx-deploy 系统优化参数
# 生成时间: $(date)
# 硬件: ${HW_CPU_CORES}核 / ${HW_MEM_GB}GB / ${HW_BANDWIDTH}
# ============================================================

# ── 文件描述符 ────────────────────────────────────────────────
# 必须在 limits.d 设置之前确保 nr_open >= nofile hard limit
fs.nr_open                          = ${NOFILE_LIMIT}
fs.file-max                         = ${NOFILE_LIMIT}

# ── TCP 拥塞控制 ──────────────────────────────────────────────
net.core.default_qdisc              = fq
net.ipv4.tcp_congestion_control     = bbr

# ── TCP 缓冲区 ────────────────────────────────────────────────
net.core.rmem_max                   = ${NET_RMEM_MAX}
net.core.wmem_max                   = ${NET_WMEM_MAX}
net.core.rmem_default               = 262144
net.core.wmem_default               = 262144
net.ipv4.tcp_rmem                   = ${NET_RMEM}
net.ipv4.tcp_wmem                   = ${NET_WMEM}
net.ipv4.tcp_mem                    = 786432 1048576 $(( NET_RMEM_MAX * 2 ))

# ── 网络连接优化 ──────────────────────────────────────────────
net.core.somaxconn                  = ${SYSCTL_SOMAXCONN}
net.core.netdev_max_backlog         = ${SYSCTL_NETDEV_BACKLOG}
net.ipv4.ip_local_port_range        = 1024 65535
net.ipv4.tcp_max_syn_backlog        = ${SYSCTL_SOMAXCONN}
net.ipv4.tcp_max_tw_buckets         = 2000000
net.ipv4.tcp_tw_reuse               = 1
net.ipv4.tcp_fin_timeout            = 30
net.ipv4.tcp_syncookies             = 1

# ── TCP 性能优化 ──────────────────────────────────────────────
net.ipv4.tcp_fastopen               = 3
net.ipv4.tcp_mtu_probing            = 1
net.ipv4.tcp_slow_start_after_idle  = 0
net.ipv4.tcp_notsent_lowat          = 16384
net.ipv4.tcp_keepalive_time         = 300
net.ipv4.tcp_keepalive_intvl        = 30
net.ipv4.tcp_keepalive_probes       = 3

# ── 连接跟踪 ─────────────────────────────────────────────────
net.netfilter.nf_conntrack_max      = ${SYSCTL_NF_CONNTRACK}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30

# ── 内存/磁盘优化 ─────────────────────────────────────────────
vm.swappiness                       = ${VM_SWAPPINESS}
vm.dirty_ratio                      = ${VM_DIRTY_RATIO}
vm.dirty_background_ratio           = ${VM_DIRTY_BACKGROUND_RATIO}
vm.overcommit_memory                = 1

# ── IPv6 配置 ─────────────────────────────────────────────────
${ipv6_conf}
CONF

    # 立即应用
    sysctl -p "$sysctl_conf" 2>&1 | while IFS= read -r line; do
        # 过滤掉 nf_conntrack 相关警告（模块未完全加载时）
        [[ "$line" == *"No such file"* ]] && \
            log_warn "$line" && continue
        log_info "$line"
    done

    log_info "sysctl 优化完成: $sysctl_conf"
}

# ── 1.5 ulimit / limits 优化（三处必须一致）─────────────────
optimize_limits() {
    log_step "优化文件描述符限制..."
    log_info "nofile 限制值: ${NOFILE_LIMIT}"
    log_info "与 fs.nr_open 保持一致"

    # 检测已有 limits 配置冲突
    local existing
    existing=$(grep -r "nofile" \
        /etc/security/limits.conf \
        /etc/security/limits.d/ \
        2>/dev/null | \
        grep -v "99-xray.conf" | \
        grep -v "^#")

    if [[ -n "$existing" ]]; then
        echo ""
        log_warn "发现已有 nofile 配置："
        echo "$existing" | while read -r line; do
            echo "  $line"
        done
        echo ""
        read -rp "是否覆盖？[Y/n]: " cont
        [[ "${cont,,}" == "n" ]] && return
    fi

    # 第一处：limits.d
    cat > /etc/security/limits.d/99-xray.conf << LIMITS
# xray-nginx-deploy - nofile 限制
# 必须与 fs.nr_open 保持一致: ${NOFILE_LIMIT}
*    soft nofile ${NOFILE_LIMIT}
*    hard nofile ${NOFILE_LIMIT}
root soft nofile ${NOFILE_LIMIT}
root hard nofile ${NOFILE_LIMIT}
LIMITS

    # 第二处：systemd system.conf.d
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-xray.conf << SYSTEMD
# xray-nginx-deploy - systemd 文件描述符限制
# 必须与 fs.nr_open 保持一致: ${NOFILE_LIMIT}
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
SYSTEMD

    # 第三处：PAM（确保 pam_limits 生效）
    local pam_files=(
        /etc/pam.d/common-session
        /etc/pam.d/sshd
    )
    for pam_file in "${pam_files[@]}"; do
        if [[ -f "$pam_file" ]] && \
           ! grep -q "pam_limits" "$pam_file"; then
            echo "session required pam_limits.so" >> "$pam_file"
            log_info "已添加 pam_limits 到: $pam_file"
        fi
    done

    # 立即应用 systemd
    systemctl daemon-reexec 2>/dev/null || true

    log_info "文件描述符限制配置完成"
    echo ""
    log_warn "⚠️  重要提示："
    log_warn "ulimit 设置需要重新登录 SSH 后才能生效"
    log_warn "验证方法：重新登录后执行 ulimit -Hn"
    log_warn "预期结果: ${NOFILE_LIMIT}"
    echo ""

    # 三处一致性验证提示
    log_info "三处配置一致性检查："
    echo "  fs.nr_open    = ${NOFILE_LIMIT} ✓ (已写入 sysctl)"
    echo "  limits.d      = ${NOFILE_LIMIT} ✓ (已写入)"
    echo "  systemd       = ${NOFILE_LIMIT} ✓ (已写入)"
    echo "  ulimit -Hn    = 需重新登录验证"
}

# ── 1.6 安装基础工具 ─────────────────────────────────────────
install_base_tools() {
    log_step "安装基础工具..."
    $PKG_UPDATE >/dev/null 2>&1

    local tools="curl wget unzip git lsof net-tools bind-utils"

    case "$OS_ID" in
        ubuntu|debian)
            tools="curl wget unzip git lsof net-tools dnsutils"
            ;;
        centos|rhel|rocky|almalinux)
            tools="curl wget unzip git lsof net-tools bind-utils"
            ;;
    esac

    $PKG_INSTALL $tools >/dev/null 2>&1
    log_info "基础工具安装完成"
}

# ── 1.7 时间同步 ─────────────────────────────────────────────
sync_time() {
    log_step "配置时间同步..."

    $PKG_INSTALL chrony >/dev/null 2>&1

    systemctl enable --now chronyd 2>/dev/null || \
    systemctl enable --now chrony  2>/dev/null || true

    chronyc makestep 2>/dev/null || true
    log_info "时间同步完成: $(date)"
}

# ── 模块入口 ─────────────────────────────────────────────────
run_system() {
    log_step "========== 系统初始化 =========="

    # 1.1 检测系统
    detect_os
    detect_kernel
    upgrade_kernel

    # 1.2 询问硬件配置
    collect_hardware_info

    # 1.3 加载内核模块（必须在 sysctl 之前）
    load_kernel_modules

    # 1.4 sysctl 优化（依赖硬件配置）
    optimize_sysctl

    # 1.5 ulimit/limits（依赖 sysctl 的 fs.nr_open）
    optimize_limits

    # 1.6 基础工具
    install_base_tools

    # 1.7 时间同步
    sync_time

    log_info "========== 系统初始化完成 =========="
    echo ""
    log_info "硬件配置已保存，后续模块将自动读取"
    log_warn "请重新登录 SSH 使 ulimit 生效后再继续下一步"
}
