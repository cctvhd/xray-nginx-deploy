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
# 三路逻辑：
#   CF 节点 + 有 CF-Connecting-IP Header → 访客真实 IP
#   CF 节点 + 无 CF-Connecting-IP Header → CF 物理 IP（异常情况兜底）
#   非 CF 节点（直连）                   → 物理连接 IP
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

# ── 信任本地环回（stream → nginx 的本地转发必须信任）────────────────
set_real_ip_from 127.0.0.1;
set_real_ip_from ::1;

# ── 信任 Cloudflare 官方节点（IPv4）──────────────────────────────────
$(echo "$CF_IPV4" | sed 's/^/set_real_ip_from /;s/$/;/')

# ── 信任 Cloudflare 官方节点（IPv6）──────────────────────────────────
$(echo "$CF_IPV6" | sed 's/^/set_real_ip_from /;s/$/;/')

# ── 核心：从 Stream 层传来的 PROXY Protocol 中提取物理连接 IP ─────────
# 注意：不能用 CF-Connecting-IP，该 Header 可被任意伪造
real_ip_header    proxy_protocol;
real_ip_recursive on;

# ── 判断物理 IP 是否属于 CF 官方节点 ─────────────────────────────────
geo \$remote_addr \$from_cf {
    default 0;
    127.0.0.1 0;
    ::1 0;
$(echo "$CF_IPV4" | sed 's/^/    /;s/$/ 1;/')
$(echo "$CF_IPV6" | sed 's/^/    /;s/$/ 1;/')
}

# ── 健壮型真实 IP 映射 ────────────────────────────────────────────────
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
    error_exit "新配置 nginx -t 未通过，已回滚，现有配置保持不变"
fi

find "$BACKUP_DIR" -name "real_ip.conf.*" -type f | sort -r | tail -n +11 | xargs -r rm -f || true
log "${GREEN}Cloudflare IP 更新完成${NC}"
SCRIPT_EOF

    chmod +x /usr/local/bin/update_cf_ip.sh
    log_info "Cloudflare IP 更新脚本已安装: /usr/local/bin/update_cf_ip.sh"
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

# ========= TLS 版本 =========
ssl_protocols TLSv1.3 TLSv1.2;

# ========= TLS 1.3 密码套件 =========
ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256;

# ========= TLS 1.2 密码套件 =========
ssl_ciphers HIGH:!aNULL:!MD5:!3DES:!RC4:!DES:!EXPORT:!LOW:!PSK;

# ECDH 曲线
ssl_ecdh_curve X25519:prime256v1;

# 会话缓存
ssl_session_cache shared:SSL:50m;
ssl_session_timeout 1d;
ssl_session_tickets off;

# 禁止 0-RTT
ssl_early_data off;

# TLS 缓冲优化
ssl_buffer_size 4k;

# ========= 取消 OCSP（LE 已停服务）=========
ssl_stapling off;
ssl_stapling_verify off;

# DNS 解析器
resolver 127.0.0.1:53 valid=300s ipv6=on;
resolver_timeout 5s;

# ========= 安全响应头 =========
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;

# CSP - 静态页面收紧版
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;

# 跨域（XHTTP CDN 需要）
add_header Access-Control-Allow-Origin "*" always;
add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
add_header Access-Control-Allow-Headers "*" always;
CONF

    log_info "SSL 通用配置生成完成"
}

