#!/usr/bin/env bash
# ============================================================
# modules/unbound.sh
# Unbound 本地递归 DNS 安装配置
# ============================================================

# ── 检测是否已安装且运行 ─────────────────────────────────────
check_unbound_installed() {
    if command -v unbound &>/dev/null && \
       systemctl is-active --quiet unbound 2>/dev/null; then
        return 0
    fi
    return 1
}

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

# ── 禁用 systemd-resolved ────────────────────────────────────
disable_systemd_resolved() {
    log_step "处理 systemd-resolved 冲突..."

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        log_info "已禁用 systemd-resolved"
    else
        log_info "systemd-resolved 未运行，跳过"
    fi

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
        -o /var/lib/unbound/root.hints 2>/dev/null || true

    if [[ ! -s /var/lib/unbound/root.hints ]]; then
        log_warn "下载失败，使用内置列表..."
        cat > /var/lib/unbound/root.hints << 'HINTS_EOF'
.                        3600000      NS    A.ROOT-SERVERS.NET.
A.ROOT-SERVERS.NET.      3600000      A     198.41.0.4
A.ROOT-SERVERS.NET.      3600000      AAAA  2001:503:ba3e::2:30
.                        3600000      NS    B.ROOT-SERVERS.NET.
B.ROOT-SERVERS.NET.      3600000      A     170.247.170.2
.                        3600000      NS    C.ROOT-SERVERS.NET.
C.ROOT-SERVERS.NET.      3600000      A     192.33.4.12
.                        3600000      NS    D.ROOT-SERVERS.NET.
D.ROOT-SERVERS.NET.      3600000      A     199.7.91.13
.                        3600000      NS    E.ROOT-SERVERS.NET.
E.ROOT-SERVERS.NET.      3600000      A     192.203.230.10
.                        3600000      NS    F.ROOT-SERVERS.NET.
F.ROOT-SERVERS.NET.      3600000      A     192.5.5.241
.                        3600000      NS    G.ROOT-SERVERS.NET.
G.ROOT-SERVERS.NET.      3600000      A     192.112.36.4
.                        3600000      NS    H.ROOT-SERVERS.NET.
H.ROOT-SERVERS.NET.      3600000      A     198.97.190.53
.                        3600000      NS    I.ROOT-SERVERS.NET.
I.ROOT-SERVERS.NET.      3600000      A     192.36.148.17
.                        3600000      NS    J.ROOT-SERVERS.NET.
J.ROOT-SERVERS.NET.      3600000      A     192.58.128.30
.                        3600000      NS    K.ROOT-SERVERS.NET.
K.ROOT-SERVERS.NET.      3600000      A     193.0.14.129
.                        3600000      NS    L.ROOT-SERVERS.NET.
L.ROOT-SERVERS.NET.      3600000      A     199.7.83.42
.                        3600000      NS    M.ROOT-SERVERS.NET.
M.ROOT-SERVERS.NET.      3600000      A     202.12.27.33
HINTS_EOF
    fi

    chown unbound:unbound /var/lib/unbound/root.hints 2>/dev/null || true
    log_info "根域名服务器列表准备完成"
}

# ── 初始化 DNSSEC trust anchor ───────────────────────────────
init_trust_anchor() {
    log_step "初始化 DNSSEC trust anchor..."

    mkdir -p /var/lib/unbound

    # 检查系统已有的 root.key
    local system_key=""
    for path in \
        /var/lib/unbound/root.key \
        /usr/share/dns/root.key \
        /etc/unbound/root.key; do
        if [[ -f "$path" && -s "$path" ]]; then
            system_key="$path"
            break
        fi
    done

    if [[ -n "$system_key" ]]; then
        if [[ "$system_key" != "/var/lib/unbound/root.key" ]]; then
            cp "$system_key" /var/lib/unbound/root.key
            log_info "使用系统自带 trust anchor: $system_key"
        else
            log_info "root.key 已存在，跳过初始化"
        fi
    else
        unbound-anchor -a /var/lib/unbound/root.key 2>/dev/null || true
        if [[ ! -s /var/lib/unbound/root.key ]]; then
            log_warn "手动写入 trust anchor DS 记录..."
            printf '. IN DS 20326 8 2 E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D\n' \
                > /var/lib/unbound/root.key
        fi
    fi

    chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null || true
    log_info "DNSSEC trust anchor 初始化完成"
}

