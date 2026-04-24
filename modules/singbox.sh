#!/usr/bin/env bash
# ============================================================
# modules/singbox.sh
# Sing-Box 安装 + AnyTLS 配置生成
# 自动识别系统：Ubuntu/Debian/CentOS/RHEL/Rocky/Alma
# ============================================================

# ── 安装 Sing-Box（官方仓库）────────────────────────────────
install_singbox() {
    log_step "安装 Sing-Box（官方仓库）..."
    log_info "检测到系统: $OS_NAME"

    case "$OS_ID" in
        ubuntu|debian)
            log_step "使用 apt 仓库安装..."

            # 导入 GPG key
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://sing-box.app/gpg.key \
                -o /etc/apt/keyrings/sagernet.asc
            chmod a+r /etc/apt/keyrings/sagernet.asc

            # 判断 apt 版本是否支持 .sources 格式（apt >= 1.6）
            local apt_ver
            apt_ver=$(apt-get --version 2>&1 | grep -oP '[\d.]+' | head -1)
            local apt_major
            apt_major=$(echo "$apt_ver" | cut -d. -f1)

            if [[ "$apt_major" -ge 2 ]] || \
               [[ "$apt_major" -eq 1 && $(echo "$apt_ver" | cut -d. -f2) -ge 6 ]]; then
                # 支持 .sources 格式
                cat > /etc/apt/sources.list.d/sagernet.sources << REPO
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
REPO
            else
                # 降级使用传统 .list 格式
                echo "deb [signed-by=/etc/apt/keyrings/sagernet.asc] \
https://deb.sagernet.org/ * *" \
                    > /etc/apt/sources.list.d/sagernet.list
            fi

            apt-get update -y >/dev/null 2>&1
            apt-get install -y sing-box >/dev/null 2>&1
            ;;

        centos|rhel|rocky|almalinux|fedora)
            log_step "使用 dnf 仓库安装..."

            # 添加官方 repo
            dnf config-manager addrepo \
                --from-repofile=https://sing-box.app/sing-box.repo \
                2>/dev/null || {
                # 兼容旧版 dnf 没有 addrepo 子命令
                curl -fsSL https://sing-box.app/sing-box.repo \
                    -o /etc/yum.repos.d/sing-box.repo
            }

            dnf install -y sing-box >/dev/null 2>&1
            ;;

        *)
            log_error "不支持的系统: $OS_NAME"
            exit 1
            ;;
    esac

    # 验证安装
    if ! command -v sing-box &>/dev/null; then
        log_error "Sing-Box 安装失败"
        exit 1
    fi

    local sb_ver
    sb_ver=$(sing-box version 2>&1 | grep -oP '[\d.]+' | head -1)
    log_info "Sing-Box 安装成功: v${sb_ver}"

    # 创建必要目录
    mkdir -p /etc/sing-box
    mkdir -p /var/lib/sing-box
    chmod 755 /var/lib/sing-box
}

