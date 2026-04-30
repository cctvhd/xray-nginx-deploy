#!/usr/bin/env bash
# ============================================================
# modules/unbound.sh
# Unbound 本地递归 DNS 安装配置 - 稳定优化版（已解决 trust anchor 冲突）
# ============================================================

check_unbound_installed() {
    if command -v unbound &>/dev/null && systemctl is-active --quiet unbound 2>/dev/null; then
        return 0
    fi
    return 1
}

get_stack_mode() {
    case "${HW_DUAL_STACK:-ipv4}" in
        yes|dual|dualstack|ipv4v6) echo "dual" ;;
        ipv6|v6|ipv6-only) echo "ipv6" ;;
        *) echo "ipv4" ;;
    esac
}

detect_unbound_stack_mode() {
    local has_v4=0 has_v6=0
    ip -o -4 addr show scope global 2>/dev/null | grep -q . && has_v4=1
    ip -o -6 addr show scope global 2>/dev/null | grep -v ' fe80:' | grep -q . && has_v6=1
    if [[ $has_v4 -eq 1 && $has_v6 -eq 1 ]]; then
        echo "dual"
    elif [[ $has_v6 -eq 1 ]]; then
        echo "ipv6"
    else
        echo "ipv4"
    fi
}

collect_unbound_stack_mode() {
    local detected_stack default_stack stack_choice default_choice
    detected_stack=$(detect_unbound_stack_mode)
    default_stack=$(get_stack_mode)
    [[ -z "${HW_DUAL_STACK:-}" ]] && default_stack="$detected_stack"

    echo "网络栈类型："
    echo " 1. 双栈 IPv4 + IPv6"
    echo " 2. 单栈 IPv4"
    echo " 3. 单栈 IPv6"
    case "$detected_stack" in
        dual) log_info "自动检测建议: 双栈" ;;
        ipv6) log_info "自动检测建议: IPv6" ;;
        *) log_info "自动检测建议: IPv4" ;;
    esac

    case "$default_stack" in
        dual) default_choice="1" ;;
        ipv6) default_choice="3" ;;
        *) default_choice="2" ;;
    esac

    read -rp "请选择 [1-3，默认${default_choice}]: " stack_choice
    case "${stack_choice:-$default_choice}" in
        1) HW_DUAL_STACK="dual" ;;
        3) HW_DUAL_STACK="ipv6" ;;
        *) HW_DUAL_STACK="ipv4" ;;
    esac
    log_info "Unbound 网络栈模式: ${HW_DUAL_STACK}"
}

# ====================== 清理 ======================
purge_unbound() {
    log_step "彻底清理 Unbound 残留..."
    systemctl stop unbound 2>/dev/null || true
    systemctl disable unbound 2>/dev/null || true
    systemctl disable --now unbound-anchor.service 2>/dev/null || true
    systemctl mask unbound-anchor.service 2>/dev/null || true

    case "$OS_ID" in
        ubuntu|debian)
            apt-get remove -y --purge unbound unbound-anchor 2>/dev/null || true ;;
        centos|rhel|rocky|almalinux)
            dnf remove -y unbound unbound-libs 2>/dev/null || true ;;
    esac

    rm -rf /etc/unbound /var/lib/unbound /run/unbound
    rm -f /usr/local/bin/update-root-hints.sh /etc/cron.weekly/update-root-hints

    log_info "Unbound 清理完成"
}

# ====================== 安装 ======================
install_unbound() {
    log_step "安装 Unbound..."
    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y unbound
            ;;
        centos|rhel|rocky|almalinux)
            dnf install -y unbound
            ;;
        *)
            log_error "不支持的系统: $OS_NAME"
            exit 1
            ;;
    esac
    log_info "Unbound 安装成功: $(unbound -V 2>&1 | head -1)"
}

disable_systemd_resolved() {
    log_step "禁用 systemd-resolved..."
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        log_info "systemd-resolved 已禁用"
    fi
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi
}

download_root_hints() {
    log_step "下载 root.hints..."
    mkdir -p /var/lib/unbound
    curl -fsSL https://www.internic.net/domain/named.root -o /var/lib/unbound/root.hints 2>/dev/null || true

    if [[ ! -s /var/lib/unbound/root.hints ]]; then
        log_warn "下载失败，使用内置 root.hints"
        cat > /var/lib/unbound/root.hints << 'HINTS_EOF'
. 3600000 NS A.ROOT-SERVERS.NET.
A.ROOT-SERVERS.NET. 3600000 A 198.41.0.4
A.ROOT-SERVERS.NET. 3600000 AAAA 2001:503:ba3e::2:30
# （此处省略其他根服务器记录，建议保留你原来的完整列表）
. 3600000 NS M.ROOT-SERVERS.NET.
M.ROOT-SERVERS.NET. 3600000 A 202.12.27.33
HINTS_EOF
    fi
    chown unbound:unbound /var/lib/unbound/root.hints 2>/dev/null || true
}

init_trust_anchor() {
    log_step "初始化 DNSSEC trust anchor (静态 DS)..."
    mkdir -p /var/lib/unbound

    cat > /var/lib/unbound/root.key << 'EOF'
. IN DS 20326 8 2 E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D
EOF

    chown unbound:unbound /var/lib/unbound/root.key
    chmod 644 /var/lib/unbound/root.key
    log_info "DNSSEC trust anchor 初始化完成"
}