# ── 服务名称与配置路径 ───────────────────────────────────────
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

get_unbound_conf_dir() {
    case "$OS_ID" in
        ubuntu|debian)
            echo "/etc/unbound/unbound.conf.d"
            ;;
        centos|rhel|rocky|almalinux)
            echo "/etc/unbound/conf.d"
            ;;
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

build_unbound_transparent_zones() {
    local extra_domains=()
    local -A seen=()
    local domain root

    if declare -p ALL_DOMAINS >/dev/null 2>&1; then
        extra_domains=("${ALL_DOMAINS[@]}")
    fi

    for domain in \
        "${XHTTP_DOMAIN:-}" \
        "${GRPC_DOMAIN:-}" \
        "${REALITY_DOMAIN:-}" \
        "${ANYTLS_DOMAIN:-}" \
        "${extra_domains[@]}"; do
        [[ -n "$domain" ]] || continue
        domain="${domain%.}"
        domain="${domain,,}"

        if [[ -z "${seen[$domain]:-}" ]]; then
            printf '    local-zone: "%s." transparent\n' "$domain"
            seen["$domain"]=1
        fi

        root=$(echo "$domain" | awk -F. 'NF >= 2 {print $(NF-1)"."$NF}')
        if [[ -n "$root" && -z "${seen[$root]:-}" ]]; then
            printf '    local-zone: "%s." transparent\n' "$root"
            seen["$root"]=1
        fi
    done
}

# ── 计算线程数 ───────────────────────────────────────────────
get_thread_count() {
    local cores
    cores=$(nproc)
    if [[ $cores -ge 4 ]]; then echo 4
    elif [[ $cores -ge 2 ]]; then echo 2
    else echo 1
    fi
}

# ── 检测主配置里已有的 auto-trust-anchor-file ────────────────
get_main_conf_anchor() {
    # 找到主配置里已声明的 trust anchor 路径
    grep -r "auto-trust-anchor-file" \
        /etc/unbound/unbound.conf \
        /etc/unbound/conf.d/ \
        /etc/unbound/unbound.conf.d/ \
        2>/dev/null | \
        grep -v "local-recursive.conf" | \
        head -1 | \
        grep -oP '"\K[^"]+' || echo ""
}

# ── 生成配置 ─────────────────────────────────────────────────
generate_unbound_config() {
    log_step "生成 Unbound 配置..."

    local threads
    threads=$(get_thread_count)

    local mem_gb
    mem_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)

    local msg_cache="64m"
    local rrset_cache="128m"
    [[ $mem_gb -ge 2 ]] && msg_cache="128m"  && rrset_cache="256m"
    [[ $mem_gb -ge 4 ]] && msg_cache="256m"  && rrset_cache="512m"
    [[ $mem_gb -ge 8 ]] && msg_cache="512m"  && rrset_cache="1024m"

    local conf_dir target_conf anchor_conf remote_conf
    local transparent_zone_lines

    UNBOUND_SERVICE_NAME=$(infer_unbound_service_name)
    ensure_unbound_include_dir

    conf_dir=$(get_unbound_conf_dir)
    target_conf="${conf_dir}/${UNBOUND_SERVICE_NAME}.conf"
    anchor_conf="${conf_dir}/root-auto-trust-anchor-file.conf"
    remote_conf="${conf_dir}/remote-control.conf"
    transparent_zone_lines=$(build_unbound_transparent_zones)

    rm -f "${conf_dir}/local-recursive.conf"

    cat > "$target_conf" << CONF_EOF
