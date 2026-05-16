#!/usr/bin/env bash
# ============================================================
# modules/unbound.sh
# Unbound 本地递归 DNS 安装配置
# 策略：完全替换 unbound.conf，conf.d 写自定义配置
# 兼容：Debian/Ubuntu/AlmaLinux/RHEL/Fedora
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
        ipv6|v6|ipv6-only)         echo "ipv6" ;;
        *)                          echo "ipv4" ;;
    esac
}

detect_unbound_stack_mode() {
    local has_v4=0 has_v6=0
    ip -o -4 addr show scope global 2>/dev/null | grep -q . && has_v4=1 || true
    ip -o -6 addr show scope global 2>/dev/null | grep -v ' fe80:' | grep -q . && has_v6=1 || true
    if [[ $has_v4 -eq 1 && $has_v6 -eq 1 ]]; then echo "dual"
    elif [[ $has_v6 -eq 1 ]];                then echo "ipv6"
    else                                          echo "ipv4"; fi
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
        *)    log_info "自动检测建议: 单栈 IPv4" ;;
    esac

    case "$default_stack" in
        dual) default_choice="1" ;;
        ipv6) default_choice="3" ;;
        *)    default_choice="2" ;;
    esac

    read -rp "请选择 [1-3，默认${default_choice}]: " stack_choice
    case "${stack_choice:-$default_choice}" in
        1) HW_DUAL_STACK="dual" ;;
        3) HW_DUAL_STACK="ipv6" ;;
        *) HW_DUAL_STACK="ipv4" ;;
    esac
    log_info "Unbound 网络栈模式: ${HW_DUAL_STACK}"
}

# ── 包管理器辅助 ─────────────────────────────────────────────
_pkg_install() {
    if [[ "${OS_ID:-}" =~ ^(ubuntu|debian)$ ]] || command -v apt-get >/dev/null 2>&1; then
        apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    else
        log_error "未找到可用的包管理器"
        exit 1
    fi
}

_pkg_remove() {
    if [[ "${OS_ID:-}" =~ ^(ubuntu|debian)$ ]] || command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y --purge "$@" 2>/dev/null || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y "$@" 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y "$@" 2>/dev/null || true
    fi
}

purge_unbound() {
    log_step "彻底清理 Unbound 残留..."
    systemctl stop    unbound                      2>/dev/null || true
    systemctl disable unbound                      2>/dev/null || true
    systemctl disable --now unbound-anchor.service 2>/dev/null || true
    systemctl mask    unbound-anchor.service        2>/dev/null || true

    if [[ "${OS_ID:-}" =~ ^(ubuntu|debian)$ ]] || command -v apt-get >/dev/null 2>&1; then
        _pkg_remove unbound unbound-anchor
    else
        _pkg_remove unbound unbound-libs
    fi

    rm -rf /etc/unbound /var/lib/unbound /run/unbound
    rm -f  /usr/local/bin/update-root-hints.sh
    rm -f  /etc/cron.weekly/update-root-hints
    rm -f  /etc/systemd/system/unbound-root-update.service
    rm -f  /etc/systemd/system/unbound-root-update.timer
    systemctl daemon-reload 2>/dev/null || true
	# 临时恢复公网 DNS，防止卸载后 resolv.conf 仍指向 127.0.0.1 导致 DNS 中断
	chattr -i /etc/resolv.conf 2>/dev/null || true
	echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
    log_info "Unbound 清理完成"
}

install_unbound() {
    log_step "安装 Unbound..."
    if [[ "${OS_ID:-}" =~ ^(ubuntu|debian)$ ]] || command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
    fi
    _pkg_install unbound
    if ! command -v unbound &>/dev/null; then
        log_error "Unbound 安装失败"
        exit 1
    fi
    log_info "Unbound 安装成功"
}

disable_systemd_resolved() {
    log_step "禁用 systemd-resolved..."
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop    systemd-resolved
        systemctl disable systemd-resolved
        log_info "已禁用 systemd-resolved"
    fi
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi
}

