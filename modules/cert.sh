#!/usr/bin/env bash
# ============================================================
# modules/cert.sh
# Cloudflare DNS 证书申请模块
# ============================================================

# ── 安装 Certbot + CF 插件 ───────────────────────────────────
install_certbot() {
    log_step "安装 Certbot + Cloudflare 插件..."

    case "$OS_ID" in
        ubuntu|debian)
            $PKG_INSTALL snapd >/dev/null 2>&1
            systemctl enable --now snapd 2>/dev/null || true
            sleep 3
            snap install --classic certbot 2>/dev/null || \
            $PKG_INSTALL certbot python3-certbot-dns-cloudflare -y >/dev/null 2>&1
            # 优先用 pip 安装 CF 插件确保版本匹配
            $PKG_INSTALL python3-pip -y >/dev/null 2>&1
            pip3 install certbot-dns-cloudflare >/dev/null 2>&1 || true
            ;;
        centos|rhel|rocky|almalinux)
            $PKG_INSTALL certbot python3-certbot-dns-cloudflare -y >/dev/null 2>&1 || {
                $PKG_INSTALL python3-pip -y >/dev/null 2>&1
                pip3 install certbot certbot-dns-cloudflare >/dev/null 2>&1
            }
            ;;
    esac

    log_info "Certbot 安装完成: $(certbot --version 2>&1)"
}

# ── 配置 Cloudflare 账号 ─────────────────────────────────────
setup_cf_accounts() {
    echo ""
    log_step "配置 Cloudflare 账号"
    echo ""

    read -rp "你有几个 Cloudflare 账号？[默认1]: " CF_ACCOUNT_COUNT
    CF_ACCOUNT_COUNT=${CF_ACCOUNT_COUNT:-1}

    mkdir -p /etc/cloudflare
    chmod 700 /etc/cloudflare

    CF_INI_FILES=()

    for i in $(seq 1 "$CF_ACCOUNT_COUNT"); do
        echo ""
        log_info "── 配置第 ${i} 个 CF 账号 ──"
        read -rp "  账号 ${i} 的 CF API Token: " cf_token

        local ini_file="/etc/cloudflare/cf_account_${i}.ini"
        cat > "$ini_file" << INI
# Cloudflare API Token - 账号 ${i}
dns_cloudflare_api_token = ${cf_token}
INI
        chmod 600 "$ini_file"
        CF_INI_FILES+=("$ini_file")
        log_info "账号 ${i} 配置已保存: $ini_file"
    done
}

