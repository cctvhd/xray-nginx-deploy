#!/usr/bin/env bash
# ============================================================
# modules/xray.sh
# Xray 安装 + 三协议配置生成
# warp 出站：内嵌 wireguard（由 warp.sh 提供凭证），不依赖本地 SOCKS5
# ============================================================

# ── 安装 Xray（直接从 GitHub releases 下载，包含预发布版本）──
install_xray() {
    log_step "安装 Xray..."

    local ver arch zip_name tmp_dir

    # 从 /releases 列表取最新版本（包含 pre-release），而非 /releases/latest
    ver=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases" 2>/dev/null \
        | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)
    [[ -z "$ver" ]] && { log_error "无法获取 Xray 最新版本"; exit 1; }
    log_info "目标版本: ${ver}"

    case "$(uname -m)" in
        x86_64)          arch="64" ;;
        aarch64|arm64)   arch="arm64-v8a" ;;
        armv7*|armv6*)   arch="arm32-v7a" ;;
        *)               arch="64" ;;
    esac
    zip_name="Xray-linux-${arch}.zip"

    # 确保 unzip 可用
    command -v unzip &>/dev/null || \
        apt-get install -y unzip 2>/dev/null || \
        dnf install -y unzip 2>/dev/null || true

    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    log_step "下载 ${zip_name}..."
    curl -fsSL --max-time 120 \
        "https://github.com/XTLS/Xray-core/releases/download/${ver}/${zip_name}" \
        -o "${tmp_dir}/xray.zip" \
        || { log_error "下载 Xray 失败"; exit 1; }

    unzip -q "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray" \
        || { log_error "解压 Xray 失败"; exit 1; }

    log_step "安装 Xray 二进制..."
    install -m 755 "${tmp_dir}/xray/xray" /usr/local/bin/xray

    # 安装地理数据（升级时一并更新）
    mkdir -p /usr/local/share/xray
    for dat in geoip.dat geosite.dat; do
        [[ -f "${tmp_dir}/xray/${dat}" ]] && \
            install -m 644 "${tmp_dir}/xray/${dat}" /usr/local/share/xray/
    done

    # 首次安装时创建 systemd service（升级时保留已有 service 文件）
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        cat > /etc/systemd/system/xray.service << 'SERVICE'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    mkdir -p /usr/local/etc/xray /var/log/xray
    chmod 755 /var/log/xray

    if ! command -v xray &>/dev/null; then
        log_error "Xray 安装失败"
        exit 1
    fi

    local xray_ver
    xray_ver=$(xray version 2>&1 | grep -oP '[\d.]+' | head -1)
    log_info "Xray 安装成功: v${xray_ver}"
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

