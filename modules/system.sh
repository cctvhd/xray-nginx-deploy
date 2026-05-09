#!/usr/bin/env bash
# ============================================================
# modules/system.sh
# 系统初始化模块 - 2026 最终独立版
# 策略：代理节点稳健上限 + 内核自适应，让软件按需使用内存
# ============================================================

# ── 全局资源常量 ─────────────────────────────────────────────
GLOBAL_NR_OPEN=2097152
GLOBAL_FILE_MAX=2097152
GLOBAL_NOFILE_LIMIT=1048576
GLOBAL_NPROC_LIMIT=65536

# ── 日志函数（独立运行时使用，与主脚本配合时会被覆盖） ───────
log_step() { echo -e "\e[36m[STEP]\e[0m $*"; }
log_info()  { echo -e "\e[32m[INFO]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*"; }

# save_state 空实现（与主脚本配合时会被覆盖）
save_state() { :; }

# ── 模块入口 ─────────────────────────────────────────────────
run_system() {
    log_step "========== 系统初始化 =========="

    detect_virt_type
    collect_hardware_info
    detect_kernel                # 检测当前内核版本
    upgrade_kernel               # 升级到 ELRepo mainline（仅 RHEL 系）
    install_base_tools           # 先装工具，后续优化依赖 ethtool/tc
    optimize_hardware_interrupts
    optimize_sysctl
    optimize_limits
    sync_time
    print_optimization_summary

    log_info "========== 系统初始化完成 =========="
}

