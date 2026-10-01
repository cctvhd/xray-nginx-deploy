#!/usr/bin/env bash
# ============================================================
# modules/mosdns.sh
# mosdns-x 安装 + DoH 入口配置
#
# 角色：家里路由器 → DoH(https://<域名>/<随机路径>) → nginx(终结 TLS)
#       → 127.0.0.1:15353/dns-query(mosdns-x，明文 http) → 境外 DoT 上游。
# mosdns-x 在这一跳只做三件事：把客户端带来的 ECS 原样透传、缓存、转发。
# 分流规则留在国内那台（EasyMosdns）做，VPS 只管无污染解析。
#
# 为什么要单独一个模块：
#   DoH 入口的生成代码（/etc/nginx/conf.d/doh.conf）一直住在 modules/nginx.sh
#   里，但入口的问答（选域名/选路径）是「配置 Nginx」流程中间弹出来的一段
#   交互 —— 重配一次 Nginx 就被问一次，而这件事跟 Nginx 关系不大；更关键的
#   是入口的后端 mosdns-x 本仓库根本没有安装入口，新机器上必然 502。
#   现在：nginx 侧退回纯自动化（只认 state），问答与安装都挪到本模块。
#
# state：DOH_DOMAIN / DOH_PATH（空 = 未启用）；INST_MOSDNS=1
# ============================================================

MOSDNS_BIN="/usr/local/bin/mosdns"
MOSDNS_DIR="/etc/mosdns"
MOSDNS_CONFIG="${MOSDNS_DIR}/config.yaml"
MOSDNS_SERVICE="/etc/systemd/system/mosdns.service"
MOSDNS_REPO="pmkol/mosdns-x"
# 必须与 modules/nginx.sh 里 doh.conf 的 proxy_pass 一致，改一处就得改两处。
MOSDNS_LISTEN_ADDR="127.0.0.1:15353"
MOSDNS_URL_PATH="/dns-query"

# ── 架构 → 发布资产名 ─────────────────────────────────────────
# 上游资产名是 mosdns-linux-<arch>.zip。
# ⚠️ x86_64 刻意取普通 amd64 而**不取** mosdns-linux-amd64-v3：v3 版本用了
# x86-64-v3 指令集（AVX2/BMI2 等），在只支持 v2 的老机器上直接 SIGILL 起不来，
# 而这一跳是纯转发，性能收益可忽略 —— 拿兼容性换那点收益不划算。
_mosdns_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)            echo "amd64" ;;
        aarch64|arm64)           echo "arm64" ;;
        armv7l|armv7)            echo "arm-7" ;;
        armv6l|armv6)            echo "arm-6" ;;
        armv5tel|armv5te|armv5l) echo "arm-5" ;;
        mips64le)                echo "mips64le-hardfloat" ;;
        mipsle|mipsel)           echo "mipsle-softfloat" ;;
        ppc64le)                 echo "ppc64le" ;;
        *)                       echo "" ;;
    esac
}

# ── 版本：取发布号（build time），不是二进制自报的 v4.6.0 ──────
# ⚠️ mosdns-x 自报的 "v4.6.0" 是它自己的版本号，GitHub tag 是发布日期
# （v26.05.25）—— 用 4.6.0 去比 tag 会永远判「可升级」，升级动作却什么也不做。
# 升级比较一律用 build time，它与 tag 的数字部分同源。
mosdns_build_version() {
    command -v mosdns >/dev/null 2>&1 || return 0
    mosdns version 2>&1 \
        | grep -oP 'build time:\s*\K[0-9]+(\.[0-9]+)+' \
        | head -1
}

mosdns_installed() {
    [[ -x "$MOSDNS_BIN" ]] || command -v mosdns >/dev/null 2>&1
}

# ── 装 unzip（GitHub 资产是 .zip）─────────────────────────────
_mosdns_ensure_unzip() {
    command -v unzip >/dev/null 2>&1 && return 0
    log_info "安装 unzip..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y unzip >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y unzip >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y unzip >/dev/null 2>&1 || true
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        log_error "unzip 不可用，无法解压 mosdns-x 发布包"
        return 1
    fi
}