# ----------------------------------------------------------------------
# Unbound 本地递归 DNS 配置
# 自动生成 - $(date)
# 服务: ${UNBOUND_SERVICE_NAME} | CPU: ${threads}线程 | 内存: ${mem_gb}GB
# ----------------------------------------------------------------------
server:
    verbosity: 1
    port: 53
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    interface: 127.0.0.1
    interface: ::1

    access-control: 127.0.0.0/8 allow
    access-control: ::1 allow
    access-control: ::ffff:127.0.0.1 allow
    access-control: 0.0.0.0/0 refuse
    access-control: ::0/0 refuse

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
    outgoing-num-tcp: 64
    incoming-num-tcp: 64
    tcp-upstream: yes
    edns-tcp-keepalive: yes
    root-hints: "/var/lib/unbound/root.hints"

    serve-expired: yes
    serve-expired-ttl: 1800
    serve-expired-client-timeout: 120

    prefer-ip6: no
    deny-any: yes
    harden-glue: yes
    harden-referral-path: yes
    harden-below-nxdomain: yes
    hide-identity: yes
    hide-version: yes
    hide-trustanchor: yes

    username: "unbound"
    directory: "/etc/unbound"
    chroot: ""
    pidfile: "/run/unbound.pid"
    use-systemd: yes
    module-config: "validator iterator"

    local-zone: "localhost." static
    local-data: "localhost. 10800 IN A 127.0.0.1"
    local-data: "localhost. 10800 IN AAAA ::1"
    local-zone: "127.in-addr.arpa." static
    local-zone: "0.0.0.0/8." static
    local-zone: "ip6.arpa." transparent

    local-zone: "cdnjs.cloudflare.com." transparent
    local-zone: "ajax.cloudflare.com." transparent
    local-zone: "ajax.googleapis.com." transparent
    local-zone: "fonts.googleapis.com." transparent
    local-zone: "fonts.gstatic.com." transparent
    local-zone: "googleapis.com." transparent
    local-zone: "gstatic.com." transparent
${transparent_zone_lines:+
${transparent_zone_lines}}
    do-not-query-localhost: yes
    private-address: 192.168.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10

    local-zone: "version.bind." refuse
    local-zone: "authors.bind." refuse
    local-zone: "hostname.bind." refuse
    local-zone: "id.server." refuse

    statistics-interval: 0
    statistics-cumulative: no
    extended-statistics: yes
CONF_EOF

    cat > "$anchor_conf" << CONF_EOF
server:
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
CONF_EOF

    cat > "$remote_conf" << CONF_EOF
remote-control:
    control-enable: yes
    control-interface: /run/unbound.ctl
CONF_EOF

    log_info "Unbound 配置生成完成: $target_conf"
}

# ── 初始化 unbound-control 证书 ──────────────────────────────
init_unbound_control() {
    log_info "使用 UNIX socket remote-control，跳过证书初始化"
}

# ── 安装 root.hints 更新脚本 ────────────────────────────────
install_root_hints_updater() {
    log_step "安装 root.hints 自动更新脚本..."

    mkdir -p /usr/local/bin

    cat > /usr/local/bin/update-root-hints.sh << 'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_HINTS_URL="${ROOT_HINTS_URL:-https://www.internic.net/domain/named.cache}"
DEST_FILE="/var/lib/unbound/root.hints"
ROOT_KEY_FILE="/var/lib/unbound/root.key"
BACKUP_DIR="/var/lib/unbound/root-hints-backup"
MAX_BACKUPS=5
MAX_RETRIES=3
LOG_FILE="/var/log/unbound-root-update.log"
MIN_ROOT_HINTS_SIZE=3000
TIMESTAMP_FILE="/var/lib/unbound/root-update.timestamp"

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR]${NC}  $*"; }

exec > >(tee -a "$LOG_FILE") 2>&1

if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行此脚本。"
    exit 1
fi

mkdir -p /var/lib/unbound