# ── 硬件信息收集（自动检测 + 用户确认/覆盖）────────────────
collect_hardware_info() {
    log_step "收集硬件信息..."

    # ── 自动检测 CPU 核心数 ──────────────────────────────────
    if [[ -z "${HW_CPU_CORES:-}" ]]; then
        HW_CPU_CORES=$(nproc 2>/dev/null \
            || grep -c '^processor' /proc/cpuinfo 2>/dev/null \
            || echo 4)
    fi
    [[ "$HW_CPU_CORES" -gt 0 ]] 2>/dev/null || HW_CPU_CORES=4

    # ── 自动检测内存 ─────────────────────────────────────────
    local mem_kb mem_mb mem_gb_auto
    mem_kb=$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')
    mem_mb=$(( mem_kb / 1024 ))
    mem_gb_auto=$(awk -v m="$mem_mb" 'BEGIN{printf "%.1f", m/1024}')
    if [[ -z "${HW_MEM_GB:-}" ]]; then
        HW_MEM_GB="$mem_gb_auto"
    fi

    # ── 自动检测磁盘类型 ─────────────────────────────────────
    local disk_auto="unknown"
    local root_dev
    root_dev=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1)
    if [[ -n "$root_dev" ]]; then
        local rotational
        rotational=$(cat "/sys/block/${root_dev}/queue/rotational" 2>/dev/null || echo "")
        if [[ "$rotational" == "0" ]]; then
            disk_auto="ssd"
        elif [[ "$rotational" == "1" ]]; then
            disk_auto="hdd"
        fi
    fi
    if [[ -z "${HW_DISK_TYPE:-}" || "${HW_DISK_TYPE}" == "unknown" ]]; then
        HW_DISK_TYPE="$disk_auto"
    fi

    # ── 自动检测双栈 ─────────────────────────────────────────
    local dual_auto="ipv4-only"
    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        dual_auto="dual-stack"
    fi
    if [[ -z "${HW_DUAL_STACK:-}" || "${HW_DUAL_STACK}" == "unknown" ]]; then
        HW_DUAL_STACK="$dual_auto"
    fi

    # ── 自动检测带宽（测速，可跳过）────────────────────────
    if [[ -z "${HW_BANDWIDTH:-}" || "${HW_BANDWIDTH}" == "unknown" ]]; then
        HW_BANDWIDTH="unknown"
    fi

    # ── 打印自动检测结果 ─────────────────────────────────────
    echo ""
    log_info "═══ 硬件自动检测结果 ═══════════════════"
    log_info "  CPU 核心数 : ${HW_CPU_CORES}"
    log_info "  物理内存   : ${mem_mb}MB (${HW_MEM_GB}GB)"
    log_info "  磁盘类型   : ${HW_DISK_TYPE}"
    log_info "  网络栈     : ${HW_DUAL_STACK}"
    log_info "  带宽       : ${HW_BANDWIDTH}"
    log_info "════════════════════════════════════════"
    echo ""

    # ── 询问是否自定义 ───────────────────────────────────────
    local customize
    read -rp "是否自定义硬件参数？[y/N（直接回车使用自动检测值）]: " customize
    if [[ "${customize,,}" != "y" ]]; then
        log_info "使用自动检测值，继续..."
        return 0
    fi

    # ── 自定义 CPU 核心数 ────────────────────────────────────
    echo ""
    local input_cores
    read -rp "CPU 核心数 [当前: ${HW_CPU_CORES}，直接回车保持]: " input_cores
    if [[ -n "$input_cores" && "$input_cores" =~ ^[0-9]+$ && "$input_cores" -gt 0 ]]; then
        HW_CPU_CORES="$input_cores"
        log_info "CPU 核心数已设为: ${HW_CPU_CORES}"
    fi

    # ── 自定义内存 ───────────────────────────────────────────
    local input_mem
    read -rp "物理内存 GB（小数点格式，如 3.8）[当前: ${HW_MEM_GB}，直接回车保持]: " input_mem
    if [[ -n "$input_mem" && "$input_mem" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        HW_MEM_GB="$input_mem"
        log_info "物理内存已设为: ${HW_MEM_GB}GB"
    fi

    # ── 自定义带宽 ───────────────────────────────────────────
    echo ""
    echo "带宽选项："
    echo "  1. 100Mbps"
    echo "  2. 500Mbps"
    echo "  3. 1Gbps"
    echo "  4. 10Gbps"
    echo "  5. 自定义"
    echo "  6. 保持当前 (${HW_BANDWIDTH})"
    local bw_choice
    read -rp "请选择 [1-6，默认6]: " bw_choice
    case "${bw_choice:-6}" in
        1) HW_BANDWIDTH="100Mbps" ;;
        2) HW_BANDWIDTH="500Mbps" ;;
        3) HW_BANDWIDTH="1Gbps" ;;
        4) HW_BANDWIDTH="10Gbps" ;;
        5)
            local input_bw
            read -rp "输入带宽（如 200Mbps、2Gbps）: " input_bw
            [[ -n "$input_bw" ]] && HW_BANDWIDTH="$input_bw"
            ;;
        6) : ;;
    esac
    log_info "带宽已设为: ${HW_BANDWIDTH}"

    # ── 自定义网络栈 ─────────────────────────────────────────
    echo ""
    echo "网络栈选项："
    echo "  1. ipv4-only"
    echo "  2. dual-stack（IPv4 + IPv6）"
    echo "  3. 保持当前 (${HW_DUAL_STACK})"
    local stack_choice
    read -rp "请选择 [1-3，默认3]: " stack_choice
    case "${stack_choice:-3}" in
        1) HW_DUAL_STACK="ipv4-only" ;;
        2) HW_DUAL_STACK="dual-stack" ;;
        3) : ;;
    esac
    log_info "网络栈已设为: ${HW_DUAL_STACK}"

    # ── 自定义磁盘类型 ───────────────────────────────────────
    echo ""
    echo "磁盘类型选项："
    echo "  1. ssd"
    echo "  2. hdd"
    echo "  3. nvme"
    echo "  4. 保持当前 (${HW_DISK_TYPE})"
    local disk_choice
    read -rp "请选择 [1-4，默认4]: " disk_choice
    case "${disk_choice:-4}" in
        1) HW_DISK_TYPE="ssd" ;;
        2) HW_DISK_TYPE="hdd" ;;
        3) HW_DISK_TYPE="nvme" ;;
        4) : ;;
    esac
    log_info "磁盘类型已设为: ${HW_DISK_TYPE}"

    # ── 确认最终值 ───────────────────────────────────────────
    echo ""
    log_info "═══ 最终硬件参数 ════════════════════════"
    log_info "  CPU 核心数 : ${HW_CPU_CORES}"
    log_info "  物理内存   : ${HW_MEM_GB}GB"
    log_info "  磁盘类型   : ${HW_DISK_TYPE}"
    log_info "  网络栈     : ${HW_DUAL_STACK}"
    log_info "  带宽       : ${HW_BANDWIDTH}"
    log_info "════════════════════════════════════════"
    echo ""
}

