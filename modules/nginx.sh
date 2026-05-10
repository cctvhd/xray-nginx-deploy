#!/usr/bin/env bash
# ============================================================
# modules/nginx.sh
# Nginx 安装 + 配置文件生成
# ============================================================

# ── 安装 Nginx 官方最新稳定版 ────────────────────────────────
install_nginx() {
    log_step "安装 Nginx 官方最新稳定版..."

    case "$OS_ID" in
        ubuntu|debian)
            curl -fsSL https://nginx.org/keys/nginx_signing.key | \
                gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

            case "$OS_ID" in
                ubuntu)
                    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
                        > /etc/apt/sources.list.d/nginx.list
                    ;;
                debian)
                    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/debian $(lsb_release -cs) nginx" \
                        > /etc/apt/sources.list.d/nginx.list
                    ;;
            esac

            cat > /etc/apt/preferences.d/99nginx << PREF
Package: nginx
Pin: origin nginx.org
Pin-Priority: 900
PREF

            apt-get update -y >/dev/null 2>&1
            apt-get install -y nginx >/dev/null 2>&1
            ;;

        centos|rhel|rocky|almalinux)
            cat > /etc/yum.repos.d/nginx.repo << REPO
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
REPO

            dnf install -y nginx >/dev/null 2>&1
            ;;
    esac

    if ! command -v nginx &>/dev/null; then
        log_error "Nginx 安装失败"
        exit 1
    fi

    local nginx_ver
    nginx_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)
    log_info "Nginx 安装成功: v${nginx_ver}"

    local nginx_nofile="${GLOBAL_NOFILE_LIMIT:-1048576}"
    mkdir -p /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/99-xray-limits.conf << LIMITS
[Service]
LimitNOFILE=${nginx_nofile}
LIMITS
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_info "Nginx systemd nofile 限制: ${nginx_nofile}"

    systemctl enable --now nginx
}

