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

GLOBAL_NR_OPEN=2097152
GLOBAL_FILE_MAX=4194304
GLOBAL_NOFILE_LIMIT=1048576
GLOBAL_NPROC_LIMIT=65536

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

# ── 检测内核版本及 BBR 支持 ──────────────────────────────────
# 输出变量：
#   KERNEL_VERSION             — 完整版本字符串
#   KERNEL_MAJOR / MINOR       — 主/次版本号
#   BBR_LEVEL                  — none / bbr / bbr_modern / bbr3
#     none        : 内核 < 4.9，不支持 BBR
#     bbr         : 4.9 ≤ 内核 < 5.0，基础 BBR v1
#     bbr_modern  : 5.0 ≤ 内核 < 6.13（含 EL10 6.12），现代 BBR v1
#     bbr3        : 内核 ≥ 6.13（mainline），BBR v3
#   KERNEL_UPGRADE_RECOMMENDED — true / false
#   KERNEL_UPGRADE_POSSIBLE    — true / false
#     AlmaLinux/Rocky/RHEL ≥ 10 暂无 ElRepo，设为 false
# ────────────────────────────────────────────────────────────
detect_kernel() {
    KERNEL_VERSION=$(uname -r)
    KERNEL_MAJOR=$(uname -r | cut -d. -f1)
    KERNEL_MINOR=$(uname -r | cut -d. -f2)

    log_info "内核版本: $KERNEL_VERSION"

    # ── BBR 支持分级 ────────────────────────────────────────
    if [[ $KERNEL_MAJOR -gt 6 ]] || \
       [[ $KERNEL_MAJOR -eq 6 && $KERNEL_MINOR -ge 13 ]]; then
        # mainline BBR v3（6.13 正式合并）
        BBR_LEVEL="bbr3"
        KERNEL_UPGRADE_RECOMMENDED=false
        log_info "BBR 支持: ✅ BBR v3 (mainline >= 6.13)"

    elif [[ $KERNEL_MAJOR -eq 6 && $KERNEL_MINOR -ge 12 ]]; then
        # EL10 发行版内核 6.12，未 backport BBR v3，仍为 v1
        # 但属于现代内核，同样写入全部 BBR v3 优化参数（无副作用）
        BBR_LEVEL="bbr_modern"
        KERNEL_UPGRADE_RECOMMENDED=false
        log_info "BBR 支持: ✅ BBR v1，现代内核 (EL10 6.12)"

    elif [[ $KERNEL_MAJOR -ge 5 ]]; then
        BBR_LEVEL="bbr_modern"
        KERNEL_UPGRADE_RECOMMENDED=false
        log_info "BBR 支持: ✅ BBR v1，现代内核 (>= 5.x)"

    elif [[ $KERNEL_MAJOR -eq 4 && $KERNEL_MINOR -ge 9 ]]; then
        BBR_LEVEL="bbr"
        KERNEL_UPGRADE_RECOMMENDED=false
        log_info "BBR 支持: ✅ BBR v1，基础版 (4.9 - 4.x)"

    else
        BBR_LEVEL="none"
        KERNEL_UPGRADE_RECOMMENDED=true
        log_warn "BBR 支持: ❌ 不支持 (内核 < 4.9)，建议升级内核"
    fi

    # ── 升级可行性判断 ───────────────────────────────────────
    # ElRepo 对 EL10（AlmaLinux/Rocky/RHEL 10+）暂无稳定支持
    KERNEL_UPGRADE_POSSIBLE=true
    if [[ "$OS_ID" =~ ^(almalinux|rocky|centos|rhel)$ ]]; then
        local os_major="${OS_VERSION:-0}"
        if [[ "$os_major" -ge 10 ]]; then
            KERNEL_UPGRADE_POSSIBLE=false
            log_info "升级判断: $OS_NAME (EL${os_major}) — ElRepo 暂不支持该版本，跳过升级"
        fi
    fi
}

