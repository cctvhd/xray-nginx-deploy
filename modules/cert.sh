#!/usr/bin/env bash
# ============================================================
# modules/cert.sh
# Cloudflare DNS 证书申请模块
# ============================================================

CF_CONFIG_DIR="/etc/cloudflare"
CF_DOMAIN_MAP_FILE="${CF_CONFIG_DIR}/domain_map.conf"
CF_CERT_STATUS_FILE="${CF_CONFIG_DIR}/cert_request_status.conf"

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
update_certbot_deps() {
    log_step "========== Certbot 依赖检查/更新 =========="

    if certbot_uses_snap; then
        log_info "检测到 snap 版 certbot，刷新插件..."
        snap refresh certbot 2>/dev/null || true
        snap refresh certbot-dns-cloudflare 2>/dev/null || true
        snap install certbot-dns-cloudflare 2>/dev/null || true
        log_info "snap 插件更新完成"
    else
        log_info "检测到传统版 certbot，更新插件..."
        pip3 install --upgrade certbot certbot-dns-cloudflare 2>/dev/null \
            || $PKG_INSTALL certbot python3-certbot-dns-cloudflare
        log_info "传统插件更新完成"
    fi

    certbot --version 2>&1 | grep -v "^$" | head -3
}

install_certbot() {
    if check_certbot_installed; then
        log_info "Certbot 已安装，跳过"
        return 0
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

# ════════════════════════════════════════════════════════════
# 账号管理
# ════════════════════════════════════════════════════════════

# ── 重建 CF_INI_FILES 数组 ───────────────────────────────────
rebuild_cf_ini_files() {
    CF_INI_FILES=()
    for i in $(seq 1 "${CF_ACCOUNT_COUNT:-1}"); do
        CF_INI_FILES+=("${CF_CONFIG_DIR}/cf_account_${i}.ini")
    done
}

# ── CF Token 验证（调用 Cloudflare API） ────────────────────
# 用法: verify_cf_token <token> [<root_domain>]
# 返回码:
#   0 = Token 有效且（如给了根域名）能访问该 Zone
#   1 = Token 无效（401 / success:false / 4xx）
#   2 = 网络错误（curl 失败 / 超时 / 5xx / 空响应）
#   3 = Token 有效，但无法访问指定根域名的 Zone（result 为空）
verify_cf_token() {
    local token="$1" root_domain="${2:-}"
    local resp body http_code curl_rc

    # ── 第一步：/user/tokens/verify ──
    resp=$(curl -sS --max-time 5 \
        -H "Authorization: Bearer ${token}" \
        -w $'\n%{http_code}' \
        "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null) || curl_rc=$?
    curl_rc="${curl_rc:-0}"

    if [[ "$curl_rc" -ne 0 || -z "$resp" ]]; then
        return 2
    fi

    http_code=$(printf '%s\n' "$resp" | tail -n1)
    body=$(printf '%s\n' "$resp" | sed '$d')

    case "$http_code" in
        200) ;;
        5*)  return 2 ;;
        *)   return 1 ;;
    esac

    if ! echo "$body" | grep -q '"success":[[:space:]]*true'; then
        return 1
    fi

    # ── 第二步（可选）：Zone 权限校验 ──
    [[ -z "$root_domain" ]] && return 0

    curl_rc=0
    resp=$(curl -sS --max-time 5 \
        -H "Authorization: Bearer ${token}" \
        -w $'\n%{http_code}' \
        "https://api.cloudflare.com/client/v4/zones?name=${root_domain}" 2>/dev/null) || curl_rc=$?

    if [[ "$curl_rc" -ne 0 || -z "$resp" ]]; then
        return 2
    fi

    http_code=$(printf '%s\n' "$resp" | tail -n1)
    body=$(printf '%s\n' "$resp" | sed '$d')

    case "$http_code" in
        200) ;;
        5*)  return 2 ;;
        *)   return 1 ;;
    esac

    if ! echo "$body" | grep -q '"success":[[:space:]]*true'; then
        return 1
    fi

    # result 为空数组 → 该 Token 无权访问该根域名
    if echo "$body" | grep -qE '"result"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]'; then
        return 3
    fi

    return 0
}

# ── 查找已使用该 Token 的账号文件（去重检测用） ─────────────
# 用法: find_cf_token_owner_file <token> [<exclude_ini_file>]
# 成功输出匹配的 ini 文件全路径并返回 0；无匹配返回 1
find_cf_token_owner_file() {
    local token="$1" exclude_file="${2:-}"
    local f t
    for f in $(_scan_cf_account_files); do
        [[ -n "$exclude_file" && "$f" == "$exclude_file" ]] && continue
        t=$(_cf_ini_token "$f")
        if [[ -n "$t" && "$t" == "$token" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# ── 查找根域名已关联的 CF 账号文件 ──────────────────────────
# 用法: find_root_domain_owner_file <root_domain>
# 输出: 关联的账号 ini 文件全路径（找不到则空），返回 0/1
find_root_domain_owner_file() {
    local root="$1"
    local filebase
    filebase=$(domain_to_ini_name "$root")

    # 新格式 per-root 账号文件直接命中
    if [[ -f "${CF_CONFIG_DIR}/${filebase}.ini" ]]; then
        echo "${CF_CONFIG_DIR}/${filebase}.ini"
        return 0
    fi

    # domain_<root>.ini 映射存在 → 反查源账号 ini
    local mapping="${CF_CONFIG_DIR}/domain_${filebase}.ini"
    if [[ -f "$mapping" ]]; then
        local mapped_token
        mapped_token=$(_cf_ini_token "$mapping")
        if [[ -n "$mapped_token" ]]; then
            local f t
            for f in $(_scan_cf_account_files); do
                t=$(_cf_ini_token "$f")
                if [[ -n "$t" && "$t" == "$mapped_token" ]]; then
                    echo "$f"
                    return 0
                fi
            done
        fi
        # 找不到源账号则返回映射文件本身
        echo "$mapping"
        return 0
    fi

    return 1
}

# ── Token 写入前的去重确认（供 prompt_cf_token 内部使用） ───
# 用法: _accept_cf_token <token> [<exclude_ini_file>]
# 成功（无重复 / 用户确认覆盖）: 写 PROMPT_CF_TOKEN_RESULT 返回 0
# 用户拒绝覆盖: 返回 1，由上层循环重新提示输入
_accept_cf_token() {
    local token="$1" exclude_file="${2:-}"
    local dup_file dup_name cont
    dup_file=$(find_cf_token_owner_file "$token" "$exclude_file" || true)
    if [[ -n "$dup_file" ]]; then
        dup_name=$(basename "$dup_file" .ini)
        log_warn "该 Token 已被账号 [${dup_name}] 使用"
        read -rp "  是否继续写入？[y/N]: " cont
        if [[ "${cont,,}" != "y" ]]; then
            log_info "请重新输入 Token..."
            return 1
        fi
    fi
    PROMPT_CF_TOKEN_RESULT="$token"
    return 0
}

# ── 交互式 Token 输入 + 验证（三种失败场景分别处理） ────────
# 用法: prompt_cf_token <prompt_label> [<root_domain>] [<exclude_ini_file>]
# 成功: 把校验通过的 Token 写入全局变量 PROMPT_CF_TOKEN_RESULT，返回 0
# 用户放弃 / 连续 3 次无效: 清空 PROMPT_CF_TOKEN_RESULT，返回 1
# exclude_ini_file: 去重检测时排除的目标文件（重配置/覆盖写场景）
prompt_cf_token() {
    local label="$1" root_domain="${2:-}" exclude_file="${3:-}"
    PROMPT_CF_TOKEN_RESULT=""
    local token rc invalid_attempts=0 choice

    while true; do
        read -rp "  ${label}: " token
        if [[ -z "$token" ]]; then
            log_warn "Token 不能为空，请重新输入"
            continue
        fi

        rc=0
        verify_cf_token "$token" "$root_domain" || rc=$?

        case "$rc" in
            0)
                if [[ -n "$root_domain" ]]; then
                    log_info "Token 验证通过（可访问 ${root_domain} 的 Zone）"
                else
                    log_info "Token 验证通过"
                fi
                _accept_cf_token "$token" "$exclude_file" && return 0
                ;;
            1)
                invalid_attempts=$((invalid_attempts + 1))
                if [[ $invalid_attempts -ge 3 ]]; then
                    log_error "Token 连续 3 次验证失败，放弃本次配置（未写入任何文件）"
                    return 1
                fi
                log_warn "Token 无效（CF API 拒绝），请重新输入 [${invalid_attempts}/3]"
                ;;
            2)
                log_warn "无法连接 api.cloudflare.com（超时 / 连接失败 / 5xx）"
                echo "  a. 重试验证（保留刚才输入的 Token）"
                echo "  b. 跳过验证强行写入（你自己确认 Token 正确，后续 certbot 会再验一次）"
                echo "  c. 放弃返回菜单"
                read -rp "  请选择 [a/b/c]: " choice
                case "${choice,,}" in
                    b)
                        log_warn "已跳过 CF API 验证，按你的输入写入"
                        _accept_cf_token "$token" "$exclude_file" && return 0
                        ;;
                    c)
                        log_warn "已放弃，未写入任何文件"
                        return 1
                        ;;
                    *)
                        log_info "重试验证..."
                        ;;
                esac
                ;;
            3)
                log_warn "Token 有效，但无法访问域名 ${root_domain} 的 Zone"
                log_warn "请确认该 Token 的权限范围 / 所属 CF 账号是否正确"
                echo "  a. 重新输入 Token"
                echo "  b. 忽略并继续（使用此 Token 写入配置）"
                read -rp "  请选择 [a/b]: " choice
                case "${choice,,}" in
                    b)
                        log_warn "已忽略 Zone 权限警告，按你的输入写入"
                        _accept_cf_token "$token" "$exclude_file" && return 0
                        ;;
                    *)
                        log_info "请重新输入 Token..."
                        ;;
                esac
                ;;
        esac
    done
}

