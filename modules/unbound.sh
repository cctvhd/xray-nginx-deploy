#!/usr/bin/env bash
# ============================================================
# modules/unbound.sh
# Unbound 本地递归 DNS 安装配置
# 自动识别系统：Ubuntu/Debian/CentOS/RHEL/Rocky/Alma
# ============================================================

# ── 安装 Unbound ─────────────────────────────────────────────
install_unbound() {
    log_step "安装 Unbound..."

    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y unbound >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux)
            dnf install -y unbound >/dev/null 2>&1
            ;;
        *)
            log_error "不支持的系统: $OS_NAME"
            exit 1
            ;;
    esac

    if ! command -v unbound &>/dev/null; then
        log_error "Unbound 安装失败"
        exit 1
    fi

    log_info "Unbound 安装成功: $(unbound -V 2>&1 | head -1)"
}

# ── 禁用 systemd-resolved 避免 53 端口冲突 ──────────────────
disable_systemd_resolved() {
    log_step "处理 systemd-resolved 冲突..."

    if systemctl is-active --quiet systemd-resolved; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        log_info "已禁用 systemd-resolved"
    else
        log_info "systemd-resolved 未运行，跳过"
    fi

    # 删除软链接
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
        log_info "已删除 resolv.conf 软链接"
    fi
}

# ── 下载根域名服务器列表 ─────────────────────────────────────
download_root_hints() {
    log_step "下载根域名服务器列表..."

    mkdir -p /var/lib/unbound

    curl -fsSL https://www.internic.net/domain/named.root \
        -o /var/lib/unbound/root.hints

    if [[ ! -s /var/lib/unbound/root.hints ]]; then
        log_warn "下载失败，使用内置根域名服务器列表..."
        cat > /var/lib/unbound/root.hints << 'HINTS'
.                        3600000      NS    A.ROOT-SERVERS.NET.
A.ROOT-SERVERS.NET.      3600000      A     198.41.0.4
A.ROOT-SERVERS.NET.      3600000      AAAA  2001:503:ba3e::2:30
.                        3600000      NS    B.ROOT-SERVERS.NET.
B.ROOT-SERVERS.NET.      3600000      A     170.247.170.2
B.ROOT-SERVERS.NET.      3600000      AAAA  2801:1b8:10::b
.                        3600000      NS    C.ROOT-SERVERS.NET.
C.ROOT-SERVERS.NET.      3600000      A     192.33.4.12
C.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:2::c
.                        3600000      NS    D.ROOT-SERVERS.NET.
D.ROOT-SERVERS.NET.      3600000      A     199.7.91.13
D.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:2d::d
.                        3600000      NS    E.ROOT-SERVERS.NET.
E.ROOT-SERVERS.NET.      3600000      A     192.203.230.10
E.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:a8::e
.                        3600000      NS    F.ROOT-SERVERS.NET.
F.ROOT-SERVERS.NET.      3600000      A     192.5.5.241
F.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:2f::f
.                        3600000      NS    G.ROOT-SERVERS.NET.
G.ROOT-SERVERS.NET.      3600000      A     192.112.36.4
G.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:12::d0d
.                        3600000      NS    H.ROOT-SERVERS.NET.
H.ROOT-SERVERS.NET.      3600000      A     198.97.190.53
H.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:1::53
.                        3600000      NS    I.ROOT-SERVERS.NET.
I.ROOT-SERVERS.NET.      3600000      A     192.36.148.17
I.ROOT-SERVERS.NET.      3600000      AAAA  2001:7fe::53
.                        3600000      NS    J.ROOT-SERVERS.NET.
J.ROOT-SERVERS.NET.      3600000      A     192.58.128.30
J.ROOT-SERVERS.NET.      3600000      AAAA  2001:503:c27::2:30
.                        3600000      NS    K.ROOT-SERVERS.NET.
K.ROOT-SERVERS.NET.      3600000      A     193.0.14.129
K.ROOT-SERVERS.NET.      3600000      AAAA  2001:7fd::1
.                        3600000      NS    L.ROOT-SERVERS.NET.
L.ROOT-SERVERS.NET.      3600000      A     199.7.83.42
L.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:9f::42
.                        3600000      NS    M.ROOT-SERVERS.NET.
M.ROOT-SERVERS.NET.      3600000      A     202.12.27.33
M.ROOT-SERVERS.NET.      3600000      AAAA  2001:dc3::35
HINTS
    fi

    log_info "根域名服务器列表准备完成"
}