# ── 升级内核（可选）─────────────────────────────────────────
upgrade_kernel() {
    # ① 内核已满足 BBR 要求，无需升级
    if [[ "$KERNEL_UPGRADE_RECOMMENDED" == "false" ]]; then
        log_info "当前内核 ($KERNEL_VERSION) 已满足 BBR 运行要求，无需升级"
        return 0
    fi

    # ② OS 层面暂无升级渠道
    if [[ "$KERNEL_UPGRADE_POSSIBLE" == "false" ]]; then
        log_warn "当前内核版本较低，但 $OS_NAME 暂无可用的自动升级渠道，建议手动处理"
        return 0
    fi

    echo ""
    log_warn "当前内核 ($KERNEL_VERSION) 不支持 BBR，建议升级"
    read -rp "是否自动升级到较新的通用内核？[y/N]: " upgrade_choice
    [[ "${upgrade_choice,,}" != "y" ]] && {
        log_warn "已跳过内核升级，BBR 相关优化将不会生效"
        return 0
    }

    log_step "开始内核升级..."
    local upgrade_ok=false

    case "$OS_ID" in
        # ── Debian / Ubuntu ─────────────────────────────────
        ubuntu|debian)
            local hwe_pkg
            hwe_pkg="linux-generic-hwe-$(lsb_release -rs 2>/dev/null || echo '')"
            log_info "尝试安装 HWE 内核: $hwe_pkg"

            if $PKG_INSTALL "$hwe_pkg" 2>&1 | tee /tmp/kernel_upgrade.log; then
                upgrade_ok=true
            else
                log_warn "HWE 内核安装失败，回退到 linux-image-generic"
                if $PKG_INSTALL linux-image-generic 2>&1 | \
                   tee -a /tmp/kernel_upgrade.log; then
                    upgrade_ok=true
                fi
            fi
            ;;

        # ── CentOS / RHEL / Rocky / AlmaLinux (EL < 10) ────
        centos|rhel|rocky|almalinux)
            local rhel_ver
            rhel_ver=$(rpm -E %rhel 2>/dev/null || echo "$OS_VERSION")
            local elrepo_rpm="https://www.elrepo.org/elrepo-release-${rhel_ver}.el${rhel_ver}.elrepo.noarch.rpm"
            local gpg_key="https://www.elrepo.org/RPM-GPG-KEY-elrepo.org"

            log_info "ElRepo 目标版本: EL${rhel_ver}"
            log_info "ElRepo RPM URL : $elrepo_rpm"

            log_info "正在导入 ElRepo GPG Key..."
            rpm --import "$gpg_key" 2>&1 || \
                log_warn "GPG Key 导入失败（可能已存在），继续..."

            log_info "正在安装 ElRepo 仓库..."
            if ! dnf install -y "$elrepo_rpm" 2>&1 | \
               tee /tmp/kernel_upgrade.log; then
                log_error "ElRepo 仓库安装失败，升级中止"
                log_error "详细日志: /tmp/kernel_upgrade.log"
                log_warn "请手动参考: https://elrepo.org/tiki/HomePage"
                return 1
            fi

            log_info "正在安装 kernel-ml（mainline）..."
            if dnf install -y --enablerepo=elrepo-kernel kernel-ml \
               2>&1 | tee -a /tmp/kernel_upgrade.log; then
                upgrade_ok=true
                grub2-set-default 0 2>/dev/null || true
                log_info "已将新内核设置为默认启动项"
            else
                log_error "kernel-ml 安装失败"
                log_error "详细日志: /tmp/kernel_upgrade.log"
                return 1
            fi
            ;;
    esac

    # ── 结果反馈 ────────────────────────────────────────────
    echo ""
    if [[ "$upgrade_ok" == "true" ]]; then
        local new_kernel=""
        case "$OS_ID" in
            ubuntu|debian)
                new_kernel=$(dpkg -l 'linux-image-*' 2>/dev/null | \
                    awk '/^ii/{print $2}' | sort -V | tail -1)
                ;;
            centos|rhel|rocky|almalinux)
                new_kernel=$(rpm -q kernel-ml 2>/dev/null | \
                    sort -V | tail -1)
                ;;
        esac
        log_info "✅ 内核升级成功"
        [[ -n "$new_kernel" ]] && log_info "   新内核包: $new_kernel"
        log_warn "⚠️  需要重启后新内核才会生效"
        echo ""
        read -rp "是否立即重启服务器？[Y/n]: " reboot_now
        [[ "${reboot_now,,}" != "n" ]] && {
            log_info "正在重启..."
            reboot
        }
        log_warn "请手动重启后重新运行脚本以使新内核生效"
        exit 0
    else
        log_error "❌ 内核升级失败，脚本将继续，但 BBR 参数可能无法生效"
        log_warn "详细日志: /tmp/kernel_upgrade.log"
    fi
}

# ── 硬件参数归一化辅助 ───────────────────────────────────────
is_decimal_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

normalize_stack_mode() {
    case "${1:-}" in
        yes|dual|dualstack|ipv4v6) echo "dual" ;;
        no|ipv4|v4|ipv4-only)      echo "ipv4" ;;
        ipv6|v6|ipv6-only)         echo "ipv6" ;;
        *)                         echo "ipv4" ;;
    esac
}

