#!/usr/bin/env bash
# ============================================================
# modules/unbound.sh
# Unbound 本地递归 DNS 安装配置 - 最终修复版
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
    ip -o -4 addr show scope global 2>/dev/null | grep -q . && has_v4=1 || true
    ip -o -6 addr show scope global 2>/dev/null | grep -v ' fe80:' | grep -q . && has_v6=1 || true
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
        dual) log_info "自动检测建议: 双栈 IPv4 + IPv6" ;;
        ipv6) log_info "自动检测建议: 单栈 IPv6" ;;
        *) log_info "自动检测建议: 单栈 IPv4" ;;
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

# 彻底清理（加强版）
purge_unbound() {
    log_step "彻底清理 Unbound 残留..."
    systemctl stop unbound 2>/dev/null || true
    systemctl disable unbound 2>/dev/null || true
    systemctl disable --now unbound-anchor.service 2>/dev/null || true
    systemctl mask unbound-anchor.service 2>/dev/null || true

    case "$OS_ID" in
        ubuntu|debian)
            apt-get remove -y --purge unbound unbound-anchor 2>/dev/null || true
            ;;
        centos|rhel|rocky|almalinux|almalinux8|almalinux9)
            dnf remove -y unbound unbound-libs 2>/dev/null || true
            ;;
        *)
            dnf remove -y unbound unbound-libs 2>/dev/null || true   # 强制尝试 dnf
            ;;
    esac

    rm -rf /etc/unbound /var/lib/unbound /run/unbound
    rm -f /usr/local/bin/update-root-hints.sh /etc/cron.weekly/update-root-hints
    log_info "Unbound 残留清理完成"
}

install_unbound() {
    log_step "安装 Unbound..."
    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y unbound
            ;;
        *)
            # AlmaLinux / Rocky / RHEL 等全部走 dnf
            dnf install -y unbound
            ;;
    esac

    if ! command -v unbound &>/dev/null; then
        log_error "Unbound 安装失败"
        exit 1
    fi
    log_info "Unbound 安装成功: $(unbound -V 2>&1 | head -1)"
}

# 其余函数（init_trust_anchor、generate_unbound_config 等关键修复）

init_trust_anchor() {
    log_step "初始化 DNSSEC trust anchor (静态 DS 格式)..."
    mkdir -p /var/lib/unbound

    cat > /var/lib/unbound/root.key << 'EOF'
. IN DS 20326 8 2 E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D
EOF

    chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null || true
    chmod 644 /var/lib/unbound/root.key
    log_info "DNSSEC trust anchor 初始化完成"
}

# 服务名称等函数（保留你原来的）
sanitize_unbound_service_name() {
    local value="${1:-}"
    value=$(echo "${value,,}" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    [[ -n "$value" ]] || value="$(hostname -s 2>/dev/null || echo unbound)"
    echo "$value"
}

infer_unbound_service_name() {
    local candidate="${UNBOUND_SERVICE_NAME:-}"
    if [[ -z "$candidate" ]]; then
        candidate="$(hostname -s 2>/dev/null || echo unbound)"
    fi
    sanitize_unbound_service_name "$candidate"
}

collect_unbound_service_name() {
    local default_name input
    default_name=$(infer_unbound_service_name)
    read -rp "Unbound 服务名称（默认 ${default_name}）: " input
    UNBOUND_SERVICE_NAME=$(sanitize_unbound_service_name "${input:-$default_name}")
    log_info "Unbound 服务配置文件名: ${UNBOUND_SERVICE_NAME}.conf"
}

get_unbound_conf_dir() {
    case "$OS_ID" in
        ubuntu|debian) echo "/etc/unbound/unbound.conf.d" ;;
        *) echo "/etc/unbound/conf.d" ;;   # AlmaLinux 等走这里
    esac
}

ensure_unbound_include_dir() {
    local conf_dir main_conf
    conf_dir=$(get_unbound_conf_dir)
    mkdir -p "$conf_dir"
    if [[ "$OS_ID" =~ ^(ubuntu|debian)$ ]]; then
        main_conf="/etc/unbound/unbound.conf"
        if [[ -f "$main_conf" ]] && ! grep -q 'unbound\.conf\.d/\*\.conf' "$main_conf"; then
            echo 'include: "/etc/unbound/unbound.conf.d/*.conf"' >> "$main_conf"
        fi
    fi
}