# ── 创建目录结构 ─────────────────────────────────────────────
create_nginx_dirs() {
    log_step "创建 Nginx 目录结构..."

    local dirs=(
        /etc/nginx/conf.d
        /etc/nginx/ssl
        /var/log/nginx
        /var/www/html
        /var/cache/nginx
        /etc/nginx/certs
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chmod 755 "$dir"
    done

    for domain in "${ALL_DOMAINS[@]}"; do
        mkdir -p "/var/www/${domain}"
        chmod 755 "/var/www/${domain}"
    done

    chown -R nginx:nginx /var/log/nginx /var/cache/nginx 2>/dev/null || \
    chown -R www-data:www-data /var/log/nginx /var/cache/nginx 2>/dev/null || true

    log_info "目录结构创建完成"
}

# ── 生成 20880 陷阱端口自签证书（P3修复：让TLS握手能完成）──
generate_trap_cert() {
    log_step "生成 SNI 陷阱端口自签证书..."

    local cert_dir="/etc/nginx/certs"
    local key="${cert_dir}/trap.key"
    local crt="${cert_dir}/trap.crt"

    if [[ -f "$key" && -f "$crt" ]]; then
        log_info "陷阱证书已存在，跳过生成"
        return
    fi

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$key" \
        -out    "$crt" \
        -days   3650 \
        -subj   "/CN=localhost" \
        -quiet 2>/dev/null

    chmod 600 "$key"
    chmod 644 "$crt"
    log_info "陷阱自签证书已生成: ${cert_dir}/trap.{key,crt}"
}

# ── 生成伪装站页面 ───────────────────────────────────────────
generate_fake_site() {
    local dir="$1"
    local title="$2"

    cat > "${dir}/index.html" << HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${title}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 40px;
               background: #f5f5f5; color: #333; }
        .container { max-width: 800px; margin: 0 auto; background: white;
                     padding: 40px; border-radius: 8px;
                     box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #2c3e50; }
        p  { line-height: 1.6; color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to ${title}</h1>
        <p>This server is running nginx.</p>
        <p>If you see this page, the web server is successfully installed and working.</p>
    </div>
</body>
</html>
HTML
}

# ── 生成 cloudflare_real_ip.conf ─────────────────────────────
generate_cf_realip_conf() {
    log_step "生成 Cloudflare 真实IP配置..."

    cat > /etc/nginx/cloudflare_real_ip.conf << CONF
# ======================================================================
# Cloudflare Real IP 配置
# 自动生成，请勿手动编辑 | 更新时间: $(date '+%Y-%m-%d %H:%M:%S')
# ======================================================================

# ── 信任本地环回（stream → nginx 的本地转发必须信任）────────────────
set_real_ip_from 127.0.0.1;
set_real_ip_from ::1;

# ── 信任 Cloudflare 官方节点（IPv4）──────────────────────────────────
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;

# ── 信任 Cloudflare 官方节点（IPv6）──────────────────────────────────
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;

# ── 核心：从 Stream 层传来的 PROXY Protocol 中提取物理连接 IP ─────────
# 注意：不能用 CF-Connecting-IP，该 Header 可被任意伪造
real_ip_header    proxy_protocol;
real_ip_recursive on;

# ── 判断物理 IP 是否属于 CF 官方节点 ─────────────────────────────────
geo \$remote_addr \$from_cf {
    default 0;
    127.0.0.1        0;
    ::1              0;
    173.245.48.0/20  1;
    103.21.244.0/22  1;
    103.22.200.0/22  1;
    103.31.4.0/22    1;
    141.101.64.0/18  1;
    108.162.192.0/18 1;
    190.93.240.0/20  1;
    188.114.96.0/20  1;
    197.234.240.0/22 1;
    198.41.128.0/17  1;
    162.158.0.0/15   1;
    104.16.0.0/13    1;
    104.24.0.0/14    1;
    172.64.0.0/13    1;
    131.0.72.0/22    1;
    2400:cb00::/32   1;
    2606:4700::/32   1;
    2803:f800::/32   1;
    2405:b500::/32   1;
    2405:8100::/32   1;
    2a06:98c0::/29   1;
    2c0f:f248::/32   1;
}

# ── 健壮型真实 IP 映射 ────────────────────────────────────────────────
map "\$from_cf:\$http_cf_connecting_ip" \$final_real_ip {
    "1:"       \$remote_addr;
    "~^1:.+"   \$http_cf_connecting_ip;
    default    \$remote_addr;
}
CONF

    log_info "Cloudflare 真实IP配置生成完成"
}

# ── 安装 Cloudflare IP 自动更新脚本 ──────────────────────────
install_cf_ip_updater() {
    log_step "安装 Cloudflare IP 自动更新脚本..."

    mkdir -p /usr/local/bin /var/backups/nginx /var/log/nginx

    cat > /usr/local/bin/update_cf_ip.sh << 'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

CF_CONF="/etc/nginx/cloudflare_real_ip.conf"
TMP_CF_CONF="/tmp/real_ip.conf.tmp"
BACKUP_DIR="/var/backups/nginx"
LOG_FILE="/var/log/nginx/cloudflare_ip_update.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()        { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
error_exit() { log "${RED}ERROR: $1${NC}"; exit 1; }

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

command -v nginx >/dev/null 2>&1 || error_exit "未找到 nginx 命令"
[[ -f "$CF_CONF" ]] || error_exit "未找到目标配置文件: $CF_CONF"

log "${YELLOW}开始更新 Cloudflare IP 地址段...${NC}"

get_cloudflare_ips() {
    local retries=3 delay=5
    for i in $(seq 1 "$retries"); do
        CF_IPV4=$(curl -fsSL --connect-timeout 10 --max-time 20 https://www.cloudflare.com/ips-v4)
        CF_IPV6=$(curl -fsSL --connect-timeout 10 --max-time 20 https://www.cloudflare.com/ips-v6)
        [[ -n "${CF_IPV4:-}" && -n "${CF_IPV6:-}" ]] && {
            log "成功获取 Cloudflare IP (第 $i 次)"
            return 0
        }
        log "获取失败，重试 $i/$retries，等待 ${delay}s..."
        sleep "$delay"
    done
    error_exit "无法获取 Cloudflare IP 地址段"
}

validate_ips() {
    local v4 v6
    v4=$(echo "$CF_IPV4" | grep -v '^$' | wc -l)
    v6=$(echo "$CF_IPV6" | grep -v '^$' | wc -l)
    (( v4 >= 10 && v6 >= 5 )) || error_exit "IP 数量异常 (IPv4: $v4, IPv6: $v6)"
    log "IP 验证通过 (IPv4: $v4, IPv6: $v6)"
}

get_cloudflare_ips
validate_ips

cat > "$TMP_CF_CONF" << HEREDOC
# ======================================================================
# Cloudflare Real IP 配置
# 自动生成，请勿手动编辑 | 更新时间: $(date '+%Y-%m-%d %H:%M:%S')
# ======================================================================

set_real_ip_from 127.0.0.1;
set_real_ip_from ::1;

$(echo "$CF_IPV4" | sed 's/^/set_real_ip_from /;s/$/;/')

$(echo "$CF_IPV6" | sed 's/^/set_real_ip_from /;s/$/;/')

real_ip_header    proxy_protocol;
real_ip_recursive on;

geo \$remote_addr \$from_cf {
    default 0;
    127.0.0.1 0;
    ::1 0;
$(echo "$CF_IPV4" | sed 's/^/    /;s/$/ 1;/')
$(echo "$CF_IPV6" | sed 's/^/    /;s/$/ 1;/')
}

map "\$from_cf:\$http_cf_connecting_ip" \$final_real_ip {
    "1:"       \$remote_addr;
    "~^1:.+"   \$http_cf_connecting_ip;
    default    \$remote_addr;
}
HEREDOC

BACKUP_FILE=""
if [[ -f "$CF_CONF" ]]; then
    BACKUP_FILE="$BACKUP_DIR/real_ip.conf.$(date +%Y%m%d-%H%M%S)"
    cp "$CF_CONF" "$BACKUP_FILE"
fi

mv "$TMP_CF_CONF" "$CF_CONF"
chmod 644 "$CF_CONF"

if nginx -t >/dev/null 2>&1; then
    command -v restorecon >/dev/null 2>&1 && restorecon "$CF_CONF" || true
    if systemctl reload nginx 2>/dev/null; then
        log "${GREEN}Cloudflare IP 更新成功，Nginx 已平滑重载${NC}"
    else
        log "${YELLOW}Nginx 重载失败，但配置已更新${NC}"
    fi
else
    log "${RED}nginx -t 未通过，正在从备份恢复旧配置...${NC}"
    if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
        cp "$BACKUP_FILE" "$CF_CONF"
        log "${YELLOW}已恢复旧配置：$BACKUP_FILE${NC}"
    else
        log "${RED}无可用备份，请手动检查 $CF_CONF${NC}"
    fi
    rm -f "$TMP_CF_CONF"
    error_exit "新配置 nginx -t 未通过，已回滚"
fi

find "$BACKUP_DIR" -name "real_ip.conf.*" -type f | sort -r | tail -n +11 | xargs -r rm -f || true
log "${GREEN}Cloudflare IP 更新完成${NC}"
SCRIPT_EOF

    chmod +x /usr/local/bin/update_cf_ip.sh
    log_info "Cloudflare IP 更新脚本已安装"
}

# ── 配置 Cloudflare IP 自动更新任务 ─────────────────────────
setup_cf_ip_updater() {
    log_step "配置 Cloudflare IP 自动更新任务..."

    cat > /etc/cron.weekly/update_cf_ip << 'CRON_EOF'
#!/usr/bin/env bash
/usr/local/bin/update_cf_ip.sh
CRON_EOF
    chmod +x /etc/cron.weekly/update_cf_ip

    (crontab -l 2>/dev/null | grep -v "update_cf_ip.sh"; \
     echo "23 4 * * 0 /usr/local/bin/update_cf_ip.sh >/dev/null 2>&1") | crontab -

    log_info "已配置每周自动更新 Cloudflare IP"
}

# ── 立即执行一次 Cloudflare IP 更新 ─────────────────────────
run_cf_ip_updater() {
    log_step "刷新 Cloudflare 官方 IP 地址段..."

    if /usr/local/bin/update_cf_ip.sh; then
        log_info "Cloudflare IP 地址段已刷新"
    else
        log_warn "Cloudflare IP 自动更新失败，保留当前静态模板配置"
    fi
}

# ── 生成 ssl/common.conf ─────────────────────────────────────
generate_ssl_conf() {
    log_step "生成 SSL 通用配置..."

    cat > /etc/nginx/ssl/common.conf << 'CONF'
# ===================================================
# /etc/nginx/ssl/common.conf
# ===================================================

ssl_protocols TLSv1.3 TLSv1.2;
ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;
ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
ssl_prefer_server_ciphers on;
ssl_conf_command Curves X25519:P-256:P-384;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_early_data off;
ssl_buffer_size 4k;
ssl_stapling off;
ssl_stapling_verify off;

resolver 127.0.0.1:53 valid=300s ipv6=on;
resolver_timeout 5s;

add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
# CSP 和 CORS 已从全局移除：CSP 仅在伪装页 location 内添加，CORS 仅在 xhttp location 内添加
# 代理 location 不需要 CSP（干扰流式传输），CORS 全局设置会污染伪装页响应
CONF

    log_info "SSL 通用配置生成完成"
}

# ── 选择 nginx 动态档位 ───────────────────────────────────────
select_nginx_profile() {
    local cpu_cores="$1"
    local mem_mb="$2"

    if [[ $cpu_cores -le 1 || $mem_mb -lt 2048 ]]; then
        NGINX_PROFILE="small"
        NGINX_WORKER_CONNECTIONS=4096
        # P5修复：全局 keepalive 改小，在 location 内单独覆盖长连接
        NGINX_KEEPALIVE_TIMEOUT=65
        NGINX_KEEPALIVE_REQUESTS=5000
        NGINX_OPEN_FILE_CACHE_MAX=2000
        NGINX_OPEN_FILE_CACHE_INACTIVE=120
        NGINX_OPEN_FILE_CACHE_VALID=60
        NGINX_OPEN_FILE_CACHE_MIN_USES=2
    elif [[ $cpu_cores -le 2 || $mem_mb -lt 8192 ]]; then
        NGINX_PROFILE="medium"
        NGINX_WORKER_CONNECTIONS=8192
        NGINX_KEEPALIVE_TIMEOUT=65
        NGINX_KEEPALIVE_REQUESTS=8000
        NGINX_OPEN_FILE_CACHE_MAX=100000
        NGINX_OPEN_FILE_CACHE_INACTIVE=240
        NGINX_OPEN_FILE_CACHE_VALID=120
        NGINX_OPEN_FILE_CACHE_MIN_USES=1
    else
        NGINX_PROFILE="large"
        NGINX_WORKER_CONNECTIONS=16384
        NGINX_KEEPALIVE_TIMEOUT=65
        NGINX_KEEPALIVE_REQUESTS=10000
        NGINX_OPEN_FILE_CACHE_MAX=200000
        NGINX_OPEN_FILE_CACHE_INACTIVE=300
        NGINX_OPEN_FILE_CACHE_VALID=120
        NGINX_OPEN_FILE_CACHE_MIN_USES=1
    fi
}

# ── 获取有效内存 ─────────────────────────────────────────────
get_effective_memory_mb() {
    local mem_mb

    if [[ -n "${HW_MEM_GB:-}" ]] && [[ "${HW_MEM_GB}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v v="${HW_MEM_GB}" 'BEGIN { print int(v * 1024 + 0.5) }'
        return
    fi

    mem_mb=$(awk '/MemTotal/{print int($2/1024 + 0.5)}' /proc/meminfo)

    if (( mem_mb >= 1792 && mem_mb < 2048 )); then
        echo 2048
    elif (( mem_mb >= 3584 && mem_mb < 4096 )); then
        echo 4096
    elif (( mem_mb >= 7168 && mem_mb < 8192 )); then
        echo 8192
    else
        echo "$mem_mb"
    fi
}

# ── 生成 nginx.conf ──────────────────────────────────────────
generate_nginx_conf() {
    log_step "生成 nginx.conf..."

    local cpu_cores
    cpu_cores=$(nproc)

    local worker_processes="auto"
    [[ $cpu_cores -eq 1 ]] && worker_processes="1"

    local mem_mb mem_gb_display
    if [[ -n "${HW_MEM_GB:-}" ]] && [[ "${HW_MEM_GB}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        mem_mb=$(awk -v v="${HW_MEM_GB}" 'BEGIN { print int(v * 1024 + 0.5) }')
        mem_gb_display="${HW_MEM_GB}"
    else
        mem_mb=$(get_effective_memory_mb)
        mem_gb_display=$(awk -v m="${mem_mb}" 'BEGIN { printf "%.1f", m / 1024 }')
    fi

    select_nginx_profile "$cpu_cores" "$mem_mb"

    # 代理转发会同时占用客户端和上游连接，按 worker_connections 动态留余量。
    local worker_rlimit_nofile=$(( NGINX_WORKER_CONNECTIONS * 2 + 8192 ))

    [[ -f /etc/nginx/nginx.conf ]] && \
        cp /etc/nginx/nginx.conf \
           "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)"

    cat > /etc/nginx/nginx.conf << CONF
# ============================================================
# /etc/nginx/nginx.conf
# 自动生成 | nginx $(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1 || echo "unknown")
# CPU: ${cpu_cores}C | MEM: ${mem_gb_display}G | $(date '+%Y-%m')
# PROFILE: ${NGINX_PROFILE}
# ============================================================
user nginx;
worker_processes ${worker_processes};
# 按代理连接峰值动态设置，和 systemd LimitNOFILE/内核 fd 上限保持匹配
worker_rlimit_nofile ${worker_rlimit_nofile};
worker_cpu_affinity auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections ${NGINX_WORKER_CONNECTIONS};
    multi_accept       on;
    use                epoll;
    accept_mutex       off;
}

http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    include /etc/nginx/cloudflare_real_ip.conf;

    log_format main '\$final_real_ip - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" rt=\$request_time ut="\$upstream_response_time"';

    # P8修复：403 安全事件单独保留，其余 4xx 继续过滤
    map \$status \$loggable {
        403     1;
        ~^4     0;
        default 1;
    }

    map \$http_user_agent \$bad_ua {
        ~*zgrab               1;
        ~*masscan             1;
        ~*python-requests     1;
        ~*Go-http-client      1;
        ~*InternetMeasurement 1;
        default               0;
    }

    map "\${loggable}\${bad_ua}" \$do_log {
        "10"    1;
        default 0;
    }

    access_log /var/log/nginx/access.log main buffer=128k flush=10s if=\$do_log;

    sendfile    on;
    tcp_nopush  on;
    tcp_nodelay on;

    # P5修复：全局 keepalive 改为 65s，xhttp/grpc 在 location 内单独覆盖
    keepalive_timeout  ${NGINX_KEEPALIVE_TIMEOUT}s;
    keepalive_requests ${NGINX_KEEPALIVE_REQUESTS};

    client_max_body_size        0;
client_body_timeout 60s;  # 修复: 7200→60s 防慢速攻击；代理 location 内显式覆盖 7200s
    client_header_timeout       300s;
    # P7修复：缓冲区按实际需求收缩，避免峰值内存超物理内存
    client_body_buffer_size     128k;
    client_header_buffer_size   4k;
    large_client_header_buffers 4 16k;
send_timeout 60s;  # 修复: 7200→60s 非代理 location 不需要长超时

    server_tokens             off;
    reset_timedout_connection on;
    server_names_hash_bucket_size 128;
    server_names_hash_max_size    1024;
    types_hash_max_size           2048;

    lingering_time    60s;
    lingering_timeout 10s;

    proxy_buffering          off;
    proxy_request_buffering  off;
    proxy_max_temp_file_size 0;
    proxy_buffer_size        64k;
    proxy_buffers            8 64k;
    proxy_busy_buffers_size  128k;
    proxy_connect_timeout    15s;
    proxy_send_timeout       7200s;
    proxy_read_timeout       7200s;
    proxy_socket_keepalive   on;
    proxy_http_version       1.1;

    proxy_next_upstream         off;
    proxy_next_upstream_timeout 0;
    proxy_next_upstream_tries   0;

    open_file_cache          max=${NGINX_OPEN_FILE_CACHE_MAX} inactive=${NGINX_OPEN_FILE_CACHE_INACTIVE}s;
    open_file_cache_valid    ${NGINX_OPEN_FILE_CACHE_VALID}s;
    open_file_cache_min_uses ${NGINX_OPEN_FILE_CACHE_MIN_USES};
    open_file_cache_errors   on;

    gzip off;

    limit_req_zone  \$final_real_ip zone=websocket:20m rate=200r/s;
    limit_req_zone  \$final_real_ip zone=health:1m    rate=10r/s;
    limit_conn_zone \$final_real_ip zone=conn_limit:20m;

    include /etc/nginx/ssl/*.conf;
    include /etc/nginx/conf.d/*.conf;
}

# ============================================================
# Stream 块 - SNI 分流
# ============================================================
stream {
    log_format stream_basic '\$remote_addr [\$time_local] '
                             '\$protocol \$status \$bytes_sent \$bytes_received '
                             '\$session_time "\$ssl_preread_server_name"';

    map \$ssl_preread_server_name \$stream_loggable {
        ""      0;
        default 1;
    }

    access_log /var/log/nginx/stream.log stream_basic if=\$stream_loggable;

    map \$ssl_preread_server_name \$backend {
$(generate_sni_map)
        # -- SNI 陷阱兜底 -----------------------------------------
        default               127.0.0.1:20880;
    }

    server {
        listen 443 fastopen=256;
        listen [::]:443 fastopen=256;
        ssl_preread           on;
        proxy_pass            \$backend;
        proxy_connect_timeout 10s;
        proxy_timeout         7200s;
        proxy_protocol        on;
    }

    # -- 中间层: 消费 proxy_protocol 后转发给 sing-box ----------
    server {
        listen 127.0.0.1:18443 proxy_protocol;
        proxy_pass            127.0.0.1:8443;
        proxy_connect_timeout 10s;
        proxy_timeout         7200s;
    }
}
CONF

    log_info "nginx.conf 生成完成"
}

# ── 生成 SNI 路由映射 ────────────────────────────────────────
# P4修复：Reality serverNames 里的所有域名都加进 stream map 指向 9443
generate_sni_map() {
    local had_output=0
    local sn
    local -A seen_sni=()

    # Reality 自有域名
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        [[ $had_output -eq 0 ]] && echo "        # -- Reality（自有域名 + 公共 serverNames 全部路由到 9443）--"
        echo "        ${REALITY_DOMAIN}     127.0.0.1:9443;"
        seen_sni["${REALITY_DOMAIN}"]=1
        had_output=1
    fi

    # Reality 所有 serverNames（包括公共域名）全部指向 9443
    # 确保客户端用任意 serverName 连接时都能命中正确后端
    if [[ -n "${REALITY_SERVER_NAMES:-}" ]]; then
        [[ $had_output -eq 0 ]] && echo "        # -- Reality serverNames 全部路由到 9443 ---------------"
        for sn in "${REALITY_SERVER_NAMES[@]}"; do
            [[ -n "$sn" ]] || continue
            [[ -n "${seen_sni[$sn]:-}" ]] && continue
            echo "        ${sn}     127.0.0.1:9443;"
            seen_sni["$sn"]=1
        done
        had_output=1
    fi

    if [[ -n "${XHTTP_DOMAIN:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- xhttp CDN 回源 -----------------------------------"
        echo "        ${XHTTP_DOMAIN}        127.0.0.1:20443;"
        had_output=1
    fi

    if [[ -n "${GRPC_DOMAIN:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- gRPC CDN 回源 ------------------------------------"
        echo "        ${GRPC_DOMAIN}         127.0.0.1:20445;"
        had_output=1
    fi

    if [[ -n "${ANYTLS_DOMAIN:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- AnyTLS -> nginx 中间层 -> sing-box ---------------"
        echo "        ${ANYTLS_DOMAIN}       127.0.0.1:18443;"
    fi
}

# ── 生成 00-upstreams.conf ───────────────────────────────────
generate_upstreams_conf() {
    log_step "生成 upstream 配置..."

    cat > /etc/nginx/conf.d/00-upstreams.conf << 'CONF'
# ============================================================
# /etc/nginx/conf.d/00-upstreams.conf
# ============================================================
upstream vless_xhttp_backend {
    server 127.0.0.1:8001 max_fails=0 fail_timeout=30s;
    keepalive          256;
    keepalive_requests 10000;
# 与 Xray xhttp hMaxReusableSecs(1800-3600s) 形成梯度
# nginx(300s) < Xray 上限(3600s)，确保 nginx 先回收，避免持有对 Xray 已关闭的连接
keepalive_timeout 300s;
}

upstream vless_grpc_backend {
    server 127.0.0.1:8002 max_fails=0 fail_timeout=30s;
    keepalive          32;
    keepalive_requests 1000;
    # 修复3：与 xray grpc idle_timeout(80s) 形成梯度
    # nginx(90s) > xray(80s) > 客户端(60s)，避免连接被提前回收
    keepalive_timeout  90s;
}
CONF

    log_info "upstream 配置生成完成"
}

# ── 生成 fallback.conf ───────────────────────────────────────
# P1修复：xhttp location 路径使用 ${XHTTP_PATH} 变量（与 xray 保持一致）
generate_fallback_conf() {
    log_step "生成 fallback 配置..."

    cat > /etc/nginx/conf.d/fallback.conf << CONF
# ============================================================
# /etc/nginx/conf.d/fallback.conf
# Reality Fallback 入口
# P1修复：xhttp path 与 xray 保持一致（均使用 XHTTP_PATH 变量）
# 注意：Xray Reality fallback xver=0，不发送 PROXY header，
# 因此 listen 不加 proxy_protocol
# ============================================================
server {
listen 127.0.0.1:10080;
    server_name   _;
    access_log    off;
    server_tokens off;
    gzip          on;
    gzip_vary     on;
    gzip_comp_level 2;
    gzip_min_length 1000;
    gzip_types    text/plain text/css application/json application/javascript
                  text/xml application/xml application/xml+rss text/javascript
                  image/svg+xml;

    # P1修复：路径与 xray xhttpSettings.path 保持一致
    location ${XHTTP_PATH} {
        gzip off;
        proxy_pass              http://vless_xhttp_backend;
        proxy_http_version      1.1;
        proxy_set_header        Connection "";
        proxy_set_header        Host \$host;
 # fallback 经 xver=0 转发，无 proxy_protocol，使用 $final_real_ip 获取真实 IP
        proxy_set_header        X-Real-IP \$final_real_ip;
        proxy_set_header        X-Forwarded-For \$final_real_ip;
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_cache             off;
        proxy_next_upstream         off;
        proxy_next_upstream_timeout 0;
        proxy_next_upstream_tries   0;
        client_max_body_size    0;
        proxy_connect_timeout   15s;
        proxy_send_timeout      7200s;
        proxy_read_timeout      7200s;
        # P5修复：fallback 长连接单独覆盖
        keepalive_timeout       7200s;
    }

    location /grpc.Service {
        gzip off;
        grpc_pass            grpc://vless_grpc_backend;
        grpc_set_header      Host \$host;
        grpc_next_upstream   off;
        grpc_connect_timeout 15s;
        grpc_send_timeout    300s;
        grpc_read_timeout    300s;
        # 修复4：与 servers.conf gRPC location 保持一致
        grpc_buffer_size     64k;
        grpc_socket_keepalive on;
        client_max_body_size 0;
        client_body_timeout 7200s;
        send_timeout 7200s;
    }

    location / {
        root      /var/www/html;
        index     index.html;
        try_files \$uri \$uri/ /index.html;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Cache-Control "public, max-age=3600" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
    }
}
CONF

    log_info "fallback 配置生成完成"
}

# ── 生成 servers.conf ────────────────────────────────────────
generate_servers_conf() {
    log_step "生成 servers.conf..."

    > /etc/nginx/conf.d/servers.conf

    get_root_domain() {
        echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
    }

    # xhttp CDN server 块
    if [[ -n "${XHTTP_DOMAIN:-}" ]]; then
        local xhttp_root
        xhttp_root=$(get_root_domain "${XHTTP_DOMAIN}")
        local cert_path="/etc/letsencrypt/live/${xhttp_root}"

        cat >> /etc/nginx/conf.d/servers.conf << CONF

# ===================================================================
# CDN ${XHTTP_DOMAIN} — xhttp
# P1修复：location 路径与 xray xhttpSettings.path 保持一致
# ===================================================================
server {
    listen 127.0.0.1:20443 ssl proxy_protocol;
    http2  on;
    server_name ${XHTTP_DOMAIN};
    gzip   on;
    gzip_vary       on;
    gzip_comp_level 2;
    gzip_min_length 1000;
    gzip_types      text/plain text/css application/json application/javascript
                    text/xml application/xml application/xml+rss text/javascript
                    image/svg+xml;

    ssl_certificate     ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;

    access_log /var/log/nginx/${XHTTP_DOMAIN}.log    main buffer=32k flush=5m;
    error_log  /var/log/nginx/${XHTTP_DOMAIN}.err.log warn;

    resolver 127.0.0.1 valid=300s;
    resolver_timeout 5s;
    server_tokens off;

    if (\$from_cf = 0) {
        rewrite ^ /_fake last;
    }

    # P1修复：路径与 xray xhttpSettings.path 保持一致
    location ${XHTTP_PATH} {
        gzip       off;
        access_log off;
        limit_req  zone=websocket burst=100 nodelay;
        limit_conn conn_limit 200;

        proxy_pass              http://vless_xhttp_backend;
        proxy_http_version      1.1;
        proxy_set_header        Connection "";
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$final_real_ip;
        proxy_set_header        X-Forwarded-For \$final_real_ip;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;

 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header X-Accel-Buffering "no" always;
 add_header Access-Control-Allow-Origin "*" always;
 add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
 add_header Access-Control-Allow-Headers "*" always;
        proxy_hide_header Via;
        proxy_hide_header X-Cache;
        proxy_hide_header X-Cache-Status;

        proxy_connect_timeout       15s;
        proxy_send_timeout          7200s;
        proxy_read_timeout          7200s;
        proxy_buffering             off;
        proxy_request_buffering     off;
        chunked_transfer_encoding   on;
        proxy_cache                 off;
        proxy_socket_keepalive      on;
        proxy_redirect              off;
        proxy_next_upstream         off;
        proxy_next_upstream_timeout 0;
        proxy_next_upstream_tries   0;
        client_max_body_size        0;
        client_body_timeout         7200s;
        send_timeout                7200s;
        # P5修复：长连接在 location 内单独覆盖
        keepalive_timeout           7200s;
        keepalive_requests          5000;
    }

    location = /health {
        limit_req  zone=health burst=5 nodelay;
        access_log off;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Content-Type  "text/plain" always;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        return 200 "healthy\n";
    }

    location /_fake {
        internal;
        root      /var/www/html;
        index     index.html;
        try_files /index.html =200;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Cache-Control "public, max-age=3600" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
        access_log off;
    }

    location / {
        root  /var/www/html;
        index index.html;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires    30d;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }
        try_files \$uri \$uri/ /index.html;
    }
}
CONF
    fi

    # gRPC CDN server 块
    if [[ -n "${GRPC_DOMAIN:-}" ]]; then
        local grpc_root
        grpc_root=$(get_root_domain "${GRPC_DOMAIN}")
        local cert_path="/etc/letsencrypt/live/${grpc_root}"

        cat >> /etc/nginx/conf.d/servers.conf << CONF

# ===================================================================
# CDN ${GRPC_DOMAIN} — gRPC
# ===================================================================
server {
    listen 127.0.0.1:20445 ssl proxy_protocol;
    http2  on;
    server_name ${GRPC_DOMAIN};
    gzip   on;
    gzip_vary       on;
    gzip_comp_level 2;
    gzip_min_length 1000;
    gzip_types      text/plain text/css application/json application/javascript
                    text/xml application/xml application/xml+rss text/javascript
                    image/svg+xml;

    ssl_certificate     ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;

    access_log /var/log/nginx/${GRPC_DOMAIN}.log    main buffer=32k flush=5m;
    error_log  /var/log/nginx/${GRPC_DOMAIN}.err.log warn;

    resolver 127.0.0.1 valid=300s;
    resolver_timeout 5s;
    server_tokens off;

    if (\$from_cf = 0) {
        rewrite ^ /_fake last;
    }

    location /grpc.Service {
        gzip       off;
        access_log off;
        limit_req  zone=websocket burst=100 nodelay;
        limit_conn conn_limit 200;

        grpc_pass             grpc://vless_grpc_backend;
        grpc_set_header       Host \$host;
        grpc_set_header       X-Real-IP \$final_real_ip;
        grpc_set_header       X-Forwarded-For \$final_real_ip;
        grpc_set_header       X-Forwarded-Proto \$scheme;
        grpc_set_header       Te "trailers";
        grpc_set_header       Content-Type "application/grpc";

        grpc_connect_timeout  15s;
        grpc_send_timeout     300s;
        grpc_read_timeout     300s;
        grpc_socket_keepalive on;
        grpc_next_upstream    off;
        # 修复4：与 fallback.conf gRPC location 保持一致
        grpc_buffer_size      64k;

        client_max_body_size  0;
        client_body_timeout   7200s;
        send_timeout          7200s;
    }

    location = /health {
        limit_req  zone=health burst=5 nodelay;
        access_log off;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Content-Type  "text/plain" always;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        return 200 "healthy\n";
    }

    location /_fake {
        internal;
        root      /var/www/${GRPC_DOMAIN};
        index     index.html;
        try_files /index.html =200;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Cache-Control "public, max-age=3600" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
        access_log off;
    }

    location / {
        root  /var/www/${GRPC_DOMAIN};
        index index.html;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires    30d;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }
        try_files \$uri \$uri/ /index.html;
    }
}
CONF
    fi

    # 兜底 server 块
    cat >> /etc/nginx/conf.d/servers.conf << 'CONF'

# ===================================================================
# 兜底：SNI 不匹配拒绝握手
# ===================================================================
server {
    listen 127.0.0.1:20443 ssl default_server proxy_protocol;
    ssl_reject_handshake on;
}

server {
    listen 127.0.0.1:20445 ssl default_server proxy_protocol;
    ssl_reject_handshake on;
}
CONF

    # P3修复：20880 加自签证书完成 TLS 握手，返回伪装页而非 RST
    cat >> /etc/nginx/conf.d/servers.conf << 'CONF'

# ===================================================================
# SNI 陷阱伪装站（20880）
# P3修复：加自签证书让扫描器能完成 TLS 握手，返回正常伪装页
#         而非直接 RST（更难被识别为代理节点）
# ===================================================================
server {
    listen 127.0.0.1:20880 ssl proxy_protocol;
    ssl_certificate     /etc/nginx/certs/trap.crt;
    ssl_certificate_key /etc/nginx/certs/trap.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    server_name         _;
    server_tokens       off;
        client_header_timeout 10s;
        send_timeout 10s;
        keepalive_timeout 10s;
    access_log          off;
    gzip                on;
    gzip_vary           on;
    gzip_comp_level     2;
    gzip_min_length     1000;
    gzip_types          text/plain text/css application/json application/javascript
                        text/xml application/xml application/xml+rss text/javascript
                        image/svg+xml;
    root                /var/www/html;
    index               index.html;

    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control          "public, max-age=3600" always;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
    }
}
CONF

    # HTTP 重定向
    local all_domain_names=""
    for domain in "${ALL_DOMAINS[@]}"; do
        all_domain_names+=" ${domain}"
    done

    cat >> /etc/nginx/conf.d/servers.conf << CONF

# ===================================================================
# HTTP → HTTPS 重定向 & ACME 验证
# ===================================================================
server {
    listen 80;
    listen [::]:80;
    server_name ${all_domain_names};

    location ^~ /.well-known/acme-challenge/ {
        root          /var/www/html;
        try_files     \$uri =404;
        access_log    off;
        log_not_found off;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
CONF

    log_info "servers.conf 生成完成"
}

# ── 验证并重启 Nginx ─────────────────────────────────────────
reload_nginx() {
    log_step "验证 Nginx 配置..."
    if nginx -t 2>&1; then
        systemctl restart nginx
        log_info "Nginx 配置验证通过并已重启，资源限制已生效"
    else
        log_error "Nginx 配置验证失败，请检查配置文件"
        nginx -t
        exit 1
    fi
}

# ── 模块入口 ─────────────────────────────────────────────────
run_nginx() {
    log_step "========== Nginx 安装配置 =========="
    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    generate_fallback_conf
    generate_servers_conf
    generate_trap_cert          # P3：生成陷阱端口自签证书
    generate_nginx_conf
    reload_nginx
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater
    log_info "========== Nginx 安装配置完成 =========="
}