# ── 生成 AnyTLS 密码 ─────────────────────────────────────────
generate_singbox_params() {
    log_step "生成 Sing-Box 参数..."

    local state_file="/etc/xray-deploy/config.env"
    local saved_password
    saved_password=$(grep "^SINGBOX_PASSWORD=" "$state_file" 2>/dev/null | \
        cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")

    if [[ -n "${saved_password}" ]]; then
        SINGBOX_PASSWORD="${saved_password}"
        log_info "复用已有 AnyTLS 密码"
    else
        SINGBOX_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)
        SINGBOX_PASSWORD="${SINGBOX_PASSWORD}-$(openssl rand -hex 4)"
        log_info "生成新 AnyTLS 密码"
    fi

    log_info "AnyTLS 密码: ${SINGBOX_PASSWORD}"
    if [[ "${SINGBOX_PASSWORD}" =~ [#\?&] ]]; then
        log_warn "当前 AnyTLS 密码包含 URI 保留字符，部分客户端导入链接时可能需要手动填写原始密码"
    fi
}

# ── 收集 AnyTLS 参数 ─────────────────────────────────────────
collect_singbox_params() {
    echo ""
    log_step "配置 AnyTLS 参数"
    echo ""

    if [[ -n "${ANYTLS_DOMAIN:-}" ]]; then
        log_info "AnyTLS 域名: ${ANYTLS_DOMAIN}"
    else
        read -rp "输入 AnyTLS 域名: " ANYTLS_DOMAIN
    fi

    # 自动查找证书
    local root_domain
    root_domain=$(echo "$ANYTLS_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

    if [[ -f "/etc/letsencrypt/live/${ANYTLS_DOMAIN}/fullchain.pem" ]]; then
        SINGBOX_CERT="/etc/letsencrypt/live/${ANYTLS_DOMAIN}/fullchain.pem"
        SINGBOX_KEY="/etc/letsencrypt/live/${ANYTLS_DOMAIN}/privkey.pem"
    elif [[ -f "/etc/letsencrypt/live/${root_domain}/fullchain.pem" ]]; then
        SINGBOX_CERT="/etc/letsencrypt/live/${root_domain}/fullchain.pem"
        SINGBOX_KEY="/etc/letsencrypt/live/${root_domain}/privkey.pem"
    else
        log_warn "未找到证书，请手动指定"
        read -rp "证书路径 fullchain.pem: " SINGBOX_CERT
        read -rp "私钥路径 privkey.pem:   " SINGBOX_KEY
    fi

    log_info "证书路径: ${SINGBOX_CERT}"
}

# ── 生成 config.json ─────────────────────────────────────────
generate_singbox_config() {
    log_step "生成 Sing-Box 配置文件..."

    cat > /etc/sing-box/config.json << CONF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "warp-dns",
        "type": "udp",
        "server": "1.1.1.1",
        "server_port": 53,
        "detour": "warp"
      },
      {
        "tag": "local_recursive",
        "type": "local"
      }
    ],
    "rules": [
      {
        "rule_set": ["geosite-cn"],
        "server": "warp-dns"
      }
    ],
    "final": "local_recursive",
    "strategy": "prefer_ipv4",
    "reverse_mapping": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "127.0.0.1",
      "listen_port": 8443,
      "users": [
        {
          "password": "${SINGBOX_PASSWORD}"
        }
      ],
      "padding_scheme": [
        "stop=8",
        "0=100-300",
        "1=300-600",
        "2=600-1200",
        "3=200-500,c",
        "4=400-900",
        "5=100-400,600-1000,c",
        "6=200-600,800-1400",
        "7=300-800,1000-1600,c"
      ],
      "tls": {
        "enabled": true,
        "server_name": "${ANYTLS_DOMAIN}",
        "certificate_path": "${SINGBOX_CERT}",
        "key_path": "${SINGBOX_KEY}",
        "alpn": ["h2", "http/1.1"],
        "min_version": "1.3",
        "max_version": "1.3"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "socks",
      "tag": "warp",
      "server": "127.0.0.1",
      "server_port": ${WARP_PROXY_PORT:-40000}
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "local_recursive",
    "rule_set": [
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
        "update_interval": "1d"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs",
        "update_interval": "1d"
      }
    ],
    "rules": [
      {
        "action": "sniff",
        "sniffer": ["dns", "http", "tls", "quic"],
        "timeout": "300ms"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "action": "reject"
      },
      {
        "rule_set": ["geosite-cn"],
        "outbound": "warp"
      },
      {
        "rule_set": ["geoip-cn"],
        "outbound": "warp"
      }
    ],
    "final": "direct"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/var/lib/sing-box/cache.db",
      "store_fakeip": false
    }
  }
}
CONF

    log_info "Sing-Box 配置文件生成完成"
}

# ── 启动 Sing-Box ────────────────────────────────────────────
start_singbox() {
    log_step "启动 Sing-Box 服务..."

    if ! sing-box check -c /etc/sing-box/config.json; then
        log_error "Sing-Box 配置验证失败"
        exit 1
    fi

    systemctl enable --now sing-box

    sleep 2
    if systemctl is-active --quiet sing-box; then
        log_info "Sing-Box 服务启动成功"
    else
        log_error "Sing-Box 服务启动失败，查看日志："
        journalctl -u sing-box -n 20 --no-pager
        exit 1
    fi
}

# ── 模块入口 ─────────────────────────────────────────────────
run_singbox() {
    log_step "========== Sing-Box 安装配置 =========="
    install_singbox
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox
    log_info "========== Sing-Box 安装配置完成 =========="
    echo ""
    log_info "关键参数（请保存）："
    echo "  AnyTLS 域名:  ${ANYTLS_DOMAIN}"
    echo "  AnyTLS 密码:  ${SINGBOX_PASSWORD}"
    echo "  监听端口:     8443"
}