download_root_hints() {
    log_step "下载 root.hints..."
    mkdir -p /etc/unbound /var/lib/unbound
    curl -fsSL https://www.internic.net/domain/named.root \
        -o /etc/unbound/root.hints 2>/dev/null || true

    if [[ ! -s /etc/unbound/root.hints ]]; then
        log_warn "下载失败，使用内置列表..."
        cat > /etc/unbound/root.hints << 'HINTS_EOF'
. 3600000 NS A.ROOT-SERVERS.NET.
A.ROOT-SERVERS.NET. 3600000 A 198.41.0.4
A.ROOT-SERVERS.NET. 3600000 AAAA 2001:503:ba3e::2:30
. 3600000 NS B.ROOT-SERVERS.NET.
B.ROOT-SERVERS.NET. 3600000 A 170.247.170.2
. 3600000 NS C.ROOT-SERVERS.NET.
C.ROOT-SERVERS.NET. 3600000 A 192.33.4.12
. 3600000 NS D.ROOT-SERVERS.NET.
D.ROOT-SERVERS.NET. 3600000 A 199.7.91.13
. 3600000 NS E.ROOT-SERVERS.NET.
E.ROOT-SERVERS.NET. 3600000 A 192.203.230.10
. 3600000 NS F.ROOT-SERVERS.NET.
F.ROOT-SERVERS.NET. 3600000 A 192.5.5.241
. 3600000 NS G.ROOT-SERVERS.NET.
G.ROOT-SERVERS.NET. 3600000 A 192.112.36.4
. 3600000 NS H.ROOT-SERVERS.NET.
H.ROOT-SERVERS.NET. 3600000 A 198.97.190.53
. 3600000 NS I.ROOT-SERVERS.NET.
I.ROOT-SERVERS.NET. 3600000 A 192.36.148.17
. 3600000 NS J.ROOT-SERVERS.NET.
J.ROOT-SERVERS.NET. 3600000 A 192.58.128.30
. 3600000 NS K.ROOT-SERVERS.NET.
K.ROOT-SERVERS.NET. 3600000 A 193.0.14.129
. 3600000 NS L.ROOT-SERVERS.NET.
L.ROOT-SERVERS.NET. 3600000 A 199.7.83.42
. 3600000 NS M.ROOT-SERVERS.NET.
M.ROOT-SERVERS.NET. 3600000 A 202.12.27.33
HINTS_EOF
    fi
    chown unbound:unbound /etc/unbound/root.hints 2>/dev/null || true
    log_info "root.hints 准备完成"
}

init_trust_anchor() {
    log_step "初始化 DNSSEC trust anchor..."
    mkdir -p /var/lib/unbound
    chown unbound:unbound /var/lib/unbound 2>/dev/null || true

    if [[ ! -s /var/lib/unbound/root.key ]]; then
        unbound-anchor -a /var/lib/unbound/root.key 2>/dev/null || true
        chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null || true
        log_info "root.key 已生成"
    else
        log_info "root.key 已存在，跳过生成"
    fi
}

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
    read -rp "Unbound 服务名称（用于配置文件名，默认 ${default_name}）: " input
    UNBOUND_SERVICE_NAME=$(sanitize_unbound_service_name "${input:-$default_name}")
    log_info "Unbound 服务配置文件名: ${UNBOUND_SERVICE_NAME}.conf"
}

get_thread_count() {
    local cores
    cores=$(nproc)
    if   [[ $cores -ge 4 ]]; then echo 4
    elif [[ $cores -ge 2 ]]; then echo 2
    else echo 1; fi
}

get_effective_mem_gb() {
    local mem_mb
    mem_mb=$(awk '/MemTotal/{print int($2/1024 + 0.5)}' /proc/meminfo)
    if   (( mem_mb >= 1792 && mem_mb < 2048 )); then echo 2
    elif (( mem_mb >= 3584 && mem_mb < 4096 )); then echo 4
    elif (( mem_mb >= 7168 && mem_mb < 8192 )); then echo 8
    else awk -v m="$mem_mb" 'BEGIN { print int(m/1024) }'; fi
}

