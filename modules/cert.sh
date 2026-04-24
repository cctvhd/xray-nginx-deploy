#!/usr/bin/env bash
# ============================================================
# modules/cert.sh
# Cloudflare DNS 证书申请模块
# ============================================================

# ── 检测 Certbot 是否已安装 ──────────────────────────────────
check_certbot_installed() {
    if command -v certbot &>/dev/null; then
        log_info "Certbot 已安装: $(certbot --version 2>&1)"
        return 0
    fi
    return 1
}

# ── 判断是否使用 Snap 安装的 Certbot ─────────────────────────
certbot_uses_snap() {
    command -v snap &>/dev/null && snap list certbot >/dev/null 2>&1
}

# ── 安装并启用 snapd ─────────────────────────────────────────
install_snapd() {
    log_step "安装 snapd..."

    case "$OS_ID" in
        ubuntu|debian)
            $PKG_INSTALL snapd -y >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            $PKG_INSTALL epel-release -y >/dev/null 2>&1 || true
            $PKG_INSTALL snapd -y >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac

    systemctl enable --now snapd.socket >/dev/null 2>&1
    systemctl enable --now snapd.seeded.service >/dev/null 2>&1 || true
    [[ -e /snap ]] || ln -s /var/lib/snapd/snap /snap

    for _ in {1..10}; do
        if command -v snap &>/dev/null; then
            return 0
        fi
        sleep 1
    done

    return 1
}

# ── 移除旧版 Certbot 包 ─────────────────────────────────────
remove_legacy_certbot() {
    case "$OS_ID" in
        ubuntu|debian)
            apt-get remove -y certbot python3-certbot-dns-cloudflare \
                >/dev/null 2>&1 || true
            ;;
        centos|rhel|rocky|almalinux|fedora)
            dnf remove -y certbot python3-certbot-dns-cloudflare \
                >/dev/null 2>&1 || true
            yum remove -y certbot python3-certbot-dns-cloudflare \
                >/dev/null 2>&1 || true
            ;;
    esac
}

# ── 使用 Snap 安装 Certbot + CF 插件 ────────────────────────
install_certbot_snap() {
    install_snapd || return 1

    log_step "使用 Snap 安装最新 Certbot..."
    remove_legacy_certbot

    snap install core >/dev/null 2>&1 || true
    snap refresh core >/dev/null 2>&1 || true
    snap install --classic certbot >/dev/null 2>&1 || \
        snap refresh certbot >/dev/null 2>&1
    snap set certbot trust-plugin-with-root=ok >/dev/null 2>&1 || true
    snap install certbot-dns-cloudflare >/dev/null 2>&1 || \
        snap refresh certbot-dns-cloudflare >/dev/null 2>&1

    ln -sfn /snap/bin/certbot /usr/local/bin/certbot
    command -v certbot &>/dev/null
}

# ── 旧方案回退安装 ───────────────────────────────────────────
install_certbot_legacy() {
    log_warn "Snap 安装失败，回退到系统/PIP 方式安装 Certbot"

    case "$OS_ID" in
        ubuntu|debian)
            $PKG_INSTALL python3-pip python3-venv -y >/dev/null 2>&1
            pip3 install certbot certbot-dns-cloudflare \
                --break-system-packages >/dev/null 2>&1 || \
            pip3 install certbot certbot-dns-cloudflare >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            $PKG_INSTALL python3-pip -y >/dev/null 2>&1
            pip3 install certbot certbot-dns-cloudflare \
                >/dev/null 2>&1 || \
            $PKG_INSTALL certbot python3-certbot-dns-cloudflare \
                -y >/dev/null 2>&1
            ;;
    esac
}

# ── 安装 Certbot + CF 插件 ───────────────────────────────────
install_certbot() {
    if check_certbot_installed; then
        read -rp "Certbot 已安装，是否重新安装？[y/N]: " reinstall
        [[ "${reinstall,,}" != "y" ]] && return
    fi

    log_step "安装 Certbot + Cloudflare 插件..."

    if ! install_certbot_snap; then
        install_certbot_legacy
    fi

    if ! command -v certbot &>/dev/null; then
        log_error "Certbot 安装失败"
        exit 1
    fi

    log_info "Certbot 安装完成: $(certbot --version 2>&1)"
    if certbot_uses_snap; then
        log_info "当前使用 Snap 版 Certbot（官方推荐）"
    else
        log_warn "当前未使用 Snap 版 Certbot，后续仍可能受系统 Python 版本影响"
    fi
}