# ── 收集域名信息 ─────────────────────────────────────────────
collect_domains() {
    echo ""
    log_step "配置域名信息"
    echo ""

    # 存储所有域名信息
    declare -g -A DOMAIN_CF_ACCOUNT   # 域名 -> CF账号序号
    declare -g -A DOMAIN_TYPE         # 域名 -> cdn/direct
    declare -g -A DOMAIN_USAGE        # 域名 -> xhttp/grpc/reality/anytls
    declare -g -a ALL_DOMAINS         # 所有域名列表
    declare -g -a CDN_DOMAINS         # CDN域名列表
    declare -g -a DIRECT_DOMAINS      # 直连域名列表
    declare -g REALITY_DOMAIN         # Reality域名
    declare -g XHTTP_DOMAIN           # xhttp域名
    declare -g GRPC_DOMAIN            # gRPC域名
    declare -g ANYTLS_DOMAIN          # AnyTLS域名

    echo "域名用途说明："
    echo "  1. xhttp-CDN   - VLESS+XHTTP 经 CF CDN 中转"
    echo "  2. gRPC-CDN    - VLESS+gRPC 经 CF CDN 中转"
    echo "  3. Reality     - VLESS+Reality 直连（需要伪装域名）"
    echo "  4. AnyTLS      - Sing-Box AnyTLS 直连"
    echo ""

    read -rp "共需要配置几个域名？: " domain_count

    for i in $(seq 1 "$domain_count"); do
        echo ""
        log_info "── 配置第 ${i} 个域名 ──"
        read -rp "  域名: " domain
        domain="${domain,,}"

        echo "  用途选择："
        echo "    1. xhttp-CDN（开启CF代理）"
        echo "    2. gRPC-CDN（开启CF代理）"
        echo "    3. Reality 伪装域名（直连，关闭CF代理）"
        echo "    4. AnyTLS（直连，关闭CF代理）"
        read -rp "  请选择 [1-4]: " usage_choice

        case "$usage_choice" in
            1)
                DOMAIN_TYPE["$domain"]="cdn"
                DOMAIN_USAGE["$domain"]="xhttp"
                XHTTP_DOMAIN="$domain"
                CDN_DOMAINS+=("$domain")
                ;;
            2)
                DOMAIN_TYPE["$domain"]="cdn"
                DOMAIN_USAGE["$domain"]="grpc"
                GRPC_DOMAIN="$domain"
                CDN_DOMAINS+=("$domain")
                ;;
            3)
                DOMAIN_TYPE["$domain"]="direct"
                DOMAIN_USAGE["$domain"]="reality"
                REALITY_DOMAIN="$domain"
                DIRECT_DOMAINS+=("$domain")
                ;;
            4)
                DOMAIN_TYPE["$domain"]="direct"
                DOMAIN_USAGE["$domain"]="anytls"
                ANYTLS_DOMAIN="$domain"
                DIRECT_DOMAINS+=("$domain")
                ;;
        esac

        if [[ "${CF_ACCOUNT_COUNT}" -gt 1 ]]; then
            read -rp "  使用第几个CF账号？[1-${CF_ACCOUNT_COUNT}]: " cf_idx
            DOMAIN_CF_ACCOUNT["$domain"]="${cf_idx:-1}"
        else
            DOMAIN_CF_ACCOUNT["$domain"]="1"
        fi

        ALL_DOMAINS+=("$domain")
        log_info "域名 $domain 配置完成（${DOMAIN_USAGE[$domain]}/${DOMAIN_TYPE[$domain]}）"
    done

    # 汇总显示
    echo ""
    log_info "域名配置汇总："
    for domain in "${ALL_DOMAINS[@]}"; do
        echo "  $domain → ${DOMAIN_USAGE[$domain]} / ${DOMAIN_TYPE[$domain]} / CF账号${DOMAIN_CF_ACCOUNT[$domain]}"
    done
    echo ""
    read -rp "确认以上配置？[Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        log_warn "重新配置域名..."
        collect_domains
    fi
}

# ── 申请证书 ─────────────────────────────────────────────────
request_certificates() {
    log_step "开始申请 SSL 证书..."

    mkdir -p /etc/letsencrypt

    for domain in "${ALL_DOMAINS[@]}"; do
        local cf_idx="${DOMAIN_CF_ACCOUNT[$domain]}"
        local ini_file="${CF_INI_FILES[$((cf_idx-1))]}"

        log_info "申请证书: $domain (使用 CF账号${cf_idx})"

        # 提取根域名用于通配符证书
        local root_domain
        root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

        # 检查证书是否已存在
        if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
            log_warn "证书已存在: $domain 跳过申请"
            continue
        fi

        # 申请通配符证书
        certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$ini_file" \
            --dns-cloudflare-propagation-seconds 30 \
            -d "$domain" \
            -d "*.${root_domain}" \
            --email "admin@${root_domain}" \
            --agree-tos \
            --non-interactive \
            --expand 2>&1 | while IFS= read -r line; do
                echo "  $line"
            done

        if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
            log_info "证书申请成功: $domain"
        else
            # 尝试申请单域名证书
            log_warn "通配符证书申请失败，尝试单域名证书..."
            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials "$ini_file" \
                --dns-cloudflare-propagation-seconds 30 \
                -d "$domain" \
                --email "admin@${root_domain}" \
                --agree-tos \
                --non-interactive 2>&1 | while IFS= read -r line; do
                    echo "  $line"
                done
        fi
    done

    log_info "所有证书申请完成"
}

# ── 配置自动续期 ─────────────────────────────────────────────
setup_auto_renew() {
    log_step "配置证书自动续期..."

    # 续期后重载 nginx
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/bin/bash
systemctl reload nginx 2>/dev/null || true
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    # 添加 cron 任务
    (crontab -l 2>/dev/null | grep -v certbot; \
     echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'") \
     | crontab -

    log_info "自动续期配置完成（每天凌晨3点检查）"
}

# ── 模块入口 ─────────────────────────────────────────────────
run_cert() {
    log_step "========== SSL 证书申请 =========="
    install_certbot
    setup_cf_accounts
    collect_domains
    request_certificates
    setup_auto_renew
    log_info "========== SSL 证书申请完成 =========="
}
