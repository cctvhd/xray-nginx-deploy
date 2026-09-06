#!/usr/bin/env bash
# ============================================================
# modules/xray.sh
# Xray 安装 + 三协议配置生成
# warp 出站：内嵌 wireguard（由 warp.sh 提供凭证），不依赖本地 SOCKS5
# ============================================================

# ── 安装 Xray（官方脚本，稳定版）────────────────────────────
install_xray() {
    log_step "安装 Xray（官方脚本）..."

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    if ! command -v xray &>/dev/null; then
        log_error "Xray 安装失败"
        exit 1
    fi

    local xray_ver
    xray_ver=$(xray version 2>&1 | grep -oP '[\d.]+' | head -1)
    log_info "Xray 安装成功: v${xray_ver}"

    mkdir -p /var/log/xray
    chmod 755 /var/log/xray
}

# ── 配置 Xray systemd 资源限制 ──────────────────────────────
configure_xray_service_limits() {
    local xray_nofile="${GLOBAL_NOFILE_LIMIT:-1048576}"

    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/99-xray-limits.conf << LIMITS
[Service]
LimitNOFILE=${xray_nofile}
LIMITS

    systemctl daemon-reload >/dev/null 2>&1 || true
    log_info "Xray systemd nofile 限制: ${xray_nofile}"
}

