#!/usr/bin/env bash
# ============================================================
# modules/firewall.sh
# nftables 防火墙安装与配置
# ============================================================

_firewall_os_family() {
    local os_id os_like
    os_id=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
    os_like=$(grep "^ID_LIKE=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')

    case "$os_id" in
        debian|ubuntu) echo "debian"; return ;;
        rhel|centos|rocky|almalinux|fedora) echo "rhel"; return ;;
    esac
    if echo "$os_like" | grep -qiE 'debian|ubuntu'; then
        echo "debian"
    elif echo "$os_like" | grep -qiE 'rhel|fedora|centos'; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

_firewall_install_pkg() {
    local pkg="$1"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg"
    else
        log_error "未找到支持的包管理器，无法安装 ${pkg}"
        return 1
    fi
}

_firewall_remove_pkg_if_installed() {
    local pkg="$1"
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || return 0
        apt-get purge -y "$pkg" || apt-get remove -y "$pkg" || true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -q "$pkg" >/dev/null 2>&1 || return 0
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y "$pkg" || true
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y "$pkg" || true
        fi
    fi
}

_firewall_disable_service() {
    local service="$1"
    systemctl list-unit-files "${service}.service" >/dev/null 2>&1 || return 0
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        systemctl stop "$service" || true
    fi
    systemctl disable "$service" >/dev/null 2>&1 || true
    systemctl mask "$service" >/dev/null 2>&1 || true
    log_info "已停用 ${service}.service"
}

_firewall_cleanup_non_nft() {
    log_step "检测并清理非 nftables 防火墙..."

    _firewall_disable_service "ufw"
    _firewall_disable_service "firewalld"
    _firewall_disable_service "iptables"
    _firewall_disable_service "ip6tables"
    _firewall_disable_service "netfilter-persistent"

    if command -v apt-get >/dev/null 2>&1; then
        _firewall_remove_pkg_if_installed "ufw"
        _firewall_remove_pkg_if_installed "firewalld"
        _firewall_remove_pkg_if_installed "iptables-persistent"
        _firewall_remove_pkg_if_installed "netfilter-persistent"
    else
        _firewall_remove_pkg_if_installed "firewalld"
        _firewall_remove_pkg_if_installed "iptables-services"
    fi
}

_firewall_detect_nft_config_path() {
    local unit_path family
    unit_path=$(systemctl cat nftables.service 2>/dev/null \
        | sed -nE 's/.*nft[[:space:]].*-f[[:space:]]+([^[:space:];]+).*/\1/p' \
        | tail -1)
    if [[ -n "$unit_path" ]]; then
        echo "$unit_path"
        return
    fi

    family=$(_firewall_os_family)
    case "$family" in
        rhel) echo "/etc/sysconfig/nftables.conf" ;;
        *) echo "/etc/nftables.conf" ;;
    esac
}

_firewall_current_ssh_ports() {
    local ports dropin="/etc/ssh/sshd_config.d/99-xray-deploy-security.conf"

    if [[ -f "$dropin" ]]; then
        ports=$(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2 }' "$dropin" \
            | sort -n -u \
            | tr '\n' ' ' \
            | sed 's/[[:space:]]*$//')
        if [[ -n "$ports" ]]; then
            echo "$ports"
            return
        fi
    fi

    ports=$(get_state "SSH_PORTS" "")
    if [[ -n "$ports" ]]; then
        echo "$ports"
        return
    fi
    ports=$(ss -tlnp 2>/dev/null \
        | awk '/sshd|ssh/{print $4}' \
        | grep -oE '[0-9]+$' \
        | sort -n -u \
        | tr '\n' ' ' \
        | sed 's/[[:space:]]*$//')
    [[ -n "$ports" ]] && echo "$ports" || echo "22"
}

_firewall_validate_ports() {
    local port
    [[ -n "${1:-}" ]] || return 0
    for port in $1; do
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        (( port >= 1 && port <= 65535 )) || return 1
    done
}

_firewall_ports_to_set() {
    local ports="$1"
    printf '%s' "$ports" | tr ' ' ',' | sed 's/,,*/,/g;s/^,//;s/,$//'
}

_firewall_build_extra_tcp() {
    local ports="$1"
    [[ -z "$ports" ]] && return 0
    echo "        tcp dport { $(_firewall_ports_to_set "$ports") } ct state new accept"
}

_firewall_build_extra_udp() {
    local ports="$1"
    [[ -z "$ports" ]] && return 0
    echo "        udp dport { $(_firewall_ports_to_set "$ports") } accept"
}

_firewall_build_ipv6_rules() {
    local dual_stack="$1"
    [[ "$dual_stack" == "true" ]] || return 0
    cat <<'CONF'

    set blacklist_v6 {
        type ipv6_addr; flags interval;
    }
CONF
}

