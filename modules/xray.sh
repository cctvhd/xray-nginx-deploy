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

# ── vless-reality：自建域名 → 公共 SNI 模式切换 ──────────────
# 用户在 menu x 内已明确选择"公共 SNI"。本函数摘除该自有域名上的
# xray-reality 标签并重推派生，令 REALITY_DOMAIN 置空，使后续生成严格
# 遵循用户刚选的第三方 SNI，不再被自有域名静默覆盖。
#   · 域名若还带其它协议标签（naive/hysteria2 等）→ 仅摘 xray-reality，保留其余
#   · 域名从此无任何标签 → 从 DOMAIN_REGISTRY 移除（不询问删 ini/证书，同编辑器语义）
reality_untag_self_domain() {
    local domain="$1"
    local suffix mode protos new_protos="" new_mode d pl
    suffix=$(printf '%s' "$domain" | tr '.' '_')

    # cert 模块例程可能未加载（menu x 仅载 xray/nginx）；按需补齐
    if ! declare -F _derive_mode_from_protocols >/dev/null 2>&1; then
        declare -F load_module >/dev/null 2>&1 && load_module cert >/dev/null 2>&1 || true
    fi

    mode=$(get_state "DOMAIN_MODE_${suffix}" "")
    protos=$(get_state "DOMAIN_PROTO_${suffix}" "")

    # 摘除 xray-reality token，保留其余协议
    if [[ -n "$protos" ]]; then
        local -a _keep=() _pl=()
        IFS=',' read -ra _pl <<< "$protos"
        for pl in "${_pl[@]}"; do
            [[ -n "$pl" && "$pl" != "xray-reality" ]] && _keep+=("$pl")
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
        log_info "已摘除 ${domain} 的 xray-reality 标签，保留其余协议: ${new_protos} [${new_mode}]"
    fi

    # 重推派生：清空 REALITY_DOMAIN 与 DOMAIN_PRIMARY_XRAY_REALITY（写 state + 当前 shell）
    declare -F rebuild_protocol_domains >/dev/null 2>&1 && rebuild_protocol_domains
    declare -F load_domain_state >/dev/null 2>&1 && load_domain_state
    # 镜像同步到 /etc/cloudflare/domain_map.conf（防旧值残留导致下次启动自愈回填）
    declare -F save_domain_config >/dev/null 2>&1 && save_domain_config
    log_info "vless-reality 已切换为公共 SNI 模式（REALITY_DOMAIN 已清空）"
}

