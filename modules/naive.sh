#!/usr/bin/env bash
# ============================================================
# modules/naive.sh
# NaiveProxy 服务端模块 — xcaddy 编译 Caddy + forwardproxy
# 参考: https://github.com/klzgrad/forwardproxy
# ============================================================

# ── 辅助：从 klzgrad/forwardproxy 仓库 go.mod 动态获取 module 路径 ──
# 不硬编码，避免未来 fork/迁移后路径失效
_get_forwardproxy_module() {
    local go_mod_url="https://raw.githubusercontent.com/klzgrad/forwardproxy/master/go.mod"
    local mod_path
    mod_path=$(curl -fsSL "$go_mod_url" 2>/dev/null \
        | grep '^module ' | head -1 | awk '{print $2}')
    if [[ -z "$mod_path" ]]; then
        log_warn "无法解析 forwardproxy go.mod，使用默认值"
        mod_path="github.com/caddyserver/forwardproxy"
    fi
    echo "$mod_path"
}

install_naive() {
    log_step "安装 NaiveProxy 服务端（xcaddy 编译 Caddy+forwardproxy）..."

    # ── 0. 检测架构 ────────────────────────────────────────
    local arch go_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  go_arch="amd64" ;;
        aarch64) go_arch="arm64" ;;
        arm64)   go_arch="arm64" ;;
        *) log_error "不支持的架构: $arch"; exit 1 ;;
    esac

    # ── 1. 安装编译依赖：gcc git ──────────────────────────
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq gcc git > /dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y gcc git > /dev/null
    elif command -v yum &>/dev/null; then
        yum install -y gcc git > /dev/null
    else
        log_warn "无法自动安装 gcc/git，请手动确保已安装"
    fi
    log_info "编译依赖 (gcc/git) 就绪"

    # ── 2. 安装 Go (≥1.21) ─────────────────────────────────
    local go_bin
    go_bin=$(command -v go 2>/dev/null)

    if [[ -n "$go_bin" ]]; then
        local go_ver go_major go_minor
        go_ver=$(go version 2>/dev/null | grep -oP 'go[\d.]+' | head -1 | sed 's/go//')
        IFS='.' read -r go_major go_minor _ <<< "$go_ver"
        if (( go_major < 1 || (go_major == 1 && go_minor < 21) )); then
            log_warn "Go ${go_ver} 版本过低（需 ≥1.21），将重新安装"
            go_bin=""
        fi
    fi

    if [[ -z "$go_bin" ]]; then
        local latest_go
        latest_go=$(curl -fsSL "https://go.dev/dl/?mode=json" 2>/dev/null \
            | grep -oP '"go\d+\.\d+(\.\d+)?"' | head -1 \
            | tr -d '"' | sed 's/go//')
        if [[ -z "$latest_go" ]]; then
            log_warn "无法获取 Go 最新版本，使用 1.24.3"
            latest_go="1.24.3"
        fi
        log_info "将安装 Go ${latest_go}"

        local go_tar="go${latest_go}.linux-${go_arch}.tar.gz"
        local tmpdir
        tmpdir=$(mktemp -d)

        log_info "下载 Go ${latest_go}..."
        if ! curl -fsSL "https://go.dev/dl/${go_tar}" -o "${tmpdir}/${go_tar}"; then
            log_error "Go 下载失败"
            rm -rf "$tmpdir"
            exit 1
        fi

        rm -rf /usr/local/go
        tar -C /usr/local -xzf "${tmpdir}/${go_tar}"
        rm -rf "$tmpdir"

        export PATH="/usr/local/go/bin:$PATH"
        grep -q '/usr/local/go/bin' /etc/profile 2>/dev/null \
            || echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile
        log_info "Go $(go version 2>&1 | grep -oP 'go[\d.]+' | head -1) 安装完成"
    else
        log_info "Go 已就绪: $(go version)"
    fi

    # ── 3. 安装 xcaddy ─────────────────────────────────────
    if ! command -v xcaddy &>/dev/null; then
        log_info "安装 xcaddy..."
        if ! go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest; then
            log_error "xcaddy 安装失败"
            exit 1
        fi
        export PATH="${HOME}/go/bin:$PATH"
        grep -q '/go/bin' /etc/profile 2>/dev/null \
            || echo 'export PATH=${HOME}/go/bin:$PATH' >> /etc/profile
    fi
    if ! command -v xcaddy &>/dev/null; then
        log_error "xcaddy 安装失败"
        exit 1
    fi
    log_info "xcaddy 就绪"

    # ── 4. 动态获取 forwardproxy module 路径并编译 ─────────
    local fp_module
    fp_module=$(_get_forwardproxy_module)
    log_info "forwardproxy module: ${fp_module}"

    log_info "开始编译 Caddy + forwardproxy（首次编译需下载依赖，请耐心等待）..."
    local build_tmpdir
    build_tmpdir=$(mktemp -d)

    if ! xcaddy build --with "${fp_module}=github.com/klzgrad/forwardproxy@naive" --output "${build_tmpdir}/caddy"; then
        log_error "xcaddy 编译失败"
        rm -rf "$build_tmpdir"
        exit 1
    fi

    # ── 5. 验证编译产物 ────────────────────────────────────
    if ! "${build_tmpdir}/caddy" list-modules 2>/dev/null | grep -q 'forward_proxy'; then
        log_error "编译验证失败: caddy list-modules 未包含 forward_proxy"
        rm -rf "$build_tmpdir"
        exit 1
    fi

    cp "${build_tmpdir}/caddy" /usr/local/bin/caddy-naive
    chmod +x /usr/local/bin/caddy-naive
    rm -rf "$build_tmpdir"

    local caddy_ver
    caddy_ver=$(caddy-naive version 2>&1 | head -1)
    log_info "NaiveProxy 安装成功: ${caddy_ver}"

    # ── 6. 创建系统用户 & systemd service ──────────────────
    if ! id -u caddy-naive &>/dev/null; then
        useradd -r -d /var/lib/caddy-naive -s /sbin/nologin caddy-naive
        log_info "已创建系统用户 caddy-naive"
    fi
    mkdir -p /var/lib/caddy-naive /etc/caddy-naive
    chown -R caddy-naive:caddy-naive /var/lib/caddy-naive /etc/caddy-naive

    cat > /etc/systemd/system/caddy-naive.service << 'SVC'
