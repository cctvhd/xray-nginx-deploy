#!/usr/bin/env bash
# ============================================================
# modules/hysteria2.sh
# Hysteria2 安装 & 配置模块
# 参考: server-audit/hy2.sh — 拥塞控制 / 混淆 / 伪装 / 端口跳跃 / 出站
# ============================================================

install_hysteria2() {
    log_step "安装 Hysteria2（官方脚本 https://get.hy2.sh/）..."

    bash <(curl -fsSL https://get.hy2.sh/)

    if ! command -v hysteria &>/dev/null; then
        log_error "Hysteria2 安装失败"
        exit 1
    fi

    # 官方脚本默认会 enable+start hysteria-server.service，
    # 配置模块实现前先停止，避免空配置运行
    systemctl stop hysteria-server.service 2>/dev/null || true

    local hy_ver
    hy_ver=$(hysteria version 2>&1 | grep -oP '[\d.]+' | head -1)
    log_info "Hysteria2 安装成功: v${hy_ver}"

    # 下载 GeoIP/GeoSite 数据库（供 ACL 使用）
    mkdir -p /var/lib/hysteria
    local GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    if curl -fsSL "${GEO_BASE}/geoip.dat" -o /var/lib/hysteria/geoip.dat; then
        log_info "geoip.dat 下载完成"
    else
        log_warn "geoip.dat 下载失败，请手动下载后放置到 /var/lib/hysteria/"
        log_warn "  curl -fsSL ${GEO_BASE}/geoip.dat -o /var/lib/hysteria/geoip.dat"
    fi
    if curl -fsSL "${GEO_BASE}/geosite.dat" -o /var/lib/hysteria/geosite.dat; then
        log_info "geosite.dat 下载完成"
    else
        log_warn "geosite.dat 下载失败，请手动下载后放置到 /var/lib/hysteria/"
        log_warn "  curl -fsSL ${GEO_BASE}/geosite.dat -o /var/lib/hysteria/geosite.dat"
    fi
    chown -R hysteria:hysteria /var/lib/hysteria
    chmod 644 /var/lib/hysteria/*.dat 2>/dev/null || true
}

configure_hysteria2() {
    log_step "配置 Hysteria2..."

    # ── 0. 生成 UUID ────────────────────────────────────────
    local _uuid
    _uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || {
        dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
        echo
    })

    # ── 1. 确定域名 ──────────────────────────────────────────
    local HY2_DOMAIN
    HY2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")

    if [[ -z "${HY2_DOMAIN}" ]]; then
        HY2_DOMAIN="${ANYTLS_DOMAIN:-}"
        [[ -n "${HY2_DOMAIN}" ]] && log_info "复用 AnyTLS 域名: ${HY2_DOMAIN}"
    fi

    if [[ -z "${HY2_DOMAIN}" ]]; then
        if [[ ${#ALL_DOMAINS[@]} -gt 0 ]]; then
            log_info "可用域名:"
            local i=1
            for d in "${ALL_DOMAINS[@]}"; do
                echo "  ${i}. ${d}"
                (( i++ ))
            done
            local sel
            read -rp "请选择 Hysteria2 域名 [1-$(( i - 1 ))]: " sel
            if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
                HY2_DOMAIN="${ALL_DOMAINS[$(( sel - 1 ))]}"
            fi
        fi
    fi

    if [[ -z "${HY2_DOMAIN}" ]]; then
        log_error "无法确定 Hysteria2 域名，请先完成证书申请（步骤 4）"
        exit 1
    fi

    save_state "HYSTERIA2_DOMAIN" "${HY2_DOMAIN}"
    log_info "Hysteria2 域名: ${HY2_DOMAIN}"

    # ── 2. 证书路径（三段式：域名 cert → 根域 cert → 手动输入）────
    local root_domain HY2_CERT HY2_KEY
    root_domain=$(echo "$HY2_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

    if [[ -f "/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem" ]]; then
        HY2_CERT="/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem"
        HY2_KEY="/etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem"
    elif [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
        HY2_CERT="/etc/letsencrypt/live/${root_domain}/fullchain.pem"
        HY2_KEY="/etc/letsencrypt/live/${root_domain}/privkey.pem"
    else
        read -rp "证书路径 fullchain.pem: " HY2_CERT
        read -rp "私钥路径 privkey.pem:   " HY2_KEY
    fi

    log_info "证书: ${HY2_CERT}"
    log_info "私钥: ${HY2_KEY}"

    # ── 3. 端口 ──────────────────────────────────────────────
    local HY2_PORT
    HY2_PORT=$(get_state "HYSTERIA2_PORT")
    if [[ -z "${HY2_PORT}" ]]; then
        read -rp "Hysteria2 端口 [默认: 443]: " HY2_PORT
        HY2_PORT="${HY2_PORT:-443}"
        save_state "HYSTERIA2_PORT" "${HY2_PORT}"
        log_info "端口: ${HY2_PORT}"
    else
        log_info "复用已配置端口: ${HY2_PORT}"
    fi

    # ── 4. 密码 ──────────────────────────────────────────────
    local HY2_PASS
    HY2_PASS=$(get_state "HYSTERIA2_PASSWORD")
    if [[ -z "${HY2_PASS}" ]]; then
        HY2_PASS=$(openssl rand -base64 18)
        save_state "HYSTERIA2_PASSWORD" "${HY2_PASS}"
        log_info "已生成新密码"
    else
        log_info "复用已有密码"
    fi

    # ── 5. 拥塞控制（参考 hy2.sh: 1397-1457）─────────────────
    # 默认 Brutal（激进），可选 BBR / Reno
    local congestion_mode congestion_type bbr_profile
    local ignore_client_bandwidth delay download upload

    echo ""
    echo "请选择拥塞控制模式:"
    echo "  1. Brutal (默认，Hysteria2 专属，固定速率，恶劣网络首选)"
    echo "  2. BBR (均衡，兼容性好)"
    echo "  3. Reno (保守，最稳)"
    read -rp "输入序号 [1-3，默认 1]: " congestion_num
    case "${congestion_num}" in
        2)
            congestion_mode="bbr"
            congestion_type="bbr"
            ignore_client_bandwidth="true"
            echo "BBR 预设等级:"
            echo "  1. conservative (保守)"
            echo "  2. standard (默认/均衡)"
            echo "  3. aggressive (激进)"
            read -rp "输入序号 [1-3，默认 2]: " bbr_num
            case "${bbr_num}" in
                1) bbr_profile="conservative" ;;
                3) bbr_profile="aggressive" ;;
                *) bbr_profile="standard" ;;
            esac
            log_info "拥塞控制: BBR / ${bbr_profile}"
            ;;
        3)
            congestion_mode="reno"
            congestion_type="reno"
            ignore_client_bandwidth="true"
            log_info "拥塞控制: Reno"
            ;;
        *)
            congestion_mode="brutal"
            congestion_type=""
            ignore_client_bandwidth="false"
            read -rp "到服务器的平均延迟 (ms) [默认: 200]: " delay
            delay="${delay:-200}"
            read -rp "期望下行速度 (mbps) [默认: 50]: " download
            download="${download:-50}"
            read -rp "期望上行速度 (mbps) [默认: 10]: " upload
            upload="${upload:-10}"
            log_info "拥塞控制: Brutal / delay=${delay}ms dl=${download}mbps ul=${upload}mbps"
            ;;
    esac

    # ── 6. QUIC 窗口参数 ─────────────────────────────────────
    # Brutal 模式：根据 BDP 计算；其他模式：基于 rmem_max
    local init_stream max_stream init_conn max_conn
    local max_CRW=0

    if [[ "${congestion_mode}" == "brutal" ]]; then
        # 带宽冗余 ×1.10 (参考 hy2.sh)
        local brutal_dl=$(( download + download / 10 ))
        local brutal_ul=$(( upload + upload / 10 ))
        # CRW = 延迟(s) × 带宽(bps) × 2 (参考 hy2.sh: line 1566)
        local CRW=$(( delay * brutal_dl * 1000000 / 1000 * 2 ))
        local SRW=$(( CRW / 5 * 2 ))
        init_stream=$(( SRW ))
        max_stream=$(( SRW * 3 / 2 ))
        init_conn=$(( CRW ))
        max_conn=$(( CRW * 3 / 2 ))
        max_CRW=$(( CRW * 3 / 2 ))
    else
        # BBR/Reno 固定窗口值，避免 rmem_max 动态值过大导致内存耗尽
        init_stream=8388608
        max_stream=33554432
        init_conn=20971520
        max_conn=41943040
    fi

    log_info "QUIC 窗口: stream=${init_stream}/${max_stream} conn=${init_conn}/${max_conn}"

    # ── 7. 混淆（salamander）（参考 hy2.sh: 1465-1478）─────────
    local obfs_status obfs_pass
    echo ""
    echo "是否使用 salamander 流量混淆?"
    echo "  1. 不使用 (默认，性能更好)"
    echo "  2. 使用 (抗封锁更强，增加 CPU 负载)"
    read -rp "输入序号 [1-2，默认 1]: " obfs_num
    if [[ "${obfs_num}" == "2" ]]; then
        obfs_status="true"
        obfs_pass="${HY2_PASS}"
        log_info "混淆: salamander (密码=认证口令)"
    else
        obfs_status="false"
        log_info "混淆: 不使用"
    fi

    # ── 8. 伪装类型（参考 hy2.sh: 1479-1543）─────────────────
    local masquerade_type masquerade_proxy masquerade_xforwarded
    local masquerade_string masquerade_stuff masquerade_file masquerade_tcp
    local MASQUERADE_URL  # 保留旧变量兼容

    echo ""
    echo "请选择伪装类型:"
    echo "  1. proxy (默认，反代一个网站)"
    echo "  2. string (返回固定字符串)"
    echo "  3. file (静态文件服务器)"
    read -rp "输入序号 [1-3，默认 1]: " masq_num
    case "${masq_num}" in
        2)
            masquerade_type="string"
            read -rp "伪装字符串 [默认: HelloWorld]: " masquerade_string
            masquerade_string="${masquerade_string:-HelloWorld}"
            read -rp "HTTP 伪装标头 content-stuff [默认: HelloWorld]: " masquerade_stuff
            masquerade_stuff="${masquerade_stuff:-HelloWorld}"
            log_info "伪装: string / ${masquerade_string}"
            ;;
        3)
            masquerade_type="file"
            masquerade_file="/etc/hihy/file"
            log_info "伪装: file / ${masquerade_file}"
            ;;
        *)
            masquerade_type="proxy"
            read -rp "伪装代理地址 [默认: https://news.ycombinator.com/]: " masquerade_proxy
            masquerade_proxy="${masquerade_proxy:-https://news.ycombinator.com/}"
            echo "是否附加 X-Forwarded-For / Host / Proto 请求头?"
            echo "  1. 启用 (默认)"
            echo "  2. 关闭"
            read -rp "输入序号 [1-2，默认 1]: " xfwd
            if [[ "${xfwd}" == "2" ]]; then
                masquerade_xforwarded="false"
            else
                masquerade_xforwarded="true"
            fi
            MASQUERADE_URL="${masquerade_proxy}"
            log_info "伪装: proxy / ${masquerade_proxy} (xForwarded=${masquerade_xforwarded})"
            ;;
    esac

    # TCP 共监听（参考 hy2.sh: 1531-1543）
    echo ""
    echo "是否同时监听 tcp/${HY2_PORT} 增强伪装?"
    echo "  1. 启用 (默认，浏览器无 H3 时也能看到伪装内容)"
    echo "  2. 跳过"
    read -rp "输入序号 [1-2，默认 1]: " masq_tcp
    if [[ -z "${masq_tcp}" ]] || [[ "${masq_tcp}" == "1" ]]; then
        masquerade_tcp="true"
        log_info "TCP 伪装监听: 启用 (端口 ${HY2_PORT})"
    else
        masquerade_tcp="false"
        log_info "TCP 伪装监听: 跳过"
    fi

    # ── 9. HTTP/3 屏蔽（参考 hy2.sh: 1545-1557）─────────────
    local block_http3
    echo ""
    echo "是否在服务器屏蔽 HTTP/3 (udp/443)?"
    echo "  使 YouTube 等 QUIC 网站不走 Hysteria2 代理，提升体验"
    echo "  1. 启用 (推荐)"
    echo "  2. 跳过 (默认)"
    read -rp "输入序号 [1-2，默认 2]: " bh3
    if [[ "${bh3}" == "1" ]]; then
        block_http3="true"
        log_info "HTTP/3 屏蔽: 启用"
    else
        block_http3="false"
        log_info "HTTP/3 屏蔽: 跳过"
    fi

    # ── 10. 端口跳跃（参考 hy2.sh: 1291-1395）────────────────
    local portHoppingStatus="false"
    local portHoppingStart portHoppingEnd
    local portHoppingIntervalMode portHoppingHopInterval
    local portHoppingMinHopInterval portHoppingMaxHopInterval

    echo ""
    echo "是否使用端口跳跃 (Port Hopping)?"
    echo "  长时间单端口 UDP 容易被 QoS/封锁，端口跳跃可有效缓解"
    echo "  1. 启用 (默认)"
    echo "  2. 跳过"
    read -rp "输入序号 [1-2，默认 1]: " ph_status
    if [[ -z "${ph_status}" ]] || [[ "${ph_status}" == "1" ]]; then
        portHoppingStatus="true"
        while true; do
            read -rp "起始端口 [默认: 47000]: " portHoppingStart
            portHoppingStart="${portHoppingStart:-47000}"
            read -rp "结束端口 [默认: 48000]: " portHoppingEnd
            portHoppingEnd="${portHoppingEnd:-48000}"
            if (( portHoppingStart >= portHoppingEnd )); then
                log_warn "起始端口必须小于结束端口"
                continue
            fi
            if (( portHoppingStart < 1 || portHoppingEnd > 65535 )); then
                log_warn "端口范围无效 (1-65535)"
                continue
            fi
            break
        done
        echo "跳跃时间模式:"
        echo "  1. 固定间隔 (默认)"
        echo "  2. 随机间隔"
        read -rp "输入序号 [1-2，默认 1]: " ph_mode
        if [[ -z "${ph_mode}" ]] || [[ "${ph_mode}" == "1" ]]; then
            portHoppingIntervalMode="fixed"
            read -rp "固定跳跃间隔 [默认: 30s，最低 5s]: " portHoppingHopInterval
            portHoppingHopInterval="${portHoppingHopInterval:-30s}"
        else
            portHoppingIntervalMode="random"
            read -rp "最小跳跃间隔 [默认: 10s，最低 5s]: " portHoppingMinHopInterval
            portHoppingMinHopInterval="${portHoppingMinHopInterval:-10s}"
            read -rp "最大跳跃间隔 [默认: 30s]: " portHoppingMaxHopInterval
            portHoppingMaxHopInterval="${portHoppingMaxHopInterval:-30s}"
        fi
        log_info "端口跳跃: ${portHoppingStart}-${portHoppingEnd} (${portHoppingIntervalMode})"
    else
        log_info "端口跳跃: 不使用"
    fi

    # ── 11. 写入配置文件 ──────────────────────────────────────
    mkdir -p /etc/hysteria

    local yaml="/etc/hysteria/config.yaml"
    > "$yaml"

    # listen（参考 hy2.sh: 1574-1580）
    if [[ "${portHoppingStatus}" == "true" ]]; then
        echo "listen: :${HY2_PORT},${portHoppingStart}-${portHoppingEnd}" >> "$yaml"
    else
        echo "listen: :${HY2_PORT}" >> "$yaml"
    fi

    # tls + sniGuard（参考 hy2.sh: 1685-1698）
    cat >> "$yaml" << EOF
tls:
  cert: /etc/hysteria/fullchain.pem
  key: /etc/hysteria/privkey.pem
  sniGuard: strict
EOF

    # auth
    cat >> "$yaml" << EOF
auth:
  type: password
  password: ${HY2_PASS}
EOF

    # resolver（使用系统 DNS，参考 hy2.sh 默认行为）
    cat >> "$yaml" << EOF
resolver:
  type: udp
  udp:
    addr: 127.0.0.1:53
    timeout: 4s
EOF

    # ignoreClientBandwidth（参考 hy2.sh: 1593）
    echo "ignoreClientBandwidth: ${ignore_client_bandwidth}" >> "$yaml"

    # congestion（参考 hy2.sh: 1594-1601）
    if [[ "${congestion_mode}" != "brutal" ]]; then
        cat >> "$yaml" << EOF
congestion:
  type: ${congestion_type}
EOF
        if [[ "${congestion_type}" == "bbr" ]]; then
            echo "  bbrProfile: ${bbr_profile}" >> "$yaml"
        fi
    fi

    # obfs（参考 hy2.sh: 1602-1607）
    if [[ "${obfs_status}" == "true" ]]; then
        cat >> "$yaml" << EOF
obfs:
  type: salamander
  salamander:
    password: ${obfs_pass}
EOF
    fi

    # quic（参考 hy2.sh: 1608-1618）
    cat >> "$yaml" << EOF
quic:
  initStreamReceiveWindow: ${init_stream}
  maxStreamReceiveWindow: ${max_stream}
  initConnReceiveWindow: ${init_conn}
  maxConnReceiveWindow: ${max_conn}
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
EOF

    # bandwidth
    if [[ "${congestion_mode}" == "brutal" ]]; then
        cat >> "$yaml" << EOF
bandwidth:
  up: ${brutal_ul:-${upload}} mbps
  down: ${brutal_dl:-${download}} mbps
EOF
    else
        cat >> "$yaml" << EOF
bandwidth:
  up: 200 mbps
  down: 200 mbps
EOF
    fi

    # speedTest（参考 hy2.sh: 1655）
    echo "speedTest: true" >> "$yaml"

    # masquerade（参考 hy2.sh: 1626-1654）
    case "${masquerade_type}" in
        "string")
            cat >> "$yaml" << EOF
masquerade:
  type: string
  string:
    content: ${masquerade_string}
    headers:
      content-type: text/plain
      custom-stuff: ${masquerade_stuff}
    statusCode: 200
EOF
            ;;
        "file")
            cat >> "$yaml" << EOF
masquerade:
  type: file
  file:
    dir: ${masquerade_file}
EOF
            ;;
        *)
            # proxy
            cat >> "$yaml" << EOF
masquerade:
  type: proxy
  proxy:
    url: ${masquerade_proxy:-${MASQUERADE_URL:-https://news.ycombinator.com/}}
    rewriteHost: true
EOF
            if [[ "${masquerade_xforwarded}" != "false" ]]; then
                echo "    xForwarded: true" >> "$yaml"
            fi
            ;;
    esac

    # TCP 共监听（参考 hy2.sh: 1652-1654）
    if [[ "${masquerade_tcp}" == "true" ]]; then
        echo "  listenHTTPS: :${HY2_PORT}" >> "$yaml"
    fi

    # ACL（参考 hy2.sh: 1625 + 本地规则）
    mkdir -p /etc/hihy/acl
    local acl_file="/etc/hihy/acl/hysteria2.acl"
    > "$acl_file"
    if [[ "${block_http3}" == "true" ]]; then
        echo "reject(all, udp/443)" >> "$acl_file"
    fi
    cat >> "$acl_file" << EOF
reject(10.0.0.0/8)
reject(172.16.0.0/12)
reject(192.168.0.0/16)
reject(127.0.0.0/8)
reject(fc00::/7)
reject(::1/128)
EOF
    cat >> "$yaml" << EOF
acl:
  file: ${acl_file}
  geoip: /var/lib/hysteria/geoip.dat
  geosite: /var/lib/hysteria/geosite.dat
  geoUpdateInterval: 168h
  inline:
    rules:
      - reject(10.0.0.0/8)
      - reject(172.16.0.0/12)
      - reject(192.168.0.0/16)
      - reject(127.0.0.0/8)
      - reject(fc00::/7)
      - reject(::1/128)
      - reject(geosite:cn)
      - reject(geosite:tld-cn)
      - reject(geoip:cn)
      - reject(all)
EOF

    # sniff（参考 hy2.sh: 1753-1757）
    cat >> "$yaml" << EOF
sniff:
  enabled: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: 80,443
  udpPorts: 80,443
EOF

    # outbounds（参考 hy2.sh: 1758-1769）
    cat >> "$yaml" << EOF
outbounds:
  - name: direct
    type: direct
    direct:
      mode: auto
      fastOpen: false
  - name: v4_only
    type: direct
    direct:
      mode: 4
      fastOpen: false
  - name: v6_only
    type: direct
    direct:
      mode: 6
      fastOpen: false
EOF

    # trafficStats（参考 hy2.sh: 1770-1775）
    local ts_port
    ts_port=$(( (RANDOM % (65534 - 10001)) + 10001 ))
    [[ "${ts_port}" == "${HY2_PORT}" ]] && ts_port=$(( HY2_PORT + 1 ))
    cat >> "$yaml" << EOF
trafficStats:
  listen: 127.0.0.1:${ts_port}
  secret: ${HY2_PASS}
EOF

    log_info "已写入 /etc/hysteria/config.yaml"

    # ── 12. 证书复制到 /etc/hysteria/ ─────────────────────────
    mkdir -p /etc/hysteria
    cp "${HY2_CERT}" /etc/hysteria/fullchain.pem
    cp "${HY2_KEY}"  /etc/hysteria/privkey.pem
    chown hysteria:hysteria /etc/hysteria/fullchain.pem /etc/hysteria/privkey.pem
    log_info "证书已复制到 /etc/hysteria/"

    # ── 13. 系统调优（参考 hy2.sh: 1779-1790）───────────────
    if [[ ${max_CRW} -gt 0 ]]; then
        sysctl -w net.core.rmem_max=${max_CRW} 2>/dev/null || true
        sysctl -w net.core.wmem_max=${max_CRW} 2>/dev/null || true
        log_info "系统缓冲区已调整 (rmem/wmem_max=${max_CRW})"
    fi
    if [[ "${portHoppingStatus}" == "true" ]]; then
        sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
        sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
        log_info "IP 转发已启用 (端口跳跃需要)"
    fi

    # ── 14. 写入 certbot deploy hook ────────────────────────────
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/hysteria-cert.sh << 'HOOK'
#!/bin/bash
# Auto-generated by xray-nginx-deploy — Hysteria2 cert deploy hook
STATE_FILE="/etc/xray-deploy/config.env"

get_hy2_domain() {
    local v
    v=$(grep "^HYSTERIA2_DOMAIN=" "$STATE_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    [[ -z "$v" ]] && v=$(grep "^ANYTLS_DOMAIN=" "$STATE_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    echo "$v"
}

[[ -z "$RENEWED_DOMAINS" ]] && exit 0

DOMAIN=$(get_hy2_domain)
[[ -z "$DOMAIN" ]] && { echo "[Hysteria Hook] 无法读取域名"; exit 1; }

ROOT_DOMAIN=$(echo "$DOMAIN" | sed 's/^[^.]*\.//')
SRC_FULLCHAIN="/etc/letsencrypt/live/${ROOT_DOMAIN}/fullchain.pem"
SRC_PRIVKEY="/etc/letsencrypt/live/${ROOT_DOMAIN}/privkey.pem"

if [[ -f "$SRC_FULLCHAIN" && -f "$SRC_PRIVKEY" ]]; then
    cp "$SRC_FULLCHAIN" /etc/hysteria/fullchain.pem
    cp "$SRC_PRIVKEY"   /etc/hysteria/privkey.pem
    chown hysteria:hysteria /etc/hysteria/fullchain.pem /etc/hysteria/privkey.pem
    systemctl restart hysteria-server.service
    echo "[Hysteria Hook] 证书已更新: ${DOMAIN}"
else
    echo "[Hysteria Hook] 证书文件不存在，跳过: ${DOMAIN}"
fi
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/hysteria-cert.sh
    log_info "已写入证书部署 hook"

    # ── 15. 启动服务 ──────────────────────────────────────────
    systemctl daemon-reload
    systemctl enable hysteria-server.service
    systemctl restart hysteria-server.service
    sleep 2
    if ! systemctl is-active --quiet hysteria-server.service; then
        log_warn "Hysteria2 服务未能正常启动，请检查："
        log_warn "  journalctl -u hysteria-server.service --no-pager -n 20"
    else
        log_info "Hysteria2 服务已启动"
    fi

    # ── 16. 客户端信息 ────────────────────────────────────────
    local client_port_display="${HY2_PORT}"
    [[ "${portHoppingStatus}" == "true" ]] && client_port_display="${portHoppingStart}-${portHoppingEnd}"

    echo ""
    log_info "━━━ Hysteria2 客户端配置 ━━━"
    log_info "服务器：   ${HY2_DOMAIN}:${client_port_display}"
    log_info "密码：     ${HY2_PASS}"
    log_info "TLS SNI：  ${HY2_DOMAIN}"
    log_info "跳过证书验证：否"
    [[ "${congestion_mode}" == "brutal" ]] && log_info "模式：     Brutal (上行 ${upload}mbps / 下行 ${download}mbps)"
    [[ "${obfs_status}" == "true" ]] && log_info "混淆：     salamander"
    [[ "${portHoppingStatus}" == "true" ]] && log_info "端口跳跃： ${portHoppingStart}-${portHoppingEnd}"
    echo ""
}

# ── 模块入口 ─────────────────────────────────────────────────
run_hysteria2() {
    log_step "========== Hysteria2 安装 =========="
    install_hysteria2
    configure_hysteria2
    log_info "========== Hysteria2 安装 & 配置完成 =========="
}