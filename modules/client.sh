#!/usr/bin/env bash
# ============================================================
# modules/client.sh
# 生成客户端连接链接
# ============================================================

# ── 读取已有配置参数 ─────────────────────────────────────────
load_existing_params() {
    local xray_config="/usr/local/etc/xray/config.json"
    local sb_config="/etc/sing-box/config.json"

    XRAY_UUID=$(get_state "XRAY_UUID")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
    GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
    XRAY_PUBLIC_KEY=$(get_state "XRAY_PUBLIC_KEY")
    XHTTP_REALITY_PUBLIC_KEY=$(get_state "XHTTP_REALITY_PUBLIC_KEY")
    REALITY_SNI=$(get_state "REALITY_SNI")
    REALITY_DEST=$(get_state "REALITY_DEST")
    XHTTP_REALITY_SNI=$(get_state "XHTTP_REALITY_SNI")
    REALITY_SHORT_ID=$(get_state "REALITY_SHORT_ID")
    REALITY_SPIDER_X=$(get_state "REALITY_SPIDER_X")
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    SINGBOX_PASSWORD=$(get_state "SINGBOX_PASSWORD")
    XHTTP_PADDING=$(get_state "XHTTP_PADDING")
    # 不覆盖非空：load_domain_state 已按 PRIMARY 兜底到内存（规则 1 的只读兜底）
    REALITY_DOMAIN="${REALITY_DOMAIN:-$(get_state "REALITY_DOMAIN")}"
    XHTTP_REALITY_DOMAIN="${XHTTP_REALITY_DOMAIN:-$(get_state "XHTTP_REALITY_DOMAIN")}"
    HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
    HYSTERIA2_PASSWORD=$(get_state "HYSTERIA2_PASSWORD")
    HYSTERIA2_PH_START=$(get_state "HYSTERIA2_PH_START")
    HYSTERIA2_PH_END=$(get_state "HYSTERIA2_PH_END")
    HYSTERIA2_OBFS=$(get_state "HYSTERIA2_OBFS")
    HYSTERIA2_ECH=$(get_state "HYSTERIA2_ECH")
    HYSTERIA2_ECH_PUBLIC=$(get_state "HYSTERIA2_ECH_PUBLIC")
    HYSTERIA2_CONGESTION=$(get_state "HYSTERIA2_CONGESTION")
    HYSTERIA2_UPLOAD=$(get_state "HYSTERIA2_UPLOAD")
    HYSTERIA2_DOWNLOAD=$(get_state "HYSTERIA2_DOWNLOAD")
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")
    NAIVE_USER=$(get_state "NAIVE_USER")
    NAIVE_PASS=$(get_state "NAIVE_PASS")
    NAIVE_PROBE_LINK=$(get_state "NAIVE_PROBE_LINK")
    SUBSCRIPTION_PATH=$(get_state "SUBSCRIPTION_PATH")
    VLESS_ENC_CLIENT=$(get_state "VLESS_ENC_CLIENT")
    GRPC_SERVICE_NAME=$(get_state "GRPC_SERVICE_NAME")
    XHTTP_REALITY_DOMAIN="${XHTTP_REALITY_DOMAIN:-$(get_state "XHTTP_REALITY_DOMAIN")}"

    # 从 xray config 读取参数
    if [[ -f "$xray_config" ]]; then
        [[ -n "${XRAY_UUID:-}" ]] || \
            XRAY_UUID=$(grep -oP '"id":\s*"\K[^"]+' "$xray_config" | head -1)
        [[ -n "${XHTTP_PATH:-}" ]] || \
            XHTTP_PATH=$(grep -oP '"path":\s*"\K[^"]+' "$xray_config" | head -1)
        [[ -n "${XHTTP_DOMAIN:-}" ]] || \
            XHTTP_DOMAIN=$(grep -oP '"host":\s*"\K[^"]+' "$xray_config" | head -1)
        XHTTP_PADDING=$(grep -oP '"xPaddingBytes":\s*"\K[^"]+' "$xray_config" | head -1 || true)
        # ── 可选：CDN 节点 xhttp 的 xmux（默认不启用，高延迟线路可按需手动填入客户端 XHTTP Extra）──
        #    规则：五项必须写全；hKeepAlivePeriod 是整数，不能写范围；不能与 maxConnections 同用
        #    A 组:
        #    {
        #      "xmux": {
        #        "maxConcurrency": "16-32",
        #        "cMaxReuseTimes": 0,
        #        "hMaxRequestTimes": "600-900",
        #        "hMaxReusableSecs": "1800-3000",
        #        "hKeepAlivePeriod": 30
        #      }
        #    }
        #    B 组:
        #    {
        #      "xmux": {
        #        "maxConcurrency": "8-16",
        #        "cMaxReuseTimes": 0,
        #        "hMaxRequestTimes": "300-600",
        #        "hMaxReusableSecs": "900-1800",
        #        "hKeepAlivePeriod": 30
        #      }
        #    }
        #    vless-xhttp-reality 节点不需要填 Extra
        XHTTP_EXTRA_JSON=$(python3 -c "
import json
# 仅导出客户端有意义的字段：enc / xPaddingBytes / xmux
# 服务端 extra 中的 scStreamUpServerSecs（上行流时长）与 headers（响应头）
# 仅服务端使用；新版 Xray-core 客户端默认动态 Chrome UA，无需 headers
CLIENT_KEYS = ('enc', 'xPaddingBytes', 'xmux')
with open('${xray_config}') as f:
    c = json.load(f)
for inb in c.get('inbounds', []):
    xs = inb.get('streamSettings', {})
    if xs.get('network') == 'xhttp':
        xhs = xs.get('xhttpSettings', {})
        extra = xhs.get('extra', {})
        client_extra = {k: extra[k] for k in CLIENT_KEYS if k in extra}
        print(json.dumps(client_extra, indent=2, ensure_ascii=False) if client_extra else '')
        break
" 2>/dev/null || echo '')

        # 读取第一个非空 shortId
        [[ -n "${REALITY_SHORT_ID:-}" ]] || REALITY_SHORT_ID=$(python3 -c "
import json
with open('${xray_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('streamSettings', {}).get('security') == 'reality':
        ids = inb['streamSettings']['realitySettings']['shortIds']
        print(next((i for i in ids if i), ids[0] if ids else ''))
        break
" 2>/dev/null || echo "")

        # 读取第一个 serverName
        [[ -n "${REALITY_SNI:-}" ]] || REALITY_SNI=$(python3 -c "
import json
with open('${xray_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('streamSettings', {}).get('security') == 'reality':
        sns = inb['streamSettings']['realitySettings']['serverNames']
        print(sns[0] if sns else '')
        break
" 2>/dev/null || echo "")

        [[ -n "${REALITY_SPIDER_X:-}" ]] || REALITY_SPIDER_X=$(python3 -c "
import json
with open('${xray_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('streamSettings', {}).get('security') == 'reality':
        print(inb['streamSettings']['realitySettings'].get('spiderX', ''))
        break
" 2>/dev/null || echo "")

        # 公钥需要从私钥推导
        if [[ -z "${XRAY_PUBLIC_KEY:-}" ]]; then
            local reality_privkey
            reality_privkey=$(grep -oP '"privateKey":\s*"\K[^"]+' "$xray_config" | head -1)
            if [[ -n "${reality_privkey:-}" ]]; then
                local keypair
                keypair=$(xray x25519 -i "$reality_privkey" 2>/dev/null || true)
                XRAY_PUBLIC_KEY=$(echo "$keypair" | grep -i "public\|password" | awk '{print $NF}' || true)
            fi
        fi

        # VLESS Encryption：state 缺失时从 config.json 的 decryption Seed 推导 Client
        if [[ -z "${VLESS_ENC_CLIENT:-}" ]]; then
            local enc_seed
            enc_seed=$(grep -oP '"decryption":\s*"mlkem768x25519plus\.[^"]+' "$xray_config" | head -1 | grep -oP '[^.]+$' || true)
            if [[ -n "${enc_seed:-}" ]]; then
                VLESS_ENC_CLIENT=$(xray mlkem768 -i "${enc_seed}" 2>/dev/null | grep -i "client" | awk '{print $NF}' || true)
            fi
        fi

        # gRPC 域名从 nginx 配置读取
        if [[ -z "${GRPC_DOMAIN:-}" ]]; then
            GRPC_DOMAIN=$(grep -oP 'server_name\s+\K\S+' \
                /etc/nginx/conf.d/servers.conf 2>/dev/null | \
                grep -v "^\." | sed -n '2p' | tr -d ';' || true)
        fi
    fi

    # 从 sing-box config 读取参数
    if [[ -f "$sb_config" ]]; then
        [[ -n "${SINGBOX_PASSWORD:-}" ]] || SINGBOX_PASSWORD=$(python3 -c "
import json
with open('${sb_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('type') == 'anytls':
        print(inb['users'][0]['password'])
        break
" 2>/dev/null || echo "")

        [[ -n "${ANYTLS_DOMAIN:-}" ]] || ANYTLS_DOMAIN=$(python3 -c "
import json
with open('${sb_config}') as f:
    c = json.load(f)
for inb in c['inbounds']:
    if inb.get('type') == 'anytls':
        print(inb['tls']['server_name'])
        break
" 2>/dev/null || echo "")
    fi

    XHTTP_PADDING="${XHTTP_PADDING:-100-300}"

    # CDN 节点分享链接的 encryption 参数（字符均为 URI 安全字符，无需编码）
    VLESS_ENC_PARAM=""
    if [[ -n "${VLESS_ENC_CLIENT:-}" ]]; then
        VLESS_ENC_PARAM="mlkem768x25519plus.native.0rtt.${VLESS_ENC_CLIENT}"
    fi
}

# ── 获取服务器IP ─────────────────────────────────────────────
get_server_ip() {
    SERVER_IP=$(curl -fsSL -4 https://api.ipify.org 2>/dev/null || \
                curl -fsSL -4 https://ip.sb 2>/dev/null || \
                hostname -I | awk '{print $1}')
    log_info "服务器IP: ${SERVER_IP}"
}

# ── 生成 xhttp CDN 节点链接 ──────────────────────────────────
gen_xhttp_url() {
    if [[ -z "${XHTTP_DOMAIN:-}" ]] || [[ -z "${XRAY_UUID:-}" ]]; then
        return
    fi

    local path_encoded
    path_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${XHTTP_PATH}'))
" 2>/dev/null || echo "${XHTTP_PATH}")

    local _hn
    _hn=$(hostname -s 2>/dev/null || echo "server")
    # 客户端 xhttp 优化参数（仅客户端生效，服务端无需配置）：
    #   mode=auto：跟随 CDN 回落方式自动切换 stream-up / stream-one / packet-up
    #   extra={"xmux":{...}}：XHTTP 多路复用，高延迟线路按需调整并发/复用窗口
    XHTTP_URL="vless://${XRAY_UUID}@${XHTTP_DOMAIN}:443?\
encryption=${VLESS_ENC_PARAM:-none}\
&security=tls\
&sni=${XHTTP_DOMAIN}\
&fp=chrome\
&type=xhttp\
&path=${path_encoded}\
&host=${XHTTP_DOMAIN}\
&mode=auto\
&extra=%7B%0A%20%20%22xmux%22%3A%20%7B%0A%20%20%20%20%22maxConcurrency%22%3A%20%2216-32%22%2C%0A%20%20%20%20%22cMaxReuseTimes%22%3A%200%2C%0A%20%20%20%20%22hMaxRequestTimes%22%3A%20%22600-900%22%2C%0A%20%20%20%20%22hMaxReusableSecs%22%3A%20%221800-3000%22%2C%0A%20%20%20%20%22hKeepAlivePeriod%22%3A%2030%0A%20%20%7D%0A%7D\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('vless-xhttp-${_hn}'))" 2>/dev/null)"
}

# ── 生成 gRPC CDN 节点链接 ───────────────────────────────────
gen_grpc_url() {
    if [[ -z "${GRPC_DOMAIN:-}" ]] || [[ -z "${XRAY_UUID:-}" ]]; then
        return
    fi

    local _hn
    _hn=$(hostname -s 2>/dev/null || echo "server")
    GRPC_URL="vless://${XRAY_UUID}@${GRPC_DOMAIN}:443?\
encryption=${VLESS_ENC_PARAM:-none}\
&security=tls\
&sni=${GRPC_DOMAIN}\
&fp=chrome\
&type=grpc\
&serviceName=${GRPC_SERVICE_NAME}\
&mode=gun\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('vless-grpc-${_hn}'))" 2>/dev/null)"
}

# 该 Reality 槽的 SNI 来源是不是「借公共大站」。0 = 借公共，1 = 用自有域自建。
#
# ⚠️ 与 modules/xray.sh、modules/nginx.sh 的同名函数**逐字同实现**，改要一起改
#    （模块之间不能依赖对方「后加」的函数——加载顺序不保证）。判据见 xray.sh
#    的长注释：无域 → 借公共；有域 → 看 *_SNI_MODE，缺省 self。
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

# ── 生成 VLESS-XHTTP-REALITY 直连节点链接 ────────────────────
gen_xhttp_reality_url() {
    # 地址与 SNI 解耦：分配了自有域就拿它当**连接地址**（客户端支持域名当地址），
    # SNI 则由 SNI 来源决定 —— 自建=该自有域，借公共=所选公共大站。
    # 旧代码把「sni」直接绑在域名上，于是「地址用自有域 + SNI 借公共」没法表达。
    local _xhttp_r_sni
    if _reality_slot_borrows_public xhttp-reality; then
        _xhttp_r_sni="${XHTTP_REALITY_SNI:-}"
    else
        _xhttp_r_sni="${XHTTP_REALITY_DOMAIN:-}"
    fi
    if [[ -z "${_xhttp_r_sni}" ]] || [[ -z "${XRAY_UUID:-}" ]] || [[ -z "${XHTTP_PATH:-}" ]]; then
        return
    fi

    local path_encoded reality_host _hn
    path_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${XHTTP_PATH}'))
" 2>/dev/null || echo "${XHTTP_PATH}")

    # 连接地址：自有直连域（支持双栈）优先，退到直连域/AnyTLS 域/服务器 IP；
    # 公共 SNI 从不作连接地址（它不属于本机，解析到的是别人家）。
    # 规则 2（2026-10-02）：连接地址 = 配置表分配给该槽的域名；无则回退服务器 IP。
    # 删掉 ANYTLS_DOMAIN 这一跳：它会把 host 换成别人家的域（与规则 2 冲突）。
    if [[ -n "${XHTTP_REALITY_DOMAIN:-}" ]]; then
        reality_host="${XHTTP_REALITY_DOMAIN}"
    else
        log_warn "vless-xhttp-reality 未在配置表第 3 行分配域名；连接地址回退为服务器 IP（${SERVER_IP}）"
        reality_host="${SERVER_IP}"
    fi
    _hn=$(hostname -s 2>/dev/null || echo "server")
    XHTTP_REALITY_URL="vless://${XRAY_UUID}@${reality_host}:443?\
path=${path_encoded}\
&mode=stream-one\
&type=xhttp\
&encryption=none\
&fp=chrome\
&pbk=${XHTTP_REALITY_PUBLIC_KEY:-${XRAY_PUBLIC_KEY}}\
&sid=${REALITY_SHORT_ID}\
&security=reality\
&sni=${_xhttp_r_sni}\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('vless-xhttp-reality-${_hn}'))" 2>/dev/null)"
}

# ── 生成 Reality 直连节点链接 ────────────────────────────────
gen_reality_url() {
    # sni 必须落在服务端 realitySettings.serverNames 里才会被接受，故由**SNI 来源**
    # 决定，与「域名是否分配」无关：
    #   自建 → serverNames=[REALITY_DOMAIN] → sni = REALITY_DOMAIN
    #   借公共 → serverNames=[REALITY_SERVER_NAMES] → sni = REALITY_SNI（=serverNames[0]）
    # 直接拼 REALITY_SNI 会因 state 残留旧公共名（如 film.ca.gov）而生成死节点；
    # 反过来在借公共时拼 REALITY_DOMAIN 同样会生成死节点（服务端 serverNames 里没有它）。
    local reality_sni
    if _reality_slot_borrows_public xray-reality; then
        reality_sni="${REALITY_SNI:-}"
    else
        reality_sni="${REALITY_DOMAIN:-}"
    fi
    if [[ -z "${reality_sni}" ]] || [[ -z "${XRAY_UUID:-}" ]]; then
        return
    fi

    local spider_encoded
    spider_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${REALITY_SPIDER_X:-/api/health}'))
" 2>/dev/null || echo "%2Fapi%2Fhealth")

    # 优先用自有直连域名（支持双栈），不使用公共 SNI 作连接地址
    # 规则 2：连接地址 = 配置表第 4 行分配给本槽的域名；无则回退服务器 IP
    local reality_host
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        reality_host="${REALITY_DOMAIN}"
    else
        log_warn "vless-reality 未在配置表第 4 行分配域名；连接地址回退为服务器 IP（${SERVER_IP}）"
        reality_host="${SERVER_IP}"
    fi
    local _hn
    _hn=$(hostname -s 2>/dev/null || echo "server")
    REALITY_URL="vless://${XRAY_UUID}@${reality_host}:443?\
encryption=none\
&security=reality\
&sni=${reality_sni}\
&fp=chrome\
&pbk=${XRAY_PUBLIC_KEY}\
&sid=${REALITY_SHORT_ID}\
&flow=xtls-rprx-vision\
&type=tcp\
&spiderX=${spider_encoded}\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('vless-reality-${_hn}'))" 2>/dev/null)"
}

# ── 生成 AnyTLS 节点链接 ─────────────────────────────────────
gen_anytls_url() {
    if [[ -z "${ANYTLS_DOMAIN:-}" ]] || [[ -z "${SINGBOX_PASSWORD:-}" ]]; then
        return
    fi

    if [[ "${SINGBOX_PASSWORD}" == *"#"* || "${SINGBOX_PASSWORD}" == *"?"* || "${SINGBOX_PASSWORD}" == *"&"* ]]; then
        log_warn "AnyTLS 密码包含 URI 保留字符，若客户端导入失败请直接使用输出文件中的原始密码"
    fi

    local password_encoded
    password_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${SINGBOX_PASSWORD}', safe=''))
" 2>/dev/null || echo "${SINGBOX_PASSWORD}")

    local _hn
    _hn=$(hostname -s 2>/dev/null || echo "server")
    ANYTLS_URL="anytls://${password_encoded}@${ANYTLS_DOMAIN}:443?\
security=tls\
&sni=${ANYTLS_DOMAIN}\
&alpn=h2\
&insecure=0\
#$(python3 -c "import urllib.parse; print(urllib.parse.quote('anytls-${_hn}'))" 2>/dev/null)"
}

# ── 生成 Hysteria2 节点链接 ────────────────────────────────────
gen_hysteria2_url() {
    if [[ -z "${HYSTERIA2_DOMAIN:-}" ]] || [[ -z "${HYSTERIA2_PASSWORD:-}" ]]; then
        return
    fi

    local password_encoded
    password_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${HYSTERIA2_PASSWORD}', safe=''))
" 2>/dev/null || echo "${HYSTERIA2_PASSWORD}")

    local extra_params="sni=${HYSTERIA2_DOMAIN}&insecure=0"
    [[ -n "${HYSTERIA2_PH_START:-}" && -n "${HYSTERIA2_PH_END:-}" ]] && extra_params+="&mport=${HYSTERIA2_PH_START}-${HYSTERIA2_PH_END}"
    [[ -n "${HYSTERIA2_OBFS:-}" ]] && extra_params+="&obfs=${HYSTERIA2_OBFS}&obfs-password=${password_encoded}"
    if [[ -n "${HYSTERIA2_ECH:-}" ]]; then
        # 只取 ECH CONFIGS 块 —— 同文件里的 ECH KEYS 是服务端私钥，绝不能进订阅
        local _ech_cfg
        _ech_cfg=$(awk '/-----BEGIN ECH CONFIGS-----/{f=1;next}
                        /-----END ECH CONFIGS-----/{f=0}
                        f' /etc/hysteria/ech.pem 2>/dev/null | tr -d '\n' || true)
        if [[ -n "${_ech_cfg}" ]]; then
            # 供 show_client_links 原样打印：Passwall 等客户端不认 URI 里的
            # ech=，需要用户手工填裸 base64（sing-box 则要 PEM 形式）
            HYSTERIA2_ECH_CFG="${_ech_cfg}"
            # PEM 形式 = 同一份 base64 按 64 列折行 + 头尾标记。两种内联写法
            # 恰好相反（实机验证）：hysteria 官方客户端内联只认裸 base64，填
            # PEM 会 FATAL（它把整串当文件路径 open）；sing-box 的
            # tls.ech.config 只认 PEM 原文，填裸 base64 会 FATAL。
            HYSTERIA2_ECH_PEM="$(printf -- '-----BEGIN ECH CONFIGS-----\n%s\n-----END ECH CONFIGS-----' \
                "$(printf '%s' "${_ech_cfg}" | fold -w 64)")"
            # 编码方式由实测确定（hysteria share -c 的输出）：ech= 用标准
            # 百分号编码，即 base64 的 + → %2B、/ → %2F、= → %3D，不是 base64url
            local _ech_encoded
            _ech_encoded=$(ECH_CFG="${_ech_cfg}" python3 -c "
import os, urllib.parse
print(urllib.parse.quote(os.environ['ECH_CFG'], safe=''))
" 2>/dev/null || echo "${_ech_cfg}")
            extra_params+="&ech=${_ech_encoded}"
        else
            log_warn "已启用 ECH，但读不到 /etc/hysteria/ech.pem 的 ECH CONFIGS 块 —— 本条链接不含 ech 参数"
        fi
    fi
    if [[ "${HYSTERIA2_CONGESTION}" == "brutal" ]]; then
        [[ -n "${HYSTERIA2_UPLOAD:-}" ]] && extra_params+="&up=${HYSTERIA2_UPLOAD}"
        [[ -n "${HYSTERIA2_DOWNLOAD:-}" ]] && extra_params+="&down=${HYSTERIA2_DOWNLOAD}"
    fi
    local _hn
    _hn=$(hostname -s 2>/dev/null || echo "server")
    HYSTERIA2_URL="hysteria2://${password_encoded}@${HYSTERIA2_DOMAIN}:443?${extra_params}#$(python3 -c "import urllib.parse; print(urllib.parse.quote('hysteria2-${_hn}'))" 2>/dev/null || echo "hysteria2-${_hn}")"
}

# ── 生成 NaiveProxy 节点链接 ───────────────────────────────────
gen_naive_url() {
    if [[ -z "${NAIVE_DOMAIN:-}" ]] || [[ -z "${NAIVE_USER:-}" ]] || [[ -z "${NAIVE_PASS:-}" ]]; then
        return
    fi

    local pass_encoded
    pass_encoded=$(python3 -c "
import urllib.parse
print(urllib.parse.quote('${NAIVE_PASS}', safe=''))
" 2>/dev/null || echo "${NAIVE_PASS}")

    local naive_params="padding=true"
    [[ -n "${NAIVE_PROBE_LINK:-}" ]] && naive_params+="&probe-resistance=${NAIVE_PROBE_LINK}.${NAIVE_DOMAIN}"
    local _hn
    _hn=$(hostname -s 2>/dev/null || echo "server")
    NAIVE_URL="naive+https://${NAIVE_USER}:${pass_encoded}@${NAIVE_DOMAIN}:443?${naive_params}#$(python3 -c "import urllib.parse; print(urllib.parse.quote('naive-${_hn}'))" 2>/dev/null || echo "naive-${_hn}")"
}

# ── 生成机场风格订阅文件 ─────────────────────────────────────
write_subscription_file() {
    local sub_domain="${XHTTP_DOMAIN:-${GRPC_DOMAIN:-}}"
    # 订阅文件必须放在对应域名的 webroot 下，nginx try_files 才能正确服务
    local sub_dir="/var/www/${sub_domain}"
    local machine_name sub_name sub_prefix

    SUBSCRIPTION_URL=""
    if [[ -z "${sub_domain}" ]]; then
        return
    fi

    machine_name=$(hostname -s 2>/dev/null || echo "server")
    sub_name=$(printf '%s' "${machine_name:-server}" | tr -c 'A-Za-z0-9._-' '-')
    sub_name="${sub_name:-server}"
    sub_prefix="/sub-${sub_name}-"
    SUBSCRIPTION_NAME="${machine_name:-server}"

    if [[ -z "${SUBSCRIPTION_PATH:-}" || ! "${SUBSCRIPTION_PATH}" =~ ^/[A-Za-z0-9._-]+$ || "${SUBSCRIPTION_PATH}" != "${sub_prefix}"* ]]; then
        SUBSCRIPTION_PATH="${sub_prefix}$(tr -d '-' < /proc/sys/kernel/random/uuid)"
        save_state "SUBSCRIPTION_PATH" "${SUBSCRIPTION_PATH}"
    fi

    mkdir -p "$sub_dir"
    # 清理旧位置（之前错误地写到 /var/www/html/）
    if [[ "$sub_dir" != "/var/www/html" ]]; then
        rm -f "/var/www/html${SUBSCRIPTION_PATH}" 2>/dev/null || true
    fi
    local sub_file="${sub_dir}${SUBSCRIPTION_PATH}"
    local tmp_links
    tmp_links=$(mktemp)
    {
        [[ -n "${XHTTP_URL:-}" ]] && echo "$XHTTP_URL"
        [[ -n "${GRPC_URL:-}" ]] && echo "$GRPC_URL"
        [[ -n "${XHTTP_REALITY_URL:-}" ]] && echo "$XHTTP_REALITY_URL"
        [[ -n "${REALITY_URL:-}" ]] && echo "$REALITY_URL"
        [[ -n "${ANYTLS_URL:-}" ]] && echo "$ANYTLS_URL"
        [[ -n "${HYSTERIA2_URL:-}" ]] && echo "$HYSTERIA2_URL"
        [[ -n "${NAIVE_URL:-}" ]] && echo "$NAIVE_URL"
    } > "$tmp_links"

    if [[ ! -s "$tmp_links" ]]; then
        rm -f "$tmp_links"
        return
    fi

    # 凭据轮换后旧订阅已失效：写新订阅前清掉同 webroot 同前缀的历史 sub-*，
    # 否则旧 URL 仍能拉到已死凭据的节点，误导用户以为又坏了。
    # 保留当前即将写入的文件（UUID 命名不可能撞名，! -name 仅作保险）。
    find "$sub_dir" -maxdepth 1 -type f -name "sub-${sub_name}-*" \
        ! -name "$(basename "$sub_file")" -delete 2>/dev/null || true

    base64 -w 0 "$tmp_links" > "$sub_file"
    echo >> "$sub_file"
    chmod 644 "$sub_file"
    rm -f "$tmp_links"

    SUBSCRIPTION_URL="https://${sub_domain}${SUBSCRIPTION_PATH}"
}

# ── 保存并展示所有链接 ───────────────────────────────────────
show_client_links() {
    local output_file="/root/xray_client_links.txt"

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}          客户端连接链接                ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    {
        echo "# ============================================================"
        echo "# 客户端连接链接"
        echo "# 生成时间: $(date)"
        echo "# 服务器IP: ${SERVER_IP}"
        echo "# ============================================================"
        echo ""
    } > "$output_file"

    if [[ -n "${SUBSCRIPTION_URL:-}" ]]; then
        echo -e "${GREEN}[订阅链接: ${SUBSCRIPTION_NAME}]${NC}"
        echo "$SUBSCRIPTION_URL"
        echo ""
        {
            echo "# 订阅名称: ${SUBSCRIPTION_NAME}"
            echo "# 订阅链接"
            echo "$SUBSCRIPTION_URL"
            echo ""
        } >> "$output_file"
    fi

    # xhttp CDN
    if [[ -n "${XHTTP_URL:-}" ]]; then
        echo -e "${GREEN}[xhttp CDN]${NC}"
        echo "$XHTTP_URL"
        echo ""
        echo "XHTTP Extra:"
        echo "$XHTTP_EXTRA_JSON"
        echo ""
        {
            echo "# xhttp CDN"
            echo "$XHTTP_URL"
            echo ""
            echo "# xhttp Extra 参数（v2rayN XHTTP Extra 填入）"
            echo "$XHTTP_EXTRA_JSON"
            echo ""
        } >> "$output_file"
    fi

    # gRPC CDN
    if [[ -n "${GRPC_URL:-}" ]]; then
        echo -e "${GREEN}[gRPC CDN]${NC}"
        echo "$GRPC_URL"
        echo ""
        {
            echo "# gRPC CDN"
            echo "$GRPC_URL"
            echo ""
        } >> "$output_file"
    fi

    # XHTTP-REALITY 直连
    if [[ -n "${XHTTP_REALITY_URL:-}" ]]; then
        echo -e "${GREEN}[XHTTP-Reality 直连]${NC}"
        echo "$XHTTP_REALITY_URL"
        echo ""
        {
            echo "# XHTTP-Reality 直连"
            echo "$XHTTP_REALITY_URL"
            echo ""
        } >> "$output_file"
    fi

    # Reality 直连
    if [[ -n "${REALITY_URL:-}" ]]; then
        echo -e "${GREEN}[Reality 直连 (TCP+Vision)]${NC}"
        echo "$REALITY_URL"
        echo ""
        {
            echo "# Reality 直连 (TCP+Vision)"
            echo "$REALITY_URL"
            echo ""
        } >> "$output_file"
    fi

    # AnyTLS
    if [[ -n "${ANYTLS_URL:-}" ]]; then
        echo -e "${GREEN}[AnyTLS]${NC}"
        echo "$ANYTLS_URL"
        echo ""
        {
            echo "# AnyTLS"
            echo "$ANYTLS_URL"
            echo ""
        } >> "$output_file"
    fi

    # Hysteria2
    if [[ -n "${HYSTERIA2_URL:-}" ]]; then
        echo -e "${GREEN}[Hysteria2]${NC}"
        echo "$HYSTERIA2_URL"
        echo -e "  服务器: ${HYSTERIA2_DOMAIN}:443"
        echo -e "  密码:   ${HYSTERIA2_PASSWORD}"
        echo -e "  SNI:    ${HYSTERIA2_DOMAIN}"
        echo -e "  协议:   UDP"
        if [[ -n "${HYSTERIA2_ECH:-}" ]]; then
            echo -e "  ECH:    已启用 (外层 SNI: ${HYSTERIA2_ECH_PUBLIC:-未记录})"
            # 下面两段刻意顶格输出，便于整段选中复制：sing-box 的 PEM 解析
            # 不接受前导空格，带缩进粘过去会 FATAL invalid ECH configs pem
            # （实机验证；hysteria 对 base64 的前导空格则容忍）。两种写法相反，
            # 务必按标注对应客户端。
            echo -e "  ECH[hysteria 官方/Passwall，裸 base64]:"
            echo "${HYSTERIA2_ECH_CFG:-（未取到，检查 /etc/hysteria/ech.pem）}"
            if [[ -n "${HYSTERIA2_ECH_PEM:-}" ]]; then
                echo -e "  ECH[sing-box，PEM 原文]:"
                printf '%s\n' "${HYSTERIA2_ECH_PEM}"
            fi
        fi
        echo ""
        {
            echo "# Hysteria2"
            echo "$HYSTERIA2_URL"
            if [[ -n "${HYSTERIA2_ECH:-}" && -n "${HYSTERIA2_ECH_CFG:-}" ]]; then
                echo "# ECH[hysteria 官方/Passwall，裸 base64]:"
                echo "# ${HYSTERIA2_ECH_CFG}"
                if [[ -n "${HYSTERIA2_ECH_PEM:-}" ]]; then
                    echo "# ECH[sing-box，PEM 原文]:"
                    printf '%s\n' "${HYSTERIA2_ECH_PEM}" | sed 's/^/# /'
                fi
            fi
            echo ""
        } >> "$output_file"
    fi

    # NaiveProxy
    if [[ -n "${NAIVE_URL:-}" ]]; then
        echo -e "${GREEN}[NaiveProxy]${NC}"
        echo "$NAIVE_URL"
        echo -e "  服务器: ${NAIVE_DOMAIN}:443"
        echo -e "  用户名: ${NAIVE_USER}"
        echo -e "  密码:   ${NAIVE_PASS}"
        echo -e "  协议:   HTTPS"
        echo ""
        {
            echo "# NaiveProxy"
            echo "$NAIVE_URL"
            echo ""
        } >> "$output_file"
    fi

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 关键参数汇总
    {
        echo "# ============================================================"
        echo "# 关键参数汇总"
        echo "# ============================================================"
        echo "UUID:            ${XRAY_UUID:-}"
        echo "公钥(PublicKey): ${XRAY_PUBLIC_KEY:-}"
        echo "VLESS Encryption(CDN 节点 encryption 填): ${VLESS_ENC_PARAM:-none}"
        echo "xhttp路径:       ${XHTTP_PATH:-}"
        echo "xhttp域名:       ${XHTTP_DOMAIN:-}"
        echo "gRPC域名:        ${GRPC_DOMAIN:-}"
        echo "Reality SNI:     ${REALITY_SNI:-}"
        echo "Reality ShortId: ${REALITY_SHORT_ID:-}"
        echo "AnyTLS域名:      ${ANYTLS_DOMAIN:-}"
        echo "AnyTLS密码:      ${SINGBOX_PASSWORD:-}"
    } >> "$output_file"

    log_info "所有链接已保存到: $output_file"
}

# ── 发布订阅一致性自检 ──────────────────────────────────────
# 防止"服务器凭据已轮换 / state 已重写，但 webroot 订阅仍是旧凭据"的静默分叉：
# 对比 已发布订阅 / 当前 state / 已部署 xray config 的 vless UUID，不一致即告警。
# 调用前需先 load_existing_params（依赖 XRAY_UUID / XHTTP_DOMAIN / SUBSCRIPTION_PATH）。
check_subscription_consistency() {
    [[ -n "${XRAY_UUID:-}" ]] || return 0
    local sub_domain="${XHTTP_DOMAIN:-${GRPC_DOMAIN:-}}"
    [[ -n "${sub_domain:-}" ]] || return 0
    [[ -n "${SUBSCRIPTION_PATH:-}" ]] || return 0

    # 1) state 与 已部署 xray config（防止 state 与线上分叉，生成出来照样连不上）
    local deployed_uuid
    deployed_uuid=$(grep -oP '"id":\s*"\K[^"]+' /usr/local/etc/xray/config.json 2>/dev/null | head -1 || true)
    if [[ -n "${deployed_uuid}" && "${XRAY_UUID}" != "${deployed_uuid}" ]]; then
        log_warn "state XRAY_UUID(${XRAY_UUID}) 与已部署 xray config(${deployed_uuid}) 不一致！生成链接可能仍连不上。"
    fi

    # 2) 已发布订阅 与 state（检测 webroot 残留旧订阅）
    local sub_file="/var/www/${sub_domain}${SUBSCRIPTION_PATH}"
    [[ -f "$sub_file" ]] || return 0
    local published_uuid
    published_uuid=$(base64 -d "$sub_file" 2>/dev/null | grep -oP 'vless://\K[0-9a-fA-F-]{36}' | head -1 || true)
    if [[ -n "${published_uuid}" && "${published_uuid}" != "${XRAY_UUID}" ]]; then
        log_warn "已发布订阅携带旧凭据 UUID ${published_uuid}，当前凭据为 ${XRAY_UUID}。"
        log_warn "将在同一订阅 URL 覆盖为当前凭据——请让客户端【重新拉取】订阅！"
    else
        log_info "订阅自检通过：已发布订阅凭据与当前凭据一致 (UUID ${XRAY_UUID:0:8}…)。"
    fi
}

# ── 模块入口 ─────────────────────────────────────────────────
run_client() {
    log_step "========== 生成客户端链接 =========="
    load_existing_params
    check_subscription_consistency
    get_server_ip
    gen_xhttp_url
    gen_grpc_url
    gen_xhttp_reality_url
    gen_reality_url
    gen_anytls_url
    gen_hysteria2_url
    gen_naive_url
    write_subscription_file
    show_client_links
    log_info "========== 客户端链接生成完成 =========="
}