# ── 配置 Cloudflare 账号 ─────────────────────────────────────
setup_cf_accounts() {
    echo ""
    log_step "配置 Cloudflare 账号"
    echo ""

    # 检查是否已有账号配置
    if ls /etc/cloudflare/cf_account_*.ini &>/dev/null 2>&1; then
        log_info "发现已有 CF 账号配置："
        ls /etc/cloudflare/cf_account_*.ini | while read -r f; do
            echo "  $f"
        done
        echo ""
        read -rp "是否重新配置 CF 账号？[y/N]: " reconf
        if [[ "${reconf,,}" != "y" ]]; then
            # 读取已有账号数量
            CF_ACCOUNT_COUNT=$(ls /etc/cloudflare/cf_account_*.ini \
                2>/dev/null | wc -l)
            CF_INI_FILES=()
            for i in $(seq 1 "$CF_ACCOUNT_COUNT"); do
                CF_INI_FILES+=("/etc/cloudflare/cf_account_${i}.ini")
            done
            log_info "使用已有 ${CF_ACCOUNT_COUNT} 个CF账号配置"
            return
        fi
    fi

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

    ALL_DOMAINS=()
    CDN_DOMAINS=()
    DIRECT_DOMAINS=()
    XHTTP_DOMAIN=""
    GRPC_DOMAIN=""
    REALITY_DOMAIN=""
    ANYTLS_DOMAIN=""

    # 域名→CF账号映射（用两个平行数组）
    DOMAIN_CF_ACCOUNT_KEYS=()
    DOMAIN_CF_ACCOUNT_VALS=()

    echo "  域名用途说明："
    echo "    1. xhttp-CDN   - VLESS+XHTTP 经 CF CDN 中转（开启CF代理）"
    echo "    2. gRPC-CDN    - VLESS+gRPC 经 CF CDN 中转（开启CF代理）"
    echo "    3. Reality     - VLESS+Reality 直连伪装域名（关闭CF代理）"
    echo "    4. AnyTLS      - Sing-Box AnyTLS 直连（关闭CF代理）"
    echo ""

    read -rp "共需要配置几个域名？: " domain_count

    for i in $(seq 1 "$domain_count"); do
        echo ""
        log_info "── 配置第 ${i} 个域名 ──"
        read -rp "  域名: " domain
        domain="${domain,,}"

        echo "  用途选择："
        echo "    1. xhttp-CDN"
        echo "    2. gRPC-CDN"
        echo "    3. Reality 伪装域名"
        echo "    4. AnyTLS"
        read -rp "  请选择 [1-4]: " usage_choice

        case "$usage_choice" in
            1)
                XHTTP_DOMAIN="$domain"
                CDN_DOMAINS+=("$domain")
                log_info "域名 $domain → xhttp-CDN"
                ;;
            2)
                GRPC_DOMAIN="$domain"
                CDN_DOMAINS+=("$domain")
                log_info "域名 $domain → gRPC-CDN"
                ;;
            3)
                REALITY_DOMAIN="$domain"
                DIRECT_DOMAINS+=("$domain")
                log_info "域名 $domain → Reality"
                ;;
            4)
                ANYTLS_DOMAIN="$domain"
                DIRECT_DOMAINS+=("$domain")
                log_info "域名 $domain → AnyTLS"
                ;;
            *)
                log_warn "无效选择，跳过 $domain"
                continue
                ;;
        esac

        # 记录对应CF账号
        if [[ "${CF_ACCOUNT_COUNT:-1}" -gt 1 ]]; then
            echo ""
            for j in $(seq 1 "$CF_ACCOUNT_COUNT"); do
                echo "    账号${j}: $(grep 'api_token' \
                    "/etc/cloudflare/cf_account_${j}.ini" | \
                    awk '{print $3}' | cut -c1-12)..."
            done
            read -rp "  域名 $domain 使用第几个CF账号？\
[1-${CF_ACCOUNT_COUNT}]: " cf_idx
            cf_idx="${cf_idx:-1}"
        else
            cf_idx="1"
        fi

        DOMAIN_CF_ACCOUNT_KEYS+=("$domain")
        DOMAIN_CF_ACCOUNT_VALS+=("$cf_idx")
        ALL_DOMAINS+=("$domain")
    done

    # 汇总确认
    echo ""
    log_info "域名配置汇总："
    [[ -n "$XHTTP_DOMAIN"   ]] && \
        echo "  xhttp CDN:  $XHTTP_DOMAIN"
    [[ -n "$GRPC_DOMAIN"    ]] && \
        echo "  gRPC  CDN:  $GRPC_DOMAIN"
    [[ -n "$REALITY_DOMAIN" ]] && \
        echo "  Reality:    $REALITY_DOMAIN"
    [[ -n "$ANYTLS_DOMAIN"  ]] && \
        echo "  AnyTLS:     $ANYTLS_DOMAIN"
    echo ""

    read -rp "确认以上配置？[Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        log_warn "重新配置域名..."
        collect_domains
    fi
}