# ── 检测虚拟化环境（仅用于日志） ─────────────────────────────
detect_virt_type() {
    local virt="physical"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    fi
    [[ "$virt" == "none" ]] && virt="physical"
    VIRT_TYPE="$virt"
    log_info "运行环境: ${VIRT_TYPE^}"
}

# ── 1. 硬件中断与多队列优化 ──────────────────────────────────
optimize_hardware_interrupts() {
    log_step "优化硬件中断与网络队列 (IRQ / XPS / RPS / RFS)..."

    main_iface=$(ip -o link show | awk -F': ' \
        '$3 !~ /lo|veth|docker|br-|virbr|bond|team|tap|tun/ {print $2; exit}')

    if [[ -z "$main_iface" ]]; then
        log_warn "未检测到有效物理网卡，跳过中断优化"
        return 0
    fi

    log_info "检测到主网卡: $main_iface (环境: ${VIRT_TYPE:-unknown})"

    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        systemctl stop irqbalance
        systemctl disable irqbalance
        log_info "已停用 irqbalance 服务"
    fi

    local channels=1
    local channels_raw
    channels_raw=$(ethtool -l "$main_iface" 2>/dev/null \
        | grep -A5 "Current hardware settings" \
        | grep -i "Combined" | awk '{print $2}')
    [[ "$channels_raw" =~ ^[0-9]+$ && "$channels_raw" -gt 0 ]] \
        && channels=$channels_raw

    save_state "MAIN_IFACE"   "$main_iface"
    save_state "NET_CHANNELS" "$channels"

    if [[ "$channels" -gt 1 && "$HW_CPU_CORES" -gt 0 ]]; then
        log_info "多队列网卡 (${channels} 队列)，执行 IRQ + XPS CPU 亲和性绑定..."

        local core_idx=0
        while read -r irq_num; do
            local mask
            mask=$(printf "%x" $((1 << (core_idx % HW_CPU_CORES))))
            echo "$mask" > "/proc/irq/${irq_num}/smp_affinity" 2>/dev/null || true
            (( core_idx++ )) || true
        done < <(grep -E "${main_iface}" /proc/interrupts \
                 | awk '{print $1}' | tr -d ':')

        local q_idx=0
        for xps_file in /sys/class/net/"$main_iface"/queues/tx-*/xps_cpus; do
            [[ -f "$xps_file" ]] || continue
            local mask
            mask=$(printf "%x" $((1 << (q_idx % HW_CPU_CORES))))
            echo "$mask" > "$xps_file" 2>/dev/null || true
            (( q_idx++ )) || true
        done

        log_info "IRQ/XPS 绑定完成 (中断数: $core_idx | TX队列数: $q_idx)"

    else
        log_info "单队列网卡，启用 RPS + RFS 软件多核分流..."
        local full_mask
        full_mask=$(printf "%x" $(( (1 << HW_CPU_CORES) - 1 )))

        echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

        for rx_dir in /sys/class/net/"$main_iface"/queues/rx-*; do
            [[ -d "$rx_dir" ]] || continue
            echo "$full_mask" > "$rx_dir/rps_cpus" 2>/dev/null || true
            [[ -f "$rx_dir/rfs_flow_cnt" ]] \
                && echo 2048 > "$rx_dir/rfs_flow_cnt" 2>/dev/null || true
        done

        log_info "RPS/RFS 配置完成 (掩码: 0x${full_mask})"
    fi

    tc qdisc replace dev "$main_iface" root fq \
        limit 10000 flow_limit 200 quantum 3028 2>/dev/null || true
    log_info "TC FQ 队列已应用 (dev: $main_iface)"
}