detect_stack_mode() {
    local has_v4=0 has_v6=0

    ip -o -4 addr show scope global 2>/dev/null | \
        grep -q . && has_v4=1 || true
    ip -o -6 addr show scope global 2>/dev/null | \
        grep -v ' fe80:' | grep -q . && has_v6=1 || true

    if [[ $has_v4 -eq 1 && $has_v6 -eq 1 ]]; then
        echo "dual"
    elif [[ $has_v6 -eq 1 ]]; then
        echo "ipv6"
    else
        echo "ipv4"
    fi
}

parse_memory_gb_to_mb() {
    local value="${1,,}"
    value="${value// /}"
    value="${value%gb}"
    value="${value%g}"

    is_decimal_number "$value" || return 1

    awk -v v="$value" 'BEGIN {
        mb = int(v * 1024 + 0.5)
        if (mb < 1024) { exit 1 }
        print mb
    }'
}

parse_bandwidth_to_mbps() {
    local value="${1,,}"
    local number unit

    value="${value// /}"
    if [[ "$value" =~ ^([0-9]+([.][0-9]+)?)([gm])(b)?$ ]]; then
        number="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
    else
        return 1
    fi

    awk -v v="$number" -v u="$unit" 'BEGIN {
        if (u == "g") { print int(v * 1000 + 0.5) }
        else          { print int(v + 0.5) }
    }'
}

# ── 1.2 询问硬件配置 ─────────────────────────────────────────
collect_hardware_info() {
    echo ""
    log_step "配置服务器硬件信息"
    echo ""
    log_info "请根据实际情况填写物理规格，用于优化系统参数"
    echo ""

    # ── CPU 核心数 ───────────────────────────────────────────
    local auto_cpu
    auto_cpu=$(nproc 2>/dev/null || echo 1)
    read -rp "CPU 核心数 [检测值 ${auto_cpu}，直接回车使用]: " HW_CPU_CORES
    HW_CPU_CORES="${HW_CPU_CORES:-$auto_cpu}"
    while ! [[ "$HW_CPU_CORES" =~ ^[0-9]+$ ]] || \
          [[ "$HW_CPU_CORES" -lt 1 ]]; do
        log_warn "请输入有效的核心数"
        read -rp "CPU 核心数: " HW_CPU_CORES
    done

    # ── 内存大小 ─────────────────────────────────────────────
    # 自动检测物理内存并取整到常见规格，避免 OS 保留导致分档偏低
    local auto_mem_mb auto_mem_gb suggested_gb
    auto_mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    auto_mem_gb=$(awk -v m="$auto_mem_mb" \
        'BEGIN{printf "%.1f", m/1024}')

    # 向上取整到最近的常见规格（1/2/4/8/16/32GB）
    if   [[ $auto_mem_mb -ge 28672 ]]; then suggested_gb=32
    elif [[ $auto_mem_mb -ge 14336 ]]; then suggested_gb=16
    elif [[ $auto_mem_mb -ge  6144 ]]; then suggested_gb=8
    elif [[ $auto_mem_mb -ge  3072 ]]; then suggested_gb=4
    elif [[ $auto_mem_mb -ge  1536 ]]; then suggested_gb=2
    else suggested_gb=1
    fi

    log_info "检测内存: ${auto_mem_gb}GB → 建议按物理规格填写: ${suggested_gb}GB"
    read -rp "内存大小 GB [直接回车使用建议值 ${suggested_gb}GB]: " HW_MEM_GB
    HW_MEM_GB="${HW_MEM_GB:-$suggested_gb}"

    while ! parse_memory_gb_to_mb "$HW_MEM_GB" >/dev/null; do
        log_warn "请输入有效的内存大小，支持小数如 2.5 或 2.5GB"
        read -rp "内存大小 GB: " HW_MEM_GB
    done
    HW_MEM_GB="${HW_MEM_GB,,}"
    HW_MEM_GB="${HW_MEM_GB// /}"
    HW_MEM_GB="${HW_MEM_GB%gb}"
    HW_MEM_GB="${HW_MEM_GB%g}"

    # ── 网口带宽 ─────────────────────────────────────────────
    echo "网口带宽 [如: 100m, 500m, 1g, 2.5g, 10g]"
    read -rp "网口带宽: " HW_BANDWIDTH
    HW_BANDWIDTH="${HW_BANDWIDTH,,}"
    while ! parse_bandwidth_to_mbps "$HW_BANDWIDTH" >/dev/null; do
        log_warn "请输入有效的带宽，支持 2500m / 2.5g / 10g"
        read -rp "网口带宽: " HW_BANDWIDTH
        HW_BANDWIDTH="${HW_BANDWIDTH,,}"
    done
    HW_BANDWIDTH="${HW_BANDWIDTH// /}"
    HW_BANDWIDTH="${HW_BANDWIDTH%b}"

    # ── 网络栈 ───────────────────────────────────────────────
    local detected_stack
    detected_stack=$(detect_stack_mode)
    echo "网络栈类型："
    echo "  1. 双栈 IPv4 + IPv6"
    echo "  2. 单栈 IPv4"
    echo "  3. 单栈 IPv6"
    case "$detected_stack" in
        dual) log_info "自动检测建议: 双栈 IPv4 + IPv6" ;;
        ipv6) log_info "自动检测建议: 单栈 IPv6" ;;
        *)    log_info "自动检测建议: 单栈 IPv4" ;;
    esac
    local stack_choice default_choice
    case "$detected_stack" in
        dual) default_choice="1" ;;
        ipv6) default_choice="3" ;;
        *)    default_choice="2" ;;
    esac
    read -rp "请选择 [1-3，默认 ${default_choice}]: " stack_choice
    case "${stack_choice:-$default_choice}" in
        1) HW_DUAL_STACK="dual" ;;
        3) HW_DUAL_STACK="ipv6" ;;
        *) HW_DUAL_STACK="ipv4" ;;
    esac

    # ── 磁盘类型 ─────────────────────────────────────────────
    read -rp "磁盘类型 [ssd/hdd，默认 ssd]: " HW_DISK_TYPE
    HW_DISK_TYPE="${HW_DISK_TYPE,,}"
    [[ -z "$HW_DISK_TYPE" ]] && HW_DISK_TYPE="ssd"
    [[ "$HW_DISK_TYPE" != "ssd" && \
       "$HW_DISK_TYPE" != "hdd" ]] && HW_DISK_TYPE="ssd"

    # ── 汇总确认 ─────────────────────────────────────────────
    echo ""
    log_info "硬件配置确认："
    echo "  CPU:    ${HW_CPU_CORES} 核"
    echo "  内存:   ${HW_MEM_GB} GB"
    echo "  带宽:   ${HW_BANDWIDTH}"
    echo "  网络栈: ${HW_DUAL_STACK}"
    echo "  磁盘:   ${HW_DISK_TYPE}"
    echo ""
    read -rp "确认以上配置？[Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        collect_hardware_info
    fi
}

