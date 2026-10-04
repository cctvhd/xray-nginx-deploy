#!/usr/bin/env bash
# ============================================================
# modules/xray.sh
# PROXY 头开关（state 持久化；见 generate_xray_config 内读取）：
#   FALLBACK_PROXY_PROTOCOL    → 8350 回退链（xray xver ↔ nginx proxy_protocol）
#   DECOY_SELF_PROXY_PROTOCOL  → 8321/8326 伪装站（xray xver ↔ nginx listen）

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

# ── 地区公共站表（**唯一来源**）────────────────────────────────
# stdout 每行：<站(不含 :443)>|<人类可读标签>|<该站对应的 serverNames（空格分隔）>
# region ∈ na|eu|as。交互选站（_reality_pick_target_list）与非交互默认
# （_reality_reset_public_params）都读这里 —— 两处各写一份表必然漂移。
# ⚠️ stdout 回传数据，函数内不得调 log_*（见 cert.sh resolve_edit_nodes_script 的说明）。
_reality_region_stations() {
    case "${1:-}" in
        na)
            printf '%s\n' \
                'solanolibrary.com|洛杉矶公共图书馆|solanolibrary.com openclaw.ai www.lapl.org www.siliconvalley.com www.oxy.edu business.ca.gov film.ca.gov' \
                'www.siliconvalley.com|硅谷媒体|www.siliconvalley.com solanolibrary.com www.oxy.edu business.ca.gov openclaw.ai film.ca.gov' \
                'business.ca.gov|加州政府|business.ca.gov film.ca.gov solanolibrary.com www.oxy.edu openclaw.ai' \
                'openclaw.ai|AI 平台|openclaw.ai solanolibrary.com www.lapl.org www.siliconvalley.com www.oxy.edu' \
                'www.oxy.edu|奥克西登特学院|www.oxy.edu solanolibrary.com openclaw.ai business.ca.gov film.ca.gov' \
                'film.ca.gov|加州电影委员会|film.ca.gov business.ca.gov solanolibrary.com openclaw.ai www.oxy.edu' \
                'www.lapl.org|洛杉矶公共图书馆官网|www.lapl.org solanolibrary.com openclaw.ai www.siliconvalley.com www.oxy.edu'
            ;;
        eu)
            printf '%s\n' \
                'ethz.ch|瑞士联邦理工学院|ethz.ch m.ethz.ch debian.ethz.ch cuni.cz mff.cuni.cz www.mpg.de developer.trumpf.com' \
                'www.ecb.europa.eu|欧洲中央银行|www.ecb.europa.eu api.ecb.europa.eu sentinels.copernicus.eu ethz.ch www.mpg.de' \
                'opendata.cern.ch|欧洲核子研究中心|opendata.cern.ch ethz.ch m.ethz.ch www.mpg.de api.aalto.fi www.nic.funet.fi' \
                'yandex.com.tr|Yandex 土耳其|yandex.com.tr ethz.ch www.ecb.europa.eu opendata.cern.ch' \
                'www.mpg.de|马克斯普朗克学会|www.mpg.de developer.trumpf.com ethz.ch m.ethz.ch debian.ethz.ch cuni.cz mff.cuni.cz' \
                'sentinels.copernicus.eu|哥白尼计划|sentinels.copernicus.eu www.ecb.europa.eu api.ecb.europa.eu opendata.cern.ch ethz.ch'
            ;;
        as)
            printf '%s\n' \
                'www.lovelive-anime.jp|日本动画|www.lovelive-anime.jp www.nintendo.co.jp' \
                'www.nintendo.co.jp|任天堂日本|www.nintendo.co.jp www.lovelive-anime.jp'
            ;;
    esac
}