# ── 2. ECN 模式决策 ──────────────────────────────────────────
determine_ecn_value() {
    SYSCTL_ECN=2
    save_state "SYSCTL_ECN" "$SYSCTL_ECN"
    log_info "ECN 模式: 2 (协商模式，由对端决定)"
}

# ── 3. sysctl 内核参数优化 ───────────────────────────────────
optimize_sysctl() {
    log_step "计算并应用 sysctl 内核优化参数 (代理节点稳健上限 + 自适应)..."

    determine_ecn_value

    SYSCTL_SOMAXCONN=32768
    VM_SWAPPINESS=10
    VM_DIRTY_RATIO=20
    VM_DIRTY_BACKGROUND_RATIO=5

    local total_mem_kb
    total_mem_kb=$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')
    local tcp_mem_min=$(( total_mem_kb * 2  / 100 / 4 ))
    local tcp_mem_press=$(( total_mem_kb * 12 / 100 / 4 ))
    local tcp_mem_max=$(( total_mem_kb * 25 / 100 / 4 ))

    local rmem_max=134217728
    local wmem_max=134217728

    local sysctl_conf="/etc/sysctl.d/99-xray-optimize.conf"
    cat > "$sysctl_conf" << CONF
# ============================================================
# xray-nginx-deploy 系统优化参数 - 2026 最终版
# 生成时间 : $(date '+%Y-%m-%d %H:%M:%S')
# 主网卡   : ${main_iface:-unknown}
# CPU 核心 : ${HW_CPU_CORES:-unknown}
# 物理内存 : $(( total_mem_kb / 1024 ))MB
# 运行环境 : ${VIRT_TYPE:-unknown}
# 优化策略 : 代理节点稳健上限 + 内核自适应
# ============================================================

# --- 文件描述符 ---
fs.nr_open  = ${GLOBAL_NR_OPEN}
fs.file-max = ${GLOBAL_FILE_MAX}

# --- BBR 拥塞控制 ---
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_moderate_rcvbuf    = 1
net.ipv4.tcp_ecn                = ${SYSCTL_ECN}

# --- Socket 缓冲区（稳健上限，内核按需分配）---
net.core.rmem_max     = ${rmem_max}
net.core.wmem_max     = ${wmem_max}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem     = 4096 262144 ${rmem_max}
net.ipv4.tcp_wmem     = 4096 65536  ${wmem_max}

# --- TCP 内存池（2% / 12% / 25% 物理内存）---
net.ipv4.tcp_mem = ${tcp_mem_min} ${tcp_mem_press} ${tcp_mem_max}

# --- 连接队列与并发 ---
net.core.somaxconn           = ${SYSCTL_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYSCTL_SOMAXCONN}
net.core.netdev_max_backlog  = 30000
net.ipv4.tcp_max_tw_buckets  = 262144
net.ipv4.ip_local_port_range = 1024 65535

# --- TCP 行为优化 ---
net.ipv4.tcp_keepalive_time        = 300
net.ipv4.tcp_keepalive_intvl       = 30
net.ipv4.tcp_keepalive_probes      = 3
net.ipv4.tcp_fin_timeout           = 30
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_notsent_lowat         = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 2

# --- 虚拟内存 ---
vm.swappiness             = ${VM_SWAPPINESS}
vm.dirty_ratio            = ${VM_DIRTY_RATIO}
vm.dirty_background_ratio = ${VM_DIRTY_BACKGROUND_RATIO}
CONF

    sysctl -p "$sysctl_conf" >/dev/null 2>&1 \
        || sysctl --system >/dev/null 2>&1

    log_info "sysctl 参数已写入并生效: $sysctl_conf"
    log_info "TCP 内存池: min=${tcp_mem_min} press=${tcp_mem_press} max=${tcp_mem_max} (页)"
    log_info "缓冲区上限: 128MB rmem/wmem (内核按需分配，不预占)"
}