# ── 根据带宽计算网络参数 ─────────────────────────────────────
calc_net_params() {
    local bw_mbps
    bw_mbps=$(parse_bandwidth_to_mbps "${HW_BANDWIDTH}") || bw_mbps=1000

    if [[ $bw_mbps -ge 10000 ]]; then
        # 10G+
        NET_CORE_RMEM_MAX=33554432      # 32MB
        NET_CORE_WMEM_MAX=33554432
        NET_RMEM="4096 262144 33554432"
        NET_WMEM="4096 262144 33554432"
    elif [[ $bw_mbps -ge 1000 ]]; then
        # 1G
        NET_CORE_RMEM_MAX=16777216      # 16MB
        NET_CORE_WMEM_MAX=16777216
        NET_RMEM="4096 262144 16777216"
        NET_WMEM="4096 262144 16777216"
    else
        # 100M 及以下，rmem_max 保持 16MB 兼顾 QUIC/Hysteria2
        NET_CORE_RMEM_MAX=16777216
        NET_CORE_WMEM_MAX=16777216
        NET_RMEM="4096 262144 8388608"
        NET_WMEM="4096 262144 8388608"
    fi
}

# ── 根据内存与 CPU 计算系统参数 ──────────────────────────────
# 分档阈值较标准值下移 10%，解决 OS 保留内存导致的分档偏低问题
# 参数值较基准上调 10%，适配代理服务器高并发场景（实测内存余量充足）
calc_mem_params() {
    local cpu_cores="${HW_CPU_CORES:-1}"
    local mem_mb
    mem_mb=$(parse_memory_gb_to_mb "${HW_MEM_GB}") || mem_mb=2048

    # 阈值：8GB→7372  4GB→3686  2GB→1843  其余→1GB
    if [[ $mem_mb -ge 7372 ]]; then
        SYSCTL_SOMAXCONN=36044
        SYSCTL_NETDEV_BACKLOG=36044
        SYSCTL_NF_CONNTRACK=1153433
        SYSCTL_TCP_MAX_TW_BUCKETS=1153433
    elif [[ $mem_mb -ge 3686 ]]; then
        SYSCTL_SOMAXCONN=18022
        SYSCTL_NETDEV_BACKLOG=18022
        SYSCTL_NF_CONNTRACK=576716
        SYSCTL_TCP_MAX_TW_BUCKETS=576716
    elif [[ $mem_mb -ge 1843 ]]; then
        # 物理 2GB 机器（OS 检测约 1.7GB）落入此档
        SYSCTL_SOMAXCONN=9011
        SYSCTL_NETDEV_BACKLOG=9011
        SYSCTL_NF_CONNTRACK=288358
        SYSCTL_TCP_MAX_TW_BUCKETS=288358
    else
        # 1GB 及以下
        SYSCTL_SOMAXCONN=4505
        SYSCTL_NETDEV_BACKLOG=4505
        SYSCTL_NF_CONNTRACK=144179
        SYSCTL_TCP_MAX_TW_BUCKETS=144179
    fi

    # CPU 核数上限（代理场景，1核封顶提升至 16384）
    if [[ $cpu_cores -le 1 ]]; then
        (( SYSCTL_SOMAXCONN > 16384 ))       && SYSCTL_SOMAXCONN=16384
        (( SYSCTL_NETDEV_BACKLOG > 16384 ))  && SYSCTL_NETDEV_BACKLOG=16384
        (( SYSCTL_NF_CONNTRACK > 288358 ))   && SYSCTL_NF_CONNTRACK=288358
        (( SYSCTL_TCP_MAX_TW_BUCKETS > 288358 )) && \
            SYSCTL_TCP_MAX_TW_BUCKETS=288358
    elif [[ $cpu_cores -le 2 ]]; then
        (( SYSCTL_SOMAXCONN > 18022 ))       && SYSCTL_SOMAXCONN=18022
        (( SYSCTL_NETDEV_BACKLOG > 18022 ))  && SYSCTL_NETDEV_BACKLOG=18022
        (( SYSCTL_NF_CONNTRACK > 576716 ))   && SYSCTL_NF_CONNTRACK=576716
        (( SYSCTL_TCP_MAX_TW_BUCKETS > 576716 )) && \
            SYSCTL_TCP_MAX_TW_BUCKETS=576716
    elif [[ $cpu_cores -le 4 ]]; then
        (( SYSCTL_SOMAXCONN > 36044 ))       && SYSCTL_SOMAXCONN=36044
        (( SYSCTL_NETDEV_BACKLOG > 36044 ))  && SYSCTL_NETDEV_BACKLOG=36044
        (( SYSCTL_NF_CONNTRACK > 1153433 ))  && SYSCTL_NF_CONNTRACK=1153433
        (( SYSCTL_TCP_MAX_TW_BUCKETS > 1153433 )) && \
            SYSCTL_TCP_MAX_TW_BUCKETS=1153433
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

    mkdir -p /etc/modules-load.d

    # nf_conntrack
    if ! lsmod | grep -q nf_conntrack; then
        if modprobe nf_conntrack 2>/dev/null; then
            log_info "nf_conntrack 模块已加载"
        else
            log_warn "nf_conntrack 模块加载失败（某些容器环境下属正常）"
        fi
    else
        log_info "nf_conntrack 模块已就绪"
    fi
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

    # tcp_bbr
    if [[ "$BBR_LEVEL" != "none" ]]; then
        if ! lsmod | grep -q tcp_bbr; then
            if modprobe tcp_bbr 2>/dev/null; then
                log_info "tcp_bbr 模块已加载"
            else
                log_warn "tcp_bbr 模块加载失败，将在 sysctl 应用时再次尝试"
            fi
        else
            log_info "tcp_bbr 模块已就绪"
        fi
        echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
    else
        log_warn "当前内核不支持 BBR，跳过 tcp_bbr 模块加载"
    fi

    log_info "内核模块配置完成"
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

# ── 验证 BBR 及关键参数是否生效 ─────────────────────────────
verify_bbr() {
    echo ""
    log_step "验证关键参数..."

    local cc qdisc

    # 拥塞控制
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]]; then
        log_info "✅  net.ipv4.tcp_congestion_control = bbr"
    else
        log_warn "⚠️  net.ipv4.tcp_congestion_control = $cc  (期望: bbr)"
        log_warn "    请手动执行: modprobe tcp_bbr && sysctl -w net.ipv4.tcp_congestion_control=bbr"
    fi

    # 队列调度器
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    if [[ "$qdisc" == "fq" ]]; then
        log_info "✅  net.core.default_qdisc = fq"
    else
        log_warn "⚠️  net.core.default_qdisc = $qdisc  (期望: fq)"
    fi

    # BBR 模块
    if lsmod | grep -q tcp_bbr; then
        log_info "✅  tcp_bbr 模块: 已加载"
    else
        log_warn "⚠️  tcp_bbr 模块: 未加载"
    fi

    # BBR v3 / ECN
    if [[ "$BBR_LEVEL" == "bbr3" ]]; then
        local ecn
        ecn=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo "unknown")
        if [[ "$ecn" == "1" ]]; then
            log_info "✅  net.ipv4.tcp_ecn = 1 (BBR v3 优化已启用)"
        else
            log_warn "⚠️  net.ipv4.tcp_ecn = $ecn  (期望: 1)"
        fi
    fi

    # 文件描述符
    local nr_open file_max
    nr_open=$(sysctl -n fs.nr_open  2>/dev/null || echo "unknown")
    file_max=$(sysctl -n fs.file-max 2>/dev/null || echo "unknown")
    log_info "✅  fs.nr_open  = $nr_open"
    log_info "✅  fs.file-max = $file_max"

    # BBR 级别汇总
    echo ""
    case "$BBR_LEVEL" in
        bbr3)       log_info "BBR 级别: BBR v3 (内核 >= 6.13，最优)" ;;
        bbr_modern) log_info "BBR 级别: BBR v1，现代内核 (5.x / EL10 6.12)" ;;
        bbr)        log_info "BBR 级别: BBR v1，基础版 (内核 4.9 - 4.x)" ;;
        none)       log_warn "BBR 级别: 不可用，请升级内核" ;;
    esac
    echo ""
}