# ── 对方 Reality 槽当前**已生效**的公共站（stdout；对方未借公共 → 空行）──
# 入参 kind = **正在配置的**那个槽 ∈ vless|xhttp，返回的是**另一个槽**占用的站。
# 用途：公共 SNI 候选过滤 —— 以「预防」取代「两槽撞站后再中止」（旧脚本行为：
# 先选的锁定、后选的在候选里看不到它）。
# 判据是「已生效」：对方槽确实处于借公共态且该键有值；对方自建时不占用任何公共站。
# ⚠️ **只读 state**，不读内存变量（vless 侧的 REALITY_SNI 恒等于其 serverNames[0]）：
#    _reality_prepare_public_params / _reality_reset_public_params 每次都先落 state，
#    所以同一轮里先配的槽一定已被后配的槽看到 —— 菜单 x 清空内存后依然成立。
# ⚠️ stdout 回传值，函数内不得调 log_*。
_reality_peer_station() {
    local _kind="${1:-vless}"
    if [[ "$_kind" == "xhttp" ]]; then
        _reality_slot_borrows_public xray-reality || return 0
        printf '%s\n' "$(get_state "REALITY_SNI" "")"
    else
        _reality_slot_borrows_public xhttp-reality || return 0
        printf '%s\n' "$(get_state "XHTTP_REALITY_SNI" "")"
    fi
}
# ── 辅助：地区 + 伪装目标列表选择 ────────────────────────────
# kind=vless(默认)：设置全局 REALITY_DEST 与 REALITY_SERVER_NAMES（已去重）。
# kind=xhttp：仅设置 XHTTP_REALITY_SNI=选中站点域名，不动 REALITY_DEST/serverNames
#             （vless-xhttp-reality 公共用，其 dest 恒=SNI 域）。
# 候选来源 = _reality_region_stations（唯一来源）**减去另一个 Reality 槽当前已生效
# 的公共站**（见 _reality_peer_station）—— 以预防取代「两槽撞站后再中止」。
# 返回 0 = 已选定（变量已设）；1 = 候选被对方占满 / 未取到（**不改动该槽**，
# 由调用方据此给出提示并保持原状）。
_reality_pick_target_list() {
    local _kind="${1:-vless}"
    local _peer
    _peer=$(_reality_peer_station "$_kind")

    # HW_REGION 来自 load_os_info；带默认值，避免 set -u 下未赋值时报 unbound
    local _hw_prefix="${HW_REGION:-}"; _hw_prefix="${_hw_prefix%%/*}"
    local _region_choice
    case "$_hw_prefix" in
        na) _region_choice=1
            log_info "从 HW_REGION=${HW_REGION} 自动选择地区：美国/北美" ;;
        eu) _region_choice=2
            log_info "从 HW_REGION=${HW_REGION} 自动选择地区：欧洲" ;;
        as) _region_choice=3
            log_info "从 HW_REGION=${HW_REGION} 自动选择地区：亚洲" ;;
        *)
            echo "请选择服务器所在地区："
            echo "  1. 美国 / 北美"
            echo "  2. 欧洲"
            echo "  3. 亚洲"
            echo "  4. 自定义"
            echo ""
            read -rp "请选择地区 [1-4，默认2]: " _region_choice
            ;;
    esac

    local _region
    case "${_region_choice:-2}" in
        1) _region=na ;;
        2) _region=eu ;;
        3) _region=as ;;
        4)
            # 自定义输入也要过同一道闸：不得与另一槽已占用的站相同
            local _custom
            if [[ "$_kind" == "xhttp" ]]; then
                read -rp "输入自定义借用站点（domain，不含 :443）: " _custom
                [[ -n "$_custom" ]] || { log_warn "未输入站点，本次不改动该槽"; return 1; }
                if [[ -n "$_peer" && "$_custom" == "$_peer" ]]; then
                    log_warn "自定义站点 ${_custom} 已被另一个 Reality 槽占用；本次不改动该槽"
                    return 1
                fi
                XHTTP_REALITY_SNI="$_custom"
            else
                read -rp "输入自定义 dest（格式 domain:443）: " _custom
                [[ -n "$_custom" ]] || { log_warn "未输入站点，本次不改动该槽"; return 1; }
                if [[ -n "$_peer" && "${_custom%%:*}" == "$_peer" ]]; then
                    log_warn "自定义站点 ${_custom%%:*} 已被另一个 Reality 槽占用；本次不改动该槽"
                    return 1
                fi
                REALITY_DEST="$_custom"
                read -rp "输入 serverName（多个用空格分隔）: " -a REALITY_SERVER_NAMES
            fi
            return 0 ;;
        *) _region=eu ;;
    esac

    local -a _kept=()
    local _ln _station _label
    while IFS= read -r _ln; do
        [[ -n "$_ln" ]] || continue
        _station="${_ln%%|*}"
        [[ -n "$_peer" && "$_station" == "$_peer" ]] && continue
        _kept+=("$_ln")
    done < <(_reality_region_stations "$_region")

    if (( ${#_kept[@]} == 0 )); then
        log_warn "地区「${_region}」的公共站已被另一个 Reality 槽占用（${_peer}），没有可选项"
        log_warn "  本次不改动该槽的 SNI。可选：让那个槽改用自有域自建、或本槽换地区/自定义站点"
        return 1
    fi

    echo ""
    echo "伪装目标（已隐藏另一个 Reality 槽占用的站点${_peer:+：${_peer}}）："
    local _i
    for (( _i=0; _i<${#_kept[@]}; _i++ )); do
        _ln="${_kept[$_i]}"
        _station="${_ln%%|*}"
        _label="${_ln#*|}"; _label="${_label%%|*}"
        printf '  %d. %s:443（%s）\n' "$(( _i+1 ))" "$_station" "$_label"
    done
    local dest_choice
    read -rp "请选择 [1-${#_kept[@]}，默认1]: " dest_choice
    local _di=$(( ${dest_choice:-1} - 1 ))
    (( _di < 0 || _di >= ${#_kept[@]} )) && _di=0
    _ln="${_kept[$_di]}"
    _station="${_ln%%|*}"

    if [[ "$_kind" == "xhttp" ]]; then
        XHTTP_REALITY_SNI="$_station"
        return 0
    fi

    REALITY_DEST="${_station}:443"
    local _sns="${_ln#*|}"; _sns="${_sns#*|}"
    read -ra REALITY_SERVER_NAMES <<< "$_sns"

    # xhttp 模式不走这里；vless 的 serverNames 去重（保持原顺序）
    local -a deduped_server_names=()
    local seen_server_names=" " sn
    for sn in "${REALITY_SERVER_NAMES[@]}"; do
        [[ -n "$sn" ]] || continue
        if [[ "$seen_server_names" != *" ${sn} "* ]]; then
            deduped_server_names+=("$sn")
            seen_server_names+=" ${sn} "
        fi
    done
    REALITY_SERVER_NAMES=("${deduped_server_names[@]}")
    return 0
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

# 该 Reality 槽的 SNI 来源是不是「借公共大站」。0 = 借公共，1 = 用自有域自建。
# 用法: _reality_slot_borrows_public <tag>   tag ∈ {xray-reality, xhttp-reality}
#
# ── 为什么要有这个判断（域名分配与 SNI 来源解耦）───────────────
# 配置表第 3/4 行的域名只表示「分配给该协议的域」，它同时充当：
#   (a) 客户端连接的**地址**（客户端支持用域名当地址），(b) 自建时的 SNI。
# 但**分配了域名 ≠ 必须拿它当 SNI**：用户可以「地址用自有域、SNI 借公共大站」。
# 旧代码用 `-n "$REALITY_DOMAIN"` 一个条件同时决定两件事，于是「借公共 SNI」
# 只能靠**清空域名**来表达（域名一清，连接地址也一起退化成 IP）。用户明确否掉：
# 「两个 reality 显然都分配了域名，但不是就强制协议 SNI 必须使用自己的，
#   它可以是地址，因为客户端支持域名」。
#
# 判据：无域 → 只能借公共（无从自建）；有域 → 看 *_SNI_MODE，缺省 self。
# ⚠️ 缺省 self 是**刻意**的向后兼容：老 state 没有这个键、且域名非空 ⇒ 旧行为
#    就是自建，升级后不能变。同理域名清空后必须回落 public（否则会生成
#    一条 serverNames 指向空串的死配置）。
# ⚠️ 同实现共三份：本文件、modules/nginx.sh、modules/client.sh。改要一起改
#    （模块不能互相依赖对方后加的函数，见 CLAUDE.md）。
_reality_slot_borrows_public() {
    local _own _mode
    if [[ "${1:-}" == "xhttp-reality" ]]; then
        _own="${XHTTP_REALITY_DOMAIN:-}"
        _mode=$(get_state "XHTTP_REALITY_SNI_MODE" "")
    else
        _own="${REALITY_DOMAIN:-}"
        _mode=$(get_state "REALITY_SNI_MODE" "")
    fi
    [[ -z "$_own" ]] && return 0
    [[ "$_mode" == "public" ]]
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

# ── 降级分支写回配置表（cert.sh 不可用时的最小内联版）────────────────
# cert.sh 的 config_table_set_slot_domain 不可用时，直接内联 edit_nodes.py
# --set-slot 把切换同步进配置表，避免下一次「5→1 配置域名表」按表推翻本次切换。
# 槽位词汇映射与 cert.sh 的 config_table_set_slot_domain 一致
#   （xray-reality→vless-reality / xhttp-reality→vless-xhttp-reality）。
# 返回 0 = 已写 / 本机无表（无第二来源，无所谓推翻）；1 = 写失败（只告警、不阻断切换）。
_reality_table_write_fallback() {
    local _tag="${1:-}" _domain="${2:-}" _proto _tsv _script _dir _out _rc
    case "$_tag" in
        xray-reality)  _proto="vless-reality" ;;
        xhttp-reality) _proto="vless-xhttp-reality" ;;
        *) return 1 ;;
    esac
    _tsv="${EDIT_NODES_DATA_DIR:-${STATE_DIR:-/etc/xray-deploy}}/.config.tsv"
    [[ -f "$_tsv" ]] || return 0
    _script="$(dirname "${MODULES_DIR:-.}")/edit_nodes.py"
    [[ -f "$_script" ]] || _script="${STATE_DIR:-/etc/xray-deploy}/edit_nodes.py"
    [[ -f "$_script" ]] || { log_warn "取不到 edit_nodes.py，配置表未同步（下次 5→1 会按表推翻本次切换）"; return 1; }
    _dir="$(dirname "$_tsv")"
    _out=$(python3 "$_script" "$_dir" --set-slot "$_proto" "${_domain:--}" 2>&1); _rc=$?
    case "$_rc" in
        0) log_info "${_out:-配置表已同步}" ;;
        4) log_warn "配置表实际不存在（${_dir}/.config.tsv），跳过写回" ;;
        *) log_warn "写回配置表失败：${_out}"; return 1 ;;
    esac
    return 0
}

# ── 规则 3：Reality SNI 来源切换的冲突检测（**只读**；命中即中止当次操作）──
# 用法: _reality_sni_conflict_check <slot> <self|public> [domain]
#   返回 0 = 无冲突，可执行切换；1 = 有冲突，已打印「槽 / 域名 / 原因 / 可选方案」。
# ⚠️ 本函数只读 state 与配置表，**绝不**做任何修复性写入 —— 「发现冲突不自动修改」
#    是 2026-10-02 的明确要求（旧代码在同域双标处自动 untag，属越权改域名分配）。
# ⚠️ 同实现只此一份：交互层（菜单 11/x）与事务入口（cert.sh）都调它，避免两份漂移。
_reality_sni_conflict_check() {
    local _slot="$1" _mode="$2" _domain="${3:-}"
    local _label _row _peer_slot
    if [[ "$_slot" == "xray-reality" ]]; then
        _label="VLESS-Reality"; _row=4; _peer_slot="xhttp-reality"
    else
        _label="XHTTP-Reality"; _row=3; _peer_slot="xray-reality"
    fi

    # ⚠️ 域名/SNI 一律以 **state** 为准，不读内存变量（规则 1：本流程不改域名分配，
    #    入参仅作回显）。state 才是「当前生效」的事实来源。
    local _st_dom
    if [[ "$_slot" == "xray-reality" ]]; then _st_dom=$(get_state "REALITY_DOMAIN" "")
    else _st_dom=$(get_state "XHTTP_REALITY_DOMAIN" ""); fi
    [[ -n "$_st_dom" ]] && _domain="$_st_dom"

    _conflict_report() {
        echo ""
        log_error "[冲突] ${_label}（配置表第 ${_row} 行）"
        log_error "  域名：${_domain:-未分配}"
        log_error "  原因：$1"
        local _p
        while IFS= read -r _p; do
            [[ -n "$_p" ]] && log_error "  可选处理方案：${_p}"
        done < <(printf '%s' "$2" | tr '|' '\n')
        log_error "  本次操作已中止，未改动 state / 配置表 / nginx / xray。"
    }

    # 1) 选自建但表里该槽没有域名
    if [[ "$_mode" == "self" && -z "$_domain" ]]; then
        _conflict_report \
            "选「自建」，但配置表第 ${_row} 行没有域名——SNI 与连接地址都无从确定。" \
            "去主菜单 5→1 在该行填域名并签发证书|改选「借公共大站 SNI」"
        return 1
    fi

    # 2) 两个 Reality 槽使用了同一域名（域层冲突）
    local _peer_dom
    if [[ "$_peer_slot" == "xhttp-reality" ]]; then _peer_dom=$(get_state "XHTTP_REALITY_DOMAIN" "")
    else _peer_dom=$(get_state "REALITY_DOMAIN" ""); fi
    if [[ -n "$_domain" && -n "$_peer_dom" && "$_domain" == "$_peer_dom" ]]; then
        _conflict_report \
            "两个 Reality 槽使用了同一域名 ${_domain}——两节点 SNI 会串台，stream map 同 key 双值。" \
            "去主菜单 5→1 给其中一个槽换一个域名|让其中一个槽改选「借公共大站 SNI」"
        return 1
    fi

    if [[ "$_mode" == "self" ]]; then
        # 3) 表里该槽的模式列是 cdn
        local _tbl_mode=""
        declare -F config_table_mode_for_slot >/dev/null 2>&1 \
            && _tbl_mode=$(config_table_mode_for_slot "$_slot" 2>/dev/null || true)
        if [[ "$_tbl_mode" == "cdn" ]]; then
            _conflict_report \
                "配置表的「模式」列是 cdn，Reality 槽必须是直连（cdn 域的 443 在 CDN 边缘终结，本机看不到真实 SNI）。" \
                "去主菜单 5→1 把该行模式改成「直连」|改选「借公共大站 SNI」"
            return 1
        fi
        # 4) 该域根域证书不存在 —— 本流程**不代签证书**
        local _root _cert
        _root=$(printf '%s' "$_domain" | awk -F. '{print $(NF-1)"."$NF}')
        _cert=$(get_state "CERT_PATH_${_root//./_}" "")
        [[ -z "$_cert" ]] && _cert="/etc/letsencrypt/live/${_root}"
        if [[ ! -s "${_cert}/fullchain.pem" ]] \
           || ! openssl x509 -in "${_cert}/fullchain.pem" -noout -checkhost "$_domain" >/dev/null 2>&1; then
            _conflict_report \
                "${_root} 的证书不存在或不覆盖 ${_domain}（${_cert}/fullchain.pem）；本流程不代签证书。" \
                "去主菜单 5→1 重跑一次让该域签上证书|改选「借公共大站 SNI」"
            return 1
        fi
    else
        # 5) 两槽借同一个公共站
        local _mine _peer_sni
        if [[ "$_slot" == "xray-reality" ]]; then _mine=$(get_state "REALITY_SNI" "")
        else _mine=$(get_state "XHTTP_REALITY_SNI" ""); fi
        if [[ "$_peer_slot" == "xray-reality" ]]; then _peer_sni=$(get_state "REALITY_SNI" "")
        else _peer_sni=$(get_state "XHTTP_REALITY_SNI" ""); fi
        if [[ -n "$_mine" && -n "$_peer_sni" && "$_mine" == "$_peer_sni" ]]; then
            _conflict_report \
                "两个 Reality 槽借用了同一个公共站 ${_mine}——stream map 一个 SNI 只能有一个后端，后配的会静默失联。" \
                "给其中一个槽换一个借用站点（本菜单 3）|让其中一个槽改用自有域自建"
            return 1
        fi
    fi

    # 6) 拟用 SNI 与其它协议的 443 业务域名重合（域层，与 preflight Check 1/2 同源）
    local _cand_sni="$_domain"
    if [[ "$_mode" == "public" ]]; then
        if [[ "$_slot" == "xray-reality" ]]; then _cand_sni=$(get_state "REALITY_SNI" "")
        else _cand_sni=$(get_state "XHTTP_REALITY_SNI" ""); fi
    fi
    local _d
    for _d in "$(get_state XHTTP_DOMAIN '')" "$(get_state GRPC_DOMAIN '')" \
             "$(get_state ANYTLS_DOMAIN '')" "$(get_state NAIVE_DOMAIN '')"; do
        if [[ -n "$_d" && -n "$_cand_sni" && "$_d" == "$_cand_sni" ]]; then
            _conflict_report \
                "${_cand_sni} 同时被其它协议声明为 443 业务域名，stream map 会出现同 key 双值（串台）。" \
                "去主菜单 5→1 调整域名分配|换一个借用站点"
            return 1
        fi
    done
    return 0
}

# ── 「自有域自建 → 借公共大站 SNI」前，把该槽的公共伪装参数备齐并落 state ──
# 用法: _reality_prepare_public_params <tag> [force]   tag ∈ {xray-reality, xhttp-reality}
# 返回 0 = 参数已就绪且已写入 state；1 = 未取到参数（**不改动该槽**），调用方取消切换。
#
# 复用判据（2026-10-02 增第 4 条）：dest 为空 / 指向本地伪装站 127.0.0.1:* /
# serverNames 含被摘掉的自建域 / **保留的站等于另一个 Reality 槽当前占用的站**
# —— 任一命中即视为不可用，进入现场重选（候选已排除对方占用的站）。
# 第 4 条堵的是：vless 自建期间保留的旧公共值（如 ethz.ch）恰被 xhttp 借走，
# 若前三条判定「可用」就直接复用 → 切回借公共即两槽同站。
# ⚠️ force：本项兼作「换伪装站点」，用户按了就必须真的重选一次（不复用）。
#
# 为什么必须在切换**之前**单独做这一步：切换的级联
# （cert.sh apply_reality_sni_changes → regen_after_domain_change）要用 state 里
# 这些值重建产物 ——
#   · vless : REALITY_DEST / REALITY_SERVER_NAMES → generate_xray_config 的
#             dokodemo 4431 目标与 reality serverNames；generate_sni_map 也按
#             REALITY_SERVER_NAMES 往 443 分流里补 8320 路由
#   · xhttp : XHTTP_REALITY_SNI → 其 dest 恒 = 该站点:443
# 而这些键在「自建」期间会被 sync_hydrate_client_state（modules/sync.sh，由
# do_client 触发）**按 live config.json 反向覆盖成自建值** —— dest 变
# 127.0.0.1:8321、serverNames 变 [自建域]。所以「自建时保留公共回滚态、切回借公共
# SNI 时直接复用」在实机上不成立：只要生成过一次客户端链接，保留的就已是自建值。
_reality_prepare_public_params() {
    local tag="$1" force="${2:-}"

    # 另一个槽当前占用的站（_reality_peer_station 只读 state，不看内存变量）
    local _peer=""
    if [[ "$tag" == "xhttp-reality" ]]; then _peer=$(_reality_peer_station xhttp)
    else _peer=$(_reality_peer_station vless); fi

    if [[ "$tag" == "xhttp-reality" ]]; then
        # xhttp 的公共参数只有 XHTTP_REALITY_SNI，而 collect_reality_params
        # 每轮进入时都会先把它清空（防残留把自建槽误当公共），故无可复用值。
        log_info "vless-xhttp-reality 借公共 SNI：请选择借用站点（=其 SNI，dest 自动=该站点:443）"
        if ! _reality_pick_target_list xhttp; then
            log_warn "未选到借用站点（候选被另一槽占满或未输入），本次不改动该槽"
            return 1
        fi
        if [[ -z "${XHTTP_REALITY_SNI:-}" ]]; then
            log_warn "未选到借用站点，本次不改动该槽"
            return 1
        fi
        save_state "XHTTP_REALITY_SNI" "${XHTTP_REALITY_SNI:-}"
        log_info "vless-xhttp-reality SNI 设为: ${XHTTP_REALITY_SNI}"
        return 0
    fi

    # 保留值的 dest 主机名（**必须带 :- **：菜单 11 的 Stage A 阶段 REALITY_DEST
    # 尚未水合，裸展开 `${REALITY_DEST%%:*}` 会在 set -u 下报 unbound variable）
    local _dest_host="${REALITY_DEST:-}"; _dest_host="${_dest_host%%:*}"
    local _usable=1 _sn
    [[ -z "${REALITY_DEST:-}" || "${REALITY_DEST}" == 127.0.0.1:* ]] && _usable=0
    for _sn in "${REALITY_SERVER_NAMES[@]}"; do
        [[ -n "$_sn" && "$_sn" == "${REALITY_DOMAIN:-}" ]] && _usable=0
    done
    # 保留的站 == 另一个槽占用的站 → 不可用（否则复用会造出两槽同站）
    if [[ -n "$_peer" ]]; then
        [[ "${REALITY_SERVER_NAMES[0]:-}" == "$_peer" || "$_dest_host" == "$_peer" ]] && _usable=0
    fi

    if [[ -n "$force" ]] || (( ! _usable )); then
        if [[ -n "$_peer" && ( "${REALITY_SERVER_NAMES[0]:-}" == "$_peer" || "$_dest_host" == "$_peer" ) ]]; then
            log_info "原保留的公共站 ${_peer} 已被 vless-xhttp-reality 占用，重新选择（候选已排除它）"
        else
            log_info "重新选择 vless-reality 借用的公共大站（原公共参数已被自建模式的客户端链接同步覆盖，无法复用）"
        fi
        REALITY_DEST=""
        REALITY_SERVER_NAMES=()
        _reality_pick_target_list || return 1
        _probe_vless_spider_x
    else
        log_info "复用已保留的公共回滚参数: dest=${REALITY_DEST} serverNames=${REALITY_SERVER_NAMES[*]:-}"
    fi

    save_state "REALITY_DEST"         "${REALITY_DEST:-}"
    save_state "REALITY_SERVER_NAMES" "${REALITY_SERVER_NAMES[*]:-}"
    save_state "REALITY_SNI"          "${REALITY_SERVER_NAMES[0]:-}"
    save_state "REALITY_SPIDER_X"     "${REALITY_SPIDER_X:-}"
    return 0
}

# ── 非交互「重置/补齐公共参数」：事务切换用（无 read）────────
# 用法: _reality_reset_public_params <tag>   tag ∈ {xray-reality, xhttp-reality}
# 与 _reality_prepare_public_params 同职责，但**从不读 stdin**：复用判据相同
# （dest 为空、或指向本地伪装站 127.0.0.1:*、或 serverNames 含被摘掉的自建域），
# 不可用时不是现场问答重选，而是**确定性取 HW_REGION 对应地区的第一个默认站**，
# 并**跳过另一个 Reality 槽已占用的站**（2026-10-02：以预防取代「撞站后中止」）。
# 返回 0 = 参数就绪（可能是纯复用，不动 state）；1 = 地区候选被对方占满、取不到
#   默认站 —— **不改动该槽任何值**，由调用方给出提示并保持原状。
#
# 供 apply_reality_sni_changes（cert.sh）公共方向在级联前调用。交互菜单的
# case 2/3 仍走 _reality_prepare_public_params（含复用/换站问答，交互行为不变）；
# 本函数只兜住「事务直接切公共」的路径（矩阵/R 恢复/降级分支），保证公共参数
# 一定干净、不含自建残留。⚠️ 若公共参数本就可用（比如菜单 case 2 刚备齐、或
# R 恢复时 state 里已有干净公共值），本函数是**纯复用**，不会覆盖用户已选站点。
_reality_reset_public_params() {
    local tag="$1"
    local _region _peer _ln _station _sns
    # ⚠️ 本段本批被提前到函数首行：HW_REGION 现在**每次调用**都会被读，
    #    必须带默认值（空 → 走 * 分支＝ eu，与既有回退一致），否则 set -u 下报 unbound
    local _hw="${HW_REGION:-}"; _hw="${_hw%%/*}"
    case "$_hw" in
        na) _region=na ;;
        as) _region=as ;;
        *)  _region=eu ;;
    esac

    if [[ "$tag" == "xhttp-reality" ]]; then
        # xhttp 公共参数只有 XHTTP_REALITY_SNI（dest 恒=该站点:443）。它不会被
        # sync_hydrate_client_state 覆盖（该函数只在第一个 reality 入站即
        # reality-direct/vless 上 break），故空即真没选过 → 确定性补默认站点。
        XHTTP_REALITY_SNI=$(get_state "XHTTP_REALITY_SNI" "")
        _peer=$(_reality_peer_station xhttp)
        # 复用判据多一条：保留值 == 另一个槽占用的站 → 视为不可用，重新挑（见下）
        if [[ -n "${XHTTP_REALITY_SNI:-}" && "${XHTTP_REALITY_SNI}" != "$_peer" ]]; then
            return 0
        fi
        if [[ -n "${XHTTP_REALITY_SNI:-}" && "${XHTTP_REALITY_SNI}" == "$_peer" ]]; then
            log_warn "保留的借用站点 ${_peer} 已被另一个 Reality 槽占用，重新挑选（已排除它）"
            XHTTP_REALITY_SNI=""
        fi
        while IFS= read -r _ln; do
            [[ -n "$_ln" ]] || continue
            _station="${_ln%%|*}"
            [[ -n "$_peer" && "$_station" == "$_peer" ]] && continue
            XHTTP_REALITY_SNI="$_station"
            save_state "XHTTP_REALITY_SNI" "$XHTTP_REALITY_SNI"
            log_info "补齐 vless-xhttp-reality 借用站点（默认，已避开另一槽占用）: ${XHTTP_REALITY_SNI}"
            return 0
        done < <(_reality_region_stations "$_region")
        log_warn "地区「${_region}」的公共站已被另一个 Reality 槽占用（${_peer}），非交互路径取不到默认站"
        log_warn "  本次不改动 vless-xhttp-reality 的借用站点；请到菜单 11/x 换地区或自定义站点"
        return 1
    fi

    # vless：从 state 读回当前值再判（事务里 globals 未必被 load_domain_state 填过）。
    REALITY_DEST=$(get_state "REALITY_DEST" "")
    REALITY_SERVER_NAMES=()
    local _rsn _selfdom
    _rsn=$(get_state "REALITY_SERVER_NAMES" "")
    [[ -n "$_rsn" ]] && read -ra REALITY_SERVER_NAMES <<< "$_rsn"
    _selfdom=$(get_state "REALITY_DOMAIN" "")

    _peer=$(_reality_peer_station vless)
    # 同 H20：dest 主机名必须带 :- 默认值（set -u 安全）
    local _dest_host="${REALITY_DEST:-}"; _dest_host="${_dest_host%%:*}"
    local _usable=1 _sn
    [[ -z "${REALITY_DEST:-}" || "${REALITY_DEST}" == 127.0.0.1:* ]] && _usable=0
    for _sn in "${REALITY_SERVER_NAMES[@]}"; do
        [[ -n "$_sn" && -n "$_selfdom" && "$_sn" == "$_selfdom" ]] && _usable=0
    done
    # 加固（2026-10-02）：state 丢了 REALITY_DOMAIN 时上一条判据会失效；若保留的
    # serverNames[0] 是**配置表里的自有域**（而非第三方公共站），说明它是自建残留。
    # ⚠️ 判据必须是「在配置表里」：ethz.ch 这类公共站本就不在表里，否则会误杀复用。
    local _sn0="${REALITY_SERVER_NAMES[0]:-}"
    if [[ -n "$_sn0" ]] && declare -F config_table_slot_domains >/dev/null 2>&1 \
       && config_table_slot_domains 2>/dev/null | cut -f2 | grep -qxF "$_sn0"; then
        _usable=0
    fi
    # 复用判据多一条：保留的站 == 另一个槽占用的站 → 不可用，重新挑（见下）
    if [[ -n "$_peer" ]]; then
        [[ "${REALITY_SERVER_NAMES[0]:-}" == "$_peer" || "$_dest_host" == "$_peer" ]] && _usable=0
    fi
    (( _usable )) && return 0
    if [[ -n "$_peer" && ( "${REALITY_SERVER_NAMES[0]:-}" == "$_peer" || "$_dest_host" == "$_peer" ) ]]; then
        log_warn "保留的公共站 ${_peer} 已被另一个 Reality 槽占用，重新挑选（已排除它）"
    fi

    while IFS= read -r _ln; do
        [[ -n "$_ln" ]] || continue
        _station="${_ln%%|*}"
        [[ -n "$_peer" && "$_station" == "$_peer" ]] && continue
        _sns="${_ln#*|}"; _sns="${_sns#*|}"
        REALITY_DEST="${_station}:443"
        read -ra REALITY_SERVER_NAMES <<< "$_sns"
        REALITY_SPIDER_X=$(get_state "REALITY_SPIDER_X" "")
        [[ -z "${REALITY_SPIDER_X:-}" ]] && REALITY_SPIDER_X="/"
        save_state "REALITY_DEST"         "${REALITY_DEST}"
        save_state "REALITY_SERVER_NAMES" "${REALITY_SERVER_NAMES[*]:-}"
        save_state "REALITY_SNI"          "${REALITY_SERVER_NAMES[0]:-}"
        save_state "REALITY_SPIDER_X"     "${REALITY_SPIDER_X}"
        log_info "重置 vless-reality 公共参数（默认，已避开另一槽占用）: dest=${REALITY_DEST} serverNames=${REALITY_SERVER_NAMES[*]:-}"
        return 0
    done < <(_reality_region_stations "$_region")
    log_warn "地区「${_region}」的公共站已被另一个 Reality 槽占用（${_peer}），非交互路径取不到默认站"
    log_warn "  本次不改动 vless-reality 的公共参数；请到菜单 11/x 换地区或自定义站点"
    return 1
}

# ── 单 Reality 槽 SNI 来源决策 ───────────────────────────────
# 用法: _reality_ask_slot_sni <tag>   tag ∈ {xray-reality, xhttp-reality}
# 只问「SNI 来源」，**不问域名**（域名归主菜单 5→1 的配置表）。可选方向严格按
# 「表里该槽有没有域名」：
#   有域 → 1 自建 / 2 借公共 / 3 换公共站
#   无域 → 1 借公共 / 2 换公共站 / 3 自建（必被规则 3 拦下并给出冲突说明）
# 选完只**记录目标**；由 collect 在两个槽都问完后一次调用 apply_reality_sni_changes（cert.sh）落地。
_reality_ask_slot_sni() {
    local tag="$1"
    local label own_key _sni_key row
    if [[ "$tag" == "xray-reality" ]]; then
        label="VLESS-Reality"; own_key="REALITY_DOMAIN";       _sni_key="REALITY_SNI";       row=4
    else
        label="XHTTP-Reality"; own_key="XHTTP_REALITY_DOMAIN"; _sni_key="XHTTP_REALITY_SNI"; row=3
    fi
    local own="${!own_key:-}" _pub_now _borrows=0
    _reality_slot_borrows_public "$tag" && _borrows=1
    _pub_now=$(get_state "$_sni_key" "")

    # 切换后要把「公共参数已就绪」回传调用方（collect_reality_params 据此跳过第二遍问答）
    local _ready_var
    if [[ "$tag" == "xray-reality" ]]; then _ready_var="_REALITY_VLESS_PUBLIC_READY"
    else _ready_var="_REALITY_XHTTP_PUBLIC_READY"; fi

    local _now_desc
    if (( _borrows )); then _now_desc="借公共大站 SNI ${_pub_now:-（未选）}"
    else _now_desc="自有域自建 ${own}"; fi

    echo ""
    local _choice _def=1
    if [[ -n "$own" ]]; then
        (( _borrows )) && _def=2
        log_info "【${label}】域名: ${own}（配置表第 ${row} 行，同时是客户端连接地址）"
        log_info "【${label}】当前 SNI 来源: ${_now_desc}"
        echo "  请选择该协议的 SNI 来源（域名分配请到主菜单 5→1 改）："
        echo "  1) 自建 —— SNI / 证书 / dest 都用 ${own}"
        echo "  2) 借公共大站 —— SNI / dest 用公共站，${own} 只作连接地址"
        echo "  3) 换一个借用的公共大站 SNI"
        read -rp "  请选择 [默认${_def} = 保持当前]: " _choice
        case "${_choice:-$_def}" in
            1)
                if (( _borrows )); then
                    printf -v "_REALITY_TARGET_MODE_${tag//-/_}" '%s' self
                    log_info "${label} 已记录：将以「自有域自建」落地（两槽问完后一次执行）"
                else
                    log_info "${label} 保持自建 ${own}"
                fi ;;
            2)
                if (( _borrows )); then
                    log_info "${label} 保持借公共大站 SNI ${_pub_now:-（未选）}"
                elif _reality_prepare_public_params "$tag"; then
                    printf -v "_REALITY_TARGET_MODE_${tag//-/_}" '%s' public
                    printf -v "$_ready_var" '%s' 1
                    log_info "${label} 已记录：将以「借公共大站 SNI」落地（两槽问完后一次执行）"
                else
                    log_warn "未能备齐公共伪装参数，已取消本次「借公共大站 SNI」"
                fi ;;
            3)
                if _reality_prepare_public_params "$tag" force; then
                    printf -v "_REALITY_TARGET_MODE_${tag//-/_}" '%s' public
                    printf -v "$_ready_var" '%s' 1
                    log_info "${label} 已记录：将以「借公共大站 SNI」落地（换站）"
                else
                    log_warn "未能选到借用站点，保持当前 SNI 来源（${_now_desc}）"
                fi ;;
            *)
                log_info "${label} 保持当前 SNI 来源（${_now_desc}）" ;;
        esac
    else
        log_info "【${label}】配置表第 ${row} 行未分配域名 —— 连接地址只能用服务器 IP，且只能借公共大站 SNI"
        echo "  1) 保持 / 选用借公共大站 SNI"
        echo "  2) 换一个借用的公共大站 SNI"
        echo "  3) 自建（当前不可用：表里该槽没有域名）"
        read -rp "  请选择 [默认1]: " _choice
        case "${_choice:-1}" in
            2)
                if _reality_prepare_public_params "$tag" force; then
                    printf -v "$_ready_var" '%s' 1
                else
                    log_warn "未能选到借用站点，保持原公共 SNI"
                fi ;;
            3)
                printf -v "_REALITY_TARGET_MODE_${tag//-/_}" '%s' self
                log_info "${label} 已记录：将以「自有域自建」落地（表里无域名，冲突检测会拦下并说明）" ;;
            *)
                log_info "${label} 保持借公共大站 SNI" ;;
        esac
        # 该槽无自有域 ⇒ 只能借公共（无自建候选）：置位供 collect_reality_params 打指路
        _REALITY_SLOT_GUIDE=1
    fi

    declare -F load_domain_state >/dev/null 2>&1 && load_domain_state
    return 0
}

