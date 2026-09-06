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
    # CDN / 反代业务域（xhttp/grpc/naiveproxy/anytls）不允许被 reality 认领自建
    # （模式与 SNI 语义都不符）；reality 需独占一个无这些标签的直连域。
    case ",${existing}," in
        *,xray-xhttp,*|*,xray-grpc,*|*,naiveproxy,*|*,singbox,*)
            log_warn "拒绝：${domain} 是 CDN/反代业务域（xray-xhttp/xray-grpc/naiveproxy/singbox），不能作为 reality 自建域"
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


# ── 收集 Reality 伪装参数（菜单 11/x = SNI 真分配：自建 vs 借公共）──
# 设计(2026-09-06 SNI 真分配)：
#   1. 域归属分两层：
#      - 主菜单 5→6 = 预分配：仅把一个「可自建 SNI」的直连域 earmark 给某
#        Reality 槽（写 REALITY_PREALLOC / XHTTP_REALITY_PREALLOC，advisory，
#        不切 SNI、不自动改绑）；
#      - 本函数（菜单 11/x）= SNI 真分配：每个 Reality 协议**独立**选 SNI 来源
#        （用自有域自建 / 借公共大站 SNI），读取 5→6 预分配并排最前。
#        reality_tag_self_domain / reality_untag_self_domain（上文）是唯一持久化
#        通道（DOMAIN_REGISTRY + DOMAIN_PROTO_* + DOMAIN_PRIMARY_* → rebuild 派生
#        REALITY_DOMAIN / XHTTP_REALITY_DOMAIN）。本函数调用它们——自建槽可随时
#        取消 / 改换，不再是只读、也不再反向依赖 option-6 解除。
#   2. 名额门控：自建候选 = 预分配优先 + 其它真正可自建 SNI 的直连域（已入册、
#      无 CDN/anytls/naiveproxy/任一 reality 标签、证书已签，见 _reality_self_capable）。
#      无候选 → 本槽「自建」选项隐藏；一域被某槽自建后自动从另一槽候选剔除
#      （两槽都想自建但可用自有域不足时，第二个自建自然选不上）。
#   3. Stage B 只给最终仍「借公共 SNI」的槽配伪装参数：
#      - vless-reality 公共 → dest + serverNames 池 + spiderX 探测；
#      - vless-xhttp-reality 公共 → 单个借用站点（即其 SNI，dest 恒=该站点:443）。
#      两槽都公共 → 目标列表归 vless，serverNames[1:] 供 xhttp 挑（避免撞 SNI）。
#   4. vless 自建时不再收敛 REALITY_DEST/serverNames（生成器自建分支固定
#      dest→本地伪装站 8321、serverNames=["REALITY_DOMAIN"]，不读这两个变量）：
#      保留它们 = 该槽公共模式回滚态，本菜单切回借公共 SNI 时直接复用。

# ── 辅助：vless-reality 走公共 SNI 时探测可用 spiderX 路径 ──
# 探测目标站返回 200 的路径；失败则手动输入。仅 vless 公共需要（xhttp-reality
# 的 realitySettings 无 spiderX 字段）。
_probe_vless_spider_x() {
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
}