# ── 收集 Reality 伪装参数 ────────────────────────────────────
# Current correct values on this server: dest=www.mpg.de:443, spiderX=/
# When re-running, select: Europe(2) -> mpg.de(5), then input spiderX=/
collect_reality_params() {
    echo ""
    log_step "配置 Reality 伪装参数"
    echo ""

    # ── Reality-direct 模式提示：模式由域名分配决定，非下方交互决定 ──
    # reality-direct 节点（vless-reality）实际用哪种 SNI，取决于域名管理里
    # 是否有 xray-reality 标签域（REALITY_DOMAIN）：
    #   在册 → 自建域名模式（SNI=自有域，dest=本地伪装站 8321）
    #   无   → 公共 SNI 模式（SNI/dest=下方所选公共伪装目标）
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        # 显式二选一：vless-reality 用自有域名还是公共 SNI。
        # 旧逻辑由 xray-reality 标签静默决定并把下方所选第三方覆盖成自有域名，
        # 与"选什么=配什么"冲突；这里把决定权交回 menu x。
        echo ""
        echo "vless-reality 当前绑定自有域名 ${REALITY_DOMAIN}（自建域名模式：SNI=${REALITY_DOMAIN}，dest→本地伪装站 8321）"
        echo "请选择 vless-reality 的伪装方式："
        echo "  1. 公共 SNI —— 借用第三方域名：自动摘除 ${REALITY_DOMAIN} 的 xray-reality 标签，"
        echo "                 你随后在下方列表里选哪个，vless-reality 就用哪个 SNI"
        echo "  2. 自建域名 —— ${REALITY_DOMAIN}（真实证书；下方列表仅供 vless-xhttp-reality 选公共 SNI）"
        read -rp "请选择 [1/2，默认2]: " _vless_mode
        echo ""
        if [[ "${_vless_mode:-2}" == "1" ]]; then
            log_info "切换 vless-reality 为公共 SNI 模式：摘除 ${REALITY_DOMAIN} 的 xray-reality 标签并重建派生..."
            reality_untag_self_domain "${REALITY_DOMAIN}"
            log_info "REALITY_DOMAIN 已清空——以下所选公共目标即 vless-reality 的 dest/SNI"
        else
            log_info "vless-reality 保持自建域名模式（SNI=${REALITY_DOMAIN}，dest→本地伪装站 8321）"
            log_info "下方公共伪装目标列表仅供 vless-xhttp-reality 挑选公共 SNI，不会改变 vless-reality 的 SNI"
        fi
    else
        log_info "节点 vless-reality（Reality-direct）当前为公共 SNI 模式"
        log_info "下方第 1 步所选伪装目标行，行首域名即 vless-reality 的 SNI（与该行 dest 同站）"
        log_info "第 2 步再从该行的其余域名中，单独为 vless-xhttp-reality 选一个 SNI（nginx 按 SNI 分流两个节点）"
    fi
    echo ""

    # 从 HW_REGION 前缀自动推断地区，避免重复手动选择
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

        # ── 美国 / 北美 ──────────────────────────────────────
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
                "solanolibrary.com:443"
                "www.siliconvalley.com:443"
                "business.ca.gov:443"
                "openclaw.ai:443"
                "www.oxy.edu:443"
                "film.ca.gov:443"
                "www.lapl.org:443"
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
            for (( _i=0; _i<${#_us_labels[@]}; _i++ )); do
                echo "  $(( _i+1 )). ${_us_labels[$_i]}"
            done
            read -rp "请选择 [1-${#_us_labels[@]}，默认1]: " dest_choice
            local _di=$(( ${dest_choice:-1} - 1 ))
            (( _di < 0 || _di >= ${#_us_dests[@]} )) && _di=0
            REALITY_DEST="${_us_dests[$_di]}"
            read -ra REALITY_SERVER_NAMES <<< "${_us_servernames[$_di]}"
            ;;

        # ── 欧洲 ─────────────────────────────────────────────
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
                "ethz.ch:443"
                "www.ecb.europa.eu:443"
                "opendata.cern.ch:443"
                "yandex.com.tr:443"
                "www.mpg.de:443"
                "sentinels.copernicus.eu:443"
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
            for (( _i=0; _i<${#_eu_labels[@]}; _i++ )); do
                echo "  $(( _i+1 )). ${_eu_labels[$_i]}"
            done
            read -rp "请选择 [1-${#_eu_labels[@]}，默认1]: " dest_choice
            local _di=$(( ${dest_choice:-1} - 1 ))
            (( _di < 0 || _di >= ${#_eu_dests[@]} )) && _di=0
            REALITY_DEST="${_eu_dests[$_di]}"
            read -ra REALITY_SERVER_NAMES <<< "${_eu_servernames[$_di]}"
            ;;

        # ── 亚洲 ─────────────────────────────────────────────
        3)
            local -a _as_labels=(
                "www.lovelive-anime.jp:443（日本动画）"
                "www.nintendo.co.jp:443（任天堂日本）"
            )
            local -a _as_dests=(
                "www.lovelive-anime.jp:443"
                "www.nintendo.co.jp:443"
            )
            local -a _as_servernames=(
                "www.lovelive-anime.jp www.nintendo.co.jp"
                "www.nintendo.co.jp www.lovelive-anime.jp"
            )
            echo ""
            echo "亚洲伪装目标："
            local _i
            for (( _i=0; _i<${#_as_labels[@]}; _i++ )); do
                echo "  $(( _i+1 )). ${_as_labels[$_i]}"
            done
            read -rp "请选择 [1-${#_as_labels[@]}，默认1]: " dest_choice
            local _di=$(( ${dest_choice:-1} - 1 ))
            (( _di < 0 || _di >= ${#_as_dests[@]} )) && _di=0
            REALITY_DEST="${_as_dests[$_di]}"
            read -ra REALITY_SERVER_NAMES <<< "${_as_servernames[$_di]}"
            ;;

        # ── 自定义 ───────────────────────────────────────────
        4)
            read -rp "输入自定义 dest（格式 domain:443）: " REALITY_DEST
            read -rp "输入 serverName（多个用空格分隔）: " -a REALITY_SERVER_NAMES
            ;;
    esac

    local deduped_server_names=()
    local seen_server_names=""
    local sn
    for sn in "${REALITY_SERVER_NAMES[@]}"; do
        [[ -n "$sn" ]] || continue
        if [[ " ${seen_server_names} " != *" ${sn} "* ]]; then
            deduped_server_names+=("$sn")
            seen_server_names+=" ${sn}"
        fi
    done
    REALITY_SERVER_NAMES=("${deduped_server_names[@]}")

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

    # ── 选择 vless-xhttp-reality 专用 SNI ─────────────────────
    # serverNames[0] 留给 vless-reality（TCP+Vision / reality-direct，REALITY_SNI），
    # 从剩余条目里选一个给 vless-xhttp-reality（8325）
    XHTTP_REALITY_SNI=""
    if (( ${#REALITY_SERVER_NAMES[@]} > 1 )); then
        echo ""
        echo "请选择 vless-xhttp-reality 节点（XHTTP-Reality 协议）使用的伪装 SNI："
        echo "  （两 Reality 节点须用不同 SNI：首域名=vless-reality(8320)，本项=vless-xhttp-reality(8325)，nginx 据此分流）"
        local _idx=1
        for sn in "${REALITY_SERVER_NAMES[@]:1}"; do
            echo "  ${_idx}. ${sn}"
            (( _idx++ ))
        done
        echo "  （默认 1：${REALITY_SERVER_NAMES[1]}）"
        read -rp "请选择 [1-$(( ${#REALITY_SERVER_NAMES[@]} - 1 ))，默认1]: " _sni_choice
        local _sni_idx=$(( ${_sni_choice:-1} - 1 ))
        # 越界则回退到 1
        if (( _sni_idx < 0 || _sni_idx >= ${#REALITY_SERVER_NAMES[@]} - 1 )); then
            _sni_idx=0
        fi
        XHTTP_REALITY_SNI="${REALITY_SERVER_NAMES[$(( _sni_idx + 1 ))]}"
        # 防呆：不允许与 vless-reality 的 SNI（[0]）相同
        if [[ "${XHTTP_REALITY_SNI}" == "${REALITY_SERVER_NAMES[0]}" ]]; then
            log_warn "所选 SNI 与 vless-reality 相同，已自动清空——vless-xhttp-reality 节点不可用"
            XHTTP_REALITY_SNI=""
        else
            log_info "vless-xhttp-reality SNI 设为: ${XHTTP_REALITY_SNI}"
        fi
    else
        log_warn "serverNames 只有一个条目，vless-xhttp-reality 节点不可用（与 vless-reality 共用同一 SNI 无法分流）"
    fi

    # ── 选择 XHTTP-Reality 域名模式 ──────────────────────────────
    # 有自有域名：dest → 本地 nginx 8326（真实证书 + 伪装站），更可控
    # 无/公共 SNI：dest → dokodemo 4432 → 借用第三方域名（默认行为）
    XHTTP_REALITY_DOMAIN=""
    if [[ -n "${XHTTP_REALITY_SNI:-}" ]]; then
        echo ""
        echo "XHTTP-Reality 伪装域名模式："
        echo "  1. 公共 SNI（${XHTTP_REALITY_SNI}）——借用第三方域名，无需自有证书（推荐）"
        echo "  2. 自有域名——需拥有该域名证书，服务器自建伪装站"
        read -rp "请选择 [1/2，默认1]: " _xhr_mode
        if [[ "${_xhr_mode}" == "2" ]]; then
            local -a _avail_direct=()
            for _d in "${DIRECT_DOMAINS[@]:-}"; do
                [[ "$_d" == "${REALITY_DOMAIN:-}"   ]] && continue
                [[ "$_d" == "${XHTTP_DOMAIN:-}"    ]] && continue
                [[ "$_d" == "${GRPC_DOMAIN:-}"     ]] && continue
                [[ "$_d" == "${NAIVE_DOMAIN:-}"    ]] && continue
                [[ "$_d" == "${ANYTLS_DOMAIN:-}"   ]] && continue
                [[ "$_d" == "${HYSTERIA2_DOMAIN:-}" ]] && continue
                _avail_direct+=("$_d")
            done
            if [[ ${#_avail_direct[@]} -gt 0 ]]; then
                echo "可用自有域名："
                local _di=1
                for _d in "${_avail_direct[@]}"; do echo "  ${_di}. ${_d}"; (( _di++ )); done
                echo "  ${_di}. 手动输入"
                read -rp "请选择 [1-${_di}，默认1]: " _dom_choice
                if [[ "${_dom_choice}" == "${_di}" ]]; then
                    read -rp "输入域名: " XHTTP_REALITY_DOMAIN
                else
                    local _dom_idx=$(( ${_dom_choice:-1} - 1 ))
                    (( _dom_idx < 0 || _dom_idx >= ${#_avail_direct[@]} )) && _dom_idx=0
                    XHTTP_REALITY_DOMAIN="${_avail_direct[$_dom_idx]}"
                fi
            else
                read -rp "输入 xhttp-reality 自有域名: " XHTTP_REALITY_DOMAIN
            fi
            [[ -n "${XHTTP_REALITY_DOMAIN}" ]] && log_info "XHTTP-Reality 自有域名: ${XHTTP_REALITY_DOMAIN}"
        fi
    fi

    # ── 自建域名模式收敛：reality-direct 参数以 REALITY_DOMAIN 为准 ──
    # 生成器在自建域名模式把 SNI 固定为 REALITY_DOMAIN、dest 固定为本地伪装站，
    # 此处同步收敛内存变量与后续 state 持久化，避免 nginx stream map 残留公共死路由。
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        REALITY_DEST="127.0.0.1:8321"
        REALITY_SERVER_NAMES=("${REALITY_DOMAIN}")
    fi

    log_info "Reality dest:        ${REALITY_DEST}"
    log_info "Reality serverNames: ${REALITY_SERVER_NAMES[*]}"
    log_info "vless-reality       的 SNI: ${REALITY_SERVER_NAMES[0]:-（无）}"
    log_info "vless-xhttp-reality 的 SNI: ${XHTTP_REALITY_SNI:-（未启用，与 vless-reality 无法分流）}"
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
        _reality_direct_sn="${sn_json}"
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
                    "privateKey":  "${XRAY_PRIVATE_KEY}",
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