# ── 下载并安装二进制（无问答，升级路径也用它）──────────────────
mosdns_download_binary() {
    local mc_arch tag url tmpd
    mc_arch=$(_mosdns_arch)
    if [[ -z "$mc_arch" ]]; then
        log_error "不支持的架构: $(uname -m)（mosdns-x 无对应 Linux 二进制）"
        return 1
    fi

    _mosdns_ensure_unzip || return 1

    log_step "下载 mosdns-x（linux-${mc_arch}）..."
    tag=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${MOSDNS_REPO}/releases/latest" 2>/dev/null \
            | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)
    if [[ -z "$tag" ]]; then
        log_error "无法获取 ${MOSDNS_REPO} 最新版本号（网络不通或 GitHub API 限速）"
        return 1
    fi

    url="https://github.com/${MOSDNS_REPO}/releases/download/${tag}/mosdns-linux-${mc_arch}.zip"

    tmpd=$(mktemp -d)
    if ! curl -fsSL --max-time 120 "$url" -o "${tmpd}/mosdns.zip"; then
        log_error "下载失败: ${url}"
        rm -rf "$tmpd"
        return 1
    fi
    if ! unzip -o -q "${tmpd}/mosdns.zip" -d "$tmpd"; then
        log_error "解压失败: ${tmpd}/mosdns.zip"
        rm -rf "$tmpd"
        return 1
    fi

    # 发布包里就是裸二进制 mosdns（可能夹带 README 等），先下载到临时目录
    # 再 install，避免解压中途失败留下半截 /usr/local/bin/mosdns。
    local src
    src=$(find "$tmpd" -maxdepth 2 -type f -name 'mosdns' -print -quit)
    if [[ -z "$src" ]]; then
        log_error "发布包里没找到 mosdns 可执行文件"
        rm -rf "$tmpd"
        return 1
    fi

    install -m 755 "$src" "$MOSDNS_BIN"
    rm -rf "$tmpd"

    local ver
    ver=$(mosdns_build_version)
    log_info "mosdns-x 安装完成: ${tag}${ver:+（build ${ver}）}"
}

# ── 安装二进制（带「已装则问」的交互入口）──────────────────────
install_mosdns_binary() {
    local force="${1:-}"

    if mosdns_installed; then
        local ver
        ver=$(mosdns_build_version)
        log_info "mosdns-x 已安装${ver:+: build ${ver}}"
        if [[ "$force" != "--force" ]]; then
            local ans
            read -rp "  是否重新下载安装？[y/N]: " ans
            [[ "${ans,,}" == "y" ]] || { log_info "跳过安装"; return 0; }
        fi
    fi

    mosdns_download_binary || return 1
}

# ── 生成配置 ─────────────────────────────────────────────────
# ⚠️ 已存在则【绝不覆盖】：这台机器上的 config.yaml 可能是用户按自家网络
# 手工调过的（活机上就如此，旁边还躺着两份 .bk）。覆盖 = 用户的 ECS 分流
# 行为当场变化，且他无从察觉。只备份、只提示，改动权留给用户。
generate_mosdns_config() {
    mkdir -p "$MOSDNS_DIR"
    chmod 755 "$MOSDNS_DIR"

    if [[ -f "$MOSDNS_CONFIG" ]]; then
        local bk
        bk="${MOSDNS_CONFIG}.bk.$(date +%Y%m%d-%H%M%S)"
        cp -p "$MOSDNS_CONFIG" "$bk" 2>/dev/null || true
        log_warn "mosdns-x 配置已存在，保持原样不动: ${MOSDNS_CONFIG}"
        log_warn "  已备份到 ${bk}（本次不覆盖，需要重置请手工替换后再重跑）"
        return 0
    fi

    log_step "生成 mosdns-x 配置..."

    cat > "$MOSDNS_CONFIG" << 'YAML'
# mosdns-x —— ECS 透传中继（VPS 端）
#
# 只做三件事：把客户端带来的 ECS 原样透传给上游、缓存、转发。
# 刻意【不】加 ECS —— ECS 由家里那台按分支算好后带上来，这一跳再加会把
# 国内算好的结果覆盖掉（所以用 _edns0_filter_ecs_only 而非 ecs_auto）。
#
# 上游直连，不经本机 unbound：unbound 会把客户端 ECS 吃掉（已实测）。
#
# 上游走 DoT（tls://，853）：早先用 udpme://，实测抓包确认那是【明文 UDP/53】
# —— 源码里无 TLS/DNSSEC/Cookie/请求 ID 校验/源地址检查。换成 DoT 后上游段
# 加密且防路径伪造，实测答案与 ECS 行为与原来逐字节一致。
# enable_pipeline 在 DoT 上是官方支持的连接复用（在 DoH 上才是静默空操作）。
#
# 入口 127.0.0.1:15353/dns-query 由 nginx 终结 TLS 后反代进来，勿改。
# 改本文件后：systemctl restart mosdns
log:
  file: ""
  level: warn

plugins:
  # 缓存放在 ECS 过滤之后：缓存键只随 ECS 变化，命中率稳定。
  - tag: cache_ecs
    type: cache
    args:
      size: 65536
      compress_resp: true
      cache_everything: true
      lazy_cache_ttl: 86400
      lazy_cache_reply_ttl: 5

  # 主上游：Google DoT。证书 SAN 含 IP，裸 IP 即可完成校验，无需 bootstrap。
  - tag: forward_google
    type: fast_forward
    args:
      upstream:
        - addr: "tls://8.8.8.8"
          enable_pipeline: true

  # 备用：Google 另一个 anycast IP，ECS 行为与主上游一致，仅防单 IP/路由故障。
  - tag: forward_backup
    type: fast_forward
    args:
      upstream:
        - addr: "tls://8.8.4.4"
          enable_pipeline: true

  - tag: main_sequence
    type: sequence
    args:
      exec:
        # 只保留客户端带来的 ECS，滤掉其它 EDNS0 option。
        # 官方建议放在管线最前、缓存之前。
        - _edns0_filter_ecs_only
        - cache_ecs
        # 主备用串行，不并发：两家给出的 CDN 节点可能不同，并发会让结果忽好忽坏。
        - primary:
            - forward_google
          secondary:
            - forward_backup
          fast_fallback: 1500
          always_standby: false
        - _return

servers:
  - exec: main_sequence
    listeners:
      # 只绑回环。这一跳是明文 HTTP，对公网暴露就是开放解析器。
      # 端口/路径必须与 modules/nginx.sh 生成的 doh.conf 的 proxy_pass 一致。
      - protocol: http
        addr: "127.0.0.1:15353"
        url_path: "/dns-query"
YAML

    chmod 644 "$MOSDNS_CONFIG"
    log_info "mosdns-x 配置生成完成: ${MOSDNS_CONFIG}"
    # 刻意不做语法自检：`config check` 这类子命令名随版本变过，猜错了只是噪音，
    # 而真正的判据是随后的 start_mosdns + verify_mosdns（真的起、真的答）。
}