# ── 辅助：地区 + 伪装目标列表选择（原 collect_reality_params 内联段）──
# kind=vless(默认)：设置全局 REALITY_DEST 与 REALITY_SERVER_NAMES（已去重）。
# kind=xhttp：仅设置 XHTTP_REALITY_SNI=选中站点域名，不动 REALITY_DEST/serverNames
#             （vless-xhttp-reality 公共用，其 dest 恒=SNI 域）。区域数组单一来源。
# 仅当至少一个协议要用「公共 SNI」时才被调用。
_reality_pick_target_list() {
    local _kind="${1:-vless}"
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
            if [[ "${_kind}" == "xhttp" ]]; then
                XHTTP_REALITY_SNI="${_us_dests[$_di]%:*}"
            else
                REALITY_DEST="${_us_dests[$_di]}"
                read -ra REALITY_SERVER_NAMES <<< "${_us_servernames[$_di]}"
            fi
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
            if [[ "${_kind}" == "xhttp" ]]; then
                XHTTP_REALITY_SNI="${_eu_dests[$_di]%:*}"
            else
                REALITY_DEST="${_eu_dests[$_di]}"
                read -ra REALITY_SERVER_NAMES <<< "${_eu_servernames[$_di]}"
            fi
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
            if [[ "${_kind}" == "xhttp" ]]; then
                XHTTP_REALITY_SNI="${_as_dests[$_di]%:*}"
            else
                REALITY_DEST="${_as_dests[$_di]}"
                read -ra REALITY_SERVER_NAMES <<< "${_as_servernames[$_di]}"
            fi
            ;;

        4)
            if [[ "${_kind}" == "xhttp" ]]; then
                read -rp "输入自定义借用站点（domain，不含 :443）: " XHTTP_REALITY_SNI
            else
                read -rp "输入自定义 dest（格式 domain:443）: " REALITY_DEST
                read -rp "输入 serverName（多个用空格分隔）: " -a REALITY_SERVER_NAMES
            fi
            ;;
    esac

    # xhttp 模式不动 REALITY_SERVER_NAMES（保持 vless 公共回滚态），故跳过去重
    if [[ "${_kind}" != "xhttp" ]]; then
        local deduped_server_names=() seen_server_names="" sn
        for sn in "${REALITY_SERVER_NAMES[@]}"; do
            [[ -n "$sn" ]] || continue
            if [[ " ${seen_server_names} " != *" ${sn} "* ]]; then
                deduped_server_names+=("$sn")
                seen_server_names+=" ${sn}"
            fi
        done
        REALITY_SERVER_NAMES=("${deduped_server_names[@]}")
    fi
}

