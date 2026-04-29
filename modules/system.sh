#!/usr/bin/env bash
# ============================================================
# modules/system.sh
# 系统初始化模块 - 2026 最终独立版
# 策略：激进上限 + 内核自适应，让软件按需使用内存
# 修正：daemon-reexec / 旧配置清理 / check_tools /
#       摘要信息补全 / 验证命令补全
# ============================================================

# ── 全局资源常量 ─────────────────────────────────────────────
GLOBAL_NR_OPEN=4194304
GLOBAL_FILE_MAX=4194304
GLOBAL_NOFILE_LIMIT=1048576
GLOBAL_NPROC_LIMIT=65536

# ── 日志函数（独立运行时使用，与主脚本配合时会被覆盖） ───────
log_step() { echo -e "\e[36m[STEP]\e[0m $*"; }
log_info()  { echo -e "\e[32m[INFO]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }

# save_state 空实现（与主脚本配合时会被覆盖）
save_state() { :; }

# ── 模块入口 ─────────────────────────────────────────────────
run_system() {
    log_step "========== 系统初始化 =========="

    detect_virt_type
    collect_hardware_info
    optimize_hardware_interrupts
    optimize_sysctl
    optimize_limits
    install_base_tools
    sync_time
    print_optimization_summary

    log_info "========== 系统初始化完成 =========="
}

# ── 硬件信息收集 ─────────────────────────────────────────────
collect_hardware_info() {
    log_step "收集硬件信息..."

    if [[ -z "${HW_CPU_CORES:-}" ]]; then
        HW_CPU_CORES=$(nproc 2>/dev/null \
            || grep -c '^processor' /proc/cpuinfo 2>/dev/null \
            || echo 4)
    fi
    [[ "$HW_CPU_CORES" -gt 0 ]] 2>/dev/null || HW_CPU_CORES=4

    log_info "CPU 核心数: ${HW_CPU_CORES}"
    log_info "物理内存: $(( $(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}') / 1024 ))MB"
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

    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y ethtool iproute2 >/dev/null 2>&1 || true
    else
        dnf install -y ethtool iproute iproute-tc >/dev/null 2>&1 || true
    fi

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
    log_step "计算并应用 sysctl 内核优化参数 (激进上限 + 自适应)..."

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
# 优化策略 : 激进上限 + 内核自适应
# ============================================================

# --- 文件描述符 ---
fs.nr_open  = ${GLOBAL_NR_OPEN}
fs.file-max = ${GLOBAL_FILE_MAX}

# --- BBR 拥塞控制 ---
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_moderate_rcvbuf    = 1
net.ipv4.tcp_ecn                = ${SYSCTL_ECN}

# --- Socket 缓冲区（激进上限，内核按需分配）---
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
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1

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

    # daemon-reexec 让 systemd 本身重新加载使 system.conf.d 生效
    # daemon-reload 重载 unit 文件
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
    log_info "物理内存   : $(( total_mem_kb / 1024 ))MB"
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
detect_os() { detect_virt_type "$@"; }

detect_kernel() {
    KERNEL_VER=$(uname -r)
    log_info "当前内核版本: ${KERNEL_VER}"
}

upgrade_kernel() {
    log_info "跳过内核升级（当前内核: ${KERNEL_VER:-$(uname -r)}）"
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