# ── 1.4 sysctl 优化 ──────────────────────────────────────────
optimize_sysctl() {
    log_step "优化系统内核参数..."

    calc_net_params
    calc_mem_params
    calc_disk_params

    check_sysctl_conflicts || return

    local sysctl_conf="/etc/sysctl.d/99-xray-optimize.conf"

    # ── IPv6 参数块 ──────────────────────────────────────────
    local ipv6_conf=""
    local stack_mode
    stack_mode=$(normalize_stack_mode "${HW_DUAL_STACK:-ipv4}")

    if [[ "$stack_mode" == "dual" || "$stack_mode" == "ipv6" ]]; then
        ipv6_conf="net.ipv6.conf.all.disable_ipv6     = 0
net.ipv6.conf.default.disable_ipv6 = 0"
    else
        ipv6_conf="net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1"
    fi

    # ── BBR / 拥塞控制块 ────────────────────────────────────
    # tcp_ecn 对所有支持 BBR 的内核均有益无害，统一写入
    # bbr3 专属：ECN 配合 BBR v3 多流公平性改进效果最佳
    # bbr_modern / bbr：ECN 辅助拥塞检测，对代理交互流量有益
    local bbr_conf=""
    if [[ "$BBR_LEVEL" != "none" ]]; then
        bbr_conf="net.core.default_qdisc              = fq
net.ipv4.tcp_congestion_control     = bbr
# ECN 显式拥塞通知：对所有 BBR 版本均有益，bbr3 效果最佳
net.ipv4.tcp_ecn                    = 1"
    else
        bbr_conf="# BBR 不可用: 当前内核 ($KERNEL_VERSION) < 4.9
# 升级内核后重新运行脚本即可自动启用
# net.core.default_qdisc            = fq
# net.ipv4.tcp_congestion_control   = bbr
# net.ipv4.tcp_ecn                  = 1"
        log_warn "内核不支持 BBR，相关参数已注释，其余优化正常写入"
    fi

    cat > "$sysctl_conf" << CONF
# ============================================================
# xray-nginx-deploy 系统优化参数
# 生成时间: $(date)
# 操作系统: ${OS_NAME}
# 内核版本: ${KERNEL_VERSION}
# BBR 级别: ${BBR_LEVEL}
# 硬件: ${HW_CPU_CORES}核 / ${HW_MEM_GB}GB / ${HW_BANDWIDTH}
# ============================================================

# ── 文件描述符 ────────────────────────────────────────────────
fs.nr_open                          = ${GLOBAL_NR_OPEN}
fs.file-max                         = ${GLOBAL_FILE_MAX}

# ── TCP 拥塞控制 ──────────────────────────────────────────────
${bbr_conf}

# ── TCP / QUIC 缓冲区 ────────────────────────────────────────
# rmem_max / wmem_max 同时作为 QUIC/Hysteria2 UDP socket 缓冲区上限
# tcp_rmem/wmem 中间值设为 262144(256KB)，减少代理短连接的扩容延迟
net.core.rmem_max                   = ${NET_CORE_RMEM_MAX}
net.core.wmem_max                   = ${NET_CORE_WMEM_MAX}
net.core.rmem_default               = 262144
net.core.wmem_default               = 262144
net.ipv4.tcp_rmem                   = ${NET_RMEM}
net.ipv4.tcp_wmem                   = ${NET_WMEM}
# Hysteria2 / QUIC UDP 缓冲区下限
net.ipv4.udp_rmem_min               = 8192
net.ipv4.udp_wmem_min               = 8192

# ── 网络连接优化 ──────────────────────────────────────────────
net.core.somaxconn                  = ${SYSCTL_SOMAXCONN}
net.core.netdev_max_backlog         = ${SYSCTL_NETDEV_BACKLOG}
net.ipv4.ip_local_port_range        = 1024 65535
net.ipv4.tcp_max_syn_backlog        = ${SYSCTL_SOMAXCONN}
net.ipv4.tcp_max_tw_buckets         = ${SYSCTL_TCP_MAX_TW_BUCKETS}
net.ipv4.tcp_tw_reuse               = 2
net.ipv4.tcp_fin_timeout            = 30
net.ipv4.tcp_syncookies             = 1

# ── TCP 性能优化 ──────────────────────────────────────────────
net.ipv4.tcp_fastopen               = 3
net.ipv4.tcp_mtu_probing            = 1
net.ipv4.tcp_slow_start_after_idle  = 0
net.ipv4.tcp_keepalive_time         = 300
net.ipv4.tcp_keepalive_intvl        = 30
net.ipv4.tcp_keepalive_probes       = 3
# 限制 TCP 发送队列积压，降低代理交互流量延迟（浏览器/短连接场景）
net.ipv4.tcp_notsent_lowat          = 131072

# ── 连接跟踪 ─────────────────────────────────────────────────
net.netfilter.nf_conntrack_max                     = ${SYSCTL_NF_CONNTRACK}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30

# ── 内存/磁盘优化 ─────────────────────────────────────────────
vm.swappiness                       = ${VM_SWAPPINESS}
vm.dirty_ratio                      = ${VM_DIRTY_RATIO}
vm.dirty_background_ratio           = ${VM_DIRTY_BACKGROUND_RATIO}
vm.overcommit_memory                = 0

# ── IPv6 配置 ─────────────────────────────────────────────────
${ipv6_conf}
CONF

    log_info "sysctl 配置已写入: $sysctl_conf"
    log_step "正在应用 sysctl 参数..."

    local apply_errors=0
    while IFS= read -r line; do
        if [[ "$line" == *"No such file"*  ]] || \
           [[ "$line" == *"Invalid argument"* ]] || \
           [[ "$line" == *"error"* ]]; then
            log_warn "sysctl 警告: $line"
            (( apply_errors++ )) || true
        else
            log_info "$line"
        fi
    done < <(sysctl -p "$sysctl_conf" 2>&1)

    if [[ $apply_errors -eq 0 ]]; then
        log_info "sysctl 全部参数应用成功 ✓"
    else
        log_warn "sysctl 有 ${apply_errors} 项警告（通常为模块未加载，不影响其他参数）"
    fi

    verify_bbr
}