# ── Reality 域「能否作自建 SNI」判定（不要求入册）────────────
# 返回 0 iff DOMAIN_PROTO_<sfx> 不含 {xray-xhttp, xray-grpc, singbox, naiveproxy,
# xray-reality, xhttp-reality} 且证书已签。证书路径解析与 nginx generate_servers_conf
# 完全一致（CERT_PATH_${root//./_} 状态优先，否则 /etc/letsencrypt/live/${root}）。
_reality_domain_usable_fast() {
    local domain="$1"
    local suffix protos
    suffix=$(printf '%s' "$domain" | tr '.' '_')
    protos=$(get_state "DOMAIN_PROTO_${suffix}" "")
    local -a _fb=(xray-xhttp xray-grpc singbox naiveproxy xray-reality xhttp-reality)
    local _t
    for _t in "${_fb[@]}"; do
        case ",${protos}," in *,"${_t}",*) return 1 ;; esac
    done
    local root cert_path
    root=$(printf '%s' "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    cert_path=$(get_state "CERT_PATH_${root//./_}" "")
    [[ -z "$cert_path" ]] && cert_path="/etc/letsencrypt/live/${root}"
    [[ -f "${cert_path}/fullchain.pem" ]]
}

# 某域现在能否作为某 Reality 槽的自建 SNI（Q2=只许可自建的域）= 已入册 + 上面可用。
_reality_self_capable() {
    local domain="$1"
    domain_is_registered "$domain" || return 1
    _reality_domain_usable_fast "$domain"
}

# 某 Reality 槽的可选自有域（stdout 每行一域）。顺序 = [5→6 预分配] + [其余空闲直连域]。
# 剔除：本槽当前活性自建域、另一槽活性自建域、另一槽预分配。预分配域即使刚被 untag
# 摘出注册表（无其它角色、证书仍在）也照列——reality_tag_self_domain 会重新入册，
# 自建取消后可一键再启用。
_reality_own_candidates() {
    local tag="$1"
    local own other own_pre other_pre
    if [[ "$tag" == "xray-reality" ]]; then
        own="${REALITY_DOMAIN:-}";        other="${XHTTP_REALITY_DOMAIN:-}"
        own_pre=$(get_state "REALITY_PREALLOC" "");       other_pre=$(get_state "XHTTP_REALITY_PREALLOC" "")
    else
        own="${XHTTP_REALITY_DOMAIN:-}";  other="${REALITY_DOMAIN:-}"
        own_pre=$(get_state "XHTTP_REALITY_PREALLOC" ""); other_pre=$(get_state "REALITY_PREALLOC" "")
    fi
    local -a pool=()
    local registry d
    registry=$(get_state "DOMAIN_REGISTRY" "")
    for d in $registry; do
        [[ "$d" == "$own" || "$d" == "$other" || "$d" == "$other_pre" ]] && continue
        _reality_self_capable "$d" && pool+=("$d")
    done
    if [[ -n "$own_pre" && "$own_pre" != "$own" && "$own_pre" != "$other" \
            && "$own_pre" != "$other_pre" ]] && _reality_domain_usable_fast "$own_pre"; then
        echo "$own_pre"
    fi
    local seen="${own_pre:-}" d2
    for d2 in "${pool[@]}"; do
        [[ "$d2" != "$seen" ]] && echo "$d2"
    done
}

# ── 单 Reality 槽 SNI 来源决策（Stage A 用）─────────────────
# 用法: _reality_ask_slot_sni <tag>   tag ∈ {xray-reality, xhttp-reality}
# 读全局 REALITY_DOMAIN / XHTTP_REALITY_DOMAIN + state 预分配；需要时调
# reality_tag/untag_self_domain（内部 rebuild+load 已刷新上述全局——调用方切勿
# 沿用进入时的旧值）。槽为「借公共 且无自建候选」时置 _REALITY_SLOT_GUIDE=1。
_reality_ask_slot_sni() {
    local tag="$1"
    local label own_key other_key prealloc_key
    if [[ "$tag" == "xray-reality" ]]; then
        label="VLESS-Reality"; own_key="REALITY_DOMAIN"; other_key="XHTTP_REALITY_DOMAIN"; prealloc_key="REALITY_PREALLOC"
    else
        label="XHTTP-Reality"; own_key="XHTTP_REALITY_DOMAIN"; other_key="REALITY_DOMAIN"; prealloc_key="XHTTP_REALITY_PREALLOC"
    fi
    local own="${!own_key:-}"
    local prealloc
    prealloc=$(get_state "$prealloc_key" "")

    local -a cands=()
    local _d
    while IFS= read -r _d; do [[ -n "$_d" ]] && cands+=("$_d"); done < <(_reality_own_candidates "$tag")

    echo ""
    local c _i _choice _target
    if [[ -n "$own" ]]; then
        # ── 当前用自有域自建：保持 / 取消（回公共）/ 改换 ──
        log_info "${label} 当前用自有域自建: ${own}"
        echo "  请选择该协议的 SNI 来源："
        echo "  1) 保持自建 ${own}（默认）"
        echo "  2) 切回借公共 SNI（取消自建）"
        if (( ${#cands[@]} > 0 )); then
            echo "  3) 改用其它自有域自建："
            local _j=1
            for c in "${cands[@]}"; do printf "     %d) %s\n" "$_j" "$c"; ((_j++)); done
        fi
        read -rp "  请选择 [默认1]: " _choice
        case "${_choice:-1}" in
            2)
                reality_untag_self_domain "$own" "$tag"
                log_info "${label} 已取消自建 → 回借公共 SNI（公共伪装参数在下方配置）"
                ;;
            3)
                if (( ${#cands[@]} > 0 )); then
                    read -rp "  选择要改用哪个自有域 [1-${#cands[@]}]: " _i
                    _target="${cands[$(( ${_i:-1} - 1 ))]:-}"
                    if [[ -n "$_target" && "$_target" != "$own" ]]; then
                        reality_untag_self_domain "$own" "$tag"
                        if reality_tag_self_domain "$_target" "$tag"; then
                            save_state "$prealloc_key" "$_target"
                            log_info "${label} 已改用自有域自建: ${_target}"
                        else
                            log_warn "改绑 ${_target} 失败（见上方原因）——恢复原自建域 ${own}"
                            reality_tag_self_domain "$own" "$tag"
                        fi
                    fi
                fi
                ;;
        esac
    else
        # ── 当前借公共 SNI（或未配置）──
        log_info "${label} 借公共 SNI（未用自有域自建）"
        if (( ${#cands[@]} == 0 )); then
            # 无任何可自建候选：只剩「借公共」一条路，不弹选择、不占 read
            _REALITY_SLOT_GUIDE=1
            return 0
        fi
        echo "  请选择该协议的 SNI 来源："
        echo "  1) 借公共大站 SNI（默认）"
        echo "  2) 用自有域自建："
        local _k=1
        for c in "${cands[@]}"; do
            local _mark=""
            [[ "$c" == "$prealloc" ]] && _mark="（主菜单5→6 已预分配，优先）"
            printf "     %d) %s %s\n" "$_k" "$c" "$_mark"
            ((_k++))
        done
        read -rp "  请选择 [1-2，默认1]: " _choice
        if [[ "${_choice:-1}" == "2" ]]; then
            read -rp "  选择要自建的自有域 [1-${#cands[@]}]: " _i
            _target="${cands[$(( ${_i:-1} - 1 ))]:-}"
            if [[ -n "$_target" ]]; then
                if reality_tag_self_domain "$_target" "$tag"; then
                    save_state "$prealloc_key" "$_target"
                    log_info "${label} 已启用自有域自建: ${_target}"
                else
                    log_warn "${label} 绑定自建域 ${_target} 失败（见上方原因），保持借公共 SNI"
                fi
            fi
        fi
    fi
}

# ── 收集 Reality 伪装参数 ────────────────────────────────────
collect_reality_params() {
    echo ""
    log_step "配置 Reality 伪装参数"
    echo ""

    local _vless_own="${REALITY_DOMAIN:-}" _xhttp_own="${XHTTP_REALITY_DOMAIN:-}"

    # ── 防御：同域双标（registry 把同一域同时标给两节点 → SNI 冲突）──
    # 属域层错误态：此处自动把 xhttp 降为公共（避免 generate_sni_map 静默丢
    # 8325）；正确归属仍须到主菜单 11/x 把两槽分配到不同自有域。
    if [[ -n "${_xhttp_own}" && "${_xhttp_own}" == "${_vless_own}" ]]; then
        log_warn "检测到 ${_xhttp_own} 同时是两 Reality 节点的自建域（SNI 冲突）"
        log_warn "将 vless-xhttp-reality 自动降为公共 SNI；请到本菜单（11/x）把两槽分配到不同自有域"
        reality_untag_self_domain "${_xhttp_own}" "xhttp-reality"
        _xhttp_own="${XHTTP_REALITY_DOMAIN:-}"
    fi

    # ═══ Stage A：逐槽 SNI 来源决策（本菜单 = SNI 真分配）═══
    # 每个 Reality 协议独立选「用自有域自建 / 借公共大站 SNI」。候选 =
    # [5→6 预分配优先] + [其它可自建空闲直连域]，见 _reality_ask_slot_sni。
    # tag/untag 内部 rebuild+load_domain_state 已刷新 shell 全局
    # REALITY_DOMAIN / XHTTP_REALITY_DOMAIN——故 Stage A 后必须重快照，
    # 不可沿用进入本函数时的旧值（这是 tag/untag 后重快照纪律）。
    _REALITY_SLOT_GUIDE=0
    _reality_ask_slot_sni xray-reality
    _reality_ask_slot_sni xhttp-reality
    _vless_own="${REALITY_DOMAIN:-}"
    _xhttp_own="${XHTTP_REALITY_DOMAIN:-}"
    if (( _REALITY_SLOT_GUIDE )); then
        echo ""
        log_info "如需让借公共 SNI 的 Reality 槽用自有域自建：主菜单 5 为域新增灰云直连并签发证书 → 5→6 预分配 → 重跑本菜单选自建"
    fi

    # ========================================================
    # 公共伪装参数：仅配置仍「借公共 SNI」的槽位。
    # XHTTP_REALITY_SNI 必须重置：xhttp 自建时要置空（防残留把自建槽误当公共）。
    # REALITY_DEST / REALITY_SERVER_NAMES 不预清：vless 自建时生成器固定
    # dest→本地伪装站8321、serverNames=["REALITY_DOMAIN"]，不读它们，保留即是
    # 该槽公共模式回滚态（本菜单切回借公共 SNI 时直接复用）。
    # ========================================================
    XHTTP_REALITY_SNI=""
    echo ""

    # vless 自建时：把 state 里的公共回滚参数（dest/serverNames/spiderX）读回
    # shell。wizard 流程 init_state/restore_domain_arrays 只还原 serverNames
    # 数组、从不还原 dest/spiderX，nounset(set -u) 下裸引用 REALITY_DEST 会崩；
    # 且调用方 save 块用 ${VAR:-} 会把未赋值的 dest/spiderX 写成 ''，清掉
    # 本菜单切回借公共 SNI 后待复用的公共回滚态。读回后展示可用、save 原样回写。
    # vless 公共时这些由下方 _reality_pick_target_list/_probe_vless_spider_x
    # 现场覆写，此读回无副作用。
    if [[ -n "${_vless_own}" ]]; then
        REALITY_DEST=$(get_state "REALITY_DEST" "")
        REALITY_SPIDER_X=$(get_state "REALITY_SPIDER_X" "")
        REALITY_SERVER_NAMES=()
        local _rsn_state
        _rsn_state=$(get_state "REALITY_SERVER_NAMES" "")
        [[ -n "${_rsn_state}" ]] && read -ra REALITY_SERVER_NAMES <<< "${_rsn_state}"
    fi

    if [[ -z "${_vless_own}" && -z "${_xhttp_own}" ]]; then
        # 两槽都公共：目标列表归 vless；xhttp 从 serverNames[1:] 挑不撞 SNI
        # （两节点共 SNI 会导致 nginx SNI map 只分流到一个后端）
        _reality_pick_target_list
        local _npool=${#REALITY_SERVER_NAMES[@]}
        if (( _npool > 1 )); then
            echo ""
            echo "请选择 vless-xhttp-reality 使用的伪装 SNI："
            local _i=1 _sn2
            for _sn2 in "${REALITY_SERVER_NAMES[@]:1}"; do echo "  ${_i}. ${_sn2}"; (( _i++ )); done
            echo "  （默认 1：${REALITY_SERVER_NAMES[1]}）"
            read -rp "请选择 [1-$(( _npool - 1 ))，默认1]: " _sni_choice
            local _sni_idx=$(( ${_sni_choice:-1} - 1 ))
            (( _sni_idx < 0 || _sni_idx >= _npool - 1 )) && _sni_idx=0
            XHTTP_REALITY_SNI="${REALITY_SERVER_NAMES[$(( _sni_idx + 1 ))]}"
            log_info "vless-xhttp-reality SNI 设为: ${XHTTP_REALITY_SNI}"
        else
            log_warn "公共目标列表无备用 SNI，vless-xhttp-reality 无法借公共 SNI——请到主菜单 11/x 处理"
        fi
        _probe_vless_spider_x
    elif [[ -z "${_vless_own}" ]]; then
        # vless 公共 + xhttp 自建：只配 vless（xhttp 自建 SNI 已置空）
        _reality_pick_target_list
        _probe_vless_spider_x
    elif [[ -z "${_xhttp_own}" ]]; then
        # vless 自建 + xhttp 公共：xhttp 公共 dest 恒=其 SNI 域 → 只问一次借用站点
        log_info "vless-xhttp-reality 借公共 SNI：请选择借用站点（=其 SNI，dest 自动=该站点:443）"
        _reality_pick_target_list xhttp
        log_info "vless-xhttp-reality SNI 设为: ${XHTTP_REALITY_SNI}"
    fi
    # 两槽都自建：无公共参数需要（XHTTP_REALITY_SNI 已清空；REALITY_* 公共回滚态保留）

    # ── 结果汇总：自建槽指向主菜单5；公共槽显示所选参数 ──
    if [[ -n "${_vless_own}" ]]; then
        log_info "vless-reality       自建模式：SNI=${_vless_own}，dest→本地伪装站8321（生成器固定）"
        if [[ -n "${REALITY_DEST}" || ${#REALITY_SERVER_NAMES[@]} -gt 0 ]]; then
            log_info "Reality 公共回滚参数保留: dest=${REALITY_DEST} serverNames=${REALITY_SERVER_NAMES[*]}（切回借公共 SNI 后复用）"
        fi
    else
        log_info "Reality dest:        ${REALITY_DEST}"
        log_info "Reality serverNames: ${REALITY_SERVER_NAMES[*]}"
    fi
    log_info "vless-xhttp-reality 的 SNI: ${_xhttp_own:-${XHTTP_REALITY_SNI:-（未启用，与 vless-reality 无法分流）}}"
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