# ── 选择 nginx 动态档位 ───────────────────────────────────────
select_nginx_profile() {
    local cpu_cores="$1"
    local mem_mb="$2"

    # 小鸡：1C 或 < 2GB，优先保守稳定
    # 中配：2C/2-8GB，兼顾连接容量和资源占用
    # 大机：> 2C 且 >= 8GB，适当拉高长连接与文件缓存
    if [[ $cpu_cores -le 1 || $mem_mb -lt 2048 ]]; then
        NGINX_PROFILE="small"
        NGINX_WORKER_CONNECTIONS=4096
        NGINX_KEEPALIVE_TIMEOUT=1800
        NGINX_KEEPALIVE_REQUESTS=5000
        NGINX_OPEN_FILE_CACHE_MAX=20000
        NGINX_OPEN_FILE_CACHE_INACTIVE=120
        NGINX_OPEN_FILE_CACHE_VALID=60
        NGINX_OPEN_FILE_CACHE_MIN_USES=2
    elif [[ $cpu_cores -le 2 || $mem_mb -lt 8192 ]]; then
        NGINX_PROFILE="medium"
        NGINX_WORKER_CONNECTIONS=8192
        NGINX_KEEPALIVE_TIMEOUT=3600
        NGINX_KEEPALIVE_REQUESTS=8000
        NGINX_OPEN_FILE_CACHE_MAX=100000
        NGINX_OPEN_FILE_CACHE_INACTIVE=240
        NGINX_OPEN_FILE_CACHE_VALID=120
        NGINX_OPEN_FILE_CACHE_MIN_USES=1
    else
        NGINX_PROFILE="large"
        NGINX_WORKER_CONNECTIONS=16384
        NGINX_KEEPALIVE_TIMEOUT=7200
        NGINX_KEEPALIVE_REQUESTS=10000
        NGINX_OPEN_FILE_CACHE_MAX=200000
        NGINX_OPEN_FILE_CACHE_INACTIVE=300
        NGINX_OPEN_FILE_CACHE_VALID=120
        NGINX_OPEN_FILE_CACHE_MIN_USES=1
    fi
}