[Unit]
Description=NaiveProxy (Caddy + forwardproxy)
Documentation=https://github.com/klzgrad/naiveproxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy-naive
Group=caddy-naive
ExecStart=/usr/local/bin/caddy-naive run --config /etc/caddy-naive/Caddyfile
ExecReload=/usr/local/bin/caddy-naive reload --config /etc/caddy-naive/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    systemctl enable caddy-naive
    log_info "已生成 systemd service（已 enable）"
}

# ── 辅助：从 nginx 配置探测 naive Caddy 端口 ──────────────
# nginx stream: NAIVE_DOMAIN → 中间层端口 → proxy_pass → Caddy 端口
_detect_naive_caddy_port() {
    local nginx_conf="/etc/nginx/nginx.conf"
    local domain="$1"
    local mid_port caddy_port

    if [[ ! -f "$nginx_conf" ]]; then
        return 1
    fi

    # 在 stream map 块语义范围内查找域名 → 中间层端口 (如 18444)
    mid_port=$(awk '
        /^map\s+\$[a-zA-Z_]+\s+\$[a-zA-Z_]+/ { in_map=1 }
        in_map { print }
        in_map && /^\s*}/ { in_map=0 }
    ' "$nginx_conf" 2>/dev/null \
        | grep -v '^\s*#' \
        | grep -F "${domain}" \
        | grep -oP '127\.0\.0\.1:\K\d+' \
        | head -1)
    if [[ -z "$mid_port" ]]; then
        return 1
    fi

    # 从 stream server 块找 中间层端口 → proxy_pass Caddy 端口 (如 8444)
    caddy_port=$(awk "/listen.*${mid_port}.*proxy_protocol/,/}/" "$nginx_conf" \
        | grep 'proxy_pass' | grep -oP '127\.0\.0\.1:\K\d+' | head -1)
    if [[ -z "$caddy_port" ]]; then
        return 1
    fi

    echo "$caddy_port"
}