# ── 初始化 DNSSEC trust anchor ───────────────────────────────
init_trust_anchor() {
    log_step "初始化 DNSSEC trust anchor..."

    mkdir -p /var/lib/unbound

    # 使用 unbound-anchor 初始化
    unbound-anchor -a /var/lib/unbound/root.key 2>/dev/null || true

    # 如果失败则手动写入
    if [[ ! -s /var/lib/unbound/root.key ]]; then
        log_warn "unbound-anchor 失败，手动写入 trust anchor..."
        cat > /var/lib/unbound/root.key << 'KEY'
. IN DS 20326 8 2 E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D
KEY
    fi

    chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true
    log_info "DNSSEC trust anchor 初始化完成"
}

# ── 根据 CPU 核心数计算线程数 ────────────────────────────────
get_thread_count() {
    local cores
    cores=$(nproc)
    # unbound 线程数不超过4，避免过多线程反而降低性能
    if [[ $cores -ge 4 ]]; then
        echo 4
    elif [[ $cores -ge 2 ]]; then
        echo 2
    else
        echo 1
    fi
}

# ── 生成 unbound 配置 ────────────────────────────────────────
generate_unbound_config() {
    log_step "生成 Unbound 配置..."

    local threads
    threads=$(get_thread_count)

    local mem_gb
    mem_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)

    # 根据内存调整缓存大小
    local msg_cache="64m"
    local rrset_cache="128m"
    [[ $mem_gb -ge 2 ]] && msg_cache="128m"  && rrset_cache="256m"
    [[ $mem_gb -ge 4 ]] && msg_cache="256m"  && rrset_cache="512m"
    [[ $mem_gb -ge 8 ]] && msg_cache="512m"  && rrset_cache="1024m"

    # 确定配置文件路径
    local conf_dir
    case "$OS_ID" in
        ubuntu|debian)
            conf_dir="/etc/unbound/unbound.conf.d"
            mkdir -p "$conf_dir"
            local main_conf="/etc/unbound/unbound.conf"
            # 确保 main conf 包含 conf.d
            if ! grep -q "include.*conf.d" "$main_conf" 2>/dev/null; then
                echo 'include: "/etc/unbound/unbound.conf.d/*.conf"' \
                    >> "$main_conf"
            fi
            local target_conf="${conf_dir}/local-recursive.conf"
            ;;
        centos|rhel|rocky|almalinux)
            conf_dir="/etc/unbound/conf.d"
            mkdir -p "$conf_dir"
            local target_conf="${conf_dir}/local-recursive.conf"
            ;;
    esac

    cat > "$target_conf" << CONF
# ----------------------------------------------------------------------
# Unbound 本地递归 DNS 配置
# 自动生成 - $(date)
# CPU: ${threads}线程 | 内存: ${mem_gb}GB
# ----------------------------------------------------------------------
server:
    # === 基本配置 ===
    verbosity: 1
    port: 53
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    # === 网络接口配置 - 仅本地访问 ===
    interface: 127.0.0.1
    interface: ::1

    # === 访问控制 ===
    access-control: 0.0.0.0/0 refuse
    access-control: 127.0.0.0/8 allow
    access-control: ::0/0 refuse
    access-control: ::1 allow
    access-control: ::ffff:127.0.0.1 allow

    # === 性能配置 ===
    num-threads: ${threads}
    so-reuseport: yes
    edns-tcp-keepalive: yes
    msg-cache-size: ${msg_cache}
    rrset-cache-size: ${rrset_cache}
    cache-max-ttl: 86400
    cache-min-ttl: 300
    prefetch: yes
    prefetch-key: yes
    outgoing-num-tcp: 64
    incoming-num-tcp: 64
    tcp-upstream: yes
    udp-upstream-without-downstream: yes
    so-rcvbuf: 4m
    so-sndbuf: 4m
    msg-buffer-size: 65552
    jostle-timeout: 200

    # === DNSSEC 验证 & 兼容性 ===
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    root-hints: "/var/lib/unbound/root.hints"
    harden-dnssec-stripped: no
    val-clean-additional: yes
    val-log-level: 1
    trust-anchor-signaling: yes

    # === 安全硬化 ===
    deny-any: yes
    harden-glue: yes
    harden-referral-path: yes
    harden-below-nxdomain: yes
    harden-algo-downgrade: yes

    # === 隐私保护 ===
    qname-minimisation: yes
    qname-minimisation-strict: yes
    hide-identity: yes
    hide-version: yes
    hide-trustanchor: yes
    aggressive-nsec: yes

    # === 系统配置 ===
    username: "unbound"
    directory: "/etc/unbound"
    chroot: ""
    pidfile: "/run/unbound.pid"
    do-daemonize: no
    use-systemd: yes

    # === 模块配置 ===
    module-config: "validator iterator"