# ── 收集 Reality 伪装参数 ────────────────────────────────────
collect_reality_params() {
    echo ""
    log_step "配置 Reality 伪装参数"
    echo ""

    local _vless_own="${REALITY_DOMAIN:-}" _xhttp_own="${XHTTP_REALITY_DOMAIN:-}"

    # Stage A 选「切到公共大站 SNI」时会就地备齐公共参数并置位（见
    # _reality_prepare_public_params）。这两个标记必须每轮清零：留着上一轮的值
    # 会让本轮静默跳过公共参数选择，用户看到参数没问就定死了。
    _REALITY_VLESS_PUBLIC_READY=""
    _REALITY_XHTTP_PUBLIC_READY=""

    # ── 规则 3：同域双标 = 冲突，**中止本次配置**，不自动改域名分配 ──
    # （旧代码在这里自动 untag，属越权改 DOMAIN_PROTO / DOMAIN_PRIMARY / DOMAIN_REGISTRY）
    if [[ -n "${_xhttp_own}" && "${_xhttp_own}" == "${_vless_own}" ]]; then
        local _xr_mode=public
        [[ "$(get_state XHTTP_REALITY_SNI_MODE '')" == "self" ]] && _xr_mode=self
        _reality_sni_conflict_check xhttp-reality "$_xr_mode" "$_xhttp_own"
        log_error "Reality 配置处理已中止；现场未改动"
        return 1
    fi

    # ═══ Stage A：逐槽 SNI 来源决策 ═══
    # 每个 Reality 协议独立选「用自有域自建 / 借公共大站 SNI」。
    # 选完只记录目标；两槽问完后一次调用 apply_reality_sni_changes（cert.sh）落地（**不写配置表**）
    # → 自建方向先签证书 → 再级联重建 nginx/xray/订阅，任一步失败全部回滚。
    # ⚠️ 配置表仍是唯一来源：这里改的**同时**落表，故 5→1 重跑不会推翻本次选择。
    # ⚠️ tag/untag 内部 rebuild+load_domain_state 刷新了 shell 全局
    #    REALITY_DOMAIN / XHTTP_REALITY_DOMAIN —— Stage A 后必须重快照。
    # 进入 Stage A 前该槽是否已是「借公共」（mode=public）。Stage B 据此跳过对
    # 「本来就借公共」的槽的第二遍地区/目标问答 —— 那种槽公共参数已在 state；
    # 只有刚在 Stage A 切换（已备齐并置 _REALITY_*_PUBLIC_READY）或刚被上方
    # 「同域双标」防御块摘除标签（mode 非 public、公共参数空）的槽才需要 Stage B
    # 现场重选。⚠️ 不能拿「own 为空」当「已 public」：own 为空也可能是刚被
    # 摘标签的槽，那种槽公共参数还没备齐，跳过会让它带着空 SNI 进生成器。
    local _vless_was_pub=0 _xhttp_was_pub=0
    [[ "$(get_state REALITY_SNI_MODE "")" == "public" ]]       && _vless_was_pub=1
    [[ "$(get_state XHTTP_REALITY_SNI_MODE "")" == "public" ]] && _xhttp_was_pub=1

    _REALITY_SLOT_GUIDE=0
    _REALITY_TARGET_MODE_xray_reality=""
    _REALITY_TARGET_MODE_xhttp_reality=""
    _reality_ask_slot_sni xray-reality
    _reality_ask_slot_sni xhttp-reality
    # ── 两个槽都问完后，**一次**调用同一事务把两槽一起落地（正式菜单 11/x 的路径）──
    #    逐槽调用只是测试脚本的调用方式，函数本身与这里完全相同。
    if ! declare -F apply_reality_sni_changes >/dev/null 2>&1; then
        declare -F load_module >/dev/null 2>&1 && load_module cert >/dev/null 2>&1 || true
    fi
    if declare -F apply_reality_sni_changes >/dev/null 2>&1; then
        apply_reality_sni_changes xray-reality xhttp-reality || {
            log_warn "SNI 来源变更未能落地（原因见上）；本次 Reality 配置处理中止"
            return 1
        }
    else
        log_error "缺少 apply_reality_sni_changes（cert 模块未加载），无法落地 SNI 来源变更"
        return 1
    fi
    _vless_own="${REALITY_DOMAIN:-}"
    _xhttp_own="${XHTTP_REALITY_DOMAIN:-}"
    # 该槽是不是「借公共 SNI」——判据是 SNI 来源，**不是**「有没有分配域名」。
    # 域名与 SNI 来源解耦：分配了自有域照样能借公共 SNI（域名留作连接地址）。
    local _vless_pub=0 _xhttp_pub=0
    _reality_slot_borrows_public xray-reality  && _vless_pub=1
    _reality_slot_borrows_public xhttp-reality && _xhttp_pub=1

    echo ""
    log_info "约定：配置表第 3/4 行的域名 = 分配给该协议的域（客户端**连接地址**）；"
    log_info "      SNI 来源在本菜单上面单独选（自有域自建 / 借公共大站），两者互不牵连。"
    if (( _REALITY_SLOT_GUIDE )); then
        log_info "如需让借公共 SNI 的槽改用自有域自建：主菜单 5 为该域签发证书 → 5→1 在对应行填域名 → 重跑本菜单"
    fi

    # ========================================================
    # 公共伪装参数：仅配置仍「借公共 SNI」的槽位。
    # XHTTP_REALITY_SNI 必须重置：xhttp 自建时要置空（防残留把自建槽误当公共）。
    # REALITY_DEST / REALITY_SERVER_NAMES 不预清：vless 自建时生成器固定
    # dest→本地伪装站8321、serverNames=["REALITY_DOMAIN"]，不读它们。
    # ⚠️ 别把它们当「公共模式回滚态」用：它们会被 sync_hydrate_client_state
    #    按 live config.json 覆盖成自建值，切回借公共 SNI 时**不能**直接复用。
    #    切公共前的备齐动作在 _reality_prepare_public_params（Stage A 里调）。
    # ========================================================
    # XHTTP_REALITY_SNI 只在 xhttp 自建时需要置空（防残留把自建槽误当公共）；
    # 借公共时下方会「复用 Stage A 已落 state 的值」或现场重选，先清会把值丢掉
    # → 复用分支拿到空串 → generate_xray_config 把空值写回 state（F1/F6 根因）。
    if (( ! _xhttp_pub )); then
        XHTTP_REALITY_SNI=""
    fi
    echo ""

    # 把 state 里的公共参数（dest/serverNames/spiderX）读回 shell：
    #   · 自建时生成器不读它们，读回只为让调用方的 save 块原样回写（保住
    #     「切回借公共 SNI 后待复用」的回滚态；wizard 的 restore_domain_arrays
    #     只还原 serverNames 数组，dest/spiderX 从不还原，且 nounset 下裸引用
    #     未赋值的 REALITY_DEST 会崩）。
    #   · 借公共时这些是 Stage A 的 _reality_prepare_public_params 刚落盘的
    #     最新值，读回与内存一致；若下方现场重选，会被 _reality_pick_target_list
    #     覆写，无副作用。
    # ⚠️ 必须**无条件**读回（旧代码只在自建时读）：域名与 SNI 来源解耦后，
    #    「借公共 + 域名保留」也是常态，那种槽同样需要这套回写。
    REALITY_DEST=$(get_state "REALITY_DEST" "")
    REALITY_SPIDER_X=$(get_state "REALITY_SPIDER_X" "")
    REALITY_SERVER_NAMES=()
    local _rsn_state
    _rsn_state=$(get_state "REALITY_SERVER_NAMES" "")
    [[ -n "${_rsn_state}" ]] && read -ra REALITY_SERVER_NAMES <<< "${_rsn_state}"

    # ── vless 槽仍借公共 SNI：选借用站点（含地区 + 目标）──
    if (( _vless_pub )); then
        if [[ -z "${_REALITY_VLESS_PUBLIC_READY:-}" ]] && (( ! _vless_was_pub )); then
            # 候选被另一槽占满/未取到时 _reality_pick_target_list 返回 1 并已打印原因：
            # 不中止整个流程，回落到非交互默认（同样跳过对方槽占用的站）。
            if _reality_pick_target_list; then
                _probe_vless_spider_x
            else
                log_warn "vless-reality 未选到借用站点，改用非交互默认参数"
                _reality_reset_public_params xray-reality \
                    || log_warn "vless-reality 公共参数仍未就绪，请在菜单 11/x 处理"
            fi
        else
            # 复用前兜底：do_reconf_xray（菜单 x）清空公共参数但保留 mode=public，
            # 「复用」分支若直接放行会拿到空 dest/serverNames → 空 serverNames 坏配置。
            # _reality_reset_public_params 非交互：参数完好则纯复用（不动 state），
            # 空/被污染则确定性补默认站点（跳过另一槽占用的站），绝不放行空参数。
            _reality_reset_public_params xray-reality \
                || log_warn "vless-reality 公共参数未就绪（另一槽已占满本地区候选），请在菜单 11/x 处理"
            log_info "复用 vless-reality 的公共伪装参数（已借公共，不重选）"
        fi
    fi

    # ── xhttp 槽仍借公共 SNI：选借用站点 ──
    if (( _xhttp_pub )); then
        if [[ -z "${_REALITY_XHTTP_PUBLIC_READY:-}" ]] && (( ! _xhttp_was_pub )); then
            if (( _vless_pub )) && (( ${#REALITY_SERVER_NAMES[@]} > 1 )); then
                # 旧行为：vless 先选定的站（serverNames[0]）已锁定，xhttp 只从**剩下
                # 的** serverNames[1:] 里挑 —— 天然不含对方槽的站点，与本批新增的
                # 「按对方已生效站过滤」是同一约束，故保留该捷径（省一遍地区问答）。
                echo ""
                echo "请选择 vless-xhttp-reality 使用的伪装 SNI："
                local _npool=${#REALITY_SERVER_NAMES[@]}
                local _i=1 _sn2
                for _sn2 in "${REALITY_SERVER_NAMES[@]:1}"; do echo "  ${_i}. ${_sn2}"; (( _i++ )); done
                echo "  （默认 1：${REALITY_SERVER_NAMES[1]}）"
                read -rp "请选择 [1-$(( _npool - 1 ))，默认1]: " _sni_choice
                local _sni_idx=$(( ${_sni_choice:-1} - 1 ))
                (( _sni_idx < 0 || _sni_idx >= _npool - 1 )) && _sni_idx=0
                XHTTP_REALITY_SNI="${REALITY_SERVER_NAMES[$(( _sni_idx + 1 ))]}"
                log_info "vless-xhttp-reality SNI 设为: ${XHTTP_REALITY_SNI}"
            else
                # vless 是自建（serverNames 里那份是旧回滚值，不能用）或列表太短
                # → xhttp 自己走一遍借用站点选择（其 dest 恒 = 该站点:443），
                # 候选已排除 vless 当前占用的站。
                log_info "vless-xhttp-reality 借公共 SNI：请选择借用站点（=其 SNI，dest 自动=该站点:443）"
                # ⚠️ 必须用 if 收掉返回值：install.sh 顶部是 set -euo pipefail，裸调一个
                #    返回 1 的函数会直接退出（菜单路径虽被 run_menu_action 的 `||`
                #    关掉 errexit，这里不依赖那个上下文）。
                if _reality_pick_target_list xhttp && [[ -n "${XHTTP_REALITY_SNI:-}" ]]; then
                    log_info "vless-xhttp-reality SNI 设为: ${XHTTP_REALITY_SNI}"
                else
                    log_warn "未选到借用站点，vless-xhttp-reality 保持原 SNI——请到主菜单 11/x 处理"
                fi
            fi
        else
            # 复用前兜底（同 vless 槽）：do_reconf_xray 清空 XHTTP_REALITY_SNI 但
            # 保留 mode=public，直接读 state 会拿到空值 → 空 serverNames。
            # _reality_reset_public_params 非交互补齐默认站点（完好则纯复用，不动 state）。
            _reality_reset_public_params xhttp-reality \
                || log_warn "vless-xhttp-reality 公共参数未就绪（另一槽已占满本地区候选），请在菜单 11/x 处理"
            XHTTP_REALITY_SNI=$(get_state "XHTTP_REALITY_SNI" "")
            log_info "复用 vless-xhttp-reality 的公共 SNI: ${XHTTP_REALITY_SNI}（已借公共，不重选）"
        fi
    fi

    # ── 结果汇总：SNI 来源 + 连接地址（两者可能不同，故分别打）──
    if (( _vless_pub )); then
        log_info "vless-reality       SNI 来源：借公共大站；dest=${REALITY_DEST:-}"
        log_info "vless-reality       serverNames: ${REALITY_SERVER_NAMES[*]:-（空）}"
    else
        log_info "vless-reality       SNI 来源：自有域自建 ${_vless_own}，dest→本地伪装站8321（生成器固定）"
    fi
    [[ -n "${_vless_own}" ]] && log_info "vless-reality       连接地址：${_vless_own}（配置表分配）"

    if (( _xhttp_pub )); then
        log_info "vless-xhttp-reality SNI 来源：借公共大站 ${XHTTP_REALITY_SNI:-（未选到，与 vless-reality 无法分流）}"
    else
        log_info "vless-xhttp-reality SNI 来源：自有域自建 ${_xhttp_own:-（未分配自有域）}"
    fi
    [[ -n "${_xhttp_own}" ]] && log_info "vless-xhttp-reality 连接地址：${_xhttp_own}（配置表分配）"
    # ⚠️ 必须显式 return 0：上一行是 `[[ ... ]] && log_info`，_xhttp_own 为空时返回 1，
    #    会让调用方的 `if ! collect_reality_params; then` 误判为「冲突中止」。
    #    本函数的 1 只表示规则 3 冲突（同域双标）那一条。
    return 0
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

    # PROXY 头开关：每次生成从 state 读最新值（不覆盖用户 config.env 设置）
    FALLBACK_PROXY_PROTOCOL=$(get_state "FALLBACK_PROXY_PROTOCOL" "0")
    DECOY_SELF_PROXY_PROTOCOL=$(get_state "DECOY_SELF_PROXY_PROTOCOL" "0")
    local _conf_path="${OUT_DIR:-/usr/local/etc/xray}/config.json"

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
    # ⚠️ 非空才写：非交互路径（_regen_xray_from_state）可能没水合这两个变量，
    #    空值覆盖会把 state 里已有的公共 SNI/连接地址清掉（F1/F6）。
    [[ -n "${XHTTP_REALITY_SNI:-}" ]]    && save_state "XHTTP_REALITY_SNI"    "${XHTTP_REALITY_SNI}"
    # 规则 1（2026-10-02）：此处原有一行把 XHTTP_REALITY_DOMAIN 写回 state —— *_DOMAIN
    # 是配置表的派生值，只有主菜单 5 的子选项 1/3 能写，生成器只读。

    # ── 防护：借公共 SNI 但公共参数为空 → 拒绝生成 ──────────────────
    # do_reconf_xray（菜单 x）清空参数但保留 mode=public 时，若 collect 阶段没兜住，
    # 这里也要在写 config.json 前报错中止，绝不落盘空 serverNames / 空 dest。
    # ⚠️ 两个 guard 都以「槽存在」为前提：无槽（XHTTP_REALITY_DOMAIN 空 = 组合 g）
    # 时既无 xhttp fallback 也无 8325 入站，公共参数空是**预期**，不得拦。
    if [[ -n "${REALITY_DOMAIN:-}" ]] && _reality_slot_borrows_public xray-reality \
        && [[ -z "${REALITY_SERVER_NAMES[0]:-}" ]]; then
        log_error "vless-reality 借公共 SNI 但 REALITY_SERVER_NAMES 为空，拒绝生成 config.json"
        return 1
    fi
    if [[ -n "${XHTTP_REALITY_DOMAIN:-}" ]] && _reality_slot_borrows_public xhttp-reality \
        && [[ -z "${XHTTP_REALITY_SNI:-}" ]]; then
        log_error "vless-xhttp-reality 借公共 SNI 但 XHTTP_REALITY_SNI 为空，拒绝生成 config.json"
        return 1
    fi

    # ── 防偷流量：reality-direct ──────────────────────────────────
    # 自建 SNI（_reality_slot_borrows_public 为假）：
    #   dest → 本地 nginx 8321（由 nginx 模块生成，携带真实证书 + 伪装网站）
    #   serverNames 仅含自有域名，非 Xray 访客直接看到本地网站，无外部流量可偷
    # 借公共 SNI（为真，域名可留作连接地址）：
    #   dest → dokodemo 4431 → 路由决定：serverNames 内的域名 direct，其余 block
    # ⚠️ 判据是 **SNI 来源**，不是「域名是否非空」——分配了自有域也可以借公共 SNI，
    #    此时域名只当客户端连接地址用（见 _reality_slot_borrows_public 的长注释）。
    local _reality_direct_dest _reality_direct_sn
    local _reality_direct_xver=0   # 默认 0，防生成 "xver": ,（修订5）
    local _dokodemo_reality_routing="" _dokodemo_reality_inbound=""
    if ! _reality_slot_borrows_public xray-reality; then
        _reality_direct_dest="127.0.0.1:8321"
        _reality_direct_xver="${DECOY_SELF_PROXY_PROTOCOL}"   # 伪装站随 DECOY
        _reality_direct_sn="\"${REALITY_DOMAIN}\""
    else
        # dokodemo 的目标 = 借用的公共站。
        # ⚠️ REALITY_DEST **不可信**：sync_hydrate_client_state（sync.sh:50）按活机
        #    config.json 的 realitySettings.dest 回填它，而公共模式下那个字段是
        #    dokodemo 自己的地址（127.0.0.1:4431）→ 下一轮生成把 dokodemo 的目标也
        #    写成 127.0.0.1:4431 → **转发给自己**，借公共 SNI 的回落全部挂死。
        #    2026-10-01 活机实测：`openssl s_client -connect 127.0.0.1:443 -servername
        #    <借用站>` 一直挂到超时；对照组自建槽同一命令立刻返回伪装站证书。
        #    故回环/空值一律改用 serverNames[0]（客户端真正会发的 SNI）+ 443，
        #    与 xhttp 槽那份（直接用 XHTTP_REALITY_SNI）保持同一写法。
        local _rdest_host="${REALITY_DEST%%:*}"
        local _rdest_port="${REALITY_DEST##*:}"
        if [[ -z "$_rdest_host" || "$_rdest_host" == "127.0.0.1" || "$_rdest_host" == "localhost" ]]; then
            _rdest_host="${REALITY_SERVER_NAMES[0]:-}"
            _rdest_port=443
        fi
        _reality_direct_dest="127.0.0.1:4431"
        _reality_direct_xver="0"   # dokodemo 固定 0（不收 PROXY）
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
                "routeOnly":    false
            }
        }'
    fi

    # ── 防偷流量：vless-xhttp-reality ────────────────────────────
    # 自建 SNI：dest → 本地 nginx 8326（真实证书 + 伪装站），无外部流量可偷
    # 借公共 SNI：dest → dokodemo 4432 → 借用第三方域名（公共 SNI 不能用本地 nginx，
    #            因为没有该域名的证书，TLS 指纹会与真实域名不符）
    # ⚠️ 同上，判据是 SNI 来源而非域名是否非空。
    local _dokodemo_xhttp_routing="" _dokodemo_xhttp_inbound=""
    local _xhttp_reality_dest="" _xhttp_reality_sn=""
    local _xhttp_reality_xver=0   # 默认 0，防生成 "xver": ,（修订5）
    if ! _reality_slot_borrows_public xhttp-reality; then
        _xhttp_reality_dest="127.0.0.1:8326"
        _xhttp_reality_xver="${DECOY_SELF_PROXY_PROTOCOL}"   # 伪装站随 DECOY
        _xhttp_reality_sn="\"${XHTTP_REALITY_DOMAIN}\""
    elif [[ -n "${XHTTP_REALITY_SNI:-}" ]]; then
        _xhttp_reality_dest="127.0.0.1:4432"
        _xhttp_reality_xver="0"   # dokodemo 固定 0（不收 PROXY）
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

    # ── 组合 g（无 xhttp-reality 槽）：跳过 fallbacks[0] 与 8325 入站 ──
    # 判定条件：槽存在且 XHTTP_REALITY_DOMAIN 非空（不靠 SNI 模式）。
    # 配置表空槽 → state 的 XHTTP_REALITY_DOMAIN 空 → load_domain_state 兜底后仍空。
    # 两个函数用内层无引号 heredoc 展开变量（外层 heredoc 的 $( ) 结果不二次展开），
    # 槽不存在时返回空 → JSON 数组相应少一个元素，全部合法（已实测）。
    _xhttp_path_fallback_json() {
        # fallbacks[0]：xhttp-path → 8325。xver 固定 1（8325 acceptProxyProtocol=true，必须收 PROXY）。
        # 这是 fallbacks 数组的**首元素** → 输出含完整对象 + 尾逗号 + 换行（无前导逗号）。
        [[ -n "${XHTTP_REALITY_DOMAIN:-}" ]] || return 0
        cat <<XHTTPFB
                        {
                            "path": "${XHTTP_PATH}",
                            "dest": "127.0.0.1:8325",
                            "xver": 1
                        },
XHTTPFB
    }
    _xhttp_inbound_json() {
        # 8325 入站（vless-xhttp-reality）。8320 结束符已去尾逗号，此处带前导逗号补分隔。
        [[ -n "${XHTTP_REALITY_DOMAIN:-}" ]] || return 0
        cat <<XHTTPIN
,
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
                    "xver":        ${_xhttp_reality_xver},
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
        }
XHTTPIN
    }

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

    # ── 屏蔽域名（PT 站等）──────────────────────────────────────
    # 三处同源：本文件 / modules/singbox.sh / modules/hysteria2.sh —— 改要一起改。
    # 意义是「服务端兜底」：客户端路由指对了它永不触发；指错了这几个站会被黑洞，
    # 而不是改走直连（blackhole 是断，不是改道）。
    # 必须排在下面 geosite:cn→warp 之前：这些域现在在 geosite 的 CATEGORY-PT 分类里
    # （实测，非 cn/tld-cn），但 geosite.dat 随 xray 升级更新，一旦将来并进 cn 分类，
    # 排在 warp 之后的规则就会被静默截走而永不生效。
    local _blocked_domains_routing='            {
                "type":        "field",
                "domain":      [
                    "domain:btschool.club",
                    "domain:pthome.org",
                    "domain:tjupt.org",
                    "domain:m-team.cc",
                    "domain:nanyangpt.com"
                ],
                "outboundTag": "block"
            },'

    mkdir -p "$(dirname "${_conf_path}")"

    # Fix: grpc initial_windows_size 4194304 (4MB) prevents CDN GOAWAY on high-BDP paths; default 65536 too small
    cat > "${_conf_path}" << CONF
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
${_blocked_domains_routing}
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
$(_xhttp_path_fallback_json)
                    {
                        "path": "/${GRPC_SERVICE_NAME}",
                        "dest": "127.0.0.1:8350",
                        "xver": ${FALLBACK_PROXY_PROTOCOL}
                    },
                    {
                        "dest": "127.0.0.1:8350",
                        "xver": ${FALLBACK_PROXY_PROTOCOL}
                    }
                ]
            },
            "streamSettings": {
                "network":  "tcp",
                "security": "reality",
                "realitySettings": {
                    "show":        false,
                    "dest":        "${_reality_direct_dest}",
                    "xver":        ${_reality_direct_xver},
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
        }$(_xhttp_inbound_json)${_dokodemo_reality_inbound}${_dokodemo_xhttp_inbound}
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
    # ⚠️ 用真实路径，不用 generate_xray_config 的 local _conf_path：
    # start_xray 启动活机服务，与测试用 OUT_DIR 隔离无关。
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