# ── systemd unit ─────────────────────────────────────────────
# 自己写 unit 而不是调 `mosdns service install`：后者产出不可控（路径/用户
# 由它决定），而仓库里其它组件一律是显式写 unit，便于审计与卸载。
generate_mosdns_service() {
    log_step "写入 mosdns systemd 服务..."

    local changed=0
    if [[ ! -f "$MOSDNS_SERVICE" ]] || ! grep -q "ExecStart=${MOSDNS_BIN}" "$MOSDNS_SERVICE" 2>/dev/null; then
        changed=1
    fi

    cat > "$MOSDNS_SERVICE" << UNIT
[Unit]
Description=mosdns-x (DoH backend for nginx)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${MOSDNS_BIN} start -c ${MOSDNS_CONFIG} -d ${MOSDNS_DIR}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload >/dev/null 2>&1 || true
    (( changed )) && log_info "已写入 ${MOSDNS_SERVICE}"
}

start_mosdns() {
    log_step "启动 mosdns-x..."
    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "无 systemd，跳过服务启动（请手工运行 mosdns start -c ${MOSDNS_CONFIG}）"
        return 1
    fi
    systemctl enable mosdns >/dev/null 2>&1 || true
    if ! systemctl restart mosdns; then
        log_error "mosdns-x 启动失败，最近日志："
        journalctl -u mosdns -n 20 --no-pager 2>/dev/null || true
        return 1
    fi
    sleep 1
    systemctl is-active --quiet mosdns || {
        log_error "mosdns-x 未处于 active 状态，最近日志："
        journalctl -u mosdns -n 20 --no-pager 2>/dev/null || true
        return 1
    }
    log_info "mosdns-x 已启动"
}

# ── 自检：明文直连 15353，不经 nginx ─────────────────────────
# 直连而非走 443：这样「mosdns 没起」与「nginx 入口没配对」是两条独立的
# 判据，不会互相掩盖。端口不对 / url_path 不对 / 进程没起 三种情况表现不同：
#   · 端口没开      → curl 直接连接失败（exit 7）
#   · url_path 不对 → 404（Content-Type 是 text/html）
#   · 正常          → 200 + application/dns-message
verify_mosdns() {
    if command -v ss >/dev/null 2>&1; then
        # 用 index() 精确匹配而不是 grep 正则：地址里有 . 与 :，派生自常量
        # 才不会与 MOSDNS_LISTEN_ADDR 改一处漏一处。
        if ! ss -lnt 2>/dev/null \
             | awk -v a="$MOSDNS_LISTEN_ADDR" 'index($0,a){f=1} END{exit !f}'; then
            log_error "mosdns-x 自检失败：${MOSDNS_LISTEN_ADDR} 没有在监听"
            log_error "  查：systemctl status mosdns / journalctl -u mosdns -n 50"
            log_error "  常见原因：config.yaml 里 listeners 的 addr 被改过，或该端口被别的进程占用"
            return 1
        fi
    elif ! command -v curl >/dev/null 2>&1; then
        log_warn "mosdns-x 自检：本机无 ss 也无 curl，无法验证，仅确认服务已启动"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_warn "mosdns-x 自检：端口在听，但本机无 curl，无法端到端确认"
        return 0
    fi

    local out ctype code
    out=$(curl -s -o /dev/null --noproxy '*' --max-time 8 \
              -H 'accept: application/dns-message' \
              -w '%{content_type} %{http_code}' \
              "http://${MOSDNS_LISTEN_ADDR}${MOSDNS_URL_PATH}?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB" \
          2>/dev/null) || out=""
    read -r ctype code <<<"$out"

    if [[ "$ctype" == application/dns-message* ]]; then
        log_info "mosdns-x 自检通过：${MOSDNS_LISTEN_ADDR}${MOSDNS_URL_PATH} → HTTP ${code} + application/dns-message"
        return 0
    fi

    log_error "mosdns-x 自检失败：${MOSDNS_LISTEN_ADDR}${MOSDNS_URL_PATH} 未返回 DNS 报文"
    log_error "  实到 Content-Type='${ctype:-<无>}' HTTP ${code:-000}"
    if [[ "$code" == "404" ]]; then
        log_error "  404 → 路径不匹配。doh.conf 的 proxy_pass 与本文件 url_path 必须都是 ${MOSDNS_URL_PATH}"
    fi
    return 1
}