# ── 获取服务器 IP ───────────────────────────────────────────
_get_server_ipv4() {
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

_get_server_ipv6() {
    ip -o -6 addr show scope global 2>/dev/null | grep -v ' fe80:' | awk '{print $4}' | cut -d/ -f1 | head -1
}

# ── 构建自有域名内部解析 ──────────────────────────────────────
_build_own_domain_zones() {
    local reality_domain anytls_domain cdn_str
    reality_domain=$(get_state "REALITY_DOMAIN" "")
    anytls_domain=$(get_state "ANYTLS_DOMAIN" "")
    cdn_str=$(get_state "CDN_DOMAINS" "")

    local server_ipv4 server_ipv6
    server_ipv4=$(_get_server_ipv4)
    server_ipv6=$(_get_server_ipv6)

    echo "    # === 自有域名内部解析 ==="

    # Reality 域名：static zone + A/AAAA 记录
    if [[ -n "$reality_domain" ]]; then
        echo "    local-zone: \"${reality_domain}.\" static"
        if [[ -n "$server_ipv4" ]]; then
            echo "    local-data: \"${reality_domain}. 300 IN A ${server_ipv4}\""
        fi
        if [[ -n "$server_ipv6" ]]; then
            echo "    local-data: \"${reality_domain}. 300 IN AAAA ${server_ipv6}\""
        fi
    fi

    # AnyTLS 域名：static zone + A/AAAA 记录
    if [[ -n "$anytls_domain" ]]; then
        echo "    local-zone: \"${anytls_domain}.\" static"
        if [[ -n "$server_ipv4" ]]; then
            echo "    local-data: \"${anytls_domain}. 300 IN A ${server_ipv4}\""
        fi
        if [[ -n "$server_ipv6" ]]; then
            echo "    local-data: \"${anytls_domain}. 300 IN AAAA ${server_ipv6}\""
        fi
    fi

    local hy2_domain naive_domain
    hy2_domain=$(get_state "HYSTERIA2_DOMAIN" "")
    naive_domain=$(get_state "NAIVE_DOMAIN" "")

    # Hysteria2 域名：static zone + A/AAAA 记录（CDN域名跳过）
    if [[ -n "$hy2_domain" ]]; then
        local is_cdn=0
        if [[ -n "$cdn_str" ]]; then
            local _cdn_arr=()
            read -ra _cdn_arr <<< "$cdn_str"
            for _d in "${_cdn_arr[@]}"; do
                [[ "$_d" == "$hy2_domain" ]] && is_cdn=1 && break
            done
        fi
        if [[ $is_cdn -eq 0 ]]; then
            echo "    local-zone: \"${hy2_domain}.\" static"
            if [[ -n "$server_ipv4" ]]; then
                echo "    local-data: \"${hy2_domain}. 300 IN A ${server_ipv4}\""
            fi
            if [[ -n "$server_ipv6" ]]; then
                echo "    local-data: \"${hy2_domain}. 300 IN AAAA ${server_ipv6}\""
            fi
        fi
    fi

    # NaiveProxy 域名：static zone + A/AAAA 记录（CDN域名跳过）
    if [[ -n "$naive_domain" ]]; then
        local is_cdn=0
        if [[ -n "$cdn_str" ]]; then
            local _cdn_arr=()
            read -ra _cdn_arr <<< "$cdn_str"
            for _d in "${_cdn_arr[@]}"; do
                [[ "$_d" == "$naive_domain" ]] && is_cdn=1 && break
            done
        fi
        if [[ $is_cdn -eq 0 ]]; then
            echo "    local-zone: \"${naive_domain}.\" static"
            if [[ -n "$server_ipv4" ]]; then
                echo "    local-data: \"${naive_domain}. 300 IN A ${server_ipv4}\""
            fi
            if [[ -n "$server_ipv6" ]]; then
                echo "    local-data: \"${naive_domain}. 300 IN AAAA ${server_ipv6}\""
            fi
        fi
    fi

    # CDN 域名：只标注注释，不做本地解析
    if [[ -n "$cdn_str" ]]; then
        local cdn_domains=()
        read -ra cdn_domains <<< "$cdn_str"
        echo ""
        echo "    # === CDN 域名（不做本地解析，走上游 CDN）==="
        local cdn_d
        for cdn_d in "${cdn_domains[@]}"; do
            [[ -z "$cdn_d" ]] && continue
            echo "    # CDN 域名: ${cdn_d}"
        done
    fi

    if [[ -z "$reality_domain" && -z "$anytls_domain" && -z "$hy2_domain" && -z "$naive_domain" && -z "$cdn_str" ]]; then
        echo "    # 暂无自有域名配置"
    fi
}

# ── 生成主配置 /etc/unbound/unbound.conf ────────────────────
generate_main_config() {
    log_step "生成主配置 /etc/unbound/unbound.conf..."

    local threads mem_gb msg_cache rrset_cache
    threads=$(get_thread_count)
    mem_gb=$(get_effective_mem_gb)
    msg_cache="256m"
    rrset_cache="512m"
    [[ $mem_gb -ge 8 ]] && msg_cache="512m" && rrset_cache="1024m"

    local do_ip6="yes"
    local iface_ipv6="    interface: ::"
    [[ "$(get_stack_mode)" == "ipv4" ]] && do_ip6="no" && iface_ipv6="    # interface: ::  # IPv4-only"

    cat > /etc/unbound/unbound.conf << MAIN_EOF
# ============================================================
# /etc/unbound/unbound.conf
# 由 xray-nginx-deploy 自动生成 - $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

server:
    # === 基础设置 ===
    verbosity: 1
    port: 53
    do-ip4: yes
    do-ip6: ${do_ip6}
    do-udp: yes
    do-tcp: yes
    interface: 0.0.0.0
${iface_ipv6}

    # === 访问控制（仅本地）===
    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow
    access-control: 0.0.0.0/0 refuse
    access-control: ::/0 refuse

    # === 性能优化 ===
    num-threads: ${threads}
    so-reuseport: yes
    msg-cache-size: ${msg_cache}
    rrset-cache-size: ${rrset_cache}
    cache-max-ttl: 86400
    cache-min-ttl: 300
    prefetch: yes
    prefetch-key: yes
    outgoing-range: 8192
    num-queries-per-thread: 4096
    jostle-timeout: 200
    so-rcvbuf: 8m
    so-sndbuf: 8m

    # === 安全加固 ===
    prefer-ip6: yes
    deny-any: yes
    harden-glue: yes
    harden-referral-path: yes
    harden-below-nxdomain: yes
    hide-identity: yes
    hide-version: yes
    hide-trustanchor: yes

    # === DNSSEC ===
    # chroot: "" 确保路径从系统根目录解析，不受 directory 影响
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    root-hints: "/etc/unbound/root.hints"

    # === 过期缓存容错 ===
    serve-expired: yes
    serve-expired-ttl: 1800
    serve-expired-client-timeout: 120

    # === 系统参数 ===
    username: "unbound"
    directory: "/etc/unbound"
    chroot: ""
    pidfile: "/run/unbound.pid"
    use-systemd: yes
    module-config: "validator iterator"

    # === 加载扩展配置 ===
    include: "/etc/unbound/conf.d/*.conf"

# === 远程控制 ===
remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-interface: ::1
    control-port: 8953
    control-use-cert: no
MAIN_EOF

    chown root:unbound /etc/unbound/unbound.conf 2>/dev/null || true
    chmod 640 /etc/unbound/unbound.conf
    log_info "主配置生成完成"
}

# ── 生成 conf.d 自定义配置 ───────────────────────────────────
generate_custom_config() {
    log_step "生成自定义配置 /etc/unbound/conf.d/..."

    UNBOUND_SERVICE_NAME=$(infer_unbound_service_name)
    mkdir -p /etc/unbound/conf.d

    rm -f "/etc/unbound/conf.d/${UNBOUND_SERVICE_NAME}.conf"

	# 清理 unbound 包自带或残留的配置文件，避免与脚本主配置冲突
	rm -f /etc/unbound/conf.d/remote-control.conf
	rm -f /etc/unbound/conf.d/example.com.conf
	rm -f /etc/unbound/conf.d/unbound-local-root.conf
	rm -f /etc/unbound/unbound-local-root.conf

    local own_domain_zones
    own_domain_zones=$(_build_own_domain_zones)

    cat > "/etc/unbound/conf.d/${UNBOUND_SERVICE_NAME}.conf" << CUSTOM_EOF
# ============================================================
# /etc/unbound/conf.d/${UNBOUND_SERVICE_NAME}.conf
# 由 xray-nginx-deploy 自动生成 - $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

server:
    # === 本地域名解析 ===
    local-zone: "localhost." static
    local-data: "localhost. 10800 IN A 127.0.0.1"
    local-data: "localhost. 10800 IN AAAA ::1"
    local-zone: "127.in-addr.arpa." static
    local-zone: "0.0.0.0/8." static
    local-zone: "ip6.arpa." transparent

${own_domain_zones}

    # === 局域与安全域 ===
    do-not-query-localhost: yes
    private-address: 192.168.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10

    # === 特殊系统域名拒绝 ===
    local-zone: "version.bind." refuse
    local-zone: "authors.bind." refuse
    local-zone: "hostname.bind." refuse
    local-zone: "id.server." refuse

    # === 性能统计 ===
    statistics-interval: 0
    statistics-cumulative: no
    extended-statistics: yes
CUSTOM_EOF

    chown root:unbound "/etc/unbound/conf.d/${UNBOUND_SERVICE_NAME}.conf" 2>/dev/null || true
    chmod 640 "/etc/unbound/conf.d/${UNBOUND_SERVICE_NAME}.conf"
    log_info "自定义配置生成完成: /etc/unbound/conf.d/${UNBOUND_SERVICE_NAME}.conf"
}

generate_unbound_config() {
    generate_main_config
    generate_custom_config
}

init_unbound_control() {
    log_info "remote-control 已写入主配置"
}

# ── root.hints 自动更新脚本 + 定时任务 ──────────────────────
install_root_update_job() {
    log_step "安装 root.hints 自动更新脚本..."

    cat > /usr/local/bin/update-root-hints.sh << 'UPDATE_EOF'
#!/usr/bin/env bash
# 自动更新 Unbound root.hints 并重启服务
set -euo pipefail

ROOT_HINTS_URL="https://www.internic.net/domain/named.root"
DEST_FILE="/etc/unbound/root.hints"
ROOT_KEY_FILE="/var/lib/unbound/root.key"
BACKUP_DIR="/var/lib/unbound/root-hints-backup"
MAX_BACKUPS=5
MAX_RETRIES=3
LOG_FILE="/var/log/unbound-root-update.log"
MIN_ROOT_HINTS_SIZE=3000
TIMESTAMP_FILE="/var/lib/unbound/root-update.timestamp"

_info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
_error() { echo -e "\033[1;31m[ERR]\033[0m  $*"; }

exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 开始更新 ====="

[[ $EUID -ne 0 ]] && { _error "请使用 root 用户运行"; exit 1; }

mkdir -p /etc/unbound /var/lib/unbound "$BACKUP_DIR"

# ── 初始化 root.key（文件不存在或为空时）───────────────────
if [[ ! -f "$ROOT_KEY_FILE" || ! -s "$ROOT_KEY_FILE" ]]; then
    _info "生成 root.key..."
    unbound-anchor -a "$ROOT_KEY_FILE" 2>/dev/null || true
    chown unbound:unbound "$ROOT_KEY_FILE" 2>/dev/null || true
fi

# ── 备份旧 root.hints ────────────────────────────────────────
TS=$(date +"%Y%m%d-%H%M%S")
if [[ -f "$DEST_FILE" ]]; then
    cp "$DEST_FILE" "${BACKUP_DIR}/root.hints.${TS}"
    _info "已备份到 ${BACKUP_DIR}/root.hints.${TS}"
    ls -1t "${BACKUP_DIR}"/root.hints.* 2>/dev/null \
        | tail -n +$((MAX_BACKUPS + 1)) \
        | xargs -r rm -f
fi

# ── 下载最新 root.hints ──────────────────────────────────────
_info "下载最新 root.hints..."
downloaded=0
for i in $(seq 1 $MAX_RETRIES); do
    if curl -fsSL "$ROOT_HINTS_URL" -o "${DEST_FILE}.new"; then
        mv "${DEST_FILE}.new" "$DEST_FILE"
        chown unbound:unbound "$DEST_FILE" 2>/dev/null || true
        chmod 644 "$DEST_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$TIMESTAMP_FILE"
        _info "下载成功，已更新 root.hints"
        downloaded=1
        break
    else
        _warn "下载失败，第 $i 次尝试..."
        sleep 2
    fi
done

if [[ $downloaded -eq 0 ]]; then
    _error "多次下载失败，保留旧版本"
    [[ -f "${BACKUP_DIR}/root.hints.${TS}" ]] && \
        cp "${BACKUP_DIR}/root.hints.${TS}" "$DEST_FILE"
    exit 1
fi

# ── 校验配置 ─────────────────────────────────────────────────
if unbound-checkconf >/dev/null 2>&1; then
    _info "Unbound 配置校验通过"
else
    _error "Unbound 配置错误，恢复旧版本..."
    [[ -f "${BACKUP_DIR}/root.hints.${TS}" ]] && \
        cp "${BACKUP_DIR}/root.hints.${TS}" "$DEST_FILE"
    exit 1
fi

# ── 重启服务 ─────────────────────────────────────────────────
_info "重启 unbound 服务..."
systemctl restart unbound
sleep 2
if systemctl is-active --quiet unbound; then
    _info "✅ Unbound 重启成功，root.hints 更新完成"
else
    _error "Unbound 重启失败"
    exit 1
fi
UPDATE_EOF

    chmod +x /usr/local/bin/update-root-hints.sh

    cat > /etc/systemd/system/unbound-root-update.service << 'SVC_EOF'
[Unit]
Description=Update Unbound root.hints
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-root-hints.sh
StandardOutput=journal
StandardError=journal
SVC_EOF

    cat > /etc/systemd/system/unbound-root-update.timer << 'TIMER_EOF'
[Unit]
Description=Monthly Unbound root.hints update
Requires=unbound-root-update.service

[Timer]
OnCalendar=monthly
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

    systemctl daemon-reload
    systemctl enable --now unbound-root-update.timer
    log_info "定时任务已启用（每月自动更新 root.hints）"
}

start_unbound() {
    log_step "启动 Unbound 服务..."

    systemctl disable --now unbound-anchor.service 2>/dev/null || true
    systemctl mask    unbound-anchor.service        2>/dev/null || true

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

setup_resolv_conf() {
    local resolver_addr="127.0.0.1"
    [[ "$(get_stack_mode)" == "ipv6" ]] && resolver_addr="::1"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << RESOLV_EOF
nameserver ${resolver_addr}
options ndots:1 timeout:2 attempts:2
RESOLV_EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    log_info "/etc/resolv.conf 配置完成 (nameserver: ${resolver_addr})"
}

verify_unbound() {
    log_step "验证本地递归解析..."
    for domain in google.com github.com cloudflare.com; do
        if dig @127.0.0.1 "$domain" +short +time=5 >/dev/null 2>&1; then
            log_info "解析成功: $domain"
        else
            log_warn "解析失败: $domain"
        fi
    done
}

# ── 供 install.sh 调用的刷新函数 ─────────────────────────────
refresh_unbound_generated_config() {
    generate_unbound_config && systemctl restart unbound 2>/dev/null || return 1
    sleep 2
    systemctl is-active --quiet unbound || return 1
    log_info "Unbound 配置已刷新"
    return 0
}

# ── 模块入口 ─────────────────────────────────────────────────
run_unbound() {
    log_step "========== Unbound 安装配置 =========="

    if check_unbound_installed; then
        log_info "Unbound 已安装且运行中"
        echo ""
        echo " 1. 跳过"
        echo " 2. 重新配置"
        echo " 3. 完整重装"
        echo " 4. 仅刷新域名配置（不重建基础环境）"
        read -rp "请选择 [1-4，默认1]: " unbound_choice
        case "${unbound_choice:-1}" in
            4)
                refresh_unbound_generated_config && log_info "域名配置已刷新" || log_error "刷新失败"
                ;;
            3)
                collect_unbound_stack_mode
                collect_unbound_service_name
                	trap 'echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf' EXIT
	purge_unbound
                install_unbound
                disable_systemd_resolved
                download_root_hints
                init_trust_anchor
                generate_unbound_config
                init_unbound_control
                start_unbound
	trap - EXIT
                install_root_update_job
                ;;
            2)
                collect_unbound_stack_mode
                collect_unbound_service_name
                disable_systemd_resolved
                mkdir -p /etc/unbound /var/lib/unbound
                chown unbound:unbound /var/lib/unbound 2>/dev/null || true
                download_root_hints
                init_trust_anchor
                generate_unbound_config
                systemctl restart unbound
                sleep 2
                if systemctl is-active --quiet unbound; then
                    setup_resolv_conf
                    verify_unbound
                    install_root_update_job
                else
                    log_error "Unbound 重启失败"
                    journalctl -u unbound -n 20 --no-pager
                    exit 1
                fi
                ;;
            *)
                log_info "已跳过 Unbound"
                ;;
        esac
    else
        collect_unbound_stack_mode
        collect_unbound_service_name
        install_unbound
        disable_systemd_resolved
        download_root_hints
        init_trust_anchor
        generate_unbound_config
        init_unbound_control
        start_unbound
        install_root_update_job
    fi

    log_info "========== Unbound 安装配置完成 =========="
    log_info "本地递归 DNS   : 127.0.0.1:53"
    log_info "root.hints 更新: 每月自动执行（systemd timer）"
}