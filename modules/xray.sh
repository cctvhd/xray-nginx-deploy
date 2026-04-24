#!/usr/bin/env bash
# ============================================================
# modules/xray.sh
# Xray 安装 + 三协议配置生成
# ============================================================

# ── 安装 Xray（官方脚本）────────────────────────────────────
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

    # 创建日志目录
    mkdir -p /var/log/xray
    chmod 755 /var/log/xray
}

# ── 生成随机参数 ─────────────────────────────────────────────
generate_xray_params() {
    log_step "生成 Xray 随机参数..."
    local state_file="/etc/xray-deploy/config.env"

    # UUID：已有则复用
    local saved_uuid
    saved_uuid=$(grep "^XRAY_UUID=" "$state_file" 2>/dev/null | \
        cut -d= -f2 | tr -d "'\"")
    if [[ -n "${saved_uuid}" ]]; then
        XRAY_UUID="${saved_uuid}"
        log_info "复用已有 UUID: ${XRAY_UUID}"
    else
        XRAY_UUID=$(xray uuid)
        log_info "生成新 UUID: ${XRAY_UUID}"
    fi

    # x25519 密钥对：已有则复用
    local saved_privkey
    saved_privkey=$(grep "^XRAY_PRIVATE_KEY=" "$state_file" 2>/dev/null | \
        cut -d= -f2 | tr -d "'\"")
    if [[ -n "${saved_privkey}" ]]; then
        XRAY_PRIVATE_KEY="${saved_privkey}"
        XRAY_PUBLIC_KEY=$(grep "^XRAY_PUBLIC_KEY=" "$state_file" 2>/dev/null | \
            cut -d= -f2 | tr -d "'\"")
        log_info "复用已有密钥对"
    else
        local keypair
        keypair=$(xray x25519)
        XRAY_PRIVATE_KEY=$(echo "$keypair" | grep -i "private" | awk '{print $NF}')
        XRAY_PUBLIC_KEY=$(echo "$keypair" | grep -i "public\|password" | \
            awk '{print $NF}')
        log_info "生成新密钥对"
    fi

    # xhttp path：已有则复用，没有才生成
    local saved_path
    saved_path=$(grep "^XHTTP_PATH=" "$state_file" 2>/dev/null | \
        cut -d= -f2 | tr -d "'\"")
    if [[ -n "${saved_path}" ]]; then
        XHTTP_PATH="${saved_path}"
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    else
        XHTTP_PATH="/$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
        log_info "生成新 XHTTP_PATH: ${XHTTP_PATH}"
    fi

    # Reality shortIds
    REALITY_SHORT_IDS=(
        ""
        "$(openssl rand -hex 4)"
        "$(openssl rand -hex 4)"
        "$(openssl rand -hex 4)"
        "$(openssl rand -hex 6)"
        "$(openssl rand -hex 8)"
    )

    # Reality spiderX
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

    # Reality dest（伪装目标）
    echo "常用伪装目标（需要支持TLS 1.3 + H2）："
    echo "  1. solanolibrary.com:443（美国）"
    echo "  2. yandex.com.tr:443（土耳其）"
    echo "  3. www.lovelive-anime.jp:443（日本）"
    echo "  4. 自定义"
    read -rp "请选择 [1-4，默认1]: " dest_choice

    case "${dest_choice:-1}" in
        1) REALITY_DEST="solanolibrary.com:443"
           REALITY_SERVER_NAMES=("solanolibrary.com" "openclaw.ai"
                                  "www.lapl.org" "www.siliconvalley.com"
                                  "www.oxy.edu" "business.ca.gov" "film.ca.gov") ;;
        2) REALITY_DEST="yandex.com.tr:443"
           REALITY_SERVER_NAMES=("yandex.com.tr") ;;
        3) REALITY_DEST="www.lovelive-anime.jp:443"
           REALITY_SERVER_NAMES=("www.lovelive-anime.jp") ;;
        4) read -rp "输入自定义 dest（格式 domain:443）: " REALITY_DEST
           read -rp "输入 serverName（多个用空格分隔）: " -a REALITY_SERVER_NAMES ;;
    esac

    # 加入自有 Reality 域名
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        REALITY_SERVER_NAMES=("${REALITY_DOMAIN}" "${REALITY_SERVER_NAMES[@]}")
    fi

    # spiderX
    read -rp "Reality spiderX [默认 /api/health]: " spider_x
    REALITY_SPIDER_X="${spider_x:-/api/health}"

    log_info "Reality dest:        ${REALITY_DEST}"
    log_info "Reality serverNames: ${REALITY_SERVER_NAMES[*]}"
}