# Reality 域做 DoH 落点的代价：照实说明，但不阻拦（用户点名要放开这一类）。
_doh_note_reality_penalty() {
    case "${1:-}" in
        reality|xhttp-reality)
            log_warn "落点是 Reality 域：请求是 xray 的 fallback 转给 nginx 的，转过去时没有"
            log_warn "  真实源地址（reality inbound 是 xver=0、不发 PROXY protocol，8321/8326 的"
            log_warn "  listen 也没开 proxy_protocol）→ \$final_real_ip 退化成 127.0.0.1。"
            log_warn "  后果：限流变成一个桶装所有客户端、access log 记不到真实 IP（2026-09-30 实测）。"
            log_warn "  能用就行；要真实 IP 就改用 CDN 域或没被占用的域。"
            ;;
    esac
}

# 打印可用域名列表。$1 = 当前生效的域名（可空），命中的那行标「← 当前」。
# 其余参数每项形如 "域名|标签"，标签标明该域是【经 Cloudflare（CDN）】还是
# 【直连本机（直连）】—— 用户 2026-10-01 原话「在备用域名中应该显示那些是 cdn 的
# 那些是直连」。CDN 域的 $final_real_ip 拿得到真实客户端 IP；直连域只能看到客户端
# 自己的地址；而 Reality 域连这个也退化（见 _doh_note_reality_penalty），故单独标出。
# 没有候选时一个字也不打、返回 1 —— 调用方据此决定提示里要不要写「或输入序号」。
# 列表要打给【两个分支】（已启用 / 未启用）看，序号的含义才有一致性：只在首次
# 启用时列候选，会让「已启用后想换域名」的人对着一个空提示盲输域名（2026-10-01
# 用户实测报「没有显示备选域名」）；而序号若只在一边可用，从第一次配置就记住
# 「输序号」的人第二次会被当成域名判成「不可用」（用户同日报「好像没有重新设置
# nginx 相关配置」—— 编号没被接受，入口自然一点没动）。
_doh_print_domain_list() {
    local cur="$1"; shift
    (( $# > 0 )) || return 1
    echo "  可用域名（同一个域名可以既跑协议又跑 DoH，共用即可）:"
    echo "    [CDN] = 经 Cloudflare 回源（客户端真实 IP 最完整）   [直连] = 直连本机"
    local i=0 entry d tag
    for entry in "$@"; do
        i=$(( i + 1 ))
        d="${entry%%|*}"; tag="${entry#*|}"
        if [[ -n "$cur" && "$d" == "$cur" ]]; then
            echo "    ${i}. ${d}   [${tag}]   ← 当前"
        else
            echo "    ${i}. ${d}   [${tag}]"
        fi
    done
    return 0
}

# ── DoH 入口（域名 / 路径）───────────────────────────────────
# 从 nginx.sh 搬过来的问答：候选域名由 _doh_candidates 从配置表派生的
# DOMAIN_REGISTRY 生成，逐个用 _doh_domain_usable 判「该域的 TLS 是否在
# nginx 手里」（判据是协议标签 + 证书齐备）。
#
# ⚠️ 这里【不再】要求域名在 443 上空闲 —— 2026-09-30 实机逐协议实测：只要该域
# 的 TLS 由 nginx 终结，DoH 就能与它共用同一个域名（nginx.sh 的
# generate_servers_conf 会把 DoH 的 location include 进那个协议的 vhost）。
# 实测结果：
#   · xhttp / grpc / xhttp-reality / reality / 纯 nginx 站   → 可共用 ✓
#   · Sing-Box AnyTLS、NaiveProxy（Caddy）                    → 不可共用 ✗
# 后两者的 TLS 在它们自己手里，nginx 根本接不到那个 SNI 之后的 HTTP，location
# 永远不执行 —— 这是技术限制，不是策略，故 _doh_domain_usable 直接把这两类排除。
#
# 免费域（没被任何协议占用）走的是另一条路：仍生成独立的 127.0.0.1:8410 vhost。
configure_doh_entry() {
    # nginx 模块此刻可能还没载进来 —— 本菜单可以独立于「配置 Nginx」先跑
    # （装完 mosdns-x 就地配入口正是主要用法）。先载再判，否则下面的门控
    # 会把整件事静默跳过：用户看到「跳过 DoH 入口配置」，却没有任何原因。
    if ! declare -F ensure_doh_conf >/dev/null 2>&1 \
       && declare -F load_module >/dev/null 2>&1; then
        load_module nginx >/dev/null 2>&1 || true
    fi
    if ! declare -F ensure_doh_conf >/dev/null 2>&1; then
        log_warn "未加载 nginx 模块，跳过 DoH 入口配置"
        return 0
    fi
    log_step "配置 DoH 入口（nginx 反代 mosdns-x）..."

    local cur_domain cur_path
    cur_domain=$(get_state "DOH_DOMAIN" "")
    cur_path=$(get_state "DOH_PATH" "")

    # ── 候选域名：两个分支共用同一份（列表、排序、序号含义都一致）──
    # 优先级：CDN 域 > 直连域 > Reality 域。
    # CDN 域最好：有 CF 那一层在，$final_real_ip 拿到的就是真实客户端 IP。
    # Reality 域最差：请求是 xray fallback 转过来的，没有真实源地址（见
    # _doh_note_reality_penalty），限流会退化成单桶、日志也记不到真实 IP。
    local -a _cdn=() _plain=() _reality=()
    local _d _m _p
    while IFS=$'\t' read -r _d _m _p; do
        [[ -n "$_d" ]] || continue
        if [[ "$_m" == "cdn" ]]; then
            _cdn+=("$_d")
        elif [[ "$_p" == *reality* ]]; then
            _reality+=("$_d")
        else
            _plain+=("$_d")
        fi
    done < <(_doh_candidates 2>/dev/null)
    # 序号就是按这个顺序（CDN → 直连 → Reality）编的。每项带上给用户看的落点
    # 标签（[CDN] / [直连] / [直连 (Reality)]）—— 只用于显示和选序号，取域名时
    # 按 "|" 前那段切回来（见下面两处 %%|*）。
    local -a _all=()
    local _x
    for _x in "${_cdn[@]}";     do _all+=("${_x}|CDN"); done
    for _x in "${_plain[@]}";   do _all+=("${_x}|直连"); done
    for _x in "${_reality[@]}"; do _all+=("${_x}|直连 (Reality)"); done
    local _default="${_all[0]%%|*}"

    # ── 已启用：回车保持 / 0 关闭 / p 换路径 / 序号或新域名换域 ──
    if [[ -n "$cur_domain" && -f /etc/nginx/conf.d/doh.conf ]]; then
        log_info "当前 DoH 入口: https://${cur_domain}${cur_path}"
        local _listed=0
        if _doh_print_domain_list "$cur_domain" "${_all[@]}"; then _listed=1; fi
        echo "        回车 = 保持不变"
        echo "        p    = 只换访问路径（/ 后面那一段）"
        echo "        0    = 关闭该入口"
        if (( _listed )); then
            echo "        或输入序号 / 新域名（换域名，路径不变）"
        else
            echo "        或直接输入新域名（路径不变）"
        fi
        local ans
        read -rp "  请选择: " ans
        ans="${ans// /}"
        if [[ -z "$ans" ]]; then
            log_info "DoH 入口保持不变"
            return 0
        fi
        # ⚠️ 这两处一律直调，绝不能写成 return $(_doh_entry_apply ...)：
        # 命令替换会把函数丢进子 shell，里面所有 log_* 的输出被当成「返回值」
        # 吞掉 —— 用户看不到任何提示，而 return 一个多行文本会直接报错。
        if [[ "$ans" == "0" ]]; then
            _doh_entry_disable "$cur_domain"
            return $?
        fi
        if [[ "${ans,,}" == "p" ]]; then
            _doh_prompt_path || return 1
            save_state "DOH_PATH" "$DOH_PATH_NEW"
            _doh_entry_apply "$cur_domain"
            return $?
        fi
        # 序号 = 上面那份列表里的第几条（与「未启用」分支的序号含义相同）。
        # 选到「当前」那一条不算空操作：下面照样走 _doh_entry_apply，会把
        # doh.conf / servers.conf / SNI map 重新生成一遍 —— 等于给了用户一个
        # 「不改域名、只重新应用一遍 nginx 路由」的入口。
        if [[ "$ans" =~ ^[0-9]+$ ]]; then
            if (( ans < 1 || ans > ${#_all[@]} )); then
                log_warn "序号超出范围（1-${#_all[@]}），请重输或直接输入域名"
                return 1
            fi
            ans="${_all[$(( ans - 1 ))]%%|*}"
        else
            ans="${ans,,}"
        fi
        if ! _doh_domain_usable "$ans"; then
            log_error "域名 ${ans} 不可用：需证书已签发，且该域的 TLS 由 nginx 终结"
            log_error "  AnyTLS / NaiveProxy 的域不行 —— TLS 在 sing-box / Caddy 自己手里，"
            log_error "  nginx 挂不上 location（实测），其余协议（xhttp / grpc / reality）都可以"
            log_error "  入口保持原样未改动"
            return 1
        fi
        save_state "DOH_DOMAIN" "$ans"
        _doh_note_reality_penalty "$(_doh_target_mode "$ans")"
        _doh_entry_apply "$ans"
        return $?
    fi

    # ── 未启用：默认取配置表派生的可用域 ───────────────────────
    # 候选列表与优先级见函数上方那段（两个分支共用同一份）。
    _doh_print_domain_list "" "${_all[@]}"

    if [[ -n "$_default" ]]; then
        local _why
        if [[ ${#_cdn[@]} -gt 0 ]]; then
            _why="配置表里第一个 CDN 域，客户端 IP 最完整"
        elif [[ ${#_plain[@]} -gt 0 ]]; then
            _why="无可用 CDN 域，取第一个直连域"
        else
            _why="只剩 Reality 域可用，客户端 IP 会退化（见下方提醒）"
        fi
        log_info "DoH 入口域名自动取自配置表: ${_default}（${_why}）"
    else
        log_warn "未找到可用域名：需「证书已签发」且「该域 TLS 由 nginx 终结」"
        log_warn "  AnyTLS / NaiveProxy 的域不能共用；可新增一条 A 记录指向本机后申请证书"
    fi

    local _sel
    while true; do
        read -rp "  回车 = ${_default:-不启用}，可输入域名（或上面列表的序号），或输入 0 不启用: " _sel
        _sel="${_sel// /}"
        if [[ -z "$_sel" ]]; then
            if [[ -z "$_default" ]]; then
                log_info "未启用 DoH 入口（可以以后再回来配）"
                return 0
            fi
            _sel="$_default"
        elif [[ "$_sel" == "0" ]]; then
            log_info "未启用 DoH 入口"
            return 0
        elif [[ "$_sel" =~ ^[0-9]+$ ]]; then
            # 序号选择：_all 就是函数开头那份列表（CDN → 直连 → Reality）
            if (( _sel < 1 || _sel > ${#_all[@]} )); then
                log_warn "序号超出范围（1-${#_all[@]}），请重输或直接输入域名"
                continue
            fi
            _sel="${_all[$(( _sel - 1 ))]%%|*}"
        else
            _sel="${_sel,,}"
            if ! _doh_domain_usable "$_sel"; then
                log_warn "域名 ${_sel} 不可用：需证书已签发，且该域 TLS 由 nginx 终结"
                log_warn "  AnyTLS / NaiveProxy 的域不能共用（TLS 不在 nginx 手里）"
                continue
            fi
        fi
        save_state "DOH_DOMAIN" "$_sel"
        break
    done

    _doh_note_reality_penalty "$(_doh_target_mode "$_sel")"

    # 路径：回车随机；也可以手输固定值（须以 / 开头）
    if [[ -z "$cur_path" ]]; then
        _doh_prompt_path || return 1
        cur_path="$DOH_PATH_NEW"
        save_state "DOH_PATH" "$cur_path"
    fi

    _doh_entry_apply "$_sel"
}

# 问一个新的访问路径（回车 = 随机重生成）。结果写进全局 DOH_PATH_NEW。
# ⚠️ 刻意不用 stdout 回传：本仓库的 log_* 全是裸 echo，混在一起会被调用方
# 一起捕获成一个多行「路径」（同 CLAUDE.md 里 resolve_edit_nodes_script 那条坑）。
_doh_prompt_path() {
    local _in
    while true; do
        read -rp "  访问路径（回车 = 随机生成，须以 / 开头）: " _in
        _in="${_in// /}"
        if [[ -z "$_in" ]]; then
            DOH_PATH_NEW="/dns-$(openssl rand -hex 6)"
            return 0
        fi
        if [[ "$_in" == /* && "$_in" != *[!A-Za-z0-9/_.-]* ]]; then
            DOH_PATH_NEW="$_in"
            return 0
        fi
        log_warn "路径须以 / 开头，且只含字母数字与 / _ . - ，请重输"
    done
}

# 落 state 后固定收尾：ensure_doh_conf（写 doh.conf）→ sync_refresh_nginx_routes
# （重生成 nginx.conf，SNI map 就在其中；reload 后自动跑 verify_doh_entry 自检）。
# ⚠️ 必须走 sync_refresh_nginx_routes 而不是自己调 generate_nginx_conf：
# 后者依赖 REALITY_DOMAIN / XHTTP_DOMAIN 等一批内存全局，不先恢复域名数组
# 就会生成一份【丢掉全部 SNI 路由】的 nginx.conf。
_doh_entry_apply() {
    # $1 = 要生效的域名。刻意【不】存进局部变量：bash 动态作用域下它会被
    # sync_refresh_nginx_routes 里那些 `for domain in ...` 改掉（见文末说明），
    # 而下面报 URL 的那行改成读 state 了 —— state 才是真正生效的那个值。
    local cur_path
    cur_path=$(get_state "DOH_PATH" "")
    if [[ -z "$cur_path" ]]; then
        cur_path="/dns-$(openssl rand -hex 6)"
        save_state "DOH_PATH" "$cur_path"
    fi

    load_module nginx
    if declare -F ensure_doh_conf >/dev/null 2>&1; then
        # ⚠️ 必须先删掉旧 doh.conf 再调 ensure_doh_conf，否则【换域名是个 no-op】：
        # ensure_doh_conf 开头是「domain 非空 且 文件已存在 → 直接 return 0」的
        # 幂等早返回，旧文件在就永远不会按新域名重写，而 state 已经被改成新域名
        # —— 结果是「state 说 A、磁盘上还是 B」，下一次 generate_sni_map 又拿着
        # 新域名去找文件（文件在，条件成立）→ 443 上把 A 路由到 8410，而 8410 的
        # server 块里 server_name 还是 B → 该 SNI 命中 default 陷阱端口，DoH 断。
        # 先删即强制重生成；路径取自 state，所以内容仍然是确定的那一份。
        # doh_location.conf 同理：它里面写死了 location = <旧路径>，换路径/换落点
        # 时不删就还是旧的（虽然 _doh_write_location_file 会按内容比对重写，但删掉
        # 更彻底，也让「写不出来」这件事在下面的断言里暴露出来）。
        rm -f /etc/nginx/conf.d/doh.conf /etc/nginx/doh_location.conf
        ensure_doh_conf || return 1
    else
        log_error "modules/nginx.sh 版本过旧（无 ensure_doh_conf），无法生成 DoH 入口"
        return 1
    fi
    # 上面的删除是破坏性的：ensure_doh_conf 在证书缺失、落点不可用（AnyTLS/Naive
    # 域）等情况下会【静默 return 0】，此时文件已被删且没有重建，必须当场拦住，
    # 不能让它带着「成功」往下走。
    if [[ ! -f /etc/nginx/conf.d/doh.conf || ! -f /etc/nginx/doh_location.conf ]]; then
        log_error "DoH 入口文件未生成（doh.conf / doh_location.conf 至少缺一个）"
        log_error "  常见原因：该域证书不存在（CERT_PATH_<根域> 解析不到 / 无 fullchain.pem）"
        log_error "            或该域是 AnyTLS/Naive 域（TLS 不在 nginx 手里，挂不上 location）"
        log_error "  上一步 ensure_doh_conf 的输出里有具体原因；入口路由不会被写入"
        return 1
    fi

    if declare -F sync_refresh_nginx_routes >/dev/null 2>&1; then
        # ⚠️ 到这一步 state 与 doh.conf / doh_location.conf 【已经改了】，而
        # nginx.conf / servers.conf 还没跟上（preflight 拦下、或生成中途失败）。
        # 不吭声地 return 1，用户看到的现象就是「改了域名但 nginx 相关配置没重新
        # 设置」—— 磁盘上两套配置已经不一致了，必须把这件事说出来并给出下一步
        # （2026-10-01 用户报告的二次配置问题里就有这一类）。
        if ! sync_refresh_nginx_routes "mosdns-x"; then
            log_error "DoH 入口已写入 state 与 doh.conf，但【nginx 路由没刷新成功】——"
            log_error "  此刻 443 上跑的还是旧的那一套（本次改动没生效）"
            log_error "  按上面报错处理后再跑一次「配置 DoH 入口」，或直接跑「配置 Nginx」把路由补上"
            return 1
        fi
    else
        log_error "modules/sync.sh 版本过旧（无 sync_refresh_nginx_routes），无法重生成 nginx 路由"
        return 1
    fi

    # ⚠️ 这一行【不能】用函数开头那个 $domain —— bash 是动态作用域，而
    # sync_refresh_nginx_routes 会调到 create_nginx_dirs / generate_servers_conf
    # 里的 `for domain in "${ALL_DOMAINS[@]}"`（那两处都没有 local），于是本函数的
    # 局部变量会被一路改写成 ALL_DOMAINS 的最后一个元素。2026-09-30 活机实测：
    # state / doh.conf / servers.conf 全部是对的（它们都读 state），只有这行日志
    # 配路由器就会配错域名。改成从 state 取，顺带保证「报出来的就是真正生效的那个」。
    log_info "DoH 入口已生效: https://$(get_state 'DOH_DOMAIN' '')${cur_path}"
    return 0
}

# 关闭入口：清 state + 删 doh.conf。doh.conf 不在，generate_sni_map 就不会
# 再写那条 443 路由（它要求 doh.conf 存在），443 上该域回到伪装站。
_doh_entry_disable() {
    # ⚠️ 局部变量名刻意加前缀：bash 动态作用域下，sync_refresh_nginx_routes 里
    # 那串 `for domain in "${ALL_DOMAINS[@]}"`（无 local）会把调用方的同名的局部
    # 变量改掉（见 _doh_entry_apply 末尾的说明）。这里 state 已经被清空、没法像
    # 那边一样回读 state，所以只能靠改名字躲开。
    local _doh_off_domain="$1"
    log_step "关闭 DoH 入口..."
    # 两个文件都要删：共用落点时 include 行还在 servers.conf 里，光删 doh.conf
    # 不够 —— 下一次「配置 Nginx」按 state 重生成时才不会再注入 include。
    # （DOH_DOMAIN 一清，_doh_target_mode 就是 off，generate_servers_conf 不再注入。）
    rm -f /etc/nginx/conf.d/doh.conf /etc/nginx/doh_location.conf
    save_state "DOH_DOMAIN" ""
    save_state "DOH_PATH" ""

    # doh.conf 删了还不够：443 那条路由写在 nginx.conf 的 stream map 里，由
    # generate_sni_map 按「doh.conf 存在」为条件写出 —— 不重生成 + reload，
    # 该 SNI 会继续被转到已无 server 块的 8410（而非回落到伪装站）。
    if declare -F sync_refresh_nginx_routes >/dev/null 2>&1; then
        sync_refresh_nginx_routes "关闭 DoH 入口" || return 1
    else
        log_warn "未加载 sync 模块，nginx.conf 里那条 443 路由仍在（该域暂时打不开）"
        log_warn "  重跑一次「配置 Nginx」即可清掉"
        return 0
    fi
    log_info "DoH 入口已关闭（${_doh_off_domain} 的 443 已不再路由到 DoH）"
    return 0
}

# ── 已安装后的子菜单 ─────────────────────────────────────────
# 装完之后再进来，十有八九只是想换 DoH 那个域名或 / 后面的路径 —— 而入口的
# 生成只动 nginx 的 doh.conf，跟 mosdns-x 本身没关系。所以已安装时不再走
# 「重下二进制 → 备份配置 → 重启服务」这一整套（重启会瞬断家里的解析），
# 而是先给一个明确的子菜单。
_mosdns_menu_installed() {
    local ver entry svc
    ver=$(mosdns_build_version)
    entry=$(get_state "DOH_DOMAIN" "")
    [[ -n "$entry" ]] && entry="https://${entry}$(get_state 'DOH_PATH' '')"

    log_info "mosdns-x 已安装${ver:+: build ${ver}}"
    if command -v systemctl >/dev/null 2>&1; then
        svc=$(systemctl is-active mosdns 2>/dev/null || true)
        log_info "服务状态: ${svc:-未知}（systemctl is-active mosdns）"
    fi
    log_info "当前 DoH 入口: ${entry:-未启用}"
    echo ""
    echo "  1. 配置 DoH 入口（更换域名 / 访问路径）"
    echo "  2. 重装 mosdns-x 并重启服务（改过 config.yaml 后用它）"
    echo "  3. 检查更新（比对 GitHub 最新发布版）"
    echo "  0. 返回"
    echo ""

    local ans
    read -rp "  请选择 [1]: " ans
    case "${ans:-1}" in
        1)
            # 只碰 nginx 侧：写 doh.conf + 重生成 SNI map + reload。
            load_module sync
            configure_doh_entry
            return $?
            ;;
        2)
            install_mosdns_binary --force || return 1
            generate_mosdns_config || return 1
            generate_mosdns_service || return 1
            start_mosdns || return 1
            verify_mosdns || log_warn "mosdns-x 自检未通过，请查 journalctl -u mosdns -n 50"
            return 0
            ;;
        3)
            _mosdns_check_update
            return $?
            ;;
        0) log_info "未做任何改动"; return 0 ;;
        *) log_warn "无效选择，未做任何改动"; return 0 ;;
    esac
}

# ── 更新：比对 GitHub 最新发布号 ─────────────────────────────
# ⚠️ 两边都取 tag 的数字部分（本机取 build time），不能拿二进制自报的 v4.6.0
# 去比 —— 那样永远判「有新版」，而下载回来的其实一模一样。
# 自己解析而不是调 install.sh 的 upgrade_github_latest：模块不能依赖 install.sh
# 里后加的函数（两条独立更新通道，缓存里的模块可能比 install.sh 新，见 CLAUDE.md）。
_mosdns_latest_version() {
    curl -fsSL --max-time 15 "https://api.github.com/repos/${MOSDNS_REPO}/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name"\s*:\s*"\K[^"]+' \
        | head -1 \
        | grep -oP '[0-9]+(\.[0-9]+)+'
}

# 更新只换二进制 + 重写 unit + 重启，**绝不碰 config.yaml**（同升级菜单的禁忌）。
_mosdns_check_update() {
    local cur latest
    cur=$(mosdns_build_version)
    latest=$(_mosdns_latest_version)
    if [[ -z "$latest" ]]; then
        log_error "无法获取 ${MOSDNS_REPO} 最新版本号（网络不通或 GitHub API 限速）"
        return 1
    fi
    log_info "mosdns-x: 当前=${cur:-未知} 最新=${latest}"
    if [[ -n "$cur" && "$cur" == "$latest" ]]; then
        log_info "已是最新，无需更新"
        return 0
    fi
    local ans
    read -rp "  更新到 ${latest}？（会重启 mosdns 服务，家里解析瞬断）[y/N]: " ans
    [[ "${ans,,}" == "y" ]] || { log_info "已取消，未做改动"; return 0; }
    install_mosdns_binary --force || return 1
    generate_mosdns_service || return 1
    start_mosdns || return 1
    verify_mosdns || log_warn "mosdns-x 自检未通过，请查 journalctl -u mosdns -n 50"
    log_info "mosdns-x 已更新到 ${latest}"
    return 0
}

# ── 模块入口 ─────────────────────────────────────────────────
run_mosdns() {
    log_step "========== mosdns-x =========="

    # 已安装 → 子菜单，不再每进一次就重装一遍。
    if mosdns_installed; then
        _mosdns_menu_installed
        return $?
    fi

    local rc=0

    install_mosdns_binary || return 1
    generate_mosdns_config || return 1
    generate_mosdns_service || return 1
    start_mosdns || return 1

    # 自检只告警不中断：服务起不来时下面配入口只会得到 502，但仍应把
    # 域名/路径问完并落 state —— 否则用户修好配置后还得再来一遍。
    verify_mosdns || { log_warn "mosdns-x 自检未通过，DoH 入口仍会配置，但后端当前不可用"; rc=1; }

    load_module sync
    configure_doh_entry || { log_warn "DoH 入口配置未完成"; rc=1; }

    log_info "========== mosdns-x 安装配置完成 =========="
    return $rc
}