# ── 重新配置指定 CF 账号 ─────────────────────────────────────
reconfigure_cf_accounts() {
    local account_indexes=("$@")

    mkdir -p "$CF_CONFIG_DIR"
    chmod 700 "$CF_CONFIG_DIR"

    for i in "${account_indexes[@]}"; do
        echo ""
        log_info "── 配置第 ${i} 个 CF 账号 ──"
        local ini_file="${CF_CONFIG_DIR}/cf_account_${i}.ini"
        if ! prompt_cf_token "账号 ${i} 的 CF API Token" "" "$ini_file"; then
            log_error "账号 ${i} 配置已放弃，停止配置剩余账号"
            return 1
        fi
        local cf_token="$PROMPT_CF_TOKEN_RESULT"

        cat > "$ini_file" << INI
# Cloudflare API Token - 账号 ${i}
dns_cloudflare_api_token = ${cf_token}
INI
        chmod 600 "$ini_file"
        log_info "账号 ${i} 配置已保存: $ini_file"
    done

    rebuild_cf_ini_files
}

# ── 配置 Cloudflare 账号 ─────────────────────────────────────
setup_cf_accounts() {
    echo ""
    log_step "配置 Cloudflare 账号"
    echo ""

    load_cert_request_status >/dev/null 2>&1 || true

    if ls "${CF_CONFIG_DIR}"/cf_account_*.ini &>/dev/null 2>&1; then
        CF_ACCOUNT_COUNT=$(ls "${CF_CONFIG_DIR}"/cf_account_*.ini \
            2>/dev/null | wc -l)
        rebuild_cf_ini_files

        log_info "发现已有 CF 账号配置："
        ls "${CF_CONFIG_DIR}"/cf_account_*.ini | while read -r f; do
            echo "  $f"
        done
        echo ""

        if [[ ${#FAILED_CF_ACCOUNTS[@]} -gt 0 ]]; then
            local -A seen_failed_accounts=()
            local failed_account_indexes=()

            for cf_idx in "${FAILED_CF_ACCOUNTS[@]}"; do
                [[ -n "${seen_failed_accounts[$cf_idx]:-}" ]] && continue
                seen_failed_accounts["$cf_idx"]=1
                failed_account_indexes+=("$cf_idx")
            done

            if [[ ${#failed_account_indexes[@]} -gt 0 ]]; then
                echo "上次失败涉及账号: ${failed_account_indexes[*]}"
                read -rp "是否只重新配置失败账号？[Y/n]: " reconf_failed
                if [[ "${reconf_failed,,}" != "n" ]]; then
                    reconfigure_cf_accounts "${failed_account_indexes[@]}"
                    log_info "其余 CF 账号配置保持不变"
                    return
                fi
            fi
        fi

        read -rp "是否重新配置全部 CF 账号？[y/N]: " reconf
        if [[ "${reconf,,}" != "y" ]]; then
            log_info "使用已有 ${CF_ACCOUNT_COUNT} 个CF账号配置"
            return
        fi
    fi

    read -rp "你有几个 Cloudflare 账号？[默认1]: " CF_ACCOUNT_COUNT
    CF_ACCOUNT_COUNT=${CF_ACCOUNT_COUNT:-1}

    rm -f "${CF_CONFIG_DIR}"/cf_account_*.ini 2>/dev/null || true
    # shellcheck disable=SC2046
    reconfigure_cf_accounts $(seq 1 "$CF_ACCOUNT_COUNT")
}

# ════════════════════════════════════════════════════════════
# 域名↔账号映射（方案 A：per-domain ini 文件）
#
# 文件布局：
#   /etc/cloudflare/cf_account_1.ini   ← 账号凭证（用户填写）
#   /etc/cloudflare/cf_account_2.ini   ← 账号凭证（用户填写）
#   /etc/cloudflare/domain_ccpv.tk.ini     ← 复制自 cf_account_2.ini
#   /etc/cloudflare/domain_shoes-bv.tk.ini ← 复制自 cf_account_1.ini
#
# 申请证书时直接读 domain_<root>.ini，不再依赖任何内存数组。
# ════════════════════════════════════════════════════════════

# ── 将根域名与 CF 账号绑定（写文件）────────────────────────
link_domain_to_cf_account() {
    local root_domain="$1"
    local cf_idx="$2"
    local src="${CF_CONFIG_DIR}/cf_account_${cf_idx}.ini"
    local _base _dst
    _base=$(domain_to_ini_name "$root_domain")
    local dst="${CF_CONFIG_DIR}/domain_${_base}.ini"

    if [[ ! -f "$src" ]]; then
        log_error "CF账号配置文件不存在: $src"
        return 1
    fi

    cp "$src" "$dst"
    chmod 600 "$dst"
    log_info "域名 *.${root_domain} → 账号${cf_idx} (${dst})"
}

# ── 获取根域名对应的 ini 文件路径 ───────────────────────────
get_domain_ini() {
    local root_domain="$1"
    local _base
    _base=$(domain_to_ini_name "$root_domain")
    local f="${CF_CONFIG_DIR}/domain_${_base}.ini"

    if [[ -f "$f" ]]; then
        echo "$f"
    else
        # 回退到账号1，同时给出警告
        log_warn "未找到 ${f}，回退到 cf_account_1.ini"
        echo "${CF_CONFIG_DIR}/cf_account_1.ini"
    fi
}

# ── 列出所有已绑定的 domain ini 文件 ────────────────────────
list_domain_ini_files() {
    ls "${CF_CONFIG_DIR}"/domain_*.ini 2>/dev/null
}

# ── 检查某根域名是否已有 domain ini ─────────────────────────
has_domain_ini() {
    local root_domain="$1"
    local _base
    _base=$(domain_to_ini_name "$root_domain")
    [[ -f "${CF_CONFIG_DIR}/domain_${_base}.ini" ]]
}

# ════════════════════════════════════════════════════════════
# 域名配置持久化（只保存域名变量，不再保存映射数组）
# ════════════════════════════════════════════════════════════

# ── 保存域名配置 ─────────────────────────────────────────────
save_domain_config() {
    mkdir -p "$CF_CONFIG_DIR"
    chmod 700 "$CF_CONFIG_DIR"

    declare -A acct_domains_map

    {
        echo "# Auto-generated by xray-nginx-deploy cert module"
        echo "CF_ACCOUNT_COUNT='${CF_ACCOUNT_COUNT:-1}'"
        echo "XHTTP_DOMAIN='${XHTTP_DOMAIN:-}'"
        echo "GRPC_DOMAIN='${GRPC_DOMAIN:-}'"
        echo "REALITY_DOMAIN='${REALITY_DOMAIN:-}'"
        echo "ANYTLS_DOMAIN='${ANYTLS_DOMAIN:-}'"
        echo "NAIVE_DOMAIN='${NAIVE_DOMAIN:-}'"
        echo "HYSTERIA2_DOMAIN='${HYSTERIA2_DOMAIN:-}'"
        # 域名数组：逐行写入，不使用 shell 数组语法（避免命令注入）
        echo "# --- ALL_DOMAINS ---"
        for _dom_item in "${ALL_DOMAINS[@]}"; do echo "$_dom_item"; done
        echo "# --- END ALL_DOMAINS ---"
        echo "# --- CDN_DOMAINS ---"
        for _dom_item in "${CDN_DOMAINS[@]}"; do echo "$_dom_item"; done
        echo "# --- END CDN_DOMAINS ---"
        echo "# --- DIRECT_DOMAINS ---"
        for _dom_item in "${DIRECT_DOMAINS[@]}"; do echo "$_dom_item"; done
        echo "# --- END DIRECT_DOMAINS ---"
        # 域名↔账号映射：从 domain_*.ini 反查，写入 CF_ACCOUNT_N 条目
        for dom_ini in "${CF_CONFIG_DIR}"/domain_*.ini; do
            [[ -f "$dom_ini" ]] || continue
            local dom_token dom_root
            dom_token=$(grep 'dns_cloudflare_api_token' "$dom_ini" 2>/dev/null \
                | awk -F' = ' '{print $2}' | xargs || true)
            [[ -z "$dom_token" ]] && continue
            dom_root=$(basename "$dom_ini" | sed 's/^domain_//;s/\.ini$//')
            # 匹配到所有账号 ini（新旧格式：N.ini / zhongning_tk.ini）
            for cf_ini in "${CF_CONFIG_DIR}"/*.ini; do
                [[ -f "$cf_ini" ]] || continue
                [[ "$(basename "$cf_ini")" =~ ^(domain_|domain_map|cert_request) ]] && continue
                local cf_token cf_key
                cf_token=$(grep 'dns_cloudflare_api_token' "$cf_ini" 2>/dev/null \
                    | awk -F' = ' '{print $2}' | xargs || true)
                [[ "$cf_token" == "$dom_token" ]] || continue
                cf_key=$(basename "$cf_ini" .ini | sed 's/^cf_account_//')
                acct_domains_map["$cf_key"]="${acct_domains_map[$cf_key]:-} ${dom_root}"
                break
            done
        done
        for key in "${!acct_domains_map[@]}"; do
            echo "CF_ACCOUNT_${key}='${acct_domains_map[$key]# }'"
        done
    } > "$CF_DOMAIN_MAP_FILE"

    chmod 600 "$CF_DOMAIN_MAP_FILE"
    log_info "域名配置已保存: $CF_DOMAIN_MAP_FILE"
}

# ── 加载域名配置 ─────────────────────────────────────────────
load_domain_config() {
    [[ -f "$CF_DOMAIN_MAP_FILE" ]] || return 1

    ALL_DOMAINS=()
    CDN_DOMAINS=()
    DIRECT_DOMAINS=()

    local _section=""
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        [[ -z "$_line" ]] && continue

        case "$_line" in
            "# --- ALL_DOMAINS ---")
                _section="ALL"; continue ;;
            "# --- END ALL_DOMAINS ---")
                _section=""; continue ;;
            "# --- CDN_DOMAINS ---")
                _section="CDN"; continue ;;
            "# --- END CDN_DOMAINS ---")
                _section=""; continue ;;
            "# --- DIRECT_DOMAINS ---")
                _section="DIRECT"; continue ;;
            "# --- END DIRECT_DOMAINS ---")
                _section=""; continue ;;
        esac

        if [[ -n "$_section" ]]; then
            case "$_section" in
                ALL) ALL_DOMAINS+=("$_line") ;;
                CDN) CDN_DOMAINS+=("$_line") ;;
                DIRECT) DIRECT_DOMAINS+=("$_line") ;;
            esac
            continue
        fi

        # 跳过注释行
        [[ "$_line" == "#"* ]] && continue
        # 只处理 KEY='VALUE' 格式的行（简单变量）
        [[ "$_line" == *"="* ]] || continue

        local _key _value
        _key="${_line%%=*}"
        _value="${_line#*=}"
        # 去掉可选的引号
        [[ "$_value" == '"'* || "$_value" == "'"* ]] && _value="${_value:1}"
        [[ "$_value" == *'"' || "$_value" == *"'" ]] && _value="${_value%?}"

        declare -g "$_key=$_value" 2>/dev/null || true
    done < "$CF_DOMAIN_MAP_FILE"

    rebuild_cf_ini_files

    # 兼容旧格式：ALL_DOMAINS 为空时从四个变量重建
    if [[ ${#ALL_DOMAINS[@]} -eq 0 ]]; then
        [[ -n "${XHTTP_DOMAIN:-}"   ]] && ALL_DOMAINS+=("$XHTTP_DOMAIN")   && CDN_DOMAINS+=("$XHTTP_DOMAIN")
        [[ -n "${GRPC_DOMAIN:-}"    ]] && ALL_DOMAINS+=("$GRPC_DOMAIN")    && CDN_DOMAINS+=("$GRPC_DOMAIN")
        [[ -n "${REALITY_DOMAIN:-}" ]] && ALL_DOMAINS+=("$REALITY_DOMAIN") && DIRECT_DOMAINS+=("$REALITY_DOMAIN")
        [[ -n "${ANYTLS_DOMAIN:-}"  ]] && ALL_DOMAINS+=("$ANYTLS_DOMAIN")  && DIRECT_DOMAINS+=("$ANYTLS_DOMAIN")
        [[ -n "${NAIVE_DOMAIN:-}"   ]] && ALL_DOMAINS+=("$NAIVE_DOMAIN")   && DIRECT_DOMAINS+=("$NAIVE_DOMAIN")
        [[ -n "${HYSTERIA2_DOMAIN:-}" ]] && ALL_DOMAINS+=("$HYSTERIA2_DOMAIN") && DIRECT_DOMAINS+=("$HYSTERIA2_DOMAIN")
    fi

    return 0
}

normalize_domain_arrays() {
    local normalized_all=()
    local normalized_cdn=()
    local normalized_direct=()

    [[ -n "${XHTTP_DOMAIN:-}"   ]] && normalized_all+=("$XHTTP_DOMAIN")   && normalized_cdn+=("$XHTTP_DOMAIN")
    [[ -n "${GRPC_DOMAIN:-}"    ]] && normalized_all+=("$GRPC_DOMAIN")    && normalized_cdn+=("$GRPC_DOMAIN")
    [[ -n "${REALITY_DOMAIN:-}" ]] && normalized_all+=("$REALITY_DOMAIN") && normalized_direct+=("$REALITY_DOMAIN")
    [[ -n "${ANYTLS_DOMAIN:-}"  ]] && normalized_all+=("$ANYTLS_DOMAIN")  && normalized_direct+=("$ANYTLS_DOMAIN")
    [[ -n "${NAIVE_DOMAIN:-}"   ]] && normalized_all+=("$NAIVE_DOMAIN")   && normalized_direct+=("$NAIVE_DOMAIN")
    [[ -n "${HYSTERIA2_DOMAIN:-}" ]] && normalized_all+=("$HYSTERIA2_DOMAIN") && normalized_direct+=("$HYSTERIA2_DOMAIN")

    if [[ ${#normalized_all[@]} -gt 0 ]]; then
        ALL_DOMAINS=("${normalized_all[@]}")
        CDN_DOMAINS=("${normalized_cdn[@]}")
        DIRECT_DOMAINS=("${normalized_direct[@]}")
    fi
}

# ════════════════════════════════════════════════════════════
# 域名收集
# ════════════════════════════════════════════════════════════

# ── 收集域名信息 ─────────────────────────────────────────────
_collect_domain_cf() {
    local domain="$1"
    local root_domain
    root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

    [[ -z "$domain" ]] && return
    has_domain_ini "$root_domain" && return

    local cf_idx="1"

    if [[ "${CF_ACCOUNT_COUNT:-1}" -gt 1 ]]; then
        echo ""
        echo "  为 *.${root_domain} 选择 Cloudflare 账号："
        for j in $(seq 1 "$CF_ACCOUNT_COUNT"); do
            local token_preview
            token_preview=$(grep 'api_token' \
                "${CF_CONFIG_DIR}/cf_account_${j}.ini" 2>/dev/null | \
                awk '{print $3}' | cut -c1-12)
            echo "    [${j}] ${token_preview}..."
        done
        read -rp "  使用第几个 CF 账号？[1-${CF_ACCOUNT_COUNT}]: " cf_idx
        cf_idx="${cf_idx:-1}"
    fi

    link_domain_to_cf_account "$root_domain" "$cf_idx"
}

collect_domains() {
    echo ""
    log_step "配置域名信息"
    echo ""

    if load_domain_config; then
        log_info "发现已有域名配置："
        local _all _cdn _direct
        _all=$(get_state "ALL_DOMAINS")
        _cdn=$(get_state "CDN_DOMAINS")
        _direct=$(get_state "DIRECT_DOMAINS")
        [[ -n "$_all"    ]] && read -ra ALL_DOMAINS    <<< "$_all"
        [[ -n "$_cdn"    ]] && read -ra CDN_DOMAINS    <<< "$_cdn"
        [[ -n "$_direct" ]] && read -ra DIRECT_DOMAINS <<< "$_direct"

        for d in "${ALL_DOMAINS[@]}"; do
            local suffix mode protos
            suffix=$(echo "$d" | tr '.' '_')
            mode=$(get_state "DOMAIN_MODE_${suffix}")
            protos=$(get_state "DOMAIN_PROTO_${suffix}")
            echo "  $d  [${mode} / ${protos}]"
        done

        echo ""
        read -rp "是否直接复用已有域名配置？[Y/n]: " reuse_domains
        if [[ "${reuse_domains,,}" != "n" ]]; then
            normalize_domain_arrays

            local missing_ini=()
            for domain in "${ALL_DOMAINS[@]}"; do
                local root_domain
                root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
                if ! has_domain_ini "$root_domain"; then
                    local already=false
                    for m in "${missing_ini[@]}"; do
                        [[ "$m" == "$root_domain" ]] && already=true && break
                    done
                    $already || missing_ini+=("$root_domain")
                fi
            done

            if [[ ${#missing_ini[@]} -gt 0 ]]; then
                log_warn "以下根域名缺少账号映射文件，需要重新关联："
                for rd in "${missing_ini[@]}"; do
                    echo "  *.${rd}"
                done
                echo ""
                _prompt_link_domains "${missing_ini[@]}"
            fi

            log_info "复用已有域名配置"
            return
        fi
    fi

    # ── 全新填写域名 ──────────────────────────────────────────
    ALL_DOMAINS=()
    CDN_DOMAINS=()
    DIRECT_DOMAINS=()
    XHTTP_DOMAIN=""
    GRPC_DOMAIN=""
    REALITY_DOMAIN=""
    ANYTLS_DOMAIN=""
    NAIVE_DOMAIN=""
    HYSTERIA2_DOMAIN=""

    rm -f "${CF_CONFIG_DIR}"/domain_*.ini 2>/dev/null || true
    save_state "DOMAIN_REGISTRY" ""

    echo "  协议说明："
    echo "    xray      - VLESS 相关 (XHTTP/gRPC via CDN, Reality via Direct)"
    echo "    singbox   - Sing-Box AnyTLS"
    echo "    hysteria2 - Hysteria2"
    echo "    naiveproxy- NaiveProxy"
    echo "    nginx     - 独立 Nginx 站点"
    echo ""
    echo "  连接方式："
    echo "    cdn    - 经 Cloudflare CDN 中转（橙云）"
    echo "    direct - 直连（关闭 CF 代理 / 灰云）"
    echo ""

    while true; do
        local domain protocols mode

        read -rp "请输入域名（留空结束添加）: " domain
        domain="${domain,,}"
        [[ -z "$domain" ]] && break

        if domain_is_registered "$domain"; then
            log_warn "域名 $domain 已存在，跳过"
            continue
        fi

        # ── 多选协议 ──
        echo ""
        echo "  请为 $domain 选择协议（多选，空格分隔序号）："
        echo "    1. xray       - VLESS 系列 (XHTTP/gRPC + Reality)"
        echo "    2. singbox    - AnyTLS"
        echo "    3. hysteria2  - Hysteria2"
        echo "    4. naiveproxy - NaiveProxy"
        echo "    5. nginx      - 独立 Nginx 站点"
        local choices
        read -rp "  输入序号如: 1 3 5: " choices

        protocols=""
        for choice in $choices; do
            case "$choice" in
                1) protocols="${protocols:+$protocols,}xray" ;;
                2) protocols="${protocols:+$protocols,}singbox" ;;
                3) protocols="${protocols:+$protocols,}hysteria2" ;;
                4) protocols="${protocols:+$protocols,}naiveproxy" ;;
                5) protocols="${protocols:+$protocols,}nginx" ;;
                *) log_warn "无效选项: $choice"; ;;
            esac
        done
        [[ -z "$protocols" ]] && { log_warn "未选择协议，跳过"; continue; }

        # ── 连接方式 ──
        local mode_r
        read -rp "  连接方式 [d=直连(默认), c=CDN]: " mode_r
        case "${mode_r:-d}" in
            c|C|cdn|CDN) mode="cdn" ;;
            *)           mode="direct" ;;
        esac

        # ── 注册 & 关联 ──
        register_domain "$domain" "$mode" "$protocols"
        log_info "已添加: $domain [mode=$mode, proto=$protocols]"
        _collect_domain_cf "$domain"

        read -rp "继续添加更多域名？[Y/n]: " more
        if [[ "${more,,}" == "n" ]]; then
            break
        fi
        echo ""
    done

    rebuild_protocol_domains
    load_domain_state

    echo ""
    log_info "域名配置汇总："
    for d in "${ALL_DOMAINS[@]}"; do
        local suffix m p
        suffix=$(echo "$d" | tr '.' '_')
        m=$(get_state "DOMAIN_MODE_${suffix}")
        p=$(get_state "DOMAIN_PROTO_${suffix}")
        echo "  $d  [${m} / ${p}]"
    done
    echo ""

    read -rp "确认以上配置？[Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        rm -f "${CF_CONFIG_DIR}"/domain_*.ini 2>/dev/null || true
        save_state "DOMAIN_REGISTRY" ""
        log_warn "重新配置域名..."
        collect_domains
        return
    fi

    save_domain_config
}

# ── 补充关联：为指定根域名列表重新选择 CF 账号 ──────────────
_prompt_link_domains() {
    local root_domains=("$@")

    for root_domain in "${root_domains[@]}"; do
        local cf_idx="1"

        if [[ "${CF_ACCOUNT_COUNT:-1}" -gt 1 ]]; then
            echo ""
            echo "  为 *.${root_domain} 选择 Cloudflare 账号："
            for j in $(seq 1 "$CF_ACCOUNT_COUNT"); do
                local token_preview
                token_preview=$(grep 'api_token' \
                    "${CF_CONFIG_DIR}/cf_account_${j}.ini" 2>/dev/null | \
                    awk '{print $3}' | cut -c1-12)
                echo "    [${j}] ${token_preview}..."
            done
            read -rp "  使用第几个 CF 账号？[1-${CF_ACCOUNT_COUNT}]: " cf_idx
            cf_idx="${cf_idx:-1}"
        fi

        link_domain_to_cf_account "$root_domain" "$cf_idx"
    done
}

# ════════════════════════════════════════════════════════════
# 证书状态
# ════════════════════════════════════════════════════════════

# ── 保存证书请求状态 ─────────────────────────────────────────
save_cert_request_status() {
    mkdir -p "$CF_CONFIG_DIR"
    chmod 700 "$CF_CONFIG_DIR"

    {
        echo "# Auto-generated by xray-nginx-deploy cert module"
        # 逐行写入普通文本，不用 declare -p，避免 source 时执行恶意代码
        echo "# --- CERT_SUCCESS_ROOTS ---"
        for _item in "${CERT_SUCCESS_ROOTS[@]}"; do echo "$_item"; done
        echo "# --- END CERT_SUCCESS_ROOTS ---"
        echo "# --- CERT_EXISTING_ROOTS ---"
        for _item in "${CERT_EXISTING_ROOTS[@]}"; do echo "$_item"; done
        echo "# --- END CERT_EXISTING_ROOTS ---"
        echo "# --- CERT_FAILED_ROOTS ---"
        for _item in "${CERT_FAILED_ROOTS[@]}"; do echo "$_item"; done
        echo "# --- END CERT_FAILED_ROOTS ---"
        echo "# --- FAILED_CF_ACCOUNTS ---"
        for _item in "${FAILED_CF_ACCOUNTS[@]}"; do echo "$_item"; done
        echo "# --- END FAILED_CF_ACCOUNTS ---"
    } > "$CF_CERT_STATUS_FILE"

    chmod 600 "$CF_CERT_STATUS_FILE"
}

# ── 加载证书请求状态 ─────────────────────────────────────────
load_cert_request_status() {
    CERT_SUCCESS_ROOTS=()
    CERT_EXISTING_ROOTS=()
    CERT_FAILED_ROOTS=()
    FAILED_CF_ACCOUNTS=()

    [[ -f "$CF_CERT_STATUS_FILE" ]] || return 1

    local _section=""
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        [[ -z "$_line" ]] && continue
        [[ "$_line" == "#"* ]] && continue

        case "$_line" in
            "# --- CERT_SUCCESS_ROOTS ---")
                _section="SUCCESS"; continue ;;
            "# --- END CERT_SUCCESS_ROOTS ---")
                _section=""; continue ;;
            "# --- CERT_EXISTING_ROOTS ---")
                _section="EXISTING"; continue ;;
            "# --- END CERT_EXISTING_ROOTS ---")
                _section=""; continue ;;
            "# --- CERT_FAILED_ROOTS ---")
                _section="FAILED"; continue ;;
            "# --- END CERT_FAILED_ROOTS ---")
                _section=""; continue ;;
            "# --- FAILED_CF_ACCOUNTS ---")
                _section="CF"; continue ;;
            "# --- END FAILED_CF_ACCOUNTS ---")
                _section=""; continue ;;
        esac

        case "$_section" in
            SUCCESS) CERT_SUCCESS_ROOTS+=("$_line") ;;
            EXISTING) CERT_EXISTING_ROOTS+=("$_line") ;;
            FAILED) CERT_FAILED_ROOTS+=("$_line") ;;
            CF) FAILED_CF_ACCOUNTS+=("$_line") ;;
        esac
    done < "$CF_CERT_STATUS_FILE"

    return 0
}

# ── 汇总展示证书请求结果 ─────────────────────────────────────
show_cert_request_summary() {
    echo ""
    log_info "证书处理结果："

    if [[ ${#CERT_SUCCESS_ROOTS[@]} -gt 0 ]]; then
        echo "  本次申请成功："
        for root_domain in "${CERT_SUCCESS_ROOTS[@]}"; do
            echo "    *.${root_domain}"
        done
    fi

    if [[ ${#CERT_EXISTING_ROOTS[@]} -gt 0 ]]; then
        echo "  已存在并跳过："
        for root_domain in "${CERT_EXISTING_ROOTS[@]}"; do
            echo "    *.${root_domain}"
        done
    fi

    if [[ ${#CERT_FAILED_ROOTS[@]} -gt 0 ]]; then
        echo "  申请失败："
        for root_domain in "${CERT_FAILED_ROOTS[@]}"; do
            echo "    *.${root_domain}"
        done
    fi

    if [[ ${#FAILED_CF_ACCOUNTS[@]} -gt 0 ]]; then
        local -A seen_failed_accounts=()
        echo "  需要检查的 CF 账号（对应 domain ini 文件）："
        for root_domain in "${FAILED_CF_ACCOUNTS[@]}"; do
            [[ -n "${seen_failed_accounts[$root_domain]:-}" ]] && continue
            seen_failed_accounts["$root_domain"]=1
            local _ini_base _ini_file
            _ini_base=$(domain_to_ini_name "$root_domain")
            _ini_file="${CF_CONFIG_DIR}/domain_${_ini_base}.ini"
            echo "    *.${root_domain} → ${_ini_file}"
        done
    fi
}

# ════════════════════════════════════════════════════════════
# 证书申请
# ════════════════════════════════════════════════════════════

# ── 检查已有证书 ─────────────────────────────────────────────
check_existing_certs() {
    log_step "检查已有证书..."

    CERT_EXISTING_ROOTS=()
    local all_exist=true
    local checked_roots=()

    if [[ ${#ALL_DOMAINS[@]} -eq 0 ]]; then
        log_warn "未找到有效域名配置，不能跳过证书申请"
        return 1
    fi

    for domain in "${ALL_DOMAINS[@]}"; do
        local root_domain
        root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

        local already=false
        for r in "${checked_roots[@]}"; do
            [[ "$r" == "$root_domain" ]] && already=true && break
        done
        $already && continue
        checked_roots+=("$root_domain")

        if [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            local expiry
            expiry=$(openssl x509 \
                -enddate -noout \
                -in "/etc/letsencrypt/live/${root_domain}/fullchain.pem" \
                2>/dev/null | cut -d= -f2)
            log_info "证书已存在: *.${root_domain} (到期: ${expiry})"
            CERT_EXISTING_ROOTS+=("$root_domain")
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

    CERT_SUCCESS_ROOTS=()
    CERT_EXISTING_ROOTS=()
    CERT_FAILED_ROOTS=()
    FAILED_CF_ACCOUNTS=()

    declare -gA ROOT_DOMAIN_DONE=()

    for domain in "${ALL_DOMAINS[@]}"; do
        local root_domain
        root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')

        # 同根域名只处理一次（无论成功还是失败）
        if [[ -n "${ROOT_DOMAIN_DONE[$root_domain]:-}" ]]; then
            log_info "*.${root_domain} 已处理，跳过 $domain"
            continue
        fi

        # 直接从 domain ini 文件获取凭证路径，不再依赖任何映射数组
        local ini_file
        ini_file=$(get_domain_ini "$root_domain")

        # 已有证书则跳过
        if [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            log_info "证书已存在，跳过: *.${root_domain}"
            CERT_EXISTING_ROOTS+=("$root_domain")
            ROOT_DOMAIN_DONE["$root_domain"]="existing"
            continue
        fi

        log_info "申请证书: *.${root_domain}"
        log_info "使用凭证: $ini_file"

        local attempt=0 max_attempts=3 certbot_output certbot_rc
        while (( attempt < max_attempts )); do
            ((attempt++))
            log_info "证书申请尝试 ${attempt}/${max_attempts}: *.${root_domain}"

            if certbot_output=$(certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials "$ini_file" \
                --dns-cloudflare-propagation-seconds 30 \
                -d "${root_domain}" \
                -d "*.${root_domain}" \
                --email "admin@${root_domain}" \
                --agree-tos \
                --non-interactive \
                --expand 2>&1); then
                certbot_rc=0
            else
                certbot_rc=$?
            fi

            while IFS= read -r line; do
                echo "  $line"
            done <<< "$certbot_output"

            if [[ $certbot_rc -eq 0 && -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
                log_info "证书申请成功: *.${root_domain} (第 ${attempt} 次尝试)"
                CERT_SUCCESS_ROOTS+=("$root_domain")
                ROOT_DOMAIN_DONE["$root_domain"]="success"
                break
            fi

            # ── 检测 LE 限流 ─────────────────────────────────
            local rate_limit_hint=""
            if echo "$certbot_output" | grep -qi "too many certificates already issued\|rate limit"; then
                rate_limit_hint="Let's Encrypt 限流：该域名本周已申请超过 5 张重复证书，请等待 7 天后重试。"
            elif echo "$certbot_output" | grep -qi "too many failed authorizations\|too many invalid"; then
                rate_limit_hint="Let's Encrypt 限流：一小时内有过多失败验证，已被暂停。请等待 1 小时后重试。"
            elif echo "$certbot_output" | grep -qi "too many registrations\|too many accounts\|too many new orders"; then
                rate_limit_hint="Let's Encrypt 限流：请求频率过高。请等待一段时间后重试。"
            elif echo "$certbot_output" | grep -qi "429"; then
                rate_limit_hint="HTTP 429 检测到限流响应，可能是 Let's Encrypt 或 Cloudflare 触发了频率限制。"
            fi

            if (( attempt >= max_attempts )); then
                log_error "证书申请失败: ${root_domain}（已重试 ${max_attempts} 次）"
                log_warn "certbot 退出码: ${certbot_rc}"
                CERT_FAILED_ROOTS+=("$root_domain")
                FAILED_CF_ACCOUNTS+=("$root_domain")
                ROOT_DOMAIN_DONE["$root_domain"]="failed"
                if [[ -n "$rate_limit_hint" ]]; then
                    log_error "${rate_limit_hint}"
                fi
                log_warn "请检查："
                echo "  1. 域名是否在该CF账号下: ${ini_file}"
                echo "  2. API Token 是否有 Zone:DNS:Edit 权限"
                echo "  3. 域名是否已添加到CF"
                echo "  4. 上面 certbot 输出中的具体报错"
            else
                if [[ -n "$rate_limit_hint" ]]; then
                    log_warn "检测到限流，${rate_limit_hint}"
                fi
                log_warn "证书申请失败（退出码: ${certbot_rc}），60秒后重试..."
                sleep 60
            fi
        done
    done

    save_cert_request_status
    show_cert_request_summary
}

# ── 配置自动续期 ─────────────────────────────────────────────
setup_auto_renew() {
    log_step "配置证书自动续期..."

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy

    cat > /etc/letsencrypt/renewal-hooks/deploy/xray-nginx-deploy-reload.sh << 'HOOK'
#!/bin/bash
# renew hook: reload services to pick up updated LetsEncrypt certs
systemctl reload  nginx    2>/dev/null && echo "nginx reloaded"     || true
systemctl restart xray     2>/dev/null && echo "xray restarted"     || true
systemctl restart sing-box 2>/dev/null && echo "sing-box restarted" || true
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/xray-nginx-deploy-reload.sh

    if certbot_uses_snap; then
        crontab -l 2>/dev/null | grep -v certbot | crontab - || true
        log_info "自动续期配置完成（使用 Snap 自带 timer）"
        log_info "可用 systemctl list-timers | grep certbot 查看续期计划"
    else
        (crontab -l 2>/dev/null | grep -v certbot; \
         echo "0 3 * * * certbot renew --quiet") | crontab -
        log_info "自动续期配置完成（每天凌晨3点检查）"
    fi
}

# ── 域名→文件名转换 ─────────────────────────────────────────
domain_to_ini_name() {
    echo "$1" | tr '.' '_'
}

# ── 扫描所有 CF 账号文件 ─────────────────────────────────────
# 兼容新旧两种格式：<root>.ini（新）+ cf_account_N.ini（旧）
_scan_cf_account_files() {
    local f base
    for f in "${CF_CONFIG_DIR}"/*.ini; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        case "$base" in
            domain_*|cert_request*) ;;
            *) echo "$f" ;;
        esac
    done
}

# ── 判断旧格式账号是否有对应的新格式文件（Token 相同则视为重复）──
_is_old_cf_dup() {
    local ini="$1"
    local bname
    bname=$(basename "$ini" .ini | sed 's/^cf_account_//')
    # 只检查旧编号格式
    [[ "$bname" =~ ^[0-9]+$ ]] || return 1
    local token
    token=$(grep 'dns_cloudflare_api_token' "$ini" 2>/dev/null | cut -d= -f2 | tr -d ' ')
    [[ -z "$token" ]] && return 1
    for other in "${CF_CONFIG_DIR}"/*.ini; do
        [[ -f "$other" ]] || continue
        local obname
        obname=$(basename "$other" .ini | sed 's/^cf_account_//')
        # 跳过旧格式文件和自身
        [[ "$obname" =~ ^[0-9]+$ ]] && continue
        [[ "$other" == "$ini" ]] && continue
        local otoken
        otoken=$(grep 'dns_cloudflare_api_token' "$other" 2>/dev/null | cut -d= -f2 | tr -d ' ')
        [[ "$otoken" == "$token" ]] && return 0
    done
    return 1
}

# ── 过滤旧格式重复文件 ─────────────────────────────────────
_filter_dup_cf_accounts() {
    for f in $(_scan_cf_account_files); do
        _is_old_cf_dup "$f" && continue
        echo "$f"
    done
}

# ── 从 ini 文件提取 token 预览（前8位…后4位）───────────────────
_cf_account_label() {
    local token
    token=$(grep 'dns_cloudflare_api_token' "$1" 2>/dev/null | cut -d= -f2 | tr -d ' ')
    echo "${token:0:8}...${token: -4}"
}

_cf_ini_token() {
    grep 'dns_cloudflare_api_token' "$1" 2>/dev/null | cut -d= -f2 | tr -d ' '
}

_cf_tokens_match() {
    local left="$1" right="$2"
    local left_token right_token
    [[ -f "$left" && -f "$right" ]] || return 1
    left_token=$(_cf_ini_token "$left")
    right_token=$(_cf_ini_token "$right")
    [[ -n "$left_token" && "$left_token" == "$right_token" ]]
}

# ── 新增 Cloudflare 账号 ─────────────────────────────────────
add_cf_account() {
    log_step "新增 Cloudflare 账号"

    mkdir -p "$CF_CONFIG_DIR"
    chmod 700 "$CF_CONFIG_DIR"

    # 显示已有账号
    local existing
    existing=$(_filter_dup_cf_accounts)
    if [[ -n "$existing" ]]; then
        log_info "已有 CF 账号（如需新增请退出后选择选项2）："
        for f in $existing; do
            local label base
            base=$(basename "$f" .ini)
            label=$(_cf_account_label "$f")
            echo "  [${base}] $(basename "$f")  |  ${label}"
        done
        echo ""
    fi

    local cf_root cf_token
    read -rp "该账号管理的根域名（如 zhongning.tk）: " cf_root
    cf_root="${cf_root,,}"
    [[ -z "$cf_root" ]] && { log_error "根域名不能为空"; return 1; }

    local filebase
    filebase=$(domain_to_ini_name "$cf_root")
    local ini_file="${CF_CONFIG_DIR}/${filebase}.ini"

    # 根域名重复检测
    local existing_owner ow
    existing_owner=$(find_root_domain_owner_file "$cf_root" || true)
    if [[ -n "$existing_owner" ]]; then
        log_warn "根域名 ${cf_root} 已关联账号 [$(basename "$existing_owner" .ini)]"
        read -rp "  是否覆盖现有关联？[y/N]: " ow
        if [[ "${ow,,}" != "y" ]]; then
            log_info "已取消，未修改任何文件"
            return 1
        fi
    fi

    if ! prompt_cf_token "请输入 CF API Token" "$cf_root" "$ini_file"; then
        log_error "新增 CF 账号已放弃，未写入任何文件"
        return 1
    fi
    cf_token="$PROMPT_CF_TOKEN_RESULT"

    cat > "$ini_file" << INI
# Cloudflare API Token — ${cf_root}
dns_cloudflare_api_token = ${cf_token}
INI
    chmod 600 "$ini_file"

    rebuild_cf_ini_files
    save_domain_config
    log_info "新账号已保存为 ${filebase}.ini"
}

# ── 根据根域名反查 CF 账号 ───────────────────────────────────
get_cf_account_by_domain() {
    local input_domain="$1"
    local root_domain
    root_domain=$(echo "$input_domain" | awk -F. '{print $(NF-1)"."$NF}')

    local matched_file=""
    local cf_dir="${CF_CONFIG_DIR}"

    # 新格式：直接按根域名查找 <root_with_underscores>.ini
    local filebase
    filebase=$(domain_to_ini_name "$root_domain")
    if [[ -f "${cf_dir}/${filebase}.ini" ]]; then
        echo "${cf_dir}/${filebase}.ini"
        return
    fi

    # 旧格式兼容：扫描 cf_account_*.ini + domain_map.conf 的 CF_ACCOUNT_N 条目
    for ini in "${cf_dir}"/cf_account_*.ini; do
        [[ -f "$ini" ]] || continue
        # 跳过新格式文件（已检查过或非编号文件）
        local bname
        bname=$(basename "$ini" .ini | sed 's/^cf_account_//')
        [[ "$bname" =~ ^[0-9]+$ ]] || continue
        local idx="$bname"
        local mapped_domains
        mapped_domains=$(grep "^CF_ACCOUNT_${idx}=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null \
            | cut -d= -f2- | tr -d "'\"")
        for d in $mapped_domains; do
            local r
            r=$(echo "$d" | awk -F. '{print $(NF-1)"."$NF}')
            if [[ "$r" == "$root_domain" ]]; then
                matched_file="$ini"
                break 2
            fi
        done
    done

    echo "$matched_file"
}

# ── 新增域名并申请证书 ───────────────────────────────────────
add_domain_and_cert() {
    log_step "新增域名并申请证书"

    load_domain_state
    load_domain_config >/dev/null 2>&1 || true

    # 显示当前域名
    echo ""
    log_info "当前已有域名："
    local registry
    registry=$(get_state "DOMAIN_REGISTRY")
    if [[ -n "$registry" ]]; then
        for d in $registry; do
            local suffix mode protos
            suffix=$(echo "$d" | tr '.' '_')
            mode=$(get_state "DOMAIN_MODE_${suffix}")
            protos=$(get_state "DOMAIN_PROTO_${suffix}")
            echo "  $d  [${mode} / ${protos}]"
        done
    else
        echo "  （暂无）"
    fi

    # 循环添加域名
    local new_domains=()

    while true; do
        echo ""
        local domain protocols mode root_domain cf_choice
        local is_existing=false current_mode="" current_protos=""

        read -rp "请输入新域名（留空结束）: " domain
        domain="${domain,,}"
        [[ -z "$domain" ]] && break

        if domain_is_registered "$domain"; then
            local suffix
            suffix=$(echo "$domain" | tr '.' '_')
            current_mode=$(get_state "DOMAIN_MODE_${suffix}" "direct")
            current_protos=$(get_state "DOMAIN_PROTO_${suffix}" "")
            log_warn "域名 $domain 已存在 [mode=$current_mode, proto=$current_protos]"
            local edit_confirm
            read -rp "  是否修改其配置？[y/N]: " edit_confirm
            if [[ "${edit_confirm,,}" != "y" ]]; then
                log_info "已跳过 $domain"
                continue
            fi
            is_existing=true
            log_info "进入编辑模式（协议将追加，mode 可改）"
        fi

        # ── 多选协议 ──
        echo ""
        echo "  请为 $domain 选择协议（多选，空格分隔序号）："
        echo "    1. xray       - VLESS 系列"
        echo "    2. singbox    - AnyTLS"
        echo "    3. hysteria2  - Hysteria2"
        echo "    4. naiveproxy - NaiveProxy"
        echo "    5. nginx      - 独立 Nginx 站点"
        local choices
        read -rp "  输入序号如: 1 3 5: " choices

        protocols=""
        for choice in $choices; do
            case "$choice" in
                1) protocols="${protocols:+$protocols,}xray" ;;
                2) protocols="${protocols:+$protocols,}singbox" ;;
                3) protocols="${protocols:+$protocols,}hysteria2" ;;
                4) protocols="${protocols:+$protocols,}naiveproxy" ;;
                5) protocols="${protocols:+$protocols,}nginx" ;;
                *) log_warn "无效选项: $choice"; ;;
            esac
        done
        [[ -z "$protocols" ]] && { log_warn "未选择协议，跳过"; continue; }

        # ── 连接方式 ──
        local mode_r
        if [[ "$is_existing" == "true" ]]; then
            read -rp "  连接方式 [d=直连, c=CDN，默认保持 ${current_mode}]: " mode_r
        else
            read -rp "  连接方式 [d=直连(默认), c=CDN]: " mode_r
        fi
        case "${mode_r:-${current_mode:-d}}" in
            c|C|cdn|CDN) mode="cdn" ;;
            *)           mode="direct" ;;
        esac

        if [[ "$is_existing" == "true" ]]; then
            protocols=$(merge_domain_protocols "$current_protos" "$protocols")
        else
            # ── 关联 CF 账号（自动匹域名 → 手动选）─────────────
            root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
            local _ini_base _ini_file _matched_ini=() _auto_ini
            _ini_base=$(domain_to_ini_name "$root_domain")
            _ini_file="${CF_CONFIG_DIR}/${_ini_base}.ini"

            if [[ -f "$_ini_file" ]]; then
                # 精确匹配成功
                _auto_ini="$_ini_file"
                log_info "已自动匹配 CF 账号: $(basename "$_auto_ini")"
            else
                # 模糊匹配：扫描所有 ini（排除 domain_ 映射文件），找出包含根域的文件
                for _f in "${CF_CONFIG_DIR}"/*.ini; do
                    [[ -f "$_f" ]] || continue
                    [[ "$(basename "$_f")" == domain_* ]] && continue
                    [[ "$(basename "$_f")" == *"${_ini_base}"* ]] && _matched_ini+=("$_f")
                done

                if [[ ${#_matched_ini[@]} -eq 1 ]]; then
                    _auto_ini="${_matched_ini[0]}"
                    log_info "已自动匹配 CF 账号: $(basename "$_auto_ini")"
                else
                    # 匹配不到或有多于一个候选，展示列表让手动选择
                    echo ""
                    log_info "可用 CF 账号："
                    for _f in "${CF_CONFIG_DIR}"/*.ini; do
                        [[ -f "$_f" ]] || continue
                        [[ "$(basename "$_f")" == domain_* ]] && continue
                        local _lb _b
                        _b=$(basename "$_f" .ini | sed 's/^cf_account_//')
                        _lb=$(_cf_account_label "$_f")
                        echo "  [${_b}] $(basename "$_f")  (token: ${_lb})"
                    done
                    local cf_choice _src_ini
                    read -rp "输入方括号内标识选择 CF 账号: " cf_choice
                    [[ -z "$cf_choice" ]] && { log_error "未选择账号"; return 1; }

                    _src_ini="${CF_CONFIG_DIR}/${cf_choice}.ini"
                    [[ -f "$_src_ini" ]] || _src_ini="${CF_CONFIG_DIR}/cf_account_${cf_choice}.ini"

                    [[ -f "$_src_ini" ]] || {
                        log_error "CF 账号文件不存在: ${_src_ini}"
                        return 1
                    }
                    _auto_ini="$_src_ini"
                fi
            fi

            # 复制到 domain_ 映射文件以供后续证书申请使用
            local _dom_ini_base
            _dom_ini_base=$(domain_to_ini_name "$root_domain")
            cp "$_auto_ini" "${CF_CONFIG_DIR}/domain_${_dom_ini_base}.ini"
            chmod 600 "${CF_CONFIG_DIR}/domain_${_dom_ini_base}.ini"
            sed -i '/^[[:space:]]*dns_cloudflare_email/d' "${CF_CONFIG_DIR}/domain_${_dom_ini_base}.ini"
        fi

        # 注册域名
        register_domain "$domain" "$mode" "$protocols"
        [[ "$is_existing" == "false" ]] && new_domains+=("$domain")
        log_info "已更新: $domain [mode=$mode, proto=$protocols]"

        # ── 继续询问 ──
        local more
        read -rp "继续添加更多域名？[Y/n]: " more
        [[ "${more,,}" == "n" ]] && break
        echo ""
    done

    # 重建并持久化
    rebuild_protocol_domains
    load_domain_state
    save_domain_config

    # ── 为所有新域名申请证书 ────────────────────────────────
    for domain in "${new_domains[@]}"; do
        local root_domain
        root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
        log_info "申请证书: *.${root_domain}"

        local _ini_base
        _ini_base=$(domain_to_ini_name "$root_domain")
        local ini_file="${CF_CONFIG_DIR}/domain_${_ini_base}.ini"
        local certbot_output certbot_rc

        if [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            log_info "证书已存在，跳过申请: *.${root_domain}"
            continue
        fi

        if certbot_output=$(certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$ini_file" \
            --dns-cloudflare-propagation-seconds 30 \
            -d "${root_domain}" \
            -d "*.${root_domain}" \
            --email "admin@${root_domain}" \
            --agree-tos \
            --non-interactive \
            --expand 2>&1); then
            certbot_rc=0
        else
            certbot_rc=$?
        fi

        if [[ $certbot_rc -eq 0 && -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
            log_info "证书申请成功: *.${root_domain}"
        else
            log_error "证书申请失败（退出码: ${certbot_rc}）"
            while IFS= read -r line; do echo "  $line"; done <<< "$certbot_output"
            log_warn "请检查域名 DNS 解析和 CF API Token 权限"
        fi
    done

    # 自动配置续期
    setup_auto_renew

    log_info "域名添加完成: ${#new_domains[@]} 个"
}

refresh_domain_assignments() {
    log_step "刷新域名协议分配"

    load_domain_state
    load_domain_config >/dev/null 2>&1 || true

    local domain
    for domain in "${ALL_DOMAINS[@]:-}"; do
        [[ -z "$domain" ]] && continue
        local suffix mode protocols
        suffix=$(echo "$domain" | tr '.' '_')
        mode=$(get_state "DOMAIN_MODE_${suffix}" "")
        protocols=$(get_state "DOMAIN_PROTO_${suffix}" "")
        if [[ -z "$mode" ]]; then
            [[ " ${CDN_DOMAINS[*]:-} " == *" ${domain} "* ]] && mode="cdn" || mode="direct"
        fi
        [[ -n "$protocols" ]] && register_domain "$domain" "$mode" "$protocols"
    done

    [[ -n "${XHTTP_DOMAIN:-}" ]] && register_domain "$XHTTP_DOMAIN" "cdn" "xray"
    [[ -n "${GRPC_DOMAIN:-}" && "${GRPC_DOMAIN}" != "${XHTTP_DOMAIN:-}" ]] && register_domain "$GRPC_DOMAIN" "cdn" "xray"
    [[ -n "${REALITY_DOMAIN:-}" ]] && register_domain "$REALITY_DOMAIN" "direct" "xray"
    [[ -n "${ANYTLS_DOMAIN:-}" ]] && register_domain "$ANYTLS_DOMAIN" "direct" "singbox"
    [[ -n "${NAIVE_DOMAIN:-}" ]] && register_domain "$NAIVE_DOMAIN" "direct" "naiveproxy"
    [[ -n "${HYSTERIA2_DOMAIN:-}" ]] && register_domain "$HYSTERIA2_DOMAIN" "direct" "hysteria2"

    rebuild_protocol_domains
    load_domain_state

    if [[ -z "${HYSTERIA2_DOMAIN:-}" ]]; then
        local registry
        registry=$(get_state "DOMAIN_REGISTRY")
        if [[ -n "$registry" ]]; then
            echo ""
            log_warn "HYSTERIA2_DOMAIN 仍为空，可从已有域名追加 hysteria2 协议"
            for domain in $registry; do
                local suffix mode protos
                suffix=$(echo "$domain" | tr '.' '_')
                mode=$(get_state "DOMAIN_MODE_${suffix}" "direct")
                protos=$(get_state "DOMAIN_PROTO_${suffix}" "")
                printf "  %-30s [%s / %s]\n" "$domain" "$mode" "$protos"
            done
            echo ""
            local hy_domain
            read -rp "输入要分配给 Hysteria2 的已有域名（留空跳过）: " hy_domain
            hy_domain="${hy_domain,,}"
            if [[ -n "$hy_domain" ]]; then
                if domain_is_registered "$hy_domain"; then
                    local hy_suffix hy_mode
                    hy_suffix=$(echo "$hy_domain" | tr '.' '_')
                    hy_mode=$(get_state "DOMAIN_MODE_${hy_suffix}" "direct")
                    if register_domain "$hy_domain" "$hy_mode" "hysteria2"; then
                        rebuild_protocol_domains
                        load_domain_state
                        log_info "已将 ${hy_domain} 分配给 Hysteria2"
                    else
                        log_error "Hysteria2 域名分配失败，请检查 ${STATE_FILE}"
                        return 1
                    fi
                else
                    log_error "域名 ${hy_domain} 不在 DOMAIN_REGISTRY 中，请先添加域名"
                fi
            fi
        fi
    fi

    save_domain_config

    echo ""
    log_info "刷新后的域名分配："
    local registry
    registry=$(get_state "DOMAIN_REGISTRY")
    if [[ -n "$registry" ]]; then
        for domain in $registry; do
            local suffix mode protos
            suffix=$(echo "$domain" | tr '.' '_')
            mode=$(get_state "DOMAIN_MODE_${suffix}" "direct")
            protos=$(get_state "DOMAIN_PROTO_${suffix}" "")
            printf "  %-30s [%s / %s]\n" "$domain" "$mode" "$protos"
        done
    else
        echo "  （暂无）"
    fi

    log_info "HYSTERIA2_DOMAIN=${HYSTERIA2_DOMAIN:-}"
    log_info "NAIVE_DOMAIN=${NAIVE_DOMAIN:-}"
}

# ── 迁移旧 cf_account_N.ini 到域名命名格式 ──────────────────
migrate_cf_account_files() {
    local cf_dir="${CF_CONFIG_DIR}"
    local -a old_files=()
    local -A auto_root=()
    local -A ini_token=()
    local -A ini_email=()

    mkdir -p "$cf_dir"
    chmod 700 "$cf_dir"
    touch "$CF_DOMAIN_MAP_FILE"
    chmod 600 "$CF_DOMAIN_MAP_FILE"

    # ── 第一遍：收集所有待迁移文件，尝试自动识别域名 ────────
    for ini in "${cf_dir}"/cf_account_*.ini; do
        [[ -f "$ini" ]] || continue
        local bname
        bname=$(basename "$ini" .ini | sed 's/^cf_account_//')

        # 只处理旧编号格式（纯数字）
        [[ "$bname" =~ ^[0-9]+$ ]] || continue

        # 已迁移过则跳过
        grep -q "^CF_ACCOUNT_${bname}=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null && continue
        if grep -q "^CF_INI_.*=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null; then
            local mapped_dup=false
            for mapped_ini in "${cf_dir}"/*.ini; do
                [[ -f "$mapped_ini" ]] || continue
                local mapped_bname
                mapped_bname=$(basename "$mapped_ini" .ini | sed 's/^cf_account_//')
                [[ "$mapped_bname" =~ ^[0-9]+$ ]] && continue
                _cf_tokens_match "$ini" "$mapped_ini" && mapped_dup=true && break
            done
            $mapped_dup && continue
        fi
        grep -q "^CF_INI_.*=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null && {
            # 检查是否有新格式文件已存在（token 内容相同）
            local already=false
            for dn in $(_scan_cf_account_files); do
                local dn_bname
                dn_bname=$(basename "$dn" .ini | sed 's/^cf_account_//')
                [[ "$dn_bname" =~ ^[0-9]+$ ]] && continue
                if _cf_tokens_match "$ini" "$dn"; then
                    already=true && break
                fi
            done
            $already && continue
        }

        # 缓存 token 和 email
        ini_token["$ini"]=$(grep 'dns_cloudflare_api_token' "$ini" 2>/dev/null | cut -d= -f2 | tr -d ' ')
        ini_email["$ini"]=$(grep 'dns_cloudflare_email' "$ini" 2>/dev/null | cut -d= -f2 | tr -d ' ')

        # ── 自动从 Let's Encrypt renewal conf 反查域名 ─────
        local auto_found=""
        local ini_path
        ini_path=$(realpath "$ini" 2>/dev/null || echo "$ini")

        for renew_conf in /etc/letsencrypt/renewal/*.conf; do
            [[ -f "$renew_conf" ]] || continue
            # 检查 renewal conf 里是否引用了本 ini 文件
            local cred_line
            cred_line=$(grep 'dns_cloudflare_credentials' "$renew_conf" 2>/dev/null | head -1)
            [[ -z "$cred_line" ]] && continue
            local cred_path
            cred_path=$(echo "$cred_line" | sed 's/.*=\s*//' | tr -d ' ')

            # 匹配：直接引用旧编号文件，或引用 domain_<root>.ini 且 token 相同
            if [[ "$cred_path" == "$ini_path" || "$cred_path" == *"cf_account_${bname}.ini" ]]; then
                auto_found=$(basename "$renew_conf" .conf)
                break
            fi
        done

        # renewal 里没找到，尝试通过 domain_*.ini + token 匹配
        if [[ -z "$auto_found" ]]; then
            for dom_ini in "${cf_dir}"/domain_*.ini; do
                [[ -f "$dom_ini" ]] || continue
                local dom_token
                dom_token=$(grep 'dns_cloudflare_api_token' "$dom_ini" 2>/dev/null | cut -d= -f2 | tr -d ' ')
                if [[ -n "$dom_token" && "$dom_token" == "${ini_token[$ini]}" ]]; then
                    auto_found=$(basename "$dom_ini" .ini | sed 's/^domain_//')
                    break
                fi
            done
        fi

        if [[ -n "$auto_found" ]]; then
            auto_root["$ini"]="$auto_found"

            local auto_base auto_ini
            auto_base=$(domain_to_ini_name "$auto_found")
            auto_ini="${cf_dir}/${auto_base}.ini"
            if [[ -f "$auto_ini" ]] && _cf_tokens_match "$ini" "$auto_ini"; then
                grep -q "^CF_ACCOUNT_${bname}=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null || \
                    echo "CF_ACCOUNT_${bname}='${auto_found}'" >> "${CF_DOMAIN_MAP_FILE}"
                grep -q "^CF_INI_${auto_base}=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null || \
                    echo "CF_INI_${auto_base}='${auto_base}'" >> "${CF_DOMAIN_MAP_FILE}"
                continue
            fi
        fi

        old_files+=("$ini")
    done

    # ── 没有待迁移文件则直接返回 ──────────────────────────
    [[ ${#old_files[@]} -eq 0 ]] && return 0 || true

    # ── 显示迁移计划 ──────────────────────────────────────
    echo ""
    log_info "检测到旧格式账号文件，自动分析对应域名："
    for ini in "${old_files[@]}"; do
        local bname label
        bname=$(basename "$ini" .ini | sed 's/^cf_account_//')
        if [[ -n "${auto_root[$ini]:-}" ]]; then
            label="发现证书：${auto_root[$ini]}（覆盖 *.${auto_root[$ini]}）→ 将重命名为 $(domain_to_ini_name "${auto_root[$ini]}").ini"
        else
            label="未找到对应证书，需手动输入"
        fi
        echo "  cf_account_${bname}.ini → ${label}"
    done

    # ── 确认 ──────────────────────────────────────────────
    echo ""
    local confirm_migrate
    read -rp "确认迁移？[Y/n]: " confirm_migrate
    [[ "${confirm_migrate,,}" == "n" ]] && { log_info "跳过迁移"; return 0; }

    # ── 第二遍：执行迁移 ──────────────────────────────────
    local migrated=0
    for ini in "${old_files[@]}"; do
        local bname cf_root
        bname=$(basename "$ini" .ini | sed 's/^cf_account_//')
        cf_root="${auto_root[$ini]:-}"

        # 自动识别失败则回退到手动输入
        if [[ -z "$cf_root" ]]; then
            local cf_email cf_token token_preview
            cf_email="${ini_email[$ini]}"
            cf_token="${ini_token[$ini]}"
            token_preview="${cf_token:0:12}"
            echo ""
            log_info "cf_account_${bname}.ini 未找到对应证书，请手动输入："
            [[ -n "$cf_email" ]] && echo "  邮箱: ${cf_email}" || true
            echo "  Token: ${token_preview}..."
            read -rp "  该账号管理的根域名是什么？（如 zhongning.tk）: " cf_root
            cf_root="${cf_root,,}"
            [[ -z "$cf_root" ]] && { log_warn "跳过迁移 cf_account_${bname}.ini（未输入域名）"; continue; }
        fi

        local new_base
        new_base=$(domain_to_ini_name "$cf_root")
        local new_ini="${cf_dir}/${new_base}.ini"

        if [[ -f "$new_ini" ]] && _cf_tokens_match "$ini" "$new_ini"; then
            grep -q "^CF_ACCOUNT_${bname}=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null || \
                echo "CF_ACCOUNT_${bname}='${cf_root}'" >> "${CF_DOMAIN_MAP_FILE}"
            grep -q "^CF_INI_${new_base}=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null || \
                echo "CF_INI_${new_base}='${new_base}'" >> "${CF_DOMAIN_MAP_FILE}"
            log_info "已存在 ${new_base}.ini，跳过旧账号迁移提示"
            continue
        fi

        cp "$ini" "$new_ini"
        # 旧格式可能有 email 字段，Token 认证不需要，过滤掉
        sed -i '/^[[:space:]]*dns_cloudflare_email/d' "$new_ini"
        chmod 600 "$new_ini"

        grep -q "^CF_ACCOUNT_${bname}=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null || \
            echo "CF_ACCOUNT_${bname}='${cf_root}'" >> "${CF_DOMAIN_MAP_FILE}"
        grep -q "^CF_INI_${new_base}=" "${CF_DOMAIN_MAP_FILE}" 2>/dev/null || \
            echo "CF_INI_${new_base}='${new_base}'"  >> "${CF_DOMAIN_MAP_FILE}"

        log_info "已将 cf_account_${bname}.ini 迁移为 ${new_base}.ini（旧文件保留）"
        (( migrated++ )) || true
    done

    [[ $migrated -gt 0 ]] && log_info "迁移完成，共处理 ${migrated} 个旧账号文件" || true
}

# ── 模块入口 ─────────────────────────────────────────────────
run_cert() {
    set +e
    trap "set -e" RETURN
    log_step "========== SSL 证书申请 =========="

    # 自动迁移旧格式 CF 账号文件
    migrate_cf_account_files

    # 子菜单
    echo ""
    echo "  请选择操作："
    echo "  1. 首次完整配置（CF账号 + 域名 + 申请证书）"
    echo "  2. 新增 Cloudflare 账号"
    echo "  3. 新增域名并申请证书（复用已有CF账号）"
    echo "  4. 仅补申请证书（域名已配置）"
    echo "  5. 检查/更新 Certbot 及 DNS 插件"
    echo "  6. 刷新/修复域名协议分配"
    echo ""
    read -rp "  请选择 [1-6，默认1]: " cert_choice
    cert_choice="${cert_choice:-1}"

    case "$cert_choice" in
        2)
            install_certbot
            add_cf_account
            log_info "新增 CF 账号完成，继续添加域名..."
            add_domain_and_cert
            log_info "重新生成 Nginx 配置..."
            do_conf_nginx 2>/dev/null || {
                log_warn "Nginx 配置生成失败，请手动执行步骤 9"
            }
            return
            ;;
        3)
            install_certbot
            add_domain_and_cert
            log_info "========== 新增域名完成 =========="
            do_conf_nginx 2>/dev/null || {
                log_warn "Nginx 配置生成失败，请手动执行步骤 9"
            }
            return
            ;;
        5)
            update_certbot_deps
            return
            ;;
        6)
            refresh_domain_assignments
            return
            ;;
        4)
            install_certbot
            # 从 state 恢复域名（domain_map.conf 可能不存在或过期）
            XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
            GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
            REALITY_DOMAIN=$(get_state "REALITY_DOMAIN")
            ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
            NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")
            HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
            ALL_DOMAINS=(); CDN_DOMAINS=(); DIRECT_DOMAINS=()
            local _all _cdn _direct
            _all=$(get_state "ALL_DOMAINS")
            _cdn=$(get_state "CDN_DOMAINS")
            _direct=$(get_state "DIRECT_DOMAINS")
            [[ -n "$_all"    ]] && read -ra ALL_DOMAINS    <<< "$_all"
            [[ -n "$_cdn"    ]] && read -ra CDN_DOMAINS    <<< "$_cdn"
            [[ -n "$_direct" ]] && read -ra DIRECT_DOMAINS <<< "$_direct"
            if [[ ${#ALL_DOMAINS[@]} -eq 0 ]]; then
                log_error "未找到域名配置，请先执行首次完整配置"
                return 1
            fi
            request_certificates
            setup_auto_renew
            log_info "========== 证书申请完成 =========="
            return
            ;;
        1|*)
            ;;
    esac

    # ── 选项 1（默认）：首次完整配置 ──

    # 1. 安装 certbot
    install_certbot

    # 2. 配置 CF 账号
    setup_cf_accounts

    # 3. 收集域名信息（同时写入 domain_<root>.ini 映射文件）
    collect_domains

    # 4. 检查已有证书，有则跳过申请
    if check_existing_certs; then
        log_info "所有域名证书已存在，跳过申请"
        CERT_SUCCESS_ROOTS=()
        CERT_FAILED_ROOTS=()
        FAILED_CF_ACCOUNTS=()
        save_cert_request_status
        show_cert_request_summary
    else
        request_certificates
    fi

    # 5. 配置自动续期
    setup_auto_renew

    log_info "========== SSL 证书模块完成 =========="
    echo ""
    log_info "Cert path (Let's Encrypt default):"
    echo "  fullchain: /etc/letsencrypt/live/<root-domain>/fullchain.pem"
    echo "  privkey:   /etc/letsencrypt/live/<root-domain>/privkey.pem"
    echo ""
    log_info "账号映射文件（可随时查看/手动修改）："
    list_domain_ini_files | while read -r f; do echo "  $f"; done
    set -e
}