# ── 获取域名对应CF账号索引 ───────────────────────────────────
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

# ── 检查已有证书 ─────────────────────────────────────────────
check_existing_certs() {
    log_step "检查已有证书..."

    local all_exist=true
    local checked_roots=()

    for domain in "${ALL_DOMAINS[@]}"; do
        local root_domain
        root_domain=$(echo "$domain" | \
            awk -F. '{print $(NF-1)"."$NF}')

        # 避免重复检查同一根域名
        local already=false
        for r in "${checked_roots[@]:-}"; do
            [[ "$r" == "$root_domain" ]] && already=true && break
        done
        $already && continue
        checked_roots+=("$root_domain")

        if [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            local expiry
            expiry=$(openssl x509 \
                -enddate \
                -noout \
                -in "/etc/letsencrypt/live/${root_domain}/fullchain.pem" \
                2>/dev/null | cut -d= -f2)
            log_info "证书已存在: *.${root_domain} (到期: ${expiry})"
        else
            log_warn "证书不存在: *.${root_domain}"
            all_exist=false
        fi
    done

    $all_exist && return 0 || return 1
}

# ── 申请证书 ─────────────────────────────────────────────────
request_certificates() {
    log_step "开始申请 SSL 证书..."

    # 已检查过的根域名
    declare -A ROOT_DOMAIN_DONE

    for domain in "${ALL_DOMAINS[@]}"; do
        local cf_idx
        cf_idx=$(get_domain_cf_idx "$domain")
        local ini_file="${CF_INI_FILES[$((cf_idx-1))]}"

        local root_domain
        root_domain=$(echo "$domain" | \
            awk -F. '{print $(NF-1)"."$NF}')

        # 同根域名只申请一次
        [[ -n "${ROOT_DOMAIN_DONE[$root_domain]:-}" ]] && \
            { log_info "*.${root_domain} 已处理，跳过 $domain"
              continue; }

        # 已有证书则跳过
        if [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            log_info "证书已存在，跳过: *.${root_domain}"
            ROOT_DOMAIN_DONE["$root_domain"]="1"
            continue
        fi

        log_info "申请证书: *.${root_domain} (CF账号${cf_idx})"
        log_info "使用配置: $ini_file"

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

        if [[ -f \
            "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            log_info "证书申请成功: *.${root_domain}"
            ROOT_DOMAIN_DONE["$root_domain"]="1"
        else
            log_error "证书申请失败: ${root_domain}"
            log_warn "请检查："
            echo "  1. 域名是否在该CF账号下"
            echo "  2. API Token 是否有 Zone:DNS:Edit 权限"
            echo "  3. 域名是否已添加到CF"
        fi
    done
}

# ── 配置自动续期 ─────────────────────────────────────────────
setup_auto_renew() {
    log_step "配置证书自动续期..."

    # 续期 hook
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/bin/bash
systemctl reload nginx 2>/dev/null || true
HOOK
    chmod +x \
        /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    if certbot_uses_snap; then
        crontab -l 2>/dev/null | grep -v certbot | crontab - || true
        log_info "自动续期配置完成（使用 Snap 自带 timer）"
        log_info "可用 systemctl list-timers | grep certbot 查看续期计划"
    else
        # cron 任务
        (crontab -l 2>/dev/null | grep -v certbot; \
         echo "0 3 * * * certbot renew --quiet") | crontab -
        log_info "自动续期配置完成（每天凌晨3点检查）"
    fi
}

# ── 模块入口 ─────────────────────────────────────────────────
run_cert() {
    log_step "========== SSL 证书申请 =========="

    # 1. 安装 certbot
    install_certbot

    # 2. 配置CF账号（先设账号再填域名）
    setup_cf_accounts

    # 3. 收集域名信息
    collect_domains

    # 4. 检查已有证书，有则跳过申请
    if check_existing_certs; then
        log_info "所有域名证书已存在，跳过申请"
    else
        request_certificates
    fi

    # 5. 配置自动续期
    setup_auto_renew

    log_info "========== SSL 证书模块完成 =========="
}