# === 远程控制 ===
remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-interface: ::1
    control-port: 8953
    control-use-cert: yes
    server-key-file: "/etc/unbound/unbound_server.key"
    server-cert-file: "/etc/unbound/unbound_server.pem"
    control-key-file: "/etc/unbound/unbound_control.key"
    control-cert-file: "/etc/unbound/unbound_control.pem"
CONF

    log_info "Unbound 配置生成完成: $target_conf"
}

# ── 初始化 unbound-control 证书 ──────────────────────────────
init_unbound_control() {
    log_step "初始化 unbound-control 证书..."
    unbound-control-setup 2>/dev/null || true
    log_info "unbound-control 证书初始化完成"
}

# ── 配置 resolv.conf ─────────────────────────────────────────
setup_resolv_conf() {
    log_step "配置 /etc/resolv.conf..."

    # 备份原配置
    [[ -f /etc/resolv.conf ]] && \
        cp /etc/resolv.conf \
           "/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)"

    cat > /etc/resolv.conf << 'RESOLV'
# 本地 Unbound 递归 DNS
nameserver 127.0.0.1
nameserver ::1
options ndots:3 timeout:2 attempts:3
RESOLV

    # 锁定文件防止被 DHCP/NetworkManager 覆盖
    chattr +i /etc/resolv.conf 2>/dev/null || true
    log_info "/etc/resolv.conf 配置完成并已锁定"
}

# ── 启动 Unbound ─────────────────────────────────────────────
start_unbound() {
    log_step "启动 Unbound 服务..."

    # 验证配置
    if ! unbound-checkconf 2>&1; then
        log_error "Unbound 配置验证失败"
        exit 1
    fi

    systemctl enable --now unbound

    sleep 2
    if systemctl is-active --quiet unbound; then
        log_info "Unbound 服务启动成功"
    else
        log_error "Unbound 服务启动失败，查看日志："
        journalctl -u unbound -n 20 --no-pager
        exit 1
    fi
}

# ── 验证递归解析 ─────────────────────────────────────────────
verify_unbound() {
    log_step "验证本地递归解析..."

    sleep 1

    local test_domains=("google.com" "github.com" "cloudflare.com")
    local failed=0

    for domain in "${test_domains[@]}"; do
        if dig @127.0.0.1 "$domain" +short +time=5 \
           >/dev/null 2>&1; then
            log_info "解析成功: $domain"
        else
            log_warn "解析失败: $domain"
            ((failed++))
        fi
    done

    if [[ $failed -eq 0 ]]; then
        log_info "本地递归 DNS 验证通过"
    else
        log_warn "${failed} 个域名解析失败，请检查网络连接"
    fi
}

# ── 模块入口 ─────────────────────────────────────────────────
run_unbound() {
    log_step "========== Unbound 安装配置 =========="
    install_unbound
    disable_systemd_resolved
    download_root_hints
    init_trust_anchor
    generate_unbound_config
    init_unbound_control
    setup_resolv_conf
    start_unbound
    verify_unbound
    log_info "========== Unbound 安装配置完成 =========="
    echo ""
    log_info "本地递归 DNS 已就绪: 127.0.0.1:53"
    log_info "xray/sing-box/nginx 无需修改，自动走本地递归"
}