# ── 4. 用户态资源限制 ────────────────────────────────────────
optimize_limits() {
    log_step "配置系统资源限制 (nofile / nproc)..."

    # 清理旧版直接写入 system.conf 的残留
    if [[ -f /etc/systemd/system.conf ]]; then
        sed -i '/^DefaultLimitNOFILE/d; /^DefaultLimitNPROC/d' \
            /etc/systemd/system.conf 2>/dev/null || true
    fi

    cat > /etc/security/limits.d/99-xray-optimize.conf << LIMITS
# xray-nginx-deploy 自动生成 - $(date '+%Y-%m-%d')
*    soft nofile ${GLOBAL_NOFILE_LIMIT}
*    hard nofile ${GLOBAL_NOFILE_LIMIT}
*    soft nproc  ${GLOBAL_NPROC_LIMIT}
*    hard nproc  ${GLOBAL_NPROC_LIMIT}
root soft nofile ${GLOBAL_NOFILE_LIMIT}
root hard nofile ${GLOBAL_NOFILE_LIMIT}
root soft nproc  ${GLOBAL_NPROC_LIMIT}
root hard nproc  ${GLOBAL_NPROC_LIMIT}
LIMITS

    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d

    cat > /etc/systemd/system.conf.d/99-xray-limits.conf << SYSTEMD
[Manager]
DefaultLimitNOFILE=${GLOBAL_NOFILE_LIMIT}
DefaultLimitNPROC=${GLOBAL_NPROC_LIMIT}
SYSTEMD

    cat > /etc/systemd/user.conf.d/99-xray-limits.conf << USERCONF
[Manager]
DefaultLimitNOFILE=${GLOBAL_NOFILE_LIMIT}
DefaultLimitNPROC=${GLOBAL_NPROC_LIMIT}
USERCONF

    systemctl daemon-reexec >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    log_info "资源限制配置完成 (nofile: ${GLOBAL_NOFILE_LIMIT} | nproc: ${GLOBAL_NPROC_LIMIT})"
}

# ── 5. 安装基础工具 ───────────────────────────────────────────
install_base_tools() {
    log_step "安装基础工具..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y \
            ethtool iproute2 sysstat procps \
            curl wget ca-certificates \
            htop iftop iotop net-tools \
            >/dev/null 2>&1 || true
        log_info "Debian/Ubuntu 基础工具安装完成"

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y \
            ethtool iproute iproute-tc sysstat procps-ng \
            curl wget ca-certificates \
            htop iftop iotop net-tools \
            >/dev/null 2>&1 || true
        log_info "RHEL/AlmaLinux 基础工具安装完成"

    elif command -v yum >/dev/null 2>&1; then
        yum install -y \
            ethtool iproute sysstat procps-ng \
            curl wget ca-certificates \
            htop net-tools \
            >/dev/null 2>&1 || true
        log_info "CentOS/RHEL(yum) 基础工具安装完成"

    else
        log_warn "未知包管理器，跳过基础工具安装"
        return 0
    fi

    systemctl enable --now sysstat >/dev/null 2>&1 || true
    log_info "sysstat 服务已启用 (sar 历史数据收集开启)"
}

# ── 6. 时间同步 ───────────────────────────────────────────────
sync_time() {
    log_step "配置时间同步..."
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1 || true
        log_info "NTP 时间同步已启用"
    else
        log_warn "timedatectl 不可用，跳过时间同步"
    fi
}

# ── 7. 验证工具可用性检查 ────────────────────────────────────
check_tools() {
    local missing=()
    for cmd in mpstat sar ss ethtool tc ip; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "以下验证工具未安装，部分命令无法执行: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            log_warn "修复命令: apt-get install -y sysstat iproute2 ethtool net-tools"
        else
            log_warn "修复命令: dnf install -y sysstat iproute iproute-tc ethtool net-tools"
        fi
    else
        log_info "验证工具检查通过 ✓"
    fi
}