# ── 收集 Reality 伪装参数 ────────────────────────────────────
collect_reality_params() {
    echo ""
    log_step "配置 Reality 伪装参数"
    echo ""

    echo "请选择服务器所在地区："
    echo "  1. 美国 / 北美"
    echo "  2. 欧洲"
    echo "  3. 亚洲"
    echo "  4. 自定义"
    echo ""
    read -rp "请选择地区 [1-4，默认1]: " region_choice

    case "${region_choice:-1}" in

        # ── 美国 / 北美 ──────────────────────────────────────
        1)
            echo ""
            echo "美国 / 北美伪装目标："
            echo "  1. solanolibrary.com:443（洛杉矶公共图书馆）"
            echo "  2. www.siliconvalley.com:443（硅谷媒体）"
            echo "  3. business.ca.gov:443（加州政府）"
            read -rp "请选择 [1-3，默认1]: " dest_choice
            case "${dest_choice:-1}" in
                1) REALITY_DEST="solanolibrary.com:443"
                   REALITY_SERVER_NAMES=("solanolibrary.com" "openclaw.ai"
                                         "www.lapl.org" "www.siliconvalley.com"
                                         "www.oxy.edu" "business.ca.gov" "film.ca.gov") ;;
                2) REALITY_DEST="www.siliconvalley.com:443"
                   REALITY_SERVER_NAMES=("www.siliconvalley.com" "solanolibrary.com"
                                         "www.oxy.edu" "business.ca.gov") ;;
                3) REALITY_DEST="business.ca.gov:443"
                   REALITY_SERVER_NAMES=("business.ca.gov" "film.ca.gov"
                                         "solanolibrary.com" "www.oxy.edu") ;;
            esac
            ;;

        # ── 欧洲 ─────────────────────────────────────────────
        2)
            echo ""
            echo "欧洲伪装目标："
            echo "  1. ethz.ch:443（瑞士联邦理工学院）"
            echo "  2. www.ecb.europa.eu:443（欧洲中央银行）"
            echo "  3. opendata.cern.ch:443（欧洲核子研究中心）"
            echo "  4. yandex.com.tr:443（Yandex 土耳其）"
            echo "  5. www.mpg.de:443（马克斯普朗克学会）"
            echo "  6. sentinels.copernicus.eu:443（哥白尼计划）"
            read -rp "请选择 [1-6，默认1]: " dest_choice
            case "${dest_choice:-1}" in
                1) REALITY_DEST="ethz.ch:443"
                   REALITY_SERVER_NAMES=("ethz.ch" "m.ethz.ch" "debian.ethz.ch"
                                         "cuni.cz" "mff.cuni.cz"
                                         "www.mpg.de" "developer.trumpf.com") ;;
                2) REALITY_DEST="www.ecb.europa.eu:443"
                   REALITY_SERVER_NAMES=("www.ecb.europa.eu" "api.ecb.europa.eu"
                                         "sentinels.copernicus.eu"
                                         "ethz.ch" "www.mpg.de") ;;
                3) REALITY_DEST="opendata.cern.ch:443"
                   REALITY_SERVER_NAMES=("opendata.cern.ch"
                                         "ethz.ch" "m.ethz.ch"
                                         "www.mpg.de" "api.aalto.fi"
                                         "www.nic.funet.fi") ;;
                4) REALITY_DEST="yandex.com.tr:443"
                   REALITY_SERVER_NAMES=("yandex.com.tr"
                                         "ethz.ch" "www.ecb.europa.eu"
                                         "opendata.cern.ch") ;;
                5) REALITY_DEST="www.mpg.de:443"
                   REALITY_SERVER_NAMES=("www.mpg.de" "developer.trumpf.com"
                                         "ethz.ch" "m.ethz.ch" "debian.ethz.ch"
                                         "cuni.cz" "mff.cuni.cz") ;;
                6) REALITY_DEST="sentinels.copernicus.eu:443"
                   REALITY_SERVER_NAMES=("sentinels.copernicus.eu"
                                         "www.ecb.europa.eu" "api.ecb.europa.eu"
                                         "opendata.cern.ch" "ethz.ch") ;;
            esac
            ;;

        # ── 亚洲 ─────────────────────────────────────────────
        3)
            echo ""
            echo "亚洲伪装目标："
            echo "  1. www.lovelive-anime.jp:443（日本）"
            echo "  2. www.nintendo.co.jp:443（任天堂日本）"
            read -rp "请选择 [1-2，默认1]: " dest_choice
            case "${dest_choice:-1}" in
                1) REALITY_DEST="www.lovelive-anime.jp:443"
                   REALITY_SERVER_NAMES=("www.lovelive-anime.jp") ;;
                2) REALITY_DEST="www.nintendo.co.jp:443"
                   REALITY_SERVER_NAMES=("www.nintendo.co.jp" "www.lovelive-anime.jp") ;;
            esac
            ;;

        # ── 自定义 ───────────────────────────────────────────
        4)
            read -rp "输入自定义 dest（格式 domain:443）: " REALITY_DEST
            read -rp "输入 serverName（多个用空格分隔）: " -a REALITY_SERVER_NAMES
            ;;
    esac

    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        echo ""
        log_info "检测到自有 Reality 域名: ${REALITY_DOMAIN}"
        log_warn "建议默认不要把自有域名加入 Reality serverNames；公共 serverNames 通常更隐蔽"
        read -rp "是否把自有域名也加入 Reality serverNames？[y/N]: " include_own_reality_domain
        if [[ "${include_own_reality_domain,,}" == "y" ]]; then
            REALITY_SERVER_NAMES=("${REALITY_DOMAIN}" "${REALITY_SERVER_NAMES[@]}")
        fi
    fi

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

    read -rp "Reality spiderX [默认 /api/health]: " spider_x
    REALITY_SPIDER_X="${spider_x:-/api/health}"

    log_info "Reality dest:        ${REALITY_DEST}"
    log_info "Reality serverNames: ${REALITY_SERVER_NAMES[*]}"
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

    local sid_json=""
    for sid in "${REALITY_SHORT_IDS[@]}"; do
        sid_json+="\"${sid}\","
    done
    sid_json="${sid_json%,}"

    local warp_outbound
    warp_outbound=$(_build_warp_outbound_json)

    local xray_query_strategy
    if is_ipv6_preferred 2>/dev/null; then
        xray_query_strategy="UseIPv6v4"
    else
        xray_query_strategy="UseIPv4v6"
    fi

    mkdir -p /usr/local/etc/xray

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
                "decryption":  "none"
            },
            "streamSettings": {
                "network":  "xhttp",
                "security": "none",
                "xhttpSettings": {
                    "path": "${XHTTP_PATH}",
                    "host": "${XHTTP_DOMAIN:-}",
                    "extra": {
                        "enc":                    "packet",
                        "xPaddingBytes":          "${x_padding}",
                        "scStreamUpServerSecs":   "20-80",
                        "headers":                {"User-Agent": "chrome"},
                        "xmux": {
                            "maxConcurrency":   "${LATENCY_XMUX_CONCURRENCY}",
                            "maxConnections":   0,
                            "cMaxReuseTimes":   0,
                            "hMaxRequestTimes": "${LATENCY_XMUX_REQUEST_TIMES}",
                            "hMaxReusableSecs": "${LATENCY_XMUX_REUSABLE_SECS}",
                            "hKeepAlivePeriod": 0
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
                "decryption": "none"
            },
            "streamSettings": {
                "network":  "grpc",
                "security": "none",
                "grpcSettings": {
                    "serviceName":          "grpc.Service",
                    "multiMode":            true,
                    "idle_timeout":         60,
                    "health_check_timeout": 20,
                    "permit_without_stream": false,
                    "initial_windows_size":  65536
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
                        "dest": "127.0.0.1:8350",
                        "xver": 0
                    },
                    {
                        "path": "/grpc.Service",
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
                    "dest":        "${REALITY_DEST}",
                    "xver":        0,
                    "serverNames": [${sn_json}],
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
        }
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
    systemctl enable --now xray

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
}