# ── 1.5 ulimit / limits 优化（三处必须一致）─────────────────
optimize_limits() {
    log_step "优化 systemd / PAM 默认限制..."
    log_info "nofile 默认值: ${GLOBAL_NOFILE_LIMIT}"
    log_info "nproc 默认值:  ${GLOBAL_NPROC_LIMIT}"
    log_info "内核层保留更高余量: nr_open=${GLOBAL_NR_OPEN}, file-max=${GLOBAL_FILE_MAX}"

    local existing
    existing=$(grep -rE "nofile|nproc" \
        /etc/security/limits.conf \
        /etc/security/limits.d/ \
        2>/dev/null | \
        grep -v "99-xray.conf" | \
        grep -v "^#")

    if [[ -n "$existing" ]]; then
        echo ""
        log_warn "发现已有 nofile / nproc 配置："
        echo "$existing" | while read -r line; do
            echo "  $line"
        done
        echo ""
        read -rp "是否覆盖？[Y/n]: " cont
        [[ "${cont,,}" == "n" ]] && return
    fi

    # 第一处：limits.d
    cat > /etc/security/limits.d/99-xray.conf << LIMITS
# xray-nginx-deploy - global nofile / nproc defaults
*    soft nofile ${GLOBAL_NOFILE_LIMIT}
*    hard nofile ${GLOBAL_NOFILE_LIMIT}
*    soft nproc  ${GLOBAL_NPROC_LIMIT}
*    hard nproc  ${GLOBAL_NPROC_LIMIT}
root soft nofile ${GLOBAL_NOFILE_LIMIT}
root hard nofile ${GLOBAL_NOFILE_LIMIT}
root soft nproc  ${GLOBAL_NPROC_LIMIT}
root hard nproc  ${GLOBAL_NPROC_LIMIT}
LIMITS

    # 第二处：systemd system.conf.d
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-xray.conf << SYSTEMD
# xray-nginx-deploy - systemd global service limits
[Manager]
DefaultLimitNOFILE=${GLOBAL_NOFILE_LIMIT}
DefaultLimitNPROC=${GLOBAL_NPROC_LIMIT}
SYSTEMD

    # 第三处：PAM
    local pam_files=()
    case "$OS_ID" in
        ubuntu|debian)
            pam_files=(
                /etc/pam.d/common-session
                /etc/pam.d/sshd
            )
            ;;
        centos|rhel|rocky|almalinux|fedora)
            pam_files=(
                /etc/pam.d/system-auth
                /etc/pam.d/password-auth
                /etc/pam.d/sshd
                /etc/pam.d/login
            )
            ;;
        *)
            pam_files=(/etc/pam.d/sshd)
            ;;
    esac
    for pam_file in "${pam_files[@]}"; do
        if [[ -f "$pam_file" ]] && \
           ! grep -q "pam_limits" "$pam_file"; then
            echo "session required pam_limits.so" >> "$pam_file"
            log_info "已添加 pam_limits 到: $pam_file"
        fi
    done

    systemctl daemon-reexec 2>/dev/null || true

    log_info "文件描述符限制配置完成"
    echo ""
    log_warn "⚠️  重要提示："
    log_warn "ulimit 设置需要重新登录 SSH 后才能生效"
    log_warn "验证方法：重新登录后执行 ulimit -Hn"
    log_warn "预期 nofile: ${GLOBAL_NOFILE_LIMIT}"
    echo ""

    log_info "三处配置一致性检查："
    echo "  fs.nr_open    = ${GLOBAL_NR_OPEN} ✓ (sysctl 天花板)"
    echo "  fs.file-max   = ${GLOBAL_FILE_MAX} ✓ (sysctl 天花板)"
    echo "  limits.d      = nofile ${GLOBAL_NOFILE_LIMIT} / nproc ${GLOBAL_NPROC_LIMIT} ✓"
    echo "  systemd       = nofile ${GLOBAL_NOFILE_LIMIT} / nproc ${GLOBAL_NPROC_LIMIT} ✓"
    echo "  ulimit -Hn    = 需重新登录验证"
}