# ── 生成 nginx.conf ──────────────────────────────────────────
generate_nginx_conf() {
    log_step "生成 nginx.conf..."

    local cpu_cores
    cpu_cores=$(nproc)

    local worker_processes="auto"
    [[ $cpu_cores -eq 1 ]] && worker_processes="1"

    local mem_mb
    local mem_gb_display
    if [[ -n "${HW_MEM_GB:-}" ]] && [[ "${HW_MEM_GB}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        mem_mb=$(awk -v v="${HW_MEM_GB}" 'BEGIN { print int(v * 1024 + 0.5) }')
        mem_gb_display="${HW_MEM_GB}"
    else
        mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
        mem_gb_display=$(awk -v m="${mem_mb}" 'BEGIN { print int((m + 1023) / 1024) }')
    fi

    select_nginx_profile "$cpu_cores" "$mem_mb"

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
worker_rlimit_nofile 200000;
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

    map \$status \$loggable {
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

    keepalive_timeout  ${NGINX_KEEPALIVE_TIMEOUT}s;
    keepalive_requests ${NGINX_KEEPALIVE_REQUESTS};

    client_max_body_size        0;
    client_body_timeout         7200s;
    client_header_timeout       300s;
    client_body_buffer_size     1m;
    client_header_buffer_size   8k;
    large_client_header_buffers 8 32k;
    send_timeout                7200s;

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

    limit_req_zone  \$final_real_ip zone=websocket:20m rate=2000r/s;
    limit_req_zone  \$final_real_ip zone=api:20m      rate=3000r/s;
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
generate_sni_map() {
    local had_output=0
    local sn
    local -A seen_reality_sni=()

    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        [[ $had_output -eq 0 ]] && echo "        # -- Reality（自有域名 + 公共 serverNames）------------"
        echo "        ${REALITY_DOMAIN}     127.0.0.1:9443;"
        seen_reality_sni["${REALITY_DOMAIN}"]=1
        had_output=1
    fi
    if [[ -n "${REALITY_SERVER_NAMES:-}" ]]; then
        [[ $had_output -eq 0 ]] && echo "        # -- Reality（自有域名 + 公共 serverNames）------------"
        for sn in "${REALITY_SERVER_NAMES[@]}"; do
            [[ -n "$sn" ]] || continue
            [[ -n "${seen_reality_sni[$sn]:-}" ]] && continue
            echo "        ${sn}     127.0.0.1:9443;"
            seen_reality_sni["$sn"]=1
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
        echo "        # -- AnyTLS -> nginx 中间层 -> sing-box --------------"
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
    server 127.0.0.1:8001 max_fails=3 fail_timeout=30s;
    keepalive          256;
    keepalive_requests 10000;
    keepalive_timeout  7200s;
}

upstream vless_grpc_backend {
    server 127.0.0.1:8002 max_fails=3 fail_timeout=30s;
    keepalive          32;
    keepalive_requests 1000;
    keepalive_timeout  40s;
}
CONF

    log_info "upstream 配置生成完成"
}

# ── 生成 fallback.conf ───────────────────────────────────────
generate_fallback_conf() {
    log_step "生成 fallback 配置..."

    cat > /etc/nginx/conf.d/fallback.conf << CONF
# ============================================================
# /etc/nginx/conf.d/fallback.conf
# Reality Fallback 入口
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

    location ${XHTTP_PATH} {
        gzip off;
        proxy_pass              http://vless_xhttp_backend;
        proxy_http_version      1.1;
        proxy_set_header        Connection "";
        proxy_set_header        Host \$host;
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
    }

    location /grpc.Service {
        gzip off;
        grpc_pass            grpc://vless_grpc_backend;
        grpc_set_header      Host \$host;
        grpc_next_upstream   off;
        grpc_connect_timeout 15s;
        grpc_send_timeout    7200s;
        grpc_read_timeout    7200s;
    }

    location / {
        root      /var/www/html;
        index     index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "public, max-age=3600" always;
    }
}
CONF

    log_info "fallback 配置生成完成"
}

# ── 生成 servers.conf ────────────────────────────────────────
# ── 生成 servers.conf ────────────────────────────────────────
generate_servers_conf() {
    log_step "生成 servers.conf..."

    # 每次重新生成，先清空
    > /etc/nginx/conf.d/servers.conf

    # 提取根域名函数
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
        proxy_set_header        Cache-Control "no-cache, no-store, private";

        add_header X-Accel-Buffering "no" always;
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
        keepalive_timeout           7200s;
        keepalive_requests          5000;
    }

    location = /health {
        limit_req  zone=health burst=5 nodelay;
        access_log off;
        add_header Content-Type  "text/plain" always;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        return 200 "healthy\n";
    }

    location /_fake {
        internal;
        root      /var/www/html;
        index     index.html;
        try_files /index.html =200;
        add_header Cache-Control "public, max-age=3600" always;
        access_log off;
    }

    location / {
        root  /var/www/html;
        index index.html;
        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires    30d;
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
        grpc_send_timeout     7200s;
        grpc_read_timeout     7200s;
        grpc_socket_keepalive on;
        grpc_next_upstream    off;

        client_max_body_size  0;
        client_body_timeout   7200s;
        send_timeout          7200s;
    }

    location = /health {
        limit_req  zone=health burst=5 nodelay;
        access_log off;
        add_header Content-Type  "text/plain" always;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        return 200 "healthy\n";
    }

    location /_fake {
        internal;
        root      /var/www/${GRPC_DOMAIN};
        index     index.html;
        try_files /index.html =200;
        add_header Cache-Control "public, max-age=3600" always;
        access_log off;
    }

    location / {
        root  /var/www/${GRPC_DOMAIN};
        index index.html;
        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires    30d;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }
        try_files \$uri \$uri/ /index.html;
    }
}
CONF
    fi

    # 兜底 + SNI陷阱
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

# ===================================================================
# SNI 陷阱兜底伪装站
# ===================================================================
server {
    listen 127.0.0.1:20880 proxy_protocol;
    server_name   _;
    server_tokens off;
    access_log    off;
    gzip          on;
    gzip_vary     on;
    gzip_comp_level 2;
    gzip_min_length 1000;
    gzip_types    text/plain text/css application/json application/javascript
                  text/xml application/xml application/xml+rss text/javascript
                  image/svg+xml;
    root          /var/www/html;
    index         index.html;

    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control          "public, max-age=3600" always;
        add_header X-Content-Type-Options "nosniff" always;
    }
}
CONF

    # HTTP 重定向（域名列表动态生成）
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

# ── 验证并重载 Nginx ─────────────────────────────────────────
reload_nginx() {
    log_step "验证 Nginx 配置..."
    if nginx -t 2>&1; then
        systemctl reload nginx
        log_info "Nginx 配置验证通过并已重载"
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
    generate_nginx_conf
    reload_nginx
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater
    log_info "========== Nginx 安装配置完成 =========="
}