# ── 生成 xray config.json ────────────────────────────────────
generate_xray_config() {
    log_step "生成 Xray 配置文件..."

    local x_padding="${XRAY_PADDING:-}"
    case "${x_padding}" in
        ""|"128-2048"|"128-1024")
            x_padding="100-1000"
            ;;
    esac

    local window_clamp="${XRAY_WINDOW_CLAMP:-1200}"
    local user_timeout=30000

    XRAY_PADDING="${x_padding}"
    XRAY_WINDOW_CLAMP="${window_clamp}"

    # 构建 Reality serverNames JSON 数组
    local sn_json=""
    for sn in "${REALITY_SERVER_NAMES[@]}"; do
        sn_json+="\"${sn}\","
    done
    sn_json="${sn_json%,}"

    # 构建 shortIds JSON 数组
    local sid_json=""
    for sid in "${REALITY_SHORT_IDS[@]}"; do
        sid_json+="\"${sid}\","
    done
    sid_json="${sid_json%,}"

    mkdir -p /usr/local/etc/xray

    cat > /usr/local/etc/xray/config.json << CONF
{
    "log": {
        "loglevel": "warn",
        "access": "none",
        "error": "/var/log/xray/error.log"
    },

    "dns": {
        "servers": [
            {
                "tag": "local-dns",
                "address": "localhost",
                "port": 53,
                "domains": [
                    "geosite:geolocation-!cn",
                    "geosite:google",
                    "geosite:github",
                    "geosite:cloudflare",
                    "geosite:netflix",
                    "geosite:openai"
                ],
                "expectIPs": ["geoip:!cn"],
                "skipFallback": true
            },
            {
                "tag": "warp-dns",
                "address": "1.1.1.1",
                "domains": [
                    "geosite:cn",
                    "geosite:tld-cn"
                ],
                "expectIPs": ["geoip:cn"],
                "proxyTag": "warp"
            }
        ],
        "disableCache": false,
        "disableFallback": true,
        "queryStrategy": "UseIPv6v4"
    },

    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": ["geosite:cn", "geosite:tld-cn"],
                "outboundTag": "warp"
            },
            {
                "type": "field",
                "ip": ["geoip:cn"],
                "outboundTag": "warp"
            }
        ]
    },

    "inbounds": [
        {
            "tag": "vless-xhttp-cdn",
            "listen": "127.0.0.1",
            "port": 8001,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {"id": "${XRAY_UUID}"}
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "none",
                "xhttpSettings": {
                    "path": "${XHTTP_PATH}",
                    "host": "${XHTTP_DOMAIN:-}",
                    "extra": {
                        "enc": "packet",
                        "xPaddingBytes": "${x_padding}",
                        "headers": {"User-Agent": "chrome"}
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
            "tag": "vless-grpc-cdn",
            "listen": "127.0.0.1",
            "port": 8002,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {"id": "${XRAY_UUID}"}
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "grpc",
                "security": "none",
                "grpcSettings": {
                    "serviceName": "grpc.Service",
                    "multiMode": true
                }
            },
            "sniffing": {
                "enabled":      true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false
            }
        },

        {
            "tag": "reality-direct",
            "listen": "127.0.0.1",
            "port": 9443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id":   "${XRAY_UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none",
                "fallbacks": [
                    {"dest": "127.0.0.1:10080", "xver": 0}
                ]
            },
            "streamSettings": {
                "network":  "tcp",
                "security": "reality",
                "realitySettings": {
                    "show":       false,
                    "dest":       "${REALITY_DEST}",
                    "xver":       0,
                    "serverNames": [${sn_json}],
                    "privateKey": "${XRAY_PRIVATE_KEY}",
                    "shortIds":   [${sid_json}],
                    "spiderX":    "${REALITY_SPIDER_X}"
                },
                "sockopt": {
                    "acceptProxyProtocol":  true
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
                    "tcpKeepAliveInterval": 30
                }
            }
        },
        {
            "tag":      "block",
            "protocol": "blackhole"
        },
        {
            "tag":      "warp",
            "protocol": "socks",
            "settings": {
                "servers": [{"address": "127.0.0.1", "port": ${WARP_PROXY_PORT:-40000}}]
            }
        }
    ]
}
CONF

    log_info "Xray 配置文件生成完成"
}

# ── 启动 Xray ────────────────────────────────────────────────
start_xray() {
    log_step "启动 Xray 服务..."

    if ! xray run -test -config /usr/local/etc/xray/config.json; then
        log_error "Xray 配置验证失败"
        exit 1
    fi

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
    echo "  UUID:       ${XRAY_UUID}"
    echo "  公钥:       ${XRAY_PUBLIC_KEY}"
    echo "  私钥:       ${XRAY_PRIVATE_KEY}"
    echo "  xhttp路径:  ${XHTTP_PATH}"
    echo "  Reality dest: ${REALITY_DEST}"
}