if [[ ! -f "$DEST_FILE" || $(stat -c%s "$DEST_FILE") -lt $MIN_ROOT_HINTS_SIZE ]]; then
    info "初始化 root.hints..."
    curl -fsSL "$ROOT_HINTS_URL" -o "$DEST_FILE"
    chown unbound:unbound "$DEST_FILE"
fi

if [[ ! -f "$ROOT_KEY_FILE" || ! -s "$ROOT_KEY_FILE" ]]; then
    info "生成 root.key..."
    unbound-anchor -a "$ROOT_KEY_FILE"
    chown unbound:unbound "$ROOT_KEY_FILE"
fi

mkdir -p "$BACKUP_DIR"
TS=$(date +"%Y%m%d-%H%M%S")
cp "$DEST_FILE" "$BACKUP_DIR/root.hints.$TS"
info "已备份 root.hints → $BACKUP_DIR/root.hints.$TS"
ls -1t "$BACKUP_DIR"/root.hints.* 2>/dev/null | \
    tail -n +$((MAX_BACKUPS+1)) | xargs -r rm -f

info "下载最新 root.hints..."
for i in $(seq 1 $MAX_RETRIES); do
    if curl -fsSL "$ROOT_HINTS_URL" -o "$DEST_FILE.new"; then
        mv "$DEST_FILE.new" "$DEST_FILE"
        chown unbound:unbound "$DEST_FILE"
        info "root.hints 更新成功"
        echo "$(date)" > "$TIMESTAMP_FILE"
        break
    else
        warn "下载失败，尝试 $i/${MAX_RETRIES}"
        sleep 2
    fi
done

info "校验 Unbound 配置..."
if ! unbound-checkconf >/dev/null 2>&1; then
    error "配置错误！恢复旧文件..."
    cp "$BACKUP_DIR/root.hints.$TS" "$DEST_FILE"
    exit 1
fi

info "测试 Unbound 查询..."
if ! dig @127.0.0.1 . NS +time=1 +retry=1 >/dev/null 2>&1; then
    warn "Unbound 查询不正常，但仍尝试重启..."
fi

info "重启 unbound..."
systemctl restart unbound

if systemctl is-active --quiet unbound; then
    info "Unbound 重启成功！"
else
    error "Unbound 重启失败！恢复旧文件..."
    cp "$BACKUP_DIR/root.hints.$TS" "$DEST_FILE"
    systemctl restart unbound || true
    exit 1
fi

info "✅ Root.hints 更新完成"
SCRIPT_EOF

    chmod +x /usr/local/bin/update-root-hints.sh
    log_info "root.hints 更新脚本已安装: /usr/local/bin/update-root-hints.sh"
}

# ── 配置 root.hints 自动更新任务 ────────────────────────────
setup_root_hints_updater() {
    log_step "配置 root.hints 自动更新任务..."

    cat > /etc/cron.weekly/update-root-hints << 'CRON_EOF'
#!/usr/bin/env bash
/usr/local/bin/update-root-hints.sh
CRON_EOF
    chmod +x /etc/cron.weekly/update-root-hints

    (crontab -l 2>/dev/null | grep -v "update-root-hints.sh"; \
     echo "17 4 * * 0 /usr/local/bin/update-root-hints.sh >/dev/null 2>&1") | crontab -

    log_info "已配置每周自动更新 root.hints"
}

# ── 配置 resolv.conf ─────────────────────────────────────────
setup_resolv_conf() {
    log_step "配置 /etc/resolv.conf..."

    chattr -i /etc/resolv.conf 2>/dev/null || true

    [[ -f /etc/resolv.conf ]] && \
        cp /etc/resolv.conf \
           "/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)" \
           2>/dev/null || true

    cat > /etc/resolv.conf << 'RESOLV_EOF'
# 本地 Unbound 递归 DNS
nameserver 127.0.0.1
nameserver ::1
options ndots:3 timeout:2 attempts:3
RESOLV_EOF

    chattr +i /etc/resolv.conf 2>/dev/null || true
    log_info "/etc/resolv.conf 配置完成并已锁定"
}