# ====================== 配置生成 ======================
generate_unbound_config() {
    log_step "生成 Unbound 配置..."
    local threads=$(get_thread_count)
    local mem_gb=$(get_effective_mem_gb)
    local msg_cache="64m" rrset_cache="128m"
    [[ $mem_gb -ge 2 ]] && msg_cache="128m" && rrset_cache="256m"
    [[ $mem_gb -ge 4 ]] && msg_cache="256m" && rrset_cache="512m"
    [[ $mem_gb -ge 8 ]] && msg_cache="512m" && rrset_cache="1024m"

    local conf_dir target_conf remote_conf
    conf_dir=$(get_unbound_conf_dir)
    target_conf="${conf_dir}/${UNBOUND_SERVICE_NAME}.conf"
    remote_conf="${conf_dir}/remote-control.conf"

    mkdir -p "$conf_dir"
    rm -f "${conf_dir}"/root-*.conf   # 清理旧 anchor 文件

    local stack_mode=$(get_stack_mode)
    local ipv6_lines=""
    [[ "$stack_mode" == "dual" || "$stack_mode" == "ipv6" ]] && ipv6_lines='    interface: ::1
    access-control: ::1 allow'

    cat > "$target_conf" << CONF_EOF
server:
    verbosity: 1
    port: 53
    interface: 127.0.0.1
${ipv6_lines}
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    num-threads: ${threads}
    msg-cache-size: ${msg_cache}
    rrset-cache-size: ${rrset_cache}
    cache-max-ttl: 86400
    cache-min-ttl: 300
    prefetch: yes
    root-hints: "/var/lib/unbound/root.hints"
    serve-expired: yes
    harden-glue: yes
    harden-referral-path: yes
    harden-below-nxdomain: yes
    hide-identity: yes
    hide-version: yes
    username: "unbound"
    directory: "/etc/unbound"
    chroot: ""
    pidfile: "/run/unbound.pid"
    module-config: "validator iterator"

    # DNSSEC 配置（关键：使用静态 trust-anchor-file）
    trust-anchor-file: "/var/lib/unbound/root.key"

    local-zone: "localhost." static
    local-data: "localhost. 10800 IN A 127.0.0.1"
    local-zone: "127.in-addr.arpa." static
    local-zone: "0.0.0.0/8." static
    do-not-query-localhost: yes
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16

CONF_EOF

    cat > "$remote_conf" << EOF
remote-control:
    control-enable: yes
    control-interface: /run/unbound.ctl
EOF

    log_info "Unbound 配置生成完成"
}

# 其他辅助函数（get_thread_count、get_effective_mem_gb、get_unbound_conf_dir 等）
# 请保留你原来的这些函数，这里为了简洁省略，你可以把你原来的对应函数粘贴回来

# ====================== 启动与验证 ======================
start_unbound() {
    log_step "启动 Unbound 服务..."

    systemctl disable --now unbound-anchor.service 2>/dev/null || true
    systemctl mask unbound-anchor.service 2>/dev/null || true

    if ! unbound-checkconf; then
        log_error "配置验证失败"
        exit 1
    fi

    systemctl enable --now unbound
    sleep 3

    if systemctl is-active --quiet unbound; then
        log_info "Unbound 启动成功"
        setup_resolv_conf
        verify_unbound
    else
        log_error "Unbound 启动失败"
        journalctl -u unbound -n 20 --no-pager
        exit 1
    fi
}

setup_resolv_conf() {
    local addr=$([[ "$(get_stack_mode)" == "ipv6" ]] && echo "::1" || echo "127.0.0.1")
    cat > /etc/resolv.conf << EOF
nameserver ${addr}
options ndots:1 timeout:2 attempts:2
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    log_info "resolv.conf 已配置并锁定"
}

verify_unbound() {
    log_step "验证解析..."
    for d in google.com github.com; do
        if dig @127.0.0.1 "$d" +short >/dev/null 2>&1; then
            log_info "解析成功: $d"
        else
            log_warn "解析失败: $d"
        fi
    done
}

# ====================== 主入口 ======================
run_unbound() {
    log_step "========== Unbound 安装配置 =========="

    if check_unbound_installed; then
        echo "1. 跳过   2. 重新配置   3. 完整重装"
        read -rp "请选择 [默认1]: " choice
        case "${choice:-1}" in
            3)
                collect_unbound_stack_mode
                collect_unbound_service_name
                purge_unbound
                install_unbound
                disable_systemd_resolved
                download_root_hints
                init_trust_anchor
                generate_unbound_config
                start_unbound
                ;;
            2)
                collect_unbound_stack_mode
                collect_unbound_service_name
                disable_systemd_resolved
                download_root_hints
                init_trust_anchor
                generate_unbound_config
                systemctl restart unbound
                setup_resolv_conf
                verify_unbound
                ;;
            *) log_info "已跳过" ;;
        esac
    else
        collect_unbound_stack_mode
        collect_unbound_service_name
        install_unbound
        disable_systemd_resolved
        download_root_hints
        init_trust_anchor
        generate_unbound_config
        start_unbound
    fi

    log_info "========== Unbound 配置完成 =========="
    log_info "本地 DNS: 127.0.0.1:53"
}