# ── 8. 优化完成摘要与验证建议 ────────────────────────────────
print_optimization_summary() {
    local total_mem_kb
    total_mem_kb=$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')

    check_tools

    echo ""
    log_info "========== 系统优化完成摘要 =========="
    log_info "运行环境   : ${VIRT_TYPE:-unknown}"
    log_info "CPU 核心数 : ${HW_CPU_CORES}"
    log_info "物理内存   : $(( total_mem_kb / 1024 ))MB (配置值: ${HW_MEM_GB}GB)"
    log_info "磁盘类型   : ${HW_DISK_TYPE:-unknown}"
    log_info "网络栈     : ${HW_DUAL_STACK:-unknown}"
    log_info "带宽       : ${HW_BANDWIDTH:-unknown}"
    log_info "主网卡     : ${main_iface:-未检测}"
    log_info "队列策略   : $( \
        [[ "${NET_CHANNELS:-1}" -gt 1 ]] \
        && echo "多队列 IRQ/XPS (${NET_CHANNELS} 队列)" \
        || echo "单队列 RPS/RFS" )"
    log_info "BBR + FQ   : 已启用"
    log_info "ECN 模式   : ${SYSCTL_ECN:-2} (协商模式)"
    log_info "somaxconn  : ${SYSCTL_SOMAXCONN}"
    log_info "缓冲区上限 : rmem/wmem = 128MB (内核自适应分配)"
    log_info "TCP 内存池 : 物理内存 2%~25% (压力时自动回收)"
    log_info "nofile 限制: ${GLOBAL_NOFILE_LIMIT}"
    if [[ "${KERNEL_UPGRADED:-0}" == "1" ]]; then
        log_warn "内核已升级，请执行 'reboot' 重启后生效"
    fi
    echo ""
    log_info "─── 推荐验证命令 ───────────────────────"
    echo "  mpstat -P ALL 1"
    echo "  cat /proc/interrupts | grep ${main_iface:-eth}"
    echo "  ss -ltn | grep -E ':(80|443)'"
    echo "  cat /proc/net/sockstat"
    echo "  sar -n DEV 1"
    echo "  sysctl net.ipv4.tcp_congestion_control"
    echo "  ulimit -Hn   # 重新 SSH 登录后执行"
    echo ""
    log_warn "提示: 重新 SSH 登录后 ulimit -Hn 才能看到新的 nofile 限制"
    log_warn "提示: 已安装的服务需 'systemctl restart <服务名>' 才能继承新限制"
    log_info "========================================"
}

# ── 直接执行入口 ─────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ $EUID -ne 0 ]] && { echo "必须使用 root 权限运行"; exit 1; }
    run_system
fi

# ── 向后兼容别名 / 补全函数（install.sh 调用）────────────────

detect_os() {
    detect_virt_type "$@"

    local os_id os_name
    if [[ -f /etc/os-release ]]; then
        os_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        os_name=$(grep "^NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi

    case "${os_id}" in
        ubuntu|debian)
            OS_ID="${os_id}"
            OS_NAME="${os_name}"
            PKG_MANAGER="apt"
            PKG_UPDATE="apt-get update -y"
            PKG_INSTALL="apt-get install -y"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            OS_ID="${os_id}"
            OS_NAME="${os_name}"
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf makecache -y"
            PKG_INSTALL="dnf install -y"
            ;;
        *)
            # ID_LIKE 兜底（amzn、openeuler 等衍生系统）
            local os_like
            os_like=$(grep "^ID_LIKE=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
            if echo "${os_like}" | grep -qE 'rhel|fedora|centos'; then
                OS_ID="${os_id}"
                OS_NAME="${os_name}"
                PKG_MANAGER="dnf"
                PKG_UPDATE="dnf makecache -y"
                PKG_INSTALL="dnf install -y"
            elif echo "${os_like}" | grep -qE 'debian|ubuntu'; then
                OS_ID="${os_id}"
                OS_NAME="${os_name}"
                PKG_MANAGER="apt"
                PKG_UPDATE="apt-get update -y"
                PKG_INSTALL="apt-get install -y"
            else
                log_error "不支持的系统: ${os_id:-未知}"
                exit 1
            fi
            ;;
    esac

    log_info "系统: ${OS_NAME} (${OS_ID}) | 包管理器: ${PKG_MANAGER}"
    save_state "OS_ID"       "${OS_ID}"
    save_state "OS_NAME"     "${OS_NAME}"
    save_state "PKG_MANAGER" "${PKG_MANAGER}"
}