_firewall_build_ipv6_input() {
    local dual_stack="$1"
    [[ "$dual_stack" == "true" ]] || return 0
    cat <<'CONF'
        ip6 saddr @blacklist_v6 drop
        ip6 nexthdr ipv6-icmp icmpv6 type echo-request limit rate 10/second burst 20 packets accept
        ip6 nexthdr ipv6-icmp icmpv6 type {
            echo-reply,
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-router-solicit,
            nd-router-advert,
            nd-neighbor-solicit,
            nd-neighbor-advert,
            nd-redirect,
            mld-listener-query,
            mld-listener-report,
            mld-listener-done
        } accept
CONF
}

_firewall_write_nft_config() {
    local config="$1" ssh_ports="$2" extra_tcp="$3" extra_udp="$4" dual_stack="$5"
    local ssh_set
    ssh_set=$(_firewall_ports_to_set "$ssh_ports")
    mkdir -p "$(dirname "$config")"
    [[ -f "$config" ]] && cp -f "$config" "${config}.bak.$(date +%Y%m%d%H%M%S)"

    cat > "$config" << CONF
#!/usr/sbin/nft -f
# Auto-generated by xray-nginx-deploy firewall module
# Generated at: $(date '+%Y-%m-%d %H:%M:%S')

flush ruleset

table inet filter {
    set blacklist_v4 {
        type ipv4_addr; flags interval;
    }
$(_firewall_build_ipv6_rules "$dual_stack")
    chain input {
        type filter hook input priority 0; policy drop;

        ip saddr @blacklist_v4 drop
$(_firewall_build_ipv6_input "$dual_stack")
        iif "lo" accept
        ct state { established, related } accept
        ct state invalid drop

        ip protocol icmp icmp type echo-request limit rate 10/second burst 20 packets accept
        ip protocol icmp icmp type != echo-request accept

        tcp dport { ${ssh_set} } ct state new meter ssh_meter { ip saddr limit rate 5/minute burst 3 packets } accept
        tcp dport { ${ssh_set} } ct state new reject with tcp reset

        tcp dport 443 ct state new accept
        udp dport 443 accept
$(_firewall_build_extra_tcp "$extra_tcp")
$(_firewall_build_extra_udp "$extra_udp")
        limit rate 10/second burst 30 packets log prefix "[nft drop in] " flags all level warn
        drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state invalid drop
        ct state { established, related } accept
        ip6 nexthdr ipv6-icmp accept
        log prefix "[nft drop fwd] " limit rate 2/second drop
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
CONF
}

run_firewall_nftables() {
    log_step "========== nftables 防火墙安装与配置 =========="

    local config ssh_ports extra_tcp extra_udp dual_stack
    _firewall_cleanup_non_nft

    if ! command -v nft >/dev/null 2>&1; then
        log_step "安装 nftables..."
        _firewall_install_pkg "nftables"
    fi

    config=$(_firewall_detect_nft_config_path)
    ssh_ports=$(_firewall_current_ssh_ports)

    echo ""
    log_info "nftables 配置文件: ${config}"
    log_info "SSH 放行端口: ${ssh_ports}"
    read -rp "SSH 端口（多个用空格分隔）[默认: ${ssh_ports}]: " input_ssh
    ssh_ports="${input_ssh:-$ssh_ports}"
    if ! _firewall_validate_ports "$ssh_ports"; then
        log_error "SSH 端口格式无效: ${ssh_ports}"
        return 1
    fi

    read -rp "是否启用 IPv6 双栈规则？[Y/n]: " input_dual
    dual_stack="true"
    [[ "${input_dual,,}" == "n" ]] && dual_stack="false"

    read -rp "额外 TCP 端口（空格分隔，留空跳过）: " extra_tcp
    if ! _firewall_validate_ports "$extra_tcp"; then
        log_error "额外 TCP 端口格式无效: ${extra_tcp}"
        return 1
    fi

    read -rp "额外 UDP 端口（空格分隔，留空跳过）: " extra_udp
    if ! _firewall_validate_ports "$extra_udp"; then
        log_error "额外 UDP 端口格式无效: ${extra_udp}"
        return 1
    fi

    _firewall_write_nft_config "$config" "$ssh_ports" "$extra_tcp" "$extra_udp" "$dual_stack"
    log_step "验证 nftables 配置..."
    if ! nft -c -f "$config"; then
        log_error "nftables 配置验证失败: ${config}"
        return 1
    fi

    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl restart nftables
    nft -f "$config"

    save_state "FIREWALL_BACKEND" "nftables"
    save_state "FIREWALL_NFT_CONFIG" "$config"
    save_state "FIREWALL_SSH_PORTS" "$ssh_ports"
    save_state "FIREWALL_EXTRA_TCP" "$extra_tcp"
    save_state "FIREWALL_EXTRA_UDP" "$extra_udp"
    save_state "FIREWALL_DUAL_STACK" "$dual_stack"
    save_state "CONF_FIREWALL" "1"

    log_info "nftables 防火墙配置完成"
}