tune_system_limits() {
    log_step "Apply system-wide runtime tuning..."

    rm -rf /etc/systemd/system/xray.service.d
    rm -rf /etc/systemd/system/xray@.service.d
    rm -f /etc/sysctl.d/98-xray-service-limits.conf

    optimize_sysctl
    optimize_limits
}

# ── 1.6 安装基础工具 ─────────────────────────────────────────
install_base_tools() {
    log_step "安装基础工具..."
    $PKG_UPDATE >/dev/null 2>&1

    local tools
    case "$OS_ID" in
        ubuntu|debian)
            tools="curl wget unzip git lsof net-tools dnsutils"
            ;;
        centos|rhel|rocky|almalinux)
            tools="curl wget unzip git lsof net-tools bind-utils"
            ;;
        *)
            tools="curl wget unzip git lsof net-tools"
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

    # 1.1 检测系统 & 内核
    detect_os
    detect_kernel

    # 1.2 按需升级内核
    upgrade_kernel

    # 1.3 询问硬件配置
    collect_hardware_info

    # 1.4 加载内核模块（必须在 sysctl 之前）
    load_kernel_modules

    # 1.5 system-wide runtime tuning (sysctl + limits + BBR 验证)
    tune_system_limits

    # 1.6 基础工具
    install_base_tools

    # 1.7 时间同步
    sync_time

    log_info "========== 系统初始化完成 =========="
    echo ""
    log_info "硬件配置已保存，后续模块将自动读取"
    log_warn "请重新登录 SSH 使 ulimit 生效后再继续下一步"
}