detect_kernel() {
    KERNEL_VER=$(uname -r)
    log_info "当前内核版本: ${KERNEL_VER}"
}

upgrade_kernel() {
    log_step "检测并升级内核（ELRepo kernel-ml）..."

    # 仅对 RHEL 系生效，Debian/Ubuntu 跳过
    if ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
        log_info "非 RHEL 系系统，跳过内核升级"
        return 0
    fi

    log_info "当前内核: ${KERNEL_VER:-$(uname -r)}"

    # 获取 RHEL 主版本号
    local rhel_major
    rhel_major=$(rpm -E '%{rhel}' 2>/dev/null | grep -oE '^[0-9]+')
    if [[ -z "$rhel_major" ]]; then
        log_warn "无法获取 RHEL 主版本号，跳过内核升级"
        return 0
    fi
    log_info "RHEL 主版本: ${rhel_major}"

    # 导入 ELRepo GPG key
    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org 2>/dev/null || true

    # 安装 elrepo-release（幂等）
    if ! rpm -q elrepo-release >/dev/null 2>&1; then
        local elrepo_url="https://www.elrepo.org/elrepo-release-${rhel_major}.el${rhel_major}.elrepo.noarch.rpm"
        log_info "安装 ELRepo: ${elrepo_url}"
        dnf install -y "$elrepo_url" >/dev/null 2>&1 \
            || yum install -y "$elrepo_url" >/dev/null 2>&1 \
            || { log_warn "ELRepo 安装失败，跳过内核升级"; return 0; }
        log_info "ELRepo 安装完成"
    else
        log_info "ELRepo 已安装，跳过重复安装"
    fi

    # 检查是否已装 kernel-ml，已装则跳过
    if rpm -q kernel-ml >/dev/null 2>&1; then
        local ml_ver
        ml_ver=$(rpm -q kernel-ml --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -1)
        log_info "kernel-ml 已安装: ${ml_ver}，跳过重复安装"
    else
        log_info "安装 kernel-ml（mainline，含 BBR3）..."
        dnf --enablerepo=elrepo-kernel install -y kernel-ml >/dev/null 2>&1 \
            || yum --enablerepo=elrepo-kernel install -y kernel-ml >/dev/null 2>&1 \
            || { log_warn "kernel-ml 安装失败，跳过内核升级"; return 0; }
        log_info "kernel-ml 安装完成"
    fi

    # 设置新内核为默认启动项
    grub2-set-default 0 2>/dev/null || true

    # 兼容 UEFI 和 BIOS 两种 grub 路径
    local efi_dir
    efi_dir=$(ls /boot/efi/EFI/ 2>/dev/null | grep -v '^BOOT$' | head -1)
    if [[ -n "$efi_dir" && -f "/boot/efi/EFI/${efi_dir}/grub.cfg" ]]; then
        grub2-mkconfig -o "/boot/efi/EFI/${efi_dir}/grub.cfg" >/dev/null 2>&1 || true
        log_info "UEFI grub 配置已更新 (/boot/efi/EFI/${efi_dir}/grub.cfg)"
    else
        grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
        log_info "BIOS grub 配置已更新 (/boot/grub2/grub.cfg)"
    fi

    log_warn "内核升级完成，需要重启后生效，重启命令: reboot"
    save_state "KERNEL_UPGRADED" "1"
}

load_kernel_modules() {
    log_step "加载内核模块..."
    local mods=(tcp_bbr nf_conntrack)
    for mod in "${mods[@]}"; do
        modprobe "$mod" 2>/dev/null \
            && log_info "模块已加载: $mod" \
            || log_warn "模块加载失败（可忽略）: $mod"
    done
}

tune_system_limits() { optimize_limits "$@"; }
