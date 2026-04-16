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
            $PKG_INSTALL python3-pip python3-venv -y >/dev/null 2>&1
            pip3 install certbot certbot-dns-cloudflare \
                --break-system-packages >/dev/null 2>&1 || \
            pip3 install certbot certbot-dns-cloudflare >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux)
            $PKG_INSTALL certbot python3-certbot-dns-cloudflare \
                -y >/dev/null 2>&1 || {
                $PKG_INSTALL python3-pip -y >/dev/null 2>&1
                pip3 install certbot certbot-dns-cloudflare \
                    >/dev/null 2>&1
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

    # 使用普通变量，兼容所有 bash 版本
    ALL_DOMAINS=()
    CDN_DOMAINS=()
    DIRECT_DOMAINS=()
    XHTTP_DOMAIN=""
    GRPC_DOMAIN=""
    REALITY_DOMAIN=""
    ANYTLS_DOMAIN=""

    # 用普通数组存储域名对应的CF账号
    DOMAIN_CF_ACCOUNT_KEYS=()
    DOMAIN_CF_ACCOUNT_VALS=()

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
                XHTTP_DOMAIN="$domain"
                CDN_DOMAINS+=("$domain")
                log_info "域名 $domain 配置完成（xhttp/cdn）"
                ;;
            2)
                GRPC_DOMAIN="$domain"
                CDN_DOMAINS+=("$domain")
                log_info "域名 $domain 配置完成（grpc/cdn）"
                ;;
            3)
                REALITY_DOMAIN="$domain"
                DIRECT_DOMAINS+=("$domain")
                log_info "域名 $domain 配置完成（reality/direct）"
                ;;
            4)
                ANYTLS_DOMAIN="$domain"
                DIRECT_DOMAINS+=("$domain")
                log_info "域名 $domain 配置完成（anytls/direct）"
                ;;
            *)
                log_warn "无效选择，跳过域名 $domain"
                continue
                ;;
        esac

        # 记录域名对应CF账号
        if [[ "${CF_ACCOUNT_COUNT}" -gt 1 ]]; then
            read -rp "  使用第几个CF账号？[1-${CF_ACCOUNT_COUNT}]: " cf_idx
            DOMAIN_CF_ACCOUNT_KEYS+=("$domain")
            DOMAIN_CF_ACCOUNT_VALS+=("${cf_idx:-1}")
        else
            DOMAIN_CF_ACCOUNT_KEYS+=("$domain")
            DOMAIN_CF_ACCOUNT_VALS+=("1")
        fi

        ALL_DOMAINS+=("$domain")
    done

    # 汇总显示
    echo ""
    log_info "域名配置汇总："
    [[ -n "$XHTTP_DOMAIN"   ]] && echo "  xhttp CDN:  $XHTTP_DOMAIN"
    [[ -n "$GRPC_DOMAIN"    ]] && echo "  gRPC  CDN:  $GRPC_DOMAIN"
    [[ -n "$REALITY_DOMAIN" ]] && echo "  Reality:    $REALITY_DOMAIN"
    [[ -n "$ANYTLS_DOMAIN"  ]] && echo "  AnyTLS:     $ANYTLS_DOMAIN"
    echo ""

    read -rp "确认以上配置？[Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        log_warn "重新配置域名..."
        collect_domains
    fi
}

# ── 获取域名对应的CF账号索引 ────────────────────────────────
get_domain_cf_idx() {
    local domain="$1"
    for i in "${!DOMAIN_CF_ACCOUNT_KEYS[@]}"; do
        if [[ "${DOMAIN_CF_ACCOUNT_KEYS[$i]}" == "$domain" ]]; then
            echo "${DOMAIN_CF_ACCOUNT_VALS[$i]}"
            return
        fi
    done
    echo "1"
}

# ── 申请证书 ─────────────────────────────────────────────────
request_certificates() {
    log_step "开始申请 SSL 证书..."

    mkdir -p /etc/letsencrypt

    # 收集所有根域名避免重复申请
    declare -A ROOT_DOMAIN_DONE

    for domain in "${ALL_DOMAINS[@]}"; do
        local cf_idx
        cf_idx=$(get_domain_cf_idx "$domain")
        local ini_file="${CF_INI_FILES[$((cf_idx-1))]}"

        # 提取根域名
        local root_domain
        root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

        # 同一根域名只申请一次通配符证书
        if [[ -n "${ROOT_DOMAIN_DONE[$root_domain]:-}" ]]; then
            log_info "根域名 $root_domain 证书已申请，跳过 $domain"
            continue
        fi

        log_info "申请证书: *.${root_domain} (使用 CF账号${cf_idx})"

        # 检查证书是否已存在
        if [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            log_warn "证书已存在: $root_domain 跳过"
            ROOT_DOMAIN_DONE["$root_domain"]="1"
            continue
        fi

        # 申请通配符证书
        certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$ini_file" \
            --dns-cloudflare-propagation-seconds 30 \
            -d "${root_domain}" \
            -d "*.${root_domain}" \
            --email "admin@${root_domain}" \
            --agree-tos \
            --non-interactive \
            --expand 2>&1 | while IFS= read -r line; do
                echo "  $line"
            done

        if [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            log_info "证书申请成功: *.${root_domain}"
            ROOT_DOMAIN_DONE["$root_domain"]="1"
        else
            log_error "证书申请失败: ${root_domain}"
        fi
    done

    log_info "所有证书申请完成"
}

# ── 配置自动续期 ─────────────────────────────────────────────
setup_auto_renew() {
    log_step "配置证书自动续期..."

    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/bin/bash
systemctl reload nginx 2>/dev/null || true
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    (crontab -l 2>/dev/null | grep -v certbot; \
     echo "0 3 * * * certbot renew --quiet \
--deploy-hook 'systemctl reload nginx'") \
     | crontab -

    log_info "自动续期配置完成（每天凌晨3点检查）"
}

# ── 模块入口 ─────────────────────────────────────────────────
run_cert() {
    log_step "========== SSL 证书处理 =========="

    # 初始化 CF 账号数（collect_domains 内部会用到）
    CF_ACCOUNT_COUNT=${CF_ACCOUNT_COUNT:-1}
    CF_INI_FILES=(${CF_INI_FILES[@]:-})

    # 第一步：域名分配（必须先做，后续才知道检查哪些证书）
    collect_domains

    # 第二步：判断证书是否已全部存在
    if check_existing_certs; then
        log_info "所有证书均已存在，跳过申请流程"
        setup_auto_renew
    else
        install_certbot
        setup_cf_accounts
        request_certificates
        setup_auto_renew
    fi

    log_info "========== SSL 证书处理完成 =========="
}

# ── 检测已有证书（返回0=全部已有，1=有缺失）─────────────────
check_existing_certs() {
    local missing=0
    local -A checked_roots

    for domain in "${ALL_DOMAINS[@]}"; do
        local root
        root=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
        [[ -n "${checked_roots[$root]:-}" ]] && continue
        checked_roots["$root"]=1

        if [[ -f "/etc/letsencrypt/live/${root}/fullchain.pem" ]]; then
            log_info "证书已存在: *.${root} ✓"
        else
            log_warn "证书缺失: *.${root}"
            missing=1
        fi
    done

    return $missing
}
