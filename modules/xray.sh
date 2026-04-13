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

    # UUID
    XRAY_UUID=$(xray uuid)

    # x25519 密钥对
    local keypair
    keypair=$(xray x25519)
    XRAY_PRIVATE_KEY=$(echo "$keypair" | grep -i "private" | awk '{print $NF}')
    XRAY_PUBLIC_KEY=$(echo "$keypair"  | grep -i "public\|password" | awk '{print $NF}')

    # xhttp path（随机32位hex）
    XHTTP_PATH="/$(cat /proc/sys/kernel/random/uuid | tr -d '-')"

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

    # 根据网口速度调整参数
    local net_speed
    net_speed=$(cat /sys/class/net/eth0/speed 2>/dev/null || echo "1000")

    # xPaddingBytes 根据网口速度
    local x_padding="128-2048"
    [[ "${net_speed}" -ge 10000 ]] && x_padding="512-4096"

    # tcpWindowClamp 根据网口速度
    local window_clamp=1200
    [[ "${net_speed}" -ge 10000 ]] && window_clamp=0

    # tcpUserTimeout
    local user_timeout=300000

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
                "inboundTag": [
                    "vless-xhttp-cdn",
                    "vless-grpc-cdn",
                    "reality-direct"
                ],
                "outboundTag": "direct"
            },
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
                        "xPaddingBytes": "${x_padding}"
                    }
                },
                "sockopt": {
                    "tcpFastOpen":          true,
                    "tcpCongestion":        "bbr",
                    "tcpUserTimeout":       ${user_timeout},
                    "tcpMaxSeg":            1460,
                    "tcpKeepAliveIdle":     60,
                    "tcpKeepAliveInterval": 30,
                    "tcpKeepAliveCount":    3,
                    "tcpMptcp":             true,
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
                    "serviceName":         "grpc.Service",
                    "multiMode":           true,
                    "idle_timeout":        60,
                    "permitWithoutStream": true
                },
                "sockopt": {
                    "tcpFastOpen":          true,
                    "tcpCongestion":        "bbr",
                    "tcpUserTimeout":       ${user_timeout},
                    "tcpMaxSeg":            1460,
                    "tcpWindowClamp":       ${window_clamp},
                    "tcpKeepAliveIdle":     60,
                    "tcpKeepAliveInterval": 30,
                    "tcpKeepAliveCount":    3,
                    "tcpMptcp":             true
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
                    "tcpFastOpen":          true,
                    "tcpCongestion":        "bbr",
                    "tcpUserTimeout":       ${user_timeout},
                    "tcpMaxSeg":            1460,
                    "tcpKeepAliveIdle":     300,
                    "tcpKeepAliveInterval": 30,
                    "acceptProxyProtocol":  true,
                    "tcpMptcp":             true
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
                    "tcpFastOpen":          true,
                    "tcpCongestion":        "bbr",
                    "tcpUserTimeout":       ${user_timeout},
                    "tcpMaxSeg":            1460,
                    "tcpKeepAliveIdle":     300,
                    "tcpKeepAliveInterval": 30,
                    "tcpMptcp":             true
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
                "servers": [{"address": "127.0.0.1", "port": 40000}]
            },
            "streamSettings": {
                "sockopt": {
                    "tcpFastOpen":          true,
                    "tcpKeepAliveInterval": 30,
                    "tcpMptcp":             true
                }
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