# 生成配置（关键修复：只使用 trust-anchor-file，并清理旧文件）
generate_unbound_config() {
    log_step "生成 Unbound 配置..."
    local threads=$(get_thread_count)
    local mem_gb=$(get_effective_mem_gb)
    local msg_cache="128m" rrset_cache="256m"
    [[ $mem_gb -ge 8 ]] && msg_cache="512m" && rrset_cache="1024m"

    local conf_dir target_conf
    UNBOUND_SERVICE_NAME=$(infer_unbound_service_name)
    ensure_unbound_include_dir
    conf_dir=$(get_unbound_conf_dir)
    target_conf="${conf_dir}/${UNBOUND_SERVICE_NAME}.conf"

    # 彻底清理可能引起冲突的 anchor 文件
    rm -f "${conf_dir}"/root-*.conf "${conf_dir}"/local-recursive.conf

    cat > "$target_conf" << CONF_EOF
server:
    verbosity: 1
    port: 53
    interface: 127.0.0.1
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    num-threads: ${threads}
    msg-cache-size: ${msg_cache}
    rrset-cache-size: ${rrset_cache}
    cache-max-ttl: 86400
    prefetch: yes
    root-hints: "/var/lib/unbound/root.hints"
    serve-expired: yes
    harden-glue: yes
    hide-identity: yes
    hide-version: yes
    username: "unbound"
    directory: "/etc/unbound"
    chroot: ""
    pidfile: "/run/unbound.pid"
    module-config: "validator iterator"

    # 使用静态 trust-anchor-file（避免 auto-trust 冲突）
    trust-anchor-file: "/var/lib/unbound/root.key"

    local-zone: "localhost." static
    local-data: "localhost. 10800 IN A 127.0.0.1"
    do-not-query-localhost: yes
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
CONF_EOF

    cat > "${conf_dir}/remote-control.conf" << 'EOF'
remote-control:
    control-enable: yes
    control-interface: /run/unbound.ctl
EOF

    log_info "Unbound 配置生成完成"
}

# start_unbound（加强版）
start_unbound() {
    log_step "启动 Unbound 服务..."

    systemctl disable --now unbound-anchor.service 2>/dev/null || true
    systemctl mask unbound-anchor.service 2>/dev/null || true

    if ! unbound-checkconf >/dev/null 2>&1; then
        log_error "配置验证失败"
        unbound-checkconf
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
        journalctl -u unbound -n 30 --no-pager
        exit 1
    fi
}

# 保留你原来的 setup_resolv_conf 和 verify_unbound 函数（如果没有就用下面这个简单版）
setup_resolv_conf() {
    local addr="127.0.0.1"
    [[ "$(get_stack_mode)" == "ipv6" ]] && addr="::1"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver $addr" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    log_info "/etc/resolv.conf 已配置"
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

# run_unbound 主入口（简化）
run_unbound() {
    log_step "========== Unbound 安装配置 =========="

    collect_unbound_stack_mode
    collect_unbound_service_name

    if check_unbound_installed; then
        echo " 1. 跳过  2. 重新配置  3. 完整重装"
        read -rp "请选择 [默认1]: " choice
        case "${choice:-1}" in
            3)
                purge_unbound
                install_unbound
                disable_systemd_resolved
                download_root_hints
                init_trust_anchor
                generate_unbound_config
                start_unbound
                ;;
            2)
                disable_systemd_resolved
                download_root_hints
                init_trust_anchor
                generate_unbound_config
                systemctl restart unbound
                setup_resolv_conf
                verify_unbound
                ;;
            *) log_info "跳过 Unbound" ;;
        esac
    else
        install_unbound
        disable_systemd_resolved
        download_root_hints
        init_trust_anchor
        generate_unbound_config
        start_unbound
    fi

    log_info "========== Unbound 配置完成 =========="
}