configure_naive() {
    log_step "配置 NaiveProxy..."

    # ── 1. 确定域名（与 hysteria2.sh 风格一致）───────────────
    local NAIVE_DOMAIN
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")

    if [[ -z "${NAIVE_DOMAIN}" ]]; then
        NAIVE_DOMAIN="${ANYTLS_DOMAIN:-}"
        [[ -n "${NAIVE_DOMAIN}" ]] && log_info "复用 AnyTLS 域名: ${NAIVE_DOMAIN}"
    fi

    if [[ -z "${NAIVE_DOMAIN}" ]]; then
        if [[ ${#ALL_DOMAINS[@]} -gt 0 ]]; then
            log_info "可用域名:"
            local i=1
            for d in "${ALL_DOMAINS[@]}"; do
                echo " ${i}. ${d}"
                (( i++ ))
            done
            local sel
            read -rp "请选择 NaiveProxy 域名 [1-$(( i - 1 ))]: " sel
            if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
                NAIVE_DOMAIN="${ALL_DOMAINS[$(( sel - 1 ))]}"
            fi
        fi
    fi

    if [[ -z "${NAIVE_DOMAIN}" ]]; then
        log_error "无法确定 NaiveProxy 域名，请先完成证书申请（步骤 4）"
        exit 1
    fi

    save_state "NAIVE_DOMAIN" "${NAIVE_DOMAIN}"
    log_info "NaiveProxy 域名: ${NAIVE_DOMAIN}"

    # ── 2. 证书路径（三段式：域名 cert → 根域 cert → 手动输入）────
    local root_domain NAIVE_CERT NAIVE_KEY
    root_domain=$(echo "$NAIVE_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

    if [[ -f "/etc/letsencrypt/live/${NAIVE_DOMAIN}/fullchain.pem" ]]; then
        NAIVE_CERT="/etc/letsencrypt/live/${NAIVE_DOMAIN}/fullchain.pem"
        NAIVE_KEY="/etc/letsencrypt/live/${NAIVE_DOMAIN}/privkey.pem"
    elif [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
        NAIVE_CERT="/etc/letsencrypt/live/${root_domain}/fullchain.pem"
        NAIVE_KEY="/etc/letsencrypt/live/${root_domain}/privkey.pem"
    else
        read -rp "证书路径 fullchain.pem: " NAIVE_CERT
        read -rp "私钥路径 privkey.pem: " NAIVE_KEY
    fi

    log_info "证书: ${NAIVE_CERT}"
    log_info "私钥: ${NAIVE_KEY}"

    # ── 3. 探测 Caddy 端口（从 nginx stream 配置自动获取）──────
    local NAIVE_PORT
    NAIVE_PORT=$(_detect_naive_caddy_port "${NAIVE_DOMAIN}")
    if [[ -n "${NAIVE_PORT}" ]]; then
        log_info "从 nginx 配置探测到 Caddy 端口: ${NAIVE_PORT}"
    else
        read -rp "Caddy 监听端口 [默认: 8444]: " NAIVE_PORT
        NAIVE_PORT="${NAIVE_PORT:-8444}"
        log_info "使用端口: ${NAIVE_PORT}（未从 nginx 探测到）"
    fi

    # ── 4. 认证信息 ──────────────────────────────────────────
    local NAIVE_USER
    NAIVE_USER=$(get_state "NAIVE_USER")
    if [[ -z "${NAIVE_USER}" ]]; then
        NAIVE_USER="naive"
        save_state "NAIVE_USER" "${NAIVE_USER}"
        log_info "默认用户名: ${NAIVE_USER}"
    else
        log_info "复用已有用户名: ${NAIVE_USER}"
    fi

    local NAIVE_PASS
    NAIVE_PASS=$(get_state "NAIVE_PASS")
    if [[ -z "${NAIVE_PASS}" ]]; then
        NAIVE_PASS=$(openssl rand -base64 18)
        save_state "NAIVE_PASS" "${NAIVE_PASS}"
        log_info "已生成新密码"
    else
        log_info "复用已有密码"
    fi

    # ── 5. probe_resistance 链接 ──────────────────────────────
    local probe_link
    probe_link=$(openssl rand -hex 8)
    save_state "NAIVE_PROBE_LINK" "${probe_link}"
    log_info "probe_resistance: ${probe_link}.${NAIVE_DOMAIN}"

    # ── 6. 伪装反代 ──────────────────────────────────────────
    local NAIVE_PROXY_TARGET
    NAIVE_PROXY_TARGET=$(get_state "NAIVE_PROXY_TARGET")
    if [[ -z "${NAIVE_PROXY_TARGET}" ]]; then
        read -rp "伪装反代地址 [默认: https://news.ycombinator.com]: " NAIVE_PROXY_TARGET
        NAIVE_PROXY_TARGET="${NAIVE_PROXY_TARGET:-https://news.ycombinator.com}"
        save_state "NAIVE_PROXY_TARGET" "${NAIVE_PROXY_TARGET}"
    fi
    log_info "伪装反代: ${NAIVE_PROXY_TARGET}"

    # ── 7. 写入 Caddyfile ────────────────────────────────────
    mkdir -p /etc/caddy-naive

    cat > /etc/caddy-naive/Caddyfile << EOF
{
    admin off
    auto_https off
}

:${NAIVE_PORT} {
    tls /etc/caddy-naive/fullchain.pem /etc/caddy-naive/privkey.pem

    route {
        forward_proxy {
            basic_auth ${NAIVE_USER} ${NAIVE_PASS}
            hide_ip
            hide_via
            probe_resistance ${probe_link}.${NAIVE_DOMAIN}
        }
        reverse_proxy ${NAIVE_PROXY_TARGET} {
            header_up Host {upstream_hostport}
        }
    }
}
EOF

    log_info "已写入 /etc/caddy-naive/Caddyfile"

    # ── 8. 证书复制 ──────────────────────────────────────────
    cp "${NAIVE_CERT}" /etc/caddy-naive/fullchain.pem
    cp "${NAIVE_KEY}" /etc/caddy-naive/privkey.pem
    chown -R caddy-naive:caddy-naive /etc/caddy-naive
    log_info "证书已复制到 /etc/caddy-naive/"

    # ── 9. 写入 certbot deploy hook ──────────────────────────
    cat > /etc/letsencrypt/renewal-hooks/deploy/naive-cert.sh << 'HOOK'
#!/bin/bash
# Auto-generated by xray-nginx-deploy — NaiveProxy cert deploy hook
STATE_FILE="/etc/xray-deploy/config.env"

get_naive_domain() {
    local v
    v=$(grep "^NAIVE_DOMAIN=" "$STATE_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    [[ -z "$v" ]] && v=$(grep "^ANYTLS_DOMAIN=" "$STATE_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    echo "$v"
}

[[ -z "$RENEWED_DOMAINS" ]] && exit 0

DOMAIN=$(get_naive_domain)
[[ -z "$DOMAIN" ]] && { echo "[Naive Hook] 无法读取域名"; exit 1; }

ROOT_DOMAIN=$(echo "$DOMAIN" | sed 's/^[^.]*\.//')
SRC_FULLCHAIN="/etc/letsencrypt/live/${ROOT_DOMAIN}/fullchain.pem"
SRC_PRIVKEY="/etc/letsencrypt/live/${ROOT_DOMAIN}/privkey.pem"

if [[ -f "$SRC_FULLCHAIN" && -f "$SRC_PRIVKEY" ]]; then
    cp "$SRC_FULLCHAIN" /etc/caddy-naive/fullchain.pem
    cp "$SRC_PRIVKEY" /etc/caddy-naive/privkey.pem
    chown -R caddy-naive:caddy-naive /etc/caddy-naive
    systemctl restart caddy-naive.service
    echo "[Naive Hook] 证书已更新: ${DOMAIN}"
else
    echo "[Naive Hook] 证书文件不存在，跳过: ${DOMAIN}"
fi
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/naive-cert.sh
    log_info "已写入证书部署 hook"

    # ── 10. 启动前验证配置 ───────────────────────────────────
    if ! /usr/local/bin/caddy-naive validate --config /etc/caddy-naive/Caddyfile; then
        log_error "Caddyfile 配置验证失败，请检查配置"
        exit 1
    fi

    # ── 11. 启动服务 ─────────────────────────────────────────
    systemctl daemon-reload
    systemctl enable caddy-naive.service
    systemctl restart caddy-naive.service
    sleep 2
    if ! systemctl is-active --quiet caddy-naive.service; then
        log_warn "NaiveProxy 服务未能正常启动，请检查："
        log_warn " journalctl -u caddy-naive.service --no-pager -n 20"
    else
        log_info "NaiveProxy 服务已启动"
    fi

    # ── 11. 客户端信息 ──────────────────────────────────────
    echo ""
    log_info "━━━ NaiveProxy 客户端配置 ━━━"
    log_info "服务器： ${NAIVE_DOMAIN}:443"
    log_info "用户名： ${NAIVE_USER}"
    log_info "密码：   ${NAIVE_PASS}"
    log_info "协议：   HTTPS"
    log_info "probe_resistance: ${probe_link}.${NAIVE_DOMAIN}"

    local naive_pass_encoded
    naive_pass_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${NAIVE_PASS}', safe=''))" 2>/dev/null || echo "${NAIVE_PASS}")
    local naive_url_extra="padding=true"
    [[ -n "${probe_link}" ]] && naive_url_extra+="&probe-resistance=${probe_link}.${NAIVE_DOMAIN}"
    log_info "链接：     naive+https://${NAIVE_USER}:${naive_pass_encoded}@${NAIVE_DOMAIN}:443?${naive_url_extra}#NaiveProxy"
    echo ""
}

# ── 模块入口 ─────────────────────────────────────────────────
run_naive() {
    log_step "========== NaiveProxy 安装 =========="
    install_naive
    configure_naive
    log_info "========== NaiveProxy 安装 & 配置完成 =========="
}