# ── 启动 Unbound ─────────────────────────────────────────────
start_unbound() {
    log_step "启动 Unbound 服务..."

    if ! unbound-checkconf >/dev/null 2>&1; then
        log_error "Unbound 配置验证失败"
        unbound-checkconf || true
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

    local failed=0
    for domain in google.com github.com cloudflare.com; do
        if dig @127.0.0.1 "$domain" +short +time=5 \
           >/dev/null 2>&1; then
            log_info "解析成功: $domain"
        else
            log_warn "解析失败: $domain"
            (( failed++ )) || true
        fi
    done

    if [[ $failed -eq 0 ]]; then
        log_info "本地递归 DNS 验证通过"
    else
        log_warn "${failed} 个域名解析失败，请检查网络"
    fi
}

# ── 域名更新后刷新生成配置 ───────────────────────────────────
refresh_unbound_generated_config() {
    log_step "刷新 Unbound 生成配置..."
    generate_unbound_config

    if ! unbound-checkconf >/dev/null 2>&1; then
        log_error "Unbound 配置验证失败"
        unbound-checkconf || true
        return 1
    fi

    if systemctl is-active --quiet unbound; then
        systemctl restart unbound
        sleep 1
        if systemctl is-active --quiet unbound; then
            log_info "Unbound 已按最新域名配置重启"
            return 0
        fi
        log_error "Unbound 重启失败"
        journalctl -u unbound -n 20 --no-pager || true
        return 1
    fi

    log_info "Unbound 当前未运行，配置文件已更新"
    return 0
}

# ── 模块入口 ─────────────────────────────────────────────────
run_unbound() {
    log_step "========== Unbound 安装配置 =========="

    # 已安装且运行中，询问是否跳过
    if check_unbound_installed; then
        log_info "Unbound 已安装且运行中: $(unbound -V 2>&1 | head -1)"
        echo ""
        echo "  选择操作："
        echo "    1. 跳过（保持现有配置）"
        echo "    2. 重新配置（不重装，只更新配置文件）"
        echo "    3. 完整重装（重新安装+配置）"
        read -rp "  请选择 [1-3，默认1]: " unbound_choice

        case "${unbound_choice:-1}" in
            1)
                log_info "跳过 Unbound，使用现有配置"
                log_info "========== Unbound 跳过 =========="
                return 0
                ;;
            2)
                # 只更新配置
                collect_unbound_service_name
                disable_systemd_resolved
                download_root_hints
                init_trust_anchor
                generate_unbound_config
                init_unbound_control
                install_root_hints_updater
                setup_root_hints_updater
                setup_resolv_conf
                systemctl restart unbound
                sleep 2
                if systemctl is-active --quiet unbound; then
                    log_info "Unbound 重新配置成功"
                else
                    log_error "Unbound 启动失败"
                    journalctl -u unbound -n 20 --no-pager
                    exit 1
                fi
                verify_unbound
                ;;
            3)
                # 完整重装
                collect_unbound_service_name
                install_unbound
                disable_systemd_resolved
                download_root_hints
                init_trust_anchor
                generate_unbound_config
                init_unbound_control
                install_root_hints_updater
                setup_root_hints_updater
                setup_resolv_conf
                start_unbound
                verify_unbound
                ;;
        esac
    else
        # 未安装，走完整安装流程
        collect_unbound_service_name
        install_unbound
        disable_systemd_resolved
        download_root_hints
        init_trust_anchor
        generate_unbound_config
        init_unbound_control
        install_root_hints_updater
        setup_root_hints_updater
        setup_resolv_conf
        start_unbound
        verify_unbound
    fi

    log_info "========== Unbound 安装配置完成 =========="
    echo ""
    log_info "本地递归 DNS: 127.0.0.1:53"
}