# ── 生成随机参数 ─────────────────────────────────────────────
generate_xray_params() {
    log_step "生成 Xray 随机参数..."
    local saved_uuid
    saved_uuid=$(get_state "XRAY_UUID" "")
    if [[ -n "${saved_uuid}" ]]; then
        XRAY_UUID="${saved_uuid}"
        log_info "复用已有 UUID: ${XRAY_UUID}"
    else
        XRAY_UUID=$(xray uuid)
        log_info "生成新 UUID: ${XRAY_UUID}"
    fi

    local saved_privkey saved_pubkey
    saved_privkey=$(get_state "XRAY_PRIVATE_KEY" "")
    saved_pubkey=$(get_state "XRAY_PUBLIC_KEY" "")
    if [[ -n "${saved_privkey}" ]]; then
        XRAY_PRIVATE_KEY="${saved_privkey}"
        if [[ -n "${saved_pubkey}" ]]; then
            XRAY_PUBLIC_KEY="${saved_pubkey}"
        else
            local keypair
            keypair=$(xray x25519 -i "$XRAY_PRIVATE_KEY" 2>/dev/null)
            XRAY_PUBLIC_KEY=$(echo "$keypair" | grep -i "public\|password" | awk '{print $NF}')
            log_warn "从私钥重新推导公钥"
        fi
        log_info "复用已有密钥对"
    else
        local keypair
        keypair=$(xray x25519)
        XRAY_PRIVATE_KEY=$(echo "$keypair" | grep -i "private" | awk '{print $NF}')
        XRAY_PUBLIC_KEY=$(echo "$keypair" | grep -i "public\|password" | awk '{print $NF}')
        log_info "生成新密钥对"
    fi

    # vless-xhttp-reality（8325）独立密钥对：与 vless-reality（reality-direct，8320）隔离，
    # 避免两个 Reality 入站复用同一次 x25519 结果，导致两个伪装身份可被关联。
    local saved_xhr_privkey saved_xhr_pubkey
    saved_xhr_privkey=$(get_state "XHTTP_REALITY_PRIVATE_KEY" "")
    saved_xhr_pubkey=$(get_state "XHTTP_REALITY_PUBLIC_KEY" "")
    if [[ -n "${saved_xhr_privkey}" ]]; then
        XHTTP_REALITY_PRIVATE_KEY="${saved_xhr_privkey}"
        if [[ -n "${saved_xhr_pubkey}" ]]; then
            XHTTP_REALITY_PUBLIC_KEY="${saved_xhr_pubkey}"
        else
            local xhr_keypair
            xhr_keypair=$(xray x25519 -i "$XHTTP_REALITY_PRIVATE_KEY" 2>/dev/null)
            XHTTP_REALITY_PUBLIC_KEY=$(echo "$xhr_keypair" | grep -i "public\|password" | awk '{print $NF}')
            log_warn "从私钥重新推导 vless-xhttp-reality 公钥"
        fi
        log_info "复用已有 vless-xhttp-reality 密钥对"
    else
        local xhr_keypair
        xhr_keypair=$(xray x25519)
        XHTTP_REALITY_PRIVATE_KEY=$(echo "$xhr_keypair" | grep -i "private" | awk '{print $NF}')
        XHTTP_REALITY_PUBLIC_KEY=$(echo "$xhr_keypair" | grep -i "public\|password" | awk '{print $NF}')
        log_info "生成新 vless-xhttp-reality 密钥对"
    fi

    # ── VLESS Encryption（ML-KEM-768 后量子认证，用于 CDN 入站端到端加密）──
    local saved_enc_seed
    saved_enc_seed=$(get_state "VLESS_ENC_SEED" "")
    if ! xray mlkem768 &>/dev/null; then
        VLESS_ENC_SEED=""
        VLESS_ENC_CLIENT=""
        log_warn "当前 Xray 内核不支持 mlkem768，CDN 入站 VLESS Encryption 已禁用（decryption=none）"
    elif [[ -n "${saved_enc_seed}" ]]; then
        VLESS_ENC_SEED="${saved_enc_seed}"
        VLESS_ENC_CLIENT=$(get_state "VLESS_ENC_CLIENT" "")
        if [[ -z "${VLESS_ENC_CLIENT}" ]]; then
            VLESS_ENC_CLIENT=$(xray mlkem768 -i "${VLESS_ENC_SEED}" | grep -i "client" | awk '{print $NF}')
            save_state "VLESS_ENC_CLIENT" "${VLESS_ENC_CLIENT}"
            log_warn "从 Seed 重新推导 ML-KEM-768 Client"
        fi
        log_info "复用已有 VLESS Encryption 密钥"
    else
        local mlkem_out
        mlkem_out=$(xray mlkem768)
        VLESS_ENC_SEED=$(echo "$mlkem_out" | grep -i "seed" | awk '{print $NF}')
        VLESS_ENC_CLIENT=$(echo "$mlkem_out" | grep -i "client" | awk '{print $NF}')
        # 与 XHTTP_PATH 同理：立即写入 state，保证 client.sh 等
        # 后续步骤无论执行顺序都能读到同一份密钥
        save_state "VLESS_ENC_SEED"   "${VLESS_ENC_SEED}"
        save_state "VLESS_ENC_CLIENT" "${VLESS_ENC_CLIENT}"
        log_info "生成新 VLESS Encryption 密钥（ML-KEM-768）"
    fi

    local saved_path
    saved_path=$(get_state "XHTTP_PATH" "")
    if [[ -n "${saved_path}" ]]; then
        XHTTP_PATH="${saved_path}"
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    else
        XHTTP_PATH="/$(tr -d '-' < /proc/sys/kernel/random/uuid)"
        # ── BUG FIX：生成新路径后立即写入 config.env ──────────
        # 原代码只赋值给 shell 变量，install.sh 在步骤8结束后才
        # save_state，如果步骤7（nginx）在步骤8之前执行，nginx
        # 读不到这个路径，导致两边 XHTTP_PATH 不一致。
        # 立即保存后，无论步骤7/8的执行顺序如何，双方都能读到
        # 同一个路径。
        save_state "XHTTP_PATH" "${XHTTP_PATH}"
        log_info "生成新 XHTTP_PATH: ${XHTTP_PATH}"
    fi

    local saved_short_ids
    saved_short_ids=$(get_state "REALITY_SHORT_IDS" "")
    REALITY_SHORT_IDS=()
    if [[ -n "${saved_short_ids}" ]]; then
        local _raw_ids _sid
        read -ra _raw_ids <<< "$saved_short_ids"
        for _sid in "${_raw_ids[@]}"; do
            [[ -n "$_sid" ]] && REALITY_SHORT_IDS+=("$_sid")
        done
        if (( ${#REALITY_SHORT_IDS[@]} > 0 )); then
            log_info "复用已有 Short IDs (${#REALITY_SHORT_IDS[@]} 个)"
        fi
    fi
    if (( ${#REALITY_SHORT_IDS[@]} == 0 )); then
        REALITY_SHORT_IDS=(
            "$(openssl rand -hex 4)"
            "$(openssl rand -hex 4)"
            "$(openssl rand -hex 4)"
            "$(openssl rand -hex 6)"
            "$(openssl rand -hex 8)"
        )
        log_info "生成新 Short IDs"
    fi

    REALITY_SPIDER_X="/api/health"

    log_info "UUID:        ${XRAY_UUID}"
    log_info "公钥:        ${XRAY_PUBLIC_KEY}"
    log_info "xhttp path:  ${XHTTP_PATH}"
}

# ── 探测伪装域名可用路径（用于 Reality spiderX）─────────────────
# 用法: detect_spider_path <domain>
# 依次测试常见路径，echo 第一个返回 200 的路径并返回 0；全部失败返回 1
detect_spider_path() {
    local domain="$1"
    local path code
    for path in / /index.html /favicon.ico /robots.txt /sitemap.xml; do
        code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://${domain}${path}")
        if [[ "$code" == "200" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# ── Reality 节点：自建域名 → 公共 SNI 模式切换 ──────────────
# 用户在向导内已明确选择"公共 SNI"。本函数从该自有域名上摘除指定的 reality
# 标签（默认 xray-reality；xhttp-reality 场景传第二参）并重推派生，令对应
# *_DOMAIN 置空，使后续生成严格遵循用户刚选的第三方 SNI，不被自有域名静默覆盖。
#   · 域名若还带其它协议标签（另一 reality 标签 / naive / hysteria2 等）→ 仅摘指定标签，保留其余
#   · 域名从此无任何标签 → 从 DOMAIN_REGISTRY 移除（不询问删 ini/证书，同编辑器语义）
# 用法: reality_untag_self_domain <domain> [tag]
reality_untag_self_domain() {
    local domain="$1"
    local tag="${2:-xray-reality}"
    local suffix mode protos new_protos="" new_mode d pl
    suffix=$(printf '%s' "$domain" | tr '.' '_')

    # cert 模块例程可能未加载（配置菜单可能仅载 xray/nginx）；按需补齐
    if ! declare -F _derive_mode_from_protocols >/dev/null 2>&1; then
        declare -F load_module >/dev/null 2>&1 && load_module cert >/dev/null 2>&1 || true
    fi

    mode=$(get_state "DOMAIN_MODE_${suffix}" "")
    protos=$(get_state "DOMAIN_PROTO_${suffix}" "")

    # 摘除指定 reality token，保留其余协议
    if [[ -n "$protos" ]]; then
        local -a _keep=() _pl=()
        IFS=',' read -ra _pl <<< "$protos"
        for pl in "${_pl[@]}"; do
            [[ -n "$pl" && "$pl" != "$tag" ]] && _keep+=("$pl")
        done
        for pl in "${_keep[@]}"; do
            new_protos="${new_protos:+$new_protos,}$pl"
        done
    fi

    if [[ -z "$new_protos" ]]; then
        # 无任何剩余协议 → 从注册表移除（保留 ini/证书，同 _editor_delete_domain 前半）
        log_info "域名 ${domain} 已无协议角色，从注册表移除"
        local registry new_reg=""
        registry=$(get_state "DOMAIN_REGISTRY" "")
        for d in $registry; do
            [[ "$d" == "$domain" ]] && continue
            new_reg="${new_reg:+$new_reg }$d"
        done
        save_state "DOMAIN_REGISTRY" "$new_reg"
        save_state "DOMAIN_MODE_${suffix}"  ""
        save_state "DOMAIN_PROTO_${suffix}" ""
    else
        # 剩余协议决定连接方式（编辑器语义：mode 由协议重推）
        if declare -F _derive_mode_from_protocols >/dev/null 2>&1; then
            new_mode=$(_derive_mode_from_protocols "$new_protos")
        else
            new_mode="${mode:-direct}"
        fi
        save_state "DOMAIN_MODE_${suffix}"  "$new_mode"
        save_state "DOMAIN_PROTO_${suffix}" "$new_protos"
        log_info "已摘除 ${domain} 的 ${tag} 标签，保留其余协议: ${new_protos} [${new_mode}]"
    fi

    # 重推派生：对应 DOMAIN_PRIMARY_<SLOT> 与 *_DOMAIN 由 rebuild 按剩余候选重算
    declare -F rebuild_protocol_domains >/dev/null 2>&1 && rebuild_protocol_domains
    declare -F load_domain_state >/dev/null 2>&1 && load_domain_state
    # 镜像同步到 /etc/cloudflare/domain_map.conf（防旧值残留导致下次启动自愈回填）
    declare -F save_domain_config >/dev/null 2>&1 && save_domain_config
    log_info "${tag} 节点已切换为公共 SNI 模式（自建域名已摘除）"
}

# ── Reality 节点：注册一个「自有域名」（公共 SNI → 自建域名模式）──
# 自建域名的唯一持久化通道 = DOMAIN_REGISTRY：本函数把 <tag> 标签 merge 到
# 该域名并显式设 DOMAIN_PRIMARY_<SLOT>=domain，再 rebuild 派生对应 *_DOMAIN，
# 与 reality_untag_self_domain() 完全对称（根治"collect 改了 shell 值却未入册，
# 域名管理菜单看不到占用"的旧缺陷）。
# 用法: reality_tag_self_domain <domain> <tag>   # tag ∈ {xray-reality, xhttp-reality}
# 约束（任一不满足 → 返回 1，不改 state）：
#   · tag=xhttp-reality 时，domain 不得 == REALITY_DOMAIN 且不得已带 xray-reality 标签
#     （两 reality 节点 SNI 互斥，generate_sni_map 会静默丢 8325）
#   · tag=xray-reality  时，domain 不得 == XHTTP_REALITY_DOMAIN 且不得已带 xhttp-reality 标签
#   · domain 不得携带 CDN 业务标签（xray-xhttp / xray-grpc）——那是步骤 5 的 CDN 域
reality_tag_self_domain() {
    local domain="$1" tag="$2"
    [[ -n "$domain" && -n "$tag" ]] || return 1

    # cert 模块例程可能未加载（配置菜单可能仅载 xray/nginx）；按需补齐
    if ! declare -F _derive_mode_from_protocols >/dev/null 2>&1; then
        declare -F load_module >/dev/null 2>&1 && load_module cert >/dev/null 2>&1 || true
    fi

    local suffix existing
    suffix=$(printf '%s' "$domain" | tr '.' '_')
    existing=$(get_state "DOMAIN_PROTO_${suffix}" "")

    # SNI 互斥约束：xhttp-reality 认领时不得踩中 vless 已占域或同域已挂另一 reality 标签
    if [[ "$tag" == "xhttp-reality" ]]; then
        if [[ -n "${REALITY_DOMAIN:-}" && "$domain" == "$REALITY_DOMAIN" ]]; then
            log_warn "拒绝：${domain} 已是 vless-reality 的自建域名（REALITY_DOMAIN），两节点 SNI 不能共用"
            return 1
        fi
        case ",${existing}," in
            *,xray-reality,*)
                log_warn "拒绝：${domain} 已带 xray-reality 标签，xhttp-reality 需独占一个不含该标签的直连域"
                return 1 ;;
        esac
    else
        if [[ -n "${XHTTP_REALITY_DOMAIN:-}" && "$domain" == "$XHTTP_REALITY_DOMAIN" ]]; then
            log_warn "拒绝：${domain} 已是 xhttp-reality 的自建域名（XHTTP_REALITY_DOMAIN），两节点 SNI 不能共用"
            return 1
        fi
        case ",${existing}," in
            *,xhttp-reality,*)
                log_warn "拒绝：${domain} 已带 xhttp-reality 标签，vless-reality 需独占一个不含该标签的直连域"
                return 1 ;;
        esac
    fi
    # CDN 业务域（xhttp/grpc）不允许被 reality 认领自建（模式与 SNI 语义都不符）
    case ",${existing}," in
        *,xray-xhttp,*|*,xray-grpc,*)
            log_warn "拒绝：${domain} 是 CDN 业务域（xray-xhttp/xray-grpc），不能作为 reality 自建域"
            return 1 ;;
    esac

    # 1) merge 标签入册；mode 由合并后的协议重推
    local mode
    if declare -F _derive_mode_from_protocols >/dev/null 2>&1 && [[ -n "$existing" ]]; then
        mode=$(_derive_mode_from_protocols "${existing},${tag}")
    else
        mode="direct"
    fi
    if ! declare -F register_domain >/dev/null 2>&1; then
        log_error "register_domain() 不可用（需在 install.sh 上下文中运行）"
        return 1
    fi
    register_domain "$domain" "$mode" "$tag" || return 1

    # 2) 显式设主域（多候选时也确定落到本次所选），重建派生
    local slot_upper
    slot_upper="${tag^^}"; slot_upper="${slot_upper//-/_}"
    save_state "DOMAIN_PRIMARY_${slot_upper}" "$domain"

    # 3) 确保该域有 CF 账号映射：入册域名若从未经步骤 5 编辑器关联账号
    #    （如直接以新域名调用本函数），在此补齐，证书流程才能覆盖签发。
    #    已关联的域 _collect_domain_cf 内部经 has_domain_ini 早退，无副作用。
    if ! declare -F _collect_domain_cf >/dev/null 2>&1; then
        declare -F load_module >/dev/null 2>&1 && load_module cert >/dev/null 2>&1 || true
    fi
    declare -F _collect_domain_cf >/dev/null 2>&1 && _collect_domain_cf "$domain"

    # 4) rebuild 派生 + 镜像到 domain_map.conf
    declare -F rebuild_protocol_domains >/dev/null 2>&1 && rebuild_protocol_domains
    declare -F load_domain_state >/dev/null 2>&1 && load_domain_state
    declare -F save_domain_config >/dev/null 2>&1 && save_domain_config
    log_info "${tag} 已绑定自建域名 ${domain}（SNI=${domain}，dest→本地伪装站）"
    return 0
}


# ── 收集 Reality 伪装参数（先问模式，再按需弹列表）─────────────────
# 设计(2026-09-06 重排)：
#   1. vless-reality 与 vless-xhttp-reality 各自先问「自有域名 / 公共 SNI」，
#      顺序完全对称，不再依赖外部标签或列表时序隐式触发。
#   2. 地区 + 伪装目标列表仅当「至少一个协议选了公共 SNI」才弹出；
#      两协议都走自有域名时直接跳过（原实现会白问一遍再被收敛覆盖）。
#   3. 列表只弹一次、按需分配：两协议都用公共 SNI 时首域名归 vless-reality、
#      其余供 xhttp 挑（避免撞 SNI）；仅 xhttp 用公共 SNI 时整表可选（vless 未占用）。
#   4. spiderX 探测只在 vless-reality 走公共 SNI 时执行（该字段仅写入
#      reality-direct，xhttp-reality 的 realitySettings 无 spiderX）。
#   5. 自建域名由剩余直连域池驱动（vless 先决策占用、xhttp 再算剩余池）：
#      vless 决策后若池仍非空 → xhttp 才显示「自有域名」选项；池空则自动隐藏
#      该选项并默认公共借 SNI（直连域不足时先占用者保留，见 Phase 4 收编）。
# 自建决策的持久化通道：reality_tag_self_domain() / reality_untag_self_domain()
#   （上文）——认领/摘除都写 DOMAIN_REGISTRY + DOMAIN_PRIMARY_*，派生值经
#   rebuild 落库，收集函数不再手改 shell 域值。

# ── 辅助：列出可被 reality 认领为「自有域名」的空闲直连域（每行一个，stdout）──
# 池 = 已注册的 direct 域 − CDN 业务域(XHTTP_DOMAIN/GRPC_DOMAIN)
#      − 其它共入口 TCP 协议占用域(NAIVE/ANYTLS/HY2) − 已挂任一 reality 标签的域
#      − 调用方排除域
# 依据：两个 reality 节点(8320/8325)在 TCP:443 各以 SNI 独占，不能与 CDN/naive/
#       anytls 等共入口的域复用；已带 xray-reality/xhttp-reality 标签的域同样排除
#       （含对方节点当前占用的自建域——SNI 互斥由注册表标签保证）。
_reality_free_domains() {
    local -a _excl=("$@")
    local _d _ex _suffix _protos _skip
    for _d in "${DIRECT_DOMAINS[@]:-}"; do
        [[ -n "$_d" ]] || continue
        _skip=0
        for _ex in "${_excl[@]}" "${XHTTP_DOMAIN:-}" "${GRPC_DOMAIN:-}" \
                   "${NAIVE_DOMAIN:-}" "${ANYTLS_DOMAIN:-}" "${HYSTERIA2_DOMAIN:-}"; do
            [[ -n "$_ex" && "$_d" == "$_ex" ]] && { _skip=1; break; }
        done
        (( _skip )) && continue
        _suffix=${_d//./_}
        _protos=$(get_state "DOMAIN_PROTO_${_suffix}" "")
        case ",${_protos}," in
            *,xray-reality,*|*,xhttp-reality,*) continue ;;
        esac
        echo "$_d"
    done
}

# ── 辅助：交互式从候选池挑一个域作为某 reality 节点的自有域名 ──
# 用法: picked=$(_reality_pick_own_domain <tag> [候选...])  # tag ∈ {xray-reality,xhttp-reality}
# 提示写 stderr（echo >&2 / read -rp 默认写 stderr），仅选中的域名走 stdout，
# 便于被 $(...) 干净捕获。池为空或用户选「0 取消」时返回 1、stdout 为空。
_reality_pick_own_domain() {
    local tag="$1"; shift
    local -a cands=("$@")
    (( ${#cands[@]} > 0 )) || return 1
    local _i=1 _c _choice
    echo "可用自有域名（将绑定为 ${tag} 的 SNI）：" >&2
    for _c in "${cands[@]}"; do echo "  ${_i}. ${_c}" >&2; (( _i++ )); done
    echo "  0. 取消（保持公共 SNI）" >&2
    read -rp "请选择 [0-${#cands[@]}，默认1]: " _choice
    [[ "${_choice:-1}" == "0" ]] && return 1
    local _idx=$(( ${_choice:-1} - 1 ))
    (( _idx < 0 || _idx >= ${#cands[@]} )) && _idx=0
    echo "${cands[$_idx]}"
}

# ── 辅助：地区 + 伪装目标列表选择（原 collect_reality_params 内联段）──
# 设置全局 REALITY_DEST 与 REALITY_SERVER_NAMES（已去重）。
# 仅当至少一个协议要用「公共 SNI」时才被调用。
_reality_pick_target_list() {
    local region_choice
    local _hw_prefix="${HW_REGION%%/*}"
    case "$_hw_prefix" in
        na) region_choice=1
            log_info "从 HW_REGION=${HW_REGION} 自动选择地区：美国/北美" ;;
        eu) region_choice=2
            log_info "从 HW_REGION=${HW_REGION} 自动选择地区：欧洲" ;;
        as) region_choice=3
            log_info "从 HW_REGION=${HW_REGION} 自动选择地区：亚洲" ;;
        *)
            echo "请选择服务器所在地区："
            echo "  1. 美国 / 北美"
            echo "  2. 欧洲"
            echo "  3. 亚洲"
            echo "  4. 自定义"
            echo ""
            read -rp "请选择地区 [1-4，默认2]: " region_choice
            ;;
    esac

    case "${region_choice:-2}" in

        1)
            local -a _us_labels=(
                "solanolibrary.com:443（洛杉矶公共图书馆）"
                "www.siliconvalley.com:443（硅谷媒体）"
                "business.ca.gov:443（加州政府）"
                "openclaw.ai:443（AI 平台）"
                "www.oxy.edu:443（奥克西登特学院）"
                "film.ca.gov:443（加州电影委员会）"
                "www.lapl.org:443（洛杉矶公共图书馆官网）"
            )
            local -a _us_dests=(
                "solanolibrary.com:443" "www.siliconvalley.com:443" "business.ca.gov:443"
                "openclaw.ai:443" "www.oxy.edu:443" "film.ca.gov:443" "www.lapl.org:443"
            )
            local -a _us_servernames=(
                "solanolibrary.com openclaw.ai www.lapl.org www.siliconvalley.com www.oxy.edu business.ca.gov film.ca.gov"
                "www.siliconvalley.com solanolibrary.com www.oxy.edu business.ca.gov openclaw.ai film.ca.gov"
                "business.ca.gov film.ca.gov solanolibrary.com www.oxy.edu openclaw.ai"
                "openclaw.ai solanolibrary.com www.lapl.org www.siliconvalley.com www.oxy.edu"
                "www.oxy.edu solanolibrary.com openclaw.ai business.ca.gov film.ca.gov"
                "film.ca.gov business.ca.gov solanolibrary.com openclaw.ai www.oxy.edu"
                "www.lapl.org solanolibrary.com openclaw.ai www.siliconvalley.com www.oxy.edu"
            )
            echo ""
            echo "美国 / 北美伪装目标："
            local _i
            for (( _i=0; _i<${#_us_labels[@]}; _i++ )); do echo "  $(( _i+1 )). ${_us_labels[$_i]}"; done
            read -rp "请选择 [1-${#_us_labels[@]}，默认1]: " dest_choice
            local _di=$(( ${dest_choice:-1} - 1 ))
            (( _di < 0 || _di >= ${#_us_dests[@]} )) && _di=0
            REALITY_DEST="${_us_dests[$_di]}"
            read -ra REALITY_SERVER_NAMES <<< "${_us_servernames[$_di]}"
            ;;

        2)
            local -a _eu_labels=(
                "ethz.ch:443（瑞士联邦理工学院）"
                "www.ecb.europa.eu:443（欧洲中央银行）"
                "opendata.cern.ch:443（欧洲核子研究中心）"
                "yandex.com.tr:443（Yandex 土耳其）"
                "www.mpg.de:443（马克斯普朗克学会）"
                "sentinels.copernicus.eu:443（哥白尼计划）"
            )
            local -a _eu_dests=(
                "ethz.ch:443" "www.ecb.europa.eu:443" "opendata.cern.ch:443"
                "yandex.com.tr:443" "www.mpg.de:443" "sentinels.copernicus.eu:443"
            )
            local -a _eu_servernames=(
                "ethz.ch m.ethz.ch debian.ethz.ch cuni.cz mff.cuni.cz www.mpg.de developer.trumpf.com"
                "www.ecb.europa.eu api.ecb.europa.eu sentinels.copernicus.eu ethz.ch www.mpg.de"
                "opendata.cern.ch ethz.ch m.ethz.ch www.mpg.de api.aalto.fi www.nic.funet.fi"
                "yandex.com.tr ethz.ch www.ecb.europa.eu opendata.cern.ch"
                "www.mpg.de developer.trumpf.com ethz.ch m.ethz.ch debian.ethz.ch cuni.cz mff.cuni.cz"
                "sentinels.copernicus.eu www.ecb.europa.eu api.ecb.europa.eu opendata.cern.ch ethz.ch"
            )
            echo ""
            echo "欧洲伪装目标："
            local _i
            for (( _i=0; _i<${#_eu_labels[@]}; _i++ )); do echo "  $(( _i+1 )). ${_eu_labels[$_i]}"; done
            read -rp "请选择 [1-${#_eu_labels[@]}，默认1]: " dest_choice
            local _di=$(( ${dest_choice:-1} - 1 ))
            (( _di < 0 || _di >= ${#_eu_dests[@]} )) && _di=0
            REALITY_DEST="${_eu_dests[$_di]}"
            read -ra REALITY_SERVER_NAMES <<< "${_eu_servernames[$_di]}"
            ;;

        3)
            local -a _as_labels=(
                "www.lovelive-anime.jp:443（日本动画）"
                "www.nintendo.co.jp:443（任天堂日本）"
            )
            local -a _as_dests=("www.lovelive-anime.jp:443" "www.nintendo.co.jp:443")
            local -a _as_servernames=(
                "www.lovelive-anime.jp www.nintendo.co.jp"
                "www.nintendo.co.jp www.lovelive-anime.jp"
            )
            echo ""
            echo "亚洲伪装目标："
            local _i
            for (( _i=0; _i<${#_as_labels[@]}; _i++ )); do echo "  $(( _i+1 )). ${_as_labels[$_i]}"; done
            read -rp "请选择 [1-${#_as_labels[@]}，默认1]: " dest_choice
            local _di=$(( ${dest_choice:-1} - 1 ))
            (( _di < 0 || _di >= ${#_as_dests[@]} )) && _di=0
            REALITY_DEST="${_as_dests[$_di]}"
            read -ra REALITY_SERVER_NAMES <<< "${_as_servernames[$_di]}"
            ;;

        4)
            read -rp "输入自定义 dest（格式 domain:443）: " REALITY_DEST
            read -rp "输入 serverName（多个用空格分隔）: " -a REALITY_SERVER_NAMES
            ;;
    esac

    local deduped_server_names=() seen_server_names="" sn
    for sn in "${REALITY_SERVER_NAMES[@]}"; do
        [[ -n "$sn" ]] || continue
        if [[ " ${seen_server_names} " != *" ${sn} "* ]]; then
            deduped_server_names+=("$sn")
            seen_server_names+=" ${sn}"
        fi
    done
    REALITY_SERVER_NAMES=("${deduped_server_names[@]}")
}

# ── 收集 Reality 伪装参数 ────────────────────────────────────
collect_reality_params() {
    echo ""
    log_step "配置 Reality 伪装参数"
    echo ""

    local _vless_own="" _xhttp_own=""

    # ========================================================
    # Step 1：vless-reality（8320）—— 先决策。
    # 已占自建域(REALITY_DOMAIN) → 保持/摘除；未占 → 仅当空闲直连域池非空才
    # 显示「自有域名」选项（vless 优先占用，见函数头注释第 5 条）。
    # ========================================================
    local _vless_pool=()
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        echo "vless-reality 当前绑定自有域名 ${REALITY_DOMAIN}"
        echo "请选择 vless-reality 的伪装方式："
        echo "  1. 公共 SNI —— 借用第三方域名（将摘除 ${REALITY_DOMAIN} 的 xray-reality 标签）"
        echo "  2. 自建域名 —— ${REALITY_DOMAIN}（真实证书）"
        read -rp "请选择 [1/2，默认2]: " _m1
        echo ""
        if [[ "${_m1:-2}" == "1" ]]; then
            reality_untag_self_domain "${REALITY_DOMAIN}" "xray-reality"
            log_info "vless-reality 已切换为公共 SNI（REALITY_DOMAIN 已清空）"
        else
            log_info "vless-reality 保持自建域名模式（SNI=${REALITY_DOMAIN}，dest→本地伪装站 8321）"
        fi
    else
        local _d
        while IFS= read -r _d; do _vless_pool+=("$_d"); done < <(_reality_free_domains)
        if (( ${#_vless_pool[@]} > 0 )); then
            echo "请选择 vless-reality 的伪装方式："
            echo "  1. 公共 SNI —— 借用第三方域名（推荐）"
            echo "  2. 自有域名 —— 需拥有该域名证书，服务器自建伪装站"
            read -rp "请选择 [1/2，默认1]: " _m1
            echo ""
            if [[ "${_m1:-1}" == "2" ]]; then
                local _picked
                if _picked=$(_reality_pick_own_domain "xray-reality" "${_vless_pool[@]}"); then
                    if reality_tag_self_domain "${_picked}" "xray-reality"; then
                        log_info "vless-reality 已绑定自建域名 ${_picked}"
                    else
                        log_error "vless-reality 认领 ${_picked} 失败，保持公共 SNI"
                    fi
                else
                    log_info "未选择，vless-reality 保持公共 SNI"
                fi
            fi
        else
            log_warn "没有可认领为 vless-reality 自建域的空闲直连域（需先在域名编辑器登记直连域），走公共借 SNI"
        fi
    fi
    _vless_own="${REALITY_DOMAIN:-}"
    echo ""

    # ========================================================
    # Step 2：vless-xhttp-reality（8325）—— vless 决策后再算剩余池。
    # 同域双标（registry 把同一域同时标给两节点，SNI 冲突）属错误态：
    # 先自动把 xhttp 降为公共并 untag，避免 generate_sni_map 静默丢 8325。
    # ========================================================
    if [[ -n "${XHTTP_REALITY_DOMAIN:-}" && "${XHTTP_REALITY_DOMAIN}" == "${REALITY_DOMAIN:-}" ]]; then
        log_warn "检测到 ${XHTTP_REALITY_DOMAIN} 同时是两 Reality 节点的自建域（SNI 冲突），将 vless-xhttp-reality 自动降为公共 SNI"
        reality_untag_self_domain "${XHTTP_REALITY_DOMAIN}" "xhttp-reality"
    fi

    local _xhttp_pool=()
    if [[ -n "${XHTTP_REALITY_DOMAIN:-}" ]]; then
        echo "vless-xhttp-reality 当前绑定自有域名 ${XHTTP_REALITY_DOMAIN}"
        echo "请选择 vless-xhttp-reality 的伪装方式："
        echo "  1. 公共 SNI —— 借用第三方域名（将摘除 ${XHTTP_REALITY_DOMAIN} 的 xhttp-reality 标签）"
        echo "  2. 自建域名 —— ${XHTTP_REALITY_DOMAIN}（真实证书）"
        read -rp "请选择 [1/2，默认2]: " _m2
        echo ""
        if [[ "${_m2:-2}" == "1" ]]; then
            reality_untag_self_domain "${XHTTP_REALITY_DOMAIN}" "xhttp-reality"
            log_info "vless-xhttp-reality 已切换为公共 SNI（XHTTP_REALITY_DOMAIN 已清空）"
        else
            log_info "vless-xhttp-reality 保持自建域名模式（SNI=${XHTTP_REALITY_DOMAIN}，dest→本地伪装站 8326）"
        fi
    else
        local _d2
        while IFS= read -r _d2; do _xhttp_pool+=("$_d2"); done < <(_reality_free_domains)
        if (( ${#_xhttp_pool[@]} > 0 )); then
            echo "请选择 vless-xhttp-reality 的伪装方式："
            echo "  1. 公共 SNI —— 借用第三方域名（推荐）"
            echo "  2. 自有域名 —— 需拥有该域名证书，服务器自建伪装站"
            read -rp "请选择 [1/2，默认1]: " _m2
            echo ""
            if [[ "${_m2:-1}" == "2" ]]; then
                local _picked2
                if _picked2=$(_reality_pick_own_domain "xhttp-reality" "${_xhttp_pool[@]}"); then
                    if reality_tag_self_domain "${_picked2}" "xhttp-reality"; then
                        log_info "vless-xhttp-reality 已绑定自建域名 ${_picked2}"
                        XHTTP_REALITY_SNI=""
                    else
                        log_error "vless-xhttp-reality 认领 ${_picked2} 失败，保持公共 SNI"
                    fi
                else
                    log_info "未选择，vless-xhttp-reality 保持公共 SNI"
                fi
            fi
        else
            log_warn "没有可认领为 vless-xhttp-reality 自建域的空闲直连域（若 vless 已占用则直连域不足），走公共借 SNI"
        fi
    fi
    _xhttp_own="${XHTTP_REALITY_DOMAIN:-}"
    echo ""

    # ========================================================
    # Step 3：只有至少一个协议选了「公共SNI」，才需要伪装目标列表
    # ========================================================
    REALITY_SERVER_NAMES=()
    XHTTP_REALITY_SNI=""
    REALITY_DEST=""

    if [[ -z "${_vless_own}" || -z "${_xhttp_own}" ]]; then
        _reality_pick_target_list

        if [[ -z "${_xhttp_own}" ]]; then
            local -a _candidates=()
            if [[ -z "${_vless_own}" ]]; then
                # vless-reality 也在用这份列表 → serverNames[0] 归它，
                # xhttp 只能从剩下的挑，避免两节点撞 SNI 导致 nginx 分流失败
                _candidates=("${REALITY_SERVER_NAMES[@]:1}")
            else
                # vless-reality 走自有域名，没占用这份列表 → 全部可选
                _candidates=("${REALITY_SERVER_NAMES[@]}")
            fi

            if (( ${#_candidates[@]} > 0 )); then
                echo "请选择 vless-xhttp-reality 使用的伪装 SNI："
                local _i=1
                for sn in "${_candidates[@]}"; do echo "  ${_i}. ${sn}"; (( _i++ )); done
                echo "  （默认 1：${_candidates[0]}）"
                read -rp "请选择 [1-${#_candidates[@]}，默认1]: " _sni_choice
                local _sni_idx=$(( ${_sni_choice:-1} - 1 ))
                (( _sni_idx < 0 || _sni_idx >= ${#_candidates[@]} )) && _sni_idx=0
                XHTTP_REALITY_SNI="${_candidates[$_sni_idx]}"
                log_info "vless-xhttp-reality SNI 设为: ${XHTTP_REALITY_SNI}"
            else
                log_warn "没有可用的备用 SNI，vless-xhttp-reality 节点不可用"
            fi
        fi

        # spiderX 只服务于 vless-reality 走公共SNI 的场景（xhttp-reality 的
        # realitySettings 本来就没有 spiderX 字段，不需要为它探测）
        if [[ -z "${_vless_own}" ]]; then
            local reality_dest_domain="${REALITY_DEST%%:*}"
            echo ""
            log_step "探测伪装域名 ${reality_dest_domain} 的可用路径..."
            local detected_path
            if detected_path=$(detect_spider_path "${reality_dest_domain}"); then
                REALITY_SPIDER_X="${detected_path}"
                log_info "spiderX 自动设为 ${detected_path}（${reality_dest_domain} 返回 200）"
            else
                log_warn "未探测到任何返回 200 的路径"
                read -rp "请手动输入 Reality spiderX [默认 /]: " spider_x
                REALITY_SPIDER_X="${spider_x:-/}"
                log_warn "请确认该路径在目标网站返回 200，否则流量特征异常"
            fi
        fi
    fi

    # ========================================================
    # Step 4：自建域名模式收敛 —— vless-reality 用自有域名时，
    # dest/serverNames 固定为本地伪装站（本身逻辑不变，只是现在
    # 不会再被「白问一遍地区/列表」污染了）
    # ========================================================
    if [[ -n "${_vless_own}" ]]; then
        REALITY_DEST="127.0.0.1:8321"
        REALITY_SERVER_NAMES=("${_vless_own}")
    fi

    log_info "Reality dest:        ${REALITY_DEST}"
    log_info "Reality serverNames: ${REALITY_SERVER_NAMES[*]}"
    log_info "vless-reality       的 SNI: ${REALITY_SERVER_NAMES[0]:-（无）}"
    log_info "vless-xhttp-reality 的 SNI: ${XHTTP_REALITY_SNI:-${XHTTP_REALITY_DOMAIN:-（未启用，与 vless-reality 无法分流）}}"
}

# ── 构建 wireguard 出站 JSON ──────────────────────────────────
_build_warp_outbound_json() {
    if [[ -z "${WGCF_PRIVATE_KEY:-}" ]]; then
        log_error "WGCF_* 凭证未设置，请确认 run_warp() 已在 run_xray() 前执行"
        exit 1
    fi

    local addr_json=""
    IFS=',' read -ra addr_arr <<< "${WGCF_ADDRESS}"
    for addr in "${addr_arr[@]}"; do
        addr=$(echo "${addr}" | tr -d ' ')
        addr_json+="\"${addr}\","
    done
    addr_json="${addr_json%,}"

    cat << WGJSON
        {
            "tag":      "warp",
            "protocol": "wireguard",
            "settings": {
                "secretKey": "${WGCF_PRIVATE_KEY}",
                "address":   [${addr_json}],
                "peers": [
                    {
                        "publicKey":  "${WGCF_PEER_PUBKEY}",
                        "endpoint":   "${WGCF_ENDPOINT}",
                        "allowedIPs": ["::/0", "0.0.0.0/0"]
                    }
                ],
                "mtu":            1280,
                "domainStrategy": "ForceIPv6v4"
            }
        }
WGJSON
}

# ── 生成 xray config.json ────────────────────────────────────
generate_xray_config() {
    log_step "生成 Xray 配置文件..."

    # 读取延迟档位参数（无 state 时使用中延迟默认值）
    if declare -F load_latency_params &>/dev/null; then
        load_latency_params
    else
        LATENCY_XMUX_CONCURRENCY="16-32"
        LATENCY_XMUX_REQUEST_TIMES="600-900"
        LATENCY_XMUX_REUSABLE_SECS="1800-3000"
    fi

    local x_padding="${XRAY_PADDING:-}"
    case "${x_padding}" in
        ""|"128-2048"|"128-1024") x_padding="100-1000" ;;
    esac
    XRAY_PADDING="${x_padding}"
    save_state "XHTTP_PADDING" "${x_padding}"

    local user_timeout=30000

    local sn_json=""
    for sn in "${REALITY_SERVER_NAMES[@]}"; do
        [[ -n "$sn" ]] || continue
        sn_json+="\"${sn}\","
    done
    sn_json="${sn_json%,}"

    # XHTTP_REALITY_SNI / XHTTP_REALITY_DOMAIN 由 collect_reality_params() 交互式设置并已赋值
    # 此处只做持久化；两者互斥：设了 DOMAIN 则 SNI 不生效
    save_state "XHTTP_REALITY_SNI"    "${XHTTP_REALITY_SNI:-}"
    save_state "XHTTP_REALITY_DOMAIN" "${XHTTP_REALITY_DOMAIN:-}"

    # ── 防偷流量：reality-direct ──────────────────────────────────
    # 有自有域名（REALITY_DOMAIN 已设置）：
    #   dest → 本地 nginx 8321（由 nginx 模块生成，携带真实证书 + 伪装网站）
    #   serverNames 仅含自有域名，非 Xray 访客直接看到本地网站，无外部流量可偷
    # 无自有域名（仅公共 SNI）：
    #   dest → dokodemo 4431 → 路由决定：serverNames 内的域名 direct，其余 block
    local _reality_direct_dest _reality_direct_sn
    local _dokodemo_reality_routing="" _dokodemo_reality_inbound=""
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        _reality_direct_dest="127.0.0.1:8321"
        _reality_direct_sn="\"${REALITY_DOMAIN}\""
    else
        local _rdest_host="${REALITY_DEST%%:*}"
        local _rdest_port="${REALITY_DEST##*:}"
        _reality_direct_dest="127.0.0.1:4431"
        # reality-direct 只接受真正路由到 8320 的 SNI：排除 XHTTP_REALITY_SNI/DOMAIN，
        # 它们由 nginx stream 分流到 8325（vless-xhttp-reality），与 generate_sni_map 对齐。
        # 否则 8320 会把本不该归它的 SNI（如 business.ca.gov）也当 Reality 客户端处理。
        local _direct_sn=""
        for _sn in "${REALITY_SERVER_NAMES[@]}"; do
            [[ -n "$_sn" ]] || continue
            [[ "$_sn" == "${XHTTP_REALITY_SNI:-}" || "$_sn" == "${XHTTP_REALITY_DOMAIN:-}" ]] && continue
            _direct_sn+="\"${_sn}\","
        done
        _reality_direct_sn="${_direct_sn%,}"
        _dokodemo_reality_routing='            {
                "type":        "field",
                "inboundTag":  ["dokodemo-reality"],
                "domain":      ['"${sn_json}"'],
                "outboundTag": "direct"
            },
            {
                "type":        "field",
                "inboundTag":  ["dokodemo-reality"],
                "outboundTag": "block"
            },'
        _dokodemo_reality_inbound=',
        {
            "tag":      "dokodemo-reality",
            "listen":   "127.0.0.1",
            "port":     4431,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "'"${_rdest_host}"'",
                "port":    '"${_rdest_port}"',
                "network": "tcp"
            },
            "sniffing": {
                "enabled":      true,
                "destOverride": ["tls"],
                "routeOnly":    true
            }
        }'
    fi

    # ── 防偷流量：vless-xhttp-reality ────────────────────────────
    # 自有域名：dest → 本地 nginx 8326（真实证书 + 伪装站），无外部流量可偷
    # 公共 SNI ：dest → dokodemo 4432 → 借用第三方域名（公共 SNI 不能用本地 nginx，
    #            因为没有该域名的证书，TLS 指纹会与真实域名不符）
    local _dokodemo_xhttp_routing="" _dokodemo_xhttp_inbound=""
    local _xhttp_reality_dest="" _xhttp_reality_sn=""
    if [[ -n "${XHTTP_REALITY_DOMAIN:-}" ]]; then
        _xhttp_reality_dest="127.0.0.1:8326"
        _xhttp_reality_sn="\"${XHTTP_REALITY_DOMAIN}\""
    elif [[ -n "${XHTTP_REALITY_SNI:-}" ]]; then
        _xhttp_reality_dest="127.0.0.1:4432"
        _xhttp_reality_sn="\"${XHTTP_REALITY_SNI}\""
        _dokodemo_xhttp_routing='            {
                "type":        "field",
                "inboundTag":  ["dokodemo-xhttp-reality"],
                "domain":      ["'"${XHTTP_REALITY_SNI}"'"],
                "outboundTag": "direct"
            },
            {
                "type":        "field",
                "inboundTag":  ["dokodemo-xhttp-reality"],
                "outboundTag": "block"
            },'
        _dokodemo_xhttp_inbound=',
        {
            "tag":      "dokodemo-xhttp-reality",
            "listen":   "127.0.0.1",
            "port":     4432,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "'"${XHTTP_REALITY_SNI}"'",
                "port":    443,
                "network": "tcp"
            },
            "sniffing": {
                "enabled":      true,
                "destOverride": ["tls"],
                "routeOnly":    true
            }
        }'
    fi

    local sid_json=""
    for sid in "${REALITY_SHORT_IDS[@]}"; do
        sid_json+="\"${sid}\","
    done
    sid_json="${sid_json%,}"

    # CDN 入站 VLESS Encryption：TLS 在 nginx/CDN 终结，启用后 CDN 无法明文窥探；
    # reality-direct 保持 none（REALITY 已端到端加密，叠加属冗余）
    local vless_decryption="none"
    if [[ -n "${VLESS_ENC_SEED:-}" ]]; then
        vless_decryption="mlkem768x25519plus.native.600s.${VLESS_ENC_SEED}"
    fi

    local warp_outbound
    warp_outbound=$(_build_warp_outbound_json)

    local xray_query_strategy
    if is_ipv6_preferred 2>/dev/null; then
        xray_query_strategy="UseIPv6v4"
    else
        xray_query_strategy="UseIPv4v6"
    fi

    mkdir -p /usr/local/etc/xray

    # Fix: grpc initial_windows_size 4194304 (4MB) prevents CDN GOAWAY on high-BDP paths; default 65536 too small
    cat > /usr/local/etc/xray/config.json << CONF
{
    "log": {
        "loglevel": "warn",
        "access":   "none",
        "error":    "/var/log/xray/error.log"
    },

    "dns": {
        "servers": [
            {
                "tag":      "local-dns",
                "address":  "127.0.0.1",
                "port":     53,
                "domains":  [
                    "geosite:geolocation-!cn",
                    "geosite:google",
                    "geosite:github",
                    "geosite:cloudflare",
                    "geosite:netflix",
                    "geosite:openai"
                ],
                "expectIPs":    ["geoip:!cn"],
                "skipFallback": true
            },
            {
                "tag":      "warp-dns",
                "address":  "1.1.1.1",
                "domains":  [
                    "geosite:cn",
                    "geosite:tld-cn"
                ],
                "expectIPs": ["geoip:cn"],
                "proxyTag":  "warp"
            }
        ],
        "disableCache":    false,
        "disableFallback": true,
        "queryStrategy":   "${xray_query_strategy}"
    },

    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
${_dokodemo_reality_routing}
${_dokodemo_xhttp_routing}
            {
                "type":        "field",
                "ip":          ["127.0.0.1"],
                "port":        53,
                "outboundTag": "direct"
            },
            {
                "type":        "field",
                "ip":          ["geoip:private"],
                "outboundTag": "block"
            },
            {
                "type":        "field",
                "domain":      ["geosite:cn", "geosite:tld-cn"],
                "outboundTag": "warp"
            },
            {
                "type":        "field",
                "ip":          ["geoip:cn"],
                "outboundTag": "warp"
            }
        ]
    },

    "inbounds": [
        {
            "tag":      "vless-xhttp-cdn",
            "listen":   "127.0.0.1",
            "port":     8300,
            "protocol": "vless",
            "settings": {
                "clients":     [{"id": "${XRAY_UUID}"}],
                "decryption":  "${vless_decryption}"
            },
            "streamSettings": {
                "network":  "xhttp",
                "security": "none",
                "xhttpSettings": {
                    "path": "${XHTTP_PATH}",
                    "host": "${XHTTP_DOMAIN:-}",
                    "mode": "auto",
                    "extra": {
                        "xPaddingBytes":          "${x_padding}",
                        "scStreamUpServerSecs":   "20-80",
                        "headers":                {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"},
                        "xmux": {
                            "maxConcurrency":   "${LATENCY_XMUX_CONCURRENCY}",
                            "maxConnections":   0,
                            "cMaxReuseTimes":   0,
                            "hMaxRequestTimes": "${LATENCY_XMUX_REQUEST_TIMES}",
                            "hMaxReusableSecs": "${LATENCY_XMUX_REUSABLE_SECS}",
                            "hKeepAlivePeriod": 60
                        }
                    }
                },
                "sockopt": {
                    "trustedXForwardedFor": ["127.0.0.1", "::1"]
                }
            },
            "sniffing": {
                "enabled":      true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false
            }
        },

        {
            "tag":      "vless-grpc-cdn",
            "listen":   "127.0.0.1",
            "port":     8310,
            "protocol": "vless",
            "settings": {
                "clients":    [{"id": "${XRAY_UUID}"}],
                "decryption": "${vless_decryption}"
            },
            "streamSettings": {
                "network":  "grpc",
                "security": "none",
                "grpcSettings": {
                    "serviceName":           "${GRPC_SERVICE_NAME}",
                    "multiMode":             false,
                    "idle_timeout":          60,
                    "health_check_timeout":  20,
                    "permit_without_stream": false
                },
                "sockopt": {
                    "trustedXForwardedFor": ["127.0.0.1", "::1"]
                }
            },
            "sniffing": {
                "enabled":      true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false
            }
        },

        {
            "tag":      "reality-direct",
            "listen":   "127.0.0.1",
            "port":     8320,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id":   "${XRAY_UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none",
                "fallbacks":  [
                    {
                        "path": "${XHTTP_PATH}",
                        "dest": "127.0.0.1:8325",
                        "xver": 0
                    },
                    {
                        "path": "/${GRPC_SERVICE_NAME}",
                        "dest": "127.0.0.1:8350",
                        "xver": 0
                    },
                    {
                        "dest": "127.0.0.1:8350",
                        "xver": 0
                    }
                ]
            },
            "streamSettings": {
                "network":  "tcp",
                "security": "reality",
                "realitySettings": {
                    "show":        false,
                    "dest":        "${_reality_direct_dest}",
                    "xver":        0,
                    "serverNames": [${_reality_direct_sn}],
                    "privateKey":  "${XRAY_PRIVATE_KEY}",
                    "shortIds":    [${sid_json}],
                    "spiderX":     "${REALITY_SPIDER_X}"
                },
                "sockopt": {
                    "acceptProxyProtocol": true,
                    "tcpUserTimeout":       ${user_timeout},
                    "tcpKeepAliveIdle":     300,
                    "tcpKeepAliveInterval": 30,
                    "tcpMptcp":             true,
                    "tcpNoDelay":           true
                }
            },
            "sniffing": {
                "enabled":      true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false
            }
        },

        {
            "tag":      "vless-xhttp-reality",
            "listen":   "127.0.0.1",
            "port":     8325,
            "protocol": "vless",
            "settings": {
                "clients":    [{"id": "${XRAY_UUID}"}],
                "decryption": "none"
            },
            "streamSettings": {
                "network":  "xhttp",
                "security": "reality",
                "xhttpSettings": {
                    "path": "${XHTTP_PATH}",
                    "mode": "stream-one",
                    "extra": {
                        "xPaddingBytes":        "${x_padding}",
                        "scStreamUpServerSecs": "20-80"
                    }
                },
                "realitySettings": {
                    "show":        false,
                    "dest":        "${_xhttp_reality_dest}",
                    "xver":        0,
                    "serverNames": [${_xhttp_reality_sn}],
                    "privateKey":  "${XHTTP_REALITY_PRIVATE_KEY}",
                    "shortIds":    [${sid_json}]
                },
                "sockopt": {
                    "acceptProxyProtocol": true,
                    "tcpMptcp":            true,
                    "tcpNoDelay":          true
                }
            },
            "sniffing": {
                "enabled":      true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false
            }
        }${_dokodemo_reality_inbound}${_dokodemo_xhttp_inbound}
    ],

    "outbounds": [
        {
            "tag":      "direct",
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv6v4"
            },
            "streamSettings": {
                "sockopt": {
                    "tcpUserTimeout":       ${user_timeout},
                    "tcpKeepAliveIdle":     300,
                    "tcpKeepAliveInterval": 30,
                    "tcpFastOpen":          true,
                    "tcpcongestion":        "bbr",
                    "tcpMptcp":             true,
                    "tcpNoDelay":           true
                }
            }
        },
        {
            "tag":      "block",
            "protocol": "blackhole"
        },
        ${warp_outbound}
    ]
}
CONF

    log_info "Xray 配置文件生成完成"
}

# ── 启动 Xray ────────────────────────────────────────────────
start_xray() {
    log_step "启动 Xray 服务..."

mkdir -p /var/log/xray
    if ! xray run -test -config /usr/local/etc/xray/config.json; then
        log_error "Xray 配置验证失败"
        exit 1
    fi

    configure_xray_service_limits
    systemctl enable xray
    systemctl restart xray

    sleep 2
    if systemctl is-active --quiet xray; then
        log_info "Xray 服务启动成功"
    else
        log_error "Xray 服务启动失败，查看日志："
        journalctl -u xray -n 20 --no-pager
        exit 1
    fi
}

# ── 模块入口 ─────────────────────────────────────────────────
run_xray() {
    log_step "========== Xray 安装配置 =========="
    install_xray
    generate_xray_params
    collect_reality_params
    generate_xray_config
    start_xray
    log_info "========== Xray 安装配置完成 =========="
    echo ""
    log_info "关键参数（请保存）："
    echo "  UUID:         ${XRAY_UUID}"
    echo "  公钥:         ${XRAY_PUBLIC_KEY}"
    echo "  私钥:         ${XRAY_PRIVATE_KEY}"
    echo "  xhttp路径:    ${XHTTP_PATH}"
    echo "  Reality dest: ${REALITY_DEST}"
    if [[ -n "${VLESS_ENC_CLIENT:-}" ]]; then
        echo "  VLESS Encryption（CDN 节点客户端 encryption 填）:"
        echo "    mlkem768x25519plus.native.0rtt.${VLESS_ENC_CLIENT}"
    fi
}
