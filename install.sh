#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 公共工具函数（安装主程序与各模块共享）
# ============================================================

# ── IPv6 优先判断：双栈或纯 IPv6 时启用 ───────────────────
is_ipv6_preferred() {
    case "${HW_DUAL_STACK:-}" in
        "dual-stack"|"ipv6-only"|"ipv6")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
# xray-nginx-deploy main entry
# GitHub: https://github.com/cctvhd/xray-nginx-deploy
# ============================================================

BASE_URL="https://raw.githubusercontent.com/cctvhd/xray-nginx-deploy/feature/hysteria2-naive"
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"
STATE_DIR="/etc/xray-deploy"
STATE_FILE="${STATE_DIR}/config.env"
LOCAL_MODULES_DIR="${STATE_DIR}/modules"

DEFAULT_MODULES=(system unbound nginx cert xray singbox hysteria2 naive warp client sync uninstall upgrade)
ALL_MODULES=()

init_module_list() {
    local module_name manifest
    ALL_MODULES=()

    if [[ -d "$MODULES_DIR" ]]; then
        while IFS= read -r module_name; do
            [[ -n "$module_name" ]] && ALL_MODULES+=("$module_name")
        done < <(find "$MODULES_DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null \
            | sed 's/\.sh$//' \
            | sort)
    fi

    if (( ${#ALL_MODULES[@]} > 0 )); then
        return
    fi

    manifest="${LOCAL_MODULES_DIR}/modules.list"
    if [[ -f "$manifest" ]]; then
        while IFS= read -r module_name; do
            [[ -z "$module_name" || "$module_name" == \#* ]] && continue
            ALL_MODULES+=("$module_name")
        done < "$manifest"
    fi

    if (( ${#ALL_MODULES[@]} > 0 )); then
        return
    fi

    if command -v curl >/dev/null 2>&1; then
        while IFS= read -r module_name; do
            [[ -z "$module_name" || "$module_name" == \#* ]] && continue
            ALL_MODULES+=("$module_name")
        done < <(curl -fsSL "${BASE_URL}/modules/modules.list" 2>/dev/null || true)
    fi

    if (( ${#ALL_MODULES[@]} == 0 )); then
        ALL_MODULES=("${DEFAULT_MODULES[@]}")
    fi
}

init_module_list

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# ── 获取全局文件锁，防止并发 ────────────────────────────────
acquire_lock() {
    local lock_file="${STATE_DIR}/install.lock"
    mkdir -p "$STATE_DIR" 2>/dev/null || lock_file="/tmp/xray-nginx-deploy.lock"
    exec {LOCK_FD}>"$lock_file"
    if ! flock -n "$LOCK_FD" 2>/dev/null; then
        log_error "另一个 xray-nginx-deploy 实例正在运行"
        exit 1
    fi
}

acquire_upgrade_lock() {
    local lock_file="${STATE_DIR}/upgrade.lock"
    mkdir -p "$STATE_DIR" 2>/dev/null || lock_file="/tmp/xray-nginx-deploy-upgrade.lock"
    exec {UPGRADE_LOCK_FD}>"$lock_file"
    if ! flock -n "$UPGRADE_LOCK_FD" 2>/dev/null; then
        log_error "另一个组件升级任务正在运行"
        exit 1
    fi
}

get_state() {
    local key="$1"
    local default="${2:-}"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "$default"
        return
    fi

    local value
    value=$(awk -F= -v k="$key" '$1 == k { v=substr($0, index($0, "=") + 1) } END { print v }' \
        "$STATE_FILE" 2>/dev/null | sed "s/^['\"]//;s/['\"]$//" || true)

    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

save_state() {
    local key="$1"
    local value="$2"
    local escaped tmp_file

    mkdir -p "$STATE_DIR" || return 1
    chmod 700 "$STATE_DIR" || return 1
    touch "$STATE_FILE" || return 1
    chmod 600 "$STATE_FILE" || return 1

    escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
    tmp_file="${STATE_FILE}.tmp.$$"

    # 原子写入：在内存构建完整内容 → 写 .tmp → mv（同 fs 下原子）
    # 任一步失败都不污染正式文件
    {
        grep -v "^${key}=" "$STATE_FILE" 2>/dev/null || true
        echo "${key}='${escaped}'"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$STATE_FILE" || { rm -f "$tmp_file"; return 1; }
}

get_step() {
    get_state "$1" "0"
}

# ── 域名注册与重建 ──────────────────────────────────────────
_domain_state_suffix() {
    local domain="$1"
    echo "${domain//./_}"
}

domain_is_registered() {
    local domain="$1"
    local registry
    registry=$(get_state "DOMAIN_REGISTRY" "")
    [[ " ${registry} " == *" ${domain} "* ]]
}

merge_domain_protocols() {
    local existing="${1:-}" added="${2:-}"
    local result="" protocol

    for protocol in ${existing//,/ } ${added//,/ }; do
        [[ -z "$protocol" ]] && continue
        [[ ",${result}," == *",${protocol},"* ]] && continue
        result="${result:+$result,}$protocol"
    done

    echo "$result"
}

_save_state_verified() {
    local key="$1" value="$2" actual attempt rc

    for attempt in 1 2 3; do
        if save_state "$key" "$value"; then
            :
        else
            rc=$?
            log_warn "${key} 写入命令失败，退出码: ${rc}，正在重试 (${attempt}/3)"
            _debug_state_write "$key" "$value" ""
            sleep 0.2
            continue
        fi

        actual=$(get_state "$key" "")
        [[ "$actual" == "$value" ]] && return 0

        log_warn "${key} 写入验证失败，正在重试 (${attempt}/3)"
        _debug_state_write "$key" "$value" "$actual"
        sleep 0.2
    done

    log_error "${key} 写入失败，请检查 ${STATE_FILE}"
    _debug_state_write "$key" "$value" "$(get_state "$key" "")"
    return 1
}

_debug_state_write() {
    local key="$1" expected="$2" actual="${3:-}"

    log_warn "  期望值: [${expected}]"
    log_warn "  实际值: [${actual:-<空>}]"
    if [[ -d "$STATE_DIR" ]]; then
        log_warn "  状态目录: $(ls -ld "$STATE_DIR" 2>/dev/null || true)"
    else
        log_warn "  状态目录不存在: ${STATE_DIR}"
    fi
    if [[ -e "$STATE_FILE" ]]; then
        log_warn "  状态文件: $(ls -l "$STATE_FILE" 2>/dev/null || true)"
        log_warn "  ${key} 原始匹配行:"
        awk -F= -v k="$key" '$1 == k { printf "    %d:%s\n", NR, $0 }' "$STATE_FILE" 2>/dev/null || true
    else
        log_warn "  状态文件不存在: ${STATE_FILE}"
    fi
}

register_domain() {
    local domain="$1" mode="$2" protocols="$3"
    local suffix existing_protocols
    suffix=$(_domain_state_suffix "$domain")
    [[ -z "$domain" ]] && return 1

    existing_protocols=$(get_state "DOMAIN_PROTO_${suffix}" "")
    if domain_is_registered "$domain" && [[ -n "$existing_protocols" ]]; then
        protocols=$(merge_domain_protocols "$existing_protocols" "$protocols")
    fi

    _save_state_verified "DOMAIN_MODE_${suffix}" "$mode" || return 1
    _save_state_verified "DOMAIN_PROTO_${suffix}" "$protocols" || return 1

    local registry
    registry=$(get_state "DOMAIN_REGISTRY" "")
    if [[ " ${registry} " != *" ${domain} "* ]]; then
        registry="${registry:+$registry }$domain"
        _save_state_verified "DOMAIN_REGISTRY" "$registry" || return 1
    fi
}

# ── 解析协议槽位的主域名 ────────────────────────────────────
# 用法: _resolve_protocol_primary <slot> <候选1> [<候选2> ...]
# 0 候选 → 清空 + 输出空
# 1 候选 → 用之 + 设 DOMAIN_PRIMARY_<slot>
# 2+ 候选 → 优先用现有 DOMAIN_PRIMARY_<slot>（如仍在候选里），
#           否则用最后一个（最新注册），log_warn 提示用户
# 注意: 所有日志写 stderr，stdout 仅输出选中的域名
_resolve_protocol_primary() {
    local slot="$1"; shift
    local -a cands=("$@")
    local primary_key="DOMAIN_PRIMARY_${slot}"
    local current chosen

    if [[ ${#cands[@]} -eq 0 ]]; then
        save_state "$primary_key" ""
        echo ""
        return
    fi

    if [[ ${#cands[@]} -eq 1 ]]; then
        save_state "$primary_key" "${cands[0]}"
        echo "${cands[0]}"
        return
    fi

    # 多候选：先看是否已显式指定 PRIMARY 且仍在候选里
    current=$(get_state "$primary_key" "")
    if [[ -n "$current" ]]; then
        local c
        for c in "${cands[@]}"; do
            if [[ "$c" == "$current" ]]; then
                echo "$current"
                return
            fi
        done
    fi

    # 退回到最后一个候选（最新注册）
    chosen="${cands[-1]}"
    log_warn "协议槽位 ${slot} 有多个候选: ${cands[*]}" >&2
    log_warn "  未指定 DOMAIN_PRIMARY_${slot} 或已失效，自动选择最新: ${chosen}" >&2
    log_warn "  如需改主域名，可在编辑器或重配置时显式指定" >&2
    save_state "$primary_key" "$chosen"
    echo "$chosen"
}

# ════════════════════════════════════════════════════════════
# Preflight 配置健康互锁（5 项检查 + 软警告）
# ════════════════════════════════════════════════════════════
# 纯函数：只读 state，stderr 输出诊断，stdout 不污染
# 返回: 0 = 全过；非 0 = 至少一项硬失败
# 用法: preflight_config_check [<context>]
#       <context> 仅用于错误信息标注调用阶段（do_conf_nginx 等）
#
# 设计原则：
# - 任何 *_DOMAIN 为空时跳过对应槽位（首次安装/未启用不应阻塞）
# - Check 1 / 2 / 3 / 4a / 4c / 5b/c/d → 硬失败
# - Check 5a (domain_map.conf 漂移) → 软警告

_PREFLIGHT_FAIL_COUNT=0
_PREFLIGHT_WARN_COUNT=0

_preflight_fail() {
    # args: title, detail, impact, fix
    echo "" >&2
    echo -e "${RED}[PREFLIGHT FAIL]${NC} $1" >&2
    echo "  $2" >&2
    echo "  影响：$3" >&2
    echo "  修复：$4" >&2
    _PREFLIGHT_FAIL_COUNT=$((_PREFLIGHT_FAIL_COUNT + 1))
}

_preflight_warn() {
    echo "" >&2
    echo -e "${YELLOW}[PREFLIGHT WARN]${NC} $1" >&2
    echo "  $2" >&2
    echo "  影响：$3" >&2
    echo "  建议：$4" >&2
    _PREFLIGHT_WARN_COUNT=$((_PREFLIGHT_WARN_COUNT + 1))
}

# Check 1: nginx stream map SNI 唯一性（数据驱动）
# stream_slots 表列出所有进入 ssl_preread 路由表的槽位
# compatible_pairs 表列出允许同 SNI 的槽位对（架构上能合并的）
_preflight_check_sni_uniqueness() {
    local -a stream_slots=(
        "xray-xhttp:XHTTP_DOMAIN"
        "xray-grpc:GRPC_DOMAIN"
        "anytls:ANYTLS_DOMAIN"
        "naive:NAIVE_DOMAIN"
    )
    # 同 SNI 允许的槽位对（双向）—— 当前架构会合并到同一 server 块
    local -a compatible_pairs=(
        "xray-xhttp:xray-grpc"
    )

    declare -A _compat=()
    local pair a b
    for pair in "${compatible_pairs[@]}"; do
        a="${pair%:*}"; b="${pair#*:}"
        _compat["${a}|${b}"]=1
        _compat["${b}|${a}"]=1
    done

    declare -A _dom_slots=()
    local entry slot var domain
    for entry in "${stream_slots[@]}"; do
        slot="${entry%:*}"; var="${entry#*:}"
        domain="${!var:-}"
        domain="${domain,,}"
        [[ -z "$domain" ]] && continue
        _dom_slots["$domain"]+="${slot} "
    done

    local d slots_str
    for d in "${!_dom_slots[@]}"; do
        slots_str="${_dom_slots[$d]}"
        local -a slots_arr
        read -ra slots_arr <<< "$slots_str"
        (( ${#slots_arr[@]} < 2 )) && continue

        local i j ok=true
        for ((i=0; i<${#slots_arr[@]}; i++)); do
            for ((j=i+1; j<${#slots_arr[@]}; j++)); do
                if [[ -z "${_compat["${slots_arr[i]}|${slots_arr[j]}"]:-}" ]]; then
                    ok=false; break 2
                fi
            done
        done
        if ! $ok; then
            _preflight_fail \
                "Check 1: SNI 唯一性冲突" \
                "域名 ${d} 同时分配给槽位: ${slots_arr[*]}" \
                "nginx stream map 同 key 多目标，nginx -t 失败" \
                "去域名编辑器，让冲突槽位指向不同域名"
        fi
    done
}

# Check 2: Reality SNI 污染
# REALITY_DOMAIN + REALITY_SERVER_NAMES[*] 全部会被 nginx stream map 路由到 9443
# 不能与四个业务域名重合
_preflight_check_reality_pollution() {
    local -a own_domains=(
        "${XHTTP_DOMAIN:-}"
        "${GRPC_DOMAIN:-}"
        "${ANYTLS_DOMAIN:-}"
        "${NAIVE_DOMAIN:-}"
    )
    local -a reality_snis=()
    [[ -n "${REALITY_DOMAIN:-}" ]] && reality_snis+=("${REALITY_DOMAIN}")

    if declare -p REALITY_SERVER_NAMES &>/dev/null; then
        local sn
        for sn in "${REALITY_SERVER_NAMES[@]:-}"; do
            [[ -n "$sn" ]] && reality_snis+=("$sn")
        done
    fi
    (( ${#reality_snis[@]} == 0 )) && return 0

    local r d r_lc d_lc
    for r in "${reality_snis[@]}"; do
        r_lc="${r,,}"
        for d in "${own_domains[@]}"; do
            [[ -z "$d" ]] && continue
            d_lc="${d,,}"
            if [[ "$r_lc" == "$d_lc" ]]; then
                _preflight_fail \
                    "Check 2: Reality SNI 污染" \
                    "${d} 既是 Reality SNI（serverNames/REALITY_DOMAIN），又是用户业务域名" \
                    "nginx stream map 同 SNI 双值（既路由到 9443 又路由到 CDN/直连后端）" \
                    "重配 Reality 选不同的公共 SNI；或在域名编辑器移走该业务域名"
                break    # 同一个 reality SNI 只报一次，避免 XHTTP==GRPC 时重复
            fi
        done
    done
}

# Check 3: XHTTP_PATH 与 gRPC location 冲突
_preflight_check_xhttp_path() {
    [[ -z "${XHTTP_PATH:-}" ]] && return 0

    if [[ "${XHTTP_PATH}" != /* ]]; then
        _preflight_fail \
            "Check 3: XHTTP_PATH 格式错误" \
            "XHTTP_PATH=${XHTTP_PATH} 必须以 / 开头" \
            "nginx location 解析失败，xhttp 入口不可用" \
            "删除 state 中 XHTTP_PATH 后重跑配置 Xray，会自动重新生成"
    fi
    if [[ "${XHTTP_PATH}" == "/" ]]; then
        _preflight_fail \
            "Check 3: XHTTP_PATH 太宽" \
            "XHTTP_PATH=/ 会拦截所有路径" \
            "fallback 站点和 _fake 路径都被吞掉，业务异常" \
            "删除 state 中 XHTTP_PATH 后重跑配置 Xray"
    fi
    if [[ "${XHTTP_PATH}" == /grpc.Service* ]]; then
        _preflight_fail \
            "Check 3: XHTTP_PATH 与 gRPC 路径冲突" \
            "XHTTP_PATH=${XHTTP_PATH} 以 /grpc.Service 开头" \
            "同域名场景下 nginx 最长前缀匹配会让 location /grpc.Service 抢走 xhttp 流量" \
            "删除 state 中 XHTTP_PATH 后重跑配置 Xray"
    fi
    if (( ${#XHTTP_PATH} < 8 )); then
        _preflight_warn \
            "Check 3: XHTTP_PATH 长度可疑" \
            "XHTTP_PATH=${XHTTP_PATH}（长度 ${#XHTTP_PATH}）" \
            "正常自动生成的 UUID 路径长度 ≥ 33；过短可能是手动改动" \
            "如需重置，删除 state 中 XHTTP_PATH 后重跑配置 Xray"
    fi
}

# Check 4a: 内部端口常量两两不同（防御性）
# 关联数组 key 重复会被 bash 静默覆盖，count 偏离 11 即异常
_preflight_check_internal_ports() {
    declare -A _internal_ports=(
        [8300]="xray vless-xhttp-cdn"
        [8310]="xray vless-grpc-cdn"
        [8330]="sing-box anytls"
        [8340]="caddy-naive"
        [8320]="xray reality-direct"
        [8350]="nginx fallback"
        [8360]="nginx middle->anytls"
        [8370]="nginx middle->naive"
        [8380]="nginx xhttp ssl"
        [8390]="nginx grpc ssl"
        [8400]="nginx SNI trap"
    )
    if (( ${#_internal_ports[@]} != 11 )); then
        _preflight_fail \
            "Check 4a: 内部端口表数量异常" \
            "期望 11 个端口，实际 ${#_internal_ports[@]} 个 —— 可能某两个常量被改成同值" \
            "nginx upstream / proxy_pass 会指向错误后端，整个栈不可用" \
            "检查 modules/{nginx,xray,singbox,naive}.sh 中的端口常量"
    fi
}

# Check 4c: 用户可配置端口（HYSTERIA2_PORT + 端口跳跃区间）冲突
# 注：Hysteria2 使用 UDP，与本工具内部的 TCP 端口（8001/8002/8443/8444 等）
# 协议不同，不构成端口冲突，因此不检测端口跳跃区间是否覆盖内部端口。
_preflight_check_user_ports() {
    [[ -z "${HYSTERIA2_PORT:-}" ]] && return 0

    # 端口越界硬失败；特权端口 (<1024) 仅软警告（Hysteria 以 root 运行可绑定）
    if ! [[ "${HYSTERIA2_PORT}" =~ ^[0-9]+$ ]] || (( HYSTERIA2_PORT < 1 || HYSTERIA2_PORT > 65535 )); then
        _preflight_fail \
            "Check 4c: HYSTERIA2_PORT 越界" \
            "HYSTERIA2_PORT=${HYSTERIA2_PORT}，期望范围 1-65535" \
            "Hysteria2 无法绑定该端口" \
            "重配 Hysteria2 选 1-65535 范围内的端口"
    elif (( HYSTERIA2_PORT < 1024 )); then
        _preflight_warn \
            "Check 4c: HYSTERIA2_PORT 为特权端口" \
            "HYSTERIA2_PORT=${HYSTERIA2_PORT} (<1024)" \
            "需要 root 权限；如以非特权用户运行会绑定失败。默认 443 属此类，systemd 服务以 root 启动正常" \
            "若以非 root 运行，改用 ≥1024 的端口"
    fi

    # Hysteria2 是 UDP，与本工具内部 TCP 端口不构成协议层冲突，不检测内部端口区间

    if [[ -n "${HYSTERIA2_PH_START:-}" && -n "${HYSTERIA2_PH_END:-}" ]]; then
        local s="${HYSTERIA2_PH_START}" e="${HYSTERIA2_PH_END}"
        if ! [[ "$s" =~ ^[0-9]+$ ]] || ! [[ "$e" =~ ^[0-9]+$ ]]; then
            _preflight_fail \
                "Check 4c: HYSTERIA2 端口跳跃区间格式错误" \
                "HYSTERIA2_PH_START=${s} HYSTERIA2_PH_END=${e}（非数字）" \
                "Hysteria2 配置生成失败" \
                "重配 Hysteria2 端口跳跃，输入数字端口"
        else
            if (( s >= e )); then
                _preflight_fail \
                    "Check 4c: HYSTERIA2 端口跳跃区间无效" \
                    "HYSTERIA2_PH_START=${s} 应小于 HYSTERIA2_PH_END=${e}" \
                    "Hysteria2 服务无法启动" \
                    "重配 Hysteria2 端口跳跃，确保 START < END"
            fi
            if (( s < 1 || e > 65535 )); then
                _preflight_fail \
                    "Check 4c: HYSTERIA2 端口跳跃区间越界" \
                    "端口跳跃区间 ${s}-${e} 超出 1-65535" \
                    "Hysteria2 无法绑定越界端口" \
                    "调整端口跳跃区间到 1-65535"
            fi
            # 主端口落在跳跃区间内会导致 listen 重复绑定
            if (( HYSTERIA2_PORT >= s && HYSTERIA2_PORT <= e )); then
                _preflight_fail \
                    "Check 4c: HYSTERIA2_PORT 落在跳跃区间内" \
                    "HYSTERIA2_PORT=${HYSTERIA2_PORT} 在端口跳跃区间 ${s}-${e} 内" \
                    "Hysteria2 listen 配置会重复绑定同一端口，启动失败" \
                    "主端口应在跳跃区间之外"
            fi
        fi
    fi
}

# Check 5b/c/d: state 内部一致性
_preflight_check_state_consistency() {
    local registry
    registry=$(get_state "DOMAIN_REGISTRY" "")

    # 5b: 注册表里每个域名都有非空 DOMAIN_PROTO_<suffix>
    local d suffix proto
    for d in $registry; do
        suffix=$(_domain_state_suffix "$d")
        proto=$(get_state "DOMAIN_PROTO_${suffix}" "")
        if [[ -z "$proto" ]]; then
            _preflight_fail \
                "Check 5b: 域名注册表悬空" \
                "DOMAIN_REGISTRY 含 ${d}，但 DOMAIN_PROTO_${suffix} 为空" \
                "rebuild_protocol_domains 会跳过该域名，下游协议变量异常" \
                "在域名编辑器删除并重新添加 ${d}"
        fi
    done

    # 5c: 每个非空 *_DOMAIN 都在 DOMAIN_REGISTRY 里
    local -a expected=(XHTTP_DOMAIN GRPC_DOMAIN REALITY_DOMAIN ANYTLS_DOMAIN NAIVE_DOMAIN HYSTERIA2_DOMAIN)
    local var dom
    for var in "${expected[@]}"; do
        dom="${!var:-}"
        [[ -z "$dom" ]] && continue
        if ! echo " $registry " | grep -qF " $dom "; then
            _preflight_fail \
                "Check 5c: 协议域名未注册" \
                "${var}=${dom}，但 ${dom} 不在 DOMAIN_REGISTRY 中" \
                "下次 rebuild_protocol_domains 会清空该协议域名" \
                "在域名编辑器添加 ${dom} 并指定协议"
        fi
    done

    # 5d: DOMAIN_PRIMARY_* 指向已注册域名
    local -a primary_keys=(
        "DOMAIN_PRIMARY_XRAY_XHTTP"
        "DOMAIN_PRIMARY_XRAY_GRPC"
        "DOMAIN_PRIMARY_XRAY_REALITY"
        "DOMAIN_PRIMARY_SINGBOX"
        "DOMAIN_PRIMARY_HYSTERIA2"
        "DOMAIN_PRIMARY_NAIVEPROXY"
    )
    local key val
    for key in "${primary_keys[@]}"; do
        val=$(get_state "$key" "")
        [[ -z "$val" ]] && continue
        if ! echo " $registry " | grep -qF " $val "; then
            _preflight_fail \
                "Check 5d: 协议主域名指向已注销域名" \
                "${key}=${val}，但不在 DOMAIN_REGISTRY 中" \
                "_resolve_protocol_primary 会回退到最新候选或清空，造成意外切换" \
                "在域名编辑器重新指定该槽位的主域名"
        fi
    done
}

# Check 5a: domain_map.conf 漂移（软警告）
_preflight_check_domain_map_drift() {
    local map_file="/etc/cloudflare/domain_map.conf"
    [[ -f "$map_file" ]] || return 0

    local -a vars=(XHTTP_DOMAIN GRPC_DOMAIN REALITY_DOMAIN ANYTLS_DOMAIN NAIVE_DOMAIN HYSTERIA2_DOMAIN)
    local var state_val map_val drifted=""
    for var in "${vars[@]}"; do
        state_val="${!var:-}"
        map_val=$(grep "^${var}=" "$map_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"")
        if [[ "$state_val" != "$map_val" ]]; then
            drifted+=" ${var}(state='${state_val}' map='${map_val}')"
        fi
    done
    if [[ -n "$drifted" ]]; then
        _preflight_warn \
            "Check 5a: domain_map.conf 漂移" \
            "STATE 与 ${map_file} 不一致：${drifted}" \
            "运行时使用 STATE，domain_map.conf 仅作恢复镜像；漂移不影响当前运行" \
            "如需同步，重跑 SSL 证书申请，或重新走域名编辑器保存"
    fi
}

preflight_config_check() {
    local context="${1:-}"
    _PREFLIGHT_FAIL_COUNT=0
    _PREFLIGHT_WARN_COUNT=0

    _preflight_check_sni_uniqueness
    _preflight_check_reality_pollution
    _preflight_check_xhttp_path
    _preflight_check_internal_ports
    _preflight_check_user_ports
    _preflight_check_state_consistency
    _preflight_check_domain_map_drift

    echo "" >&2
    if (( _PREFLIGHT_FAIL_COUNT > 0 )); then
        echo -e "${RED}[PREFLIGHT]${NC} ${_PREFLIGHT_FAIL_COUNT} 项硬失败${context:+（${context} 阶段）}，已阻止配置生成" >&2
        echo -e "${RED}[PREFLIGHT]${NC} 修复入口：菜单 → 申请 SSL 证书 → 编辑域名" >&2
        return 1
    fi
    if (( _PREFLIGHT_WARN_COUNT > 0 )); then
        echo -e "${YELLOW}[PREFLIGHT]${NC} ${_PREFLIGHT_WARN_COUNT} 项软警告${context:+（${context} 阶段）}，配置已继续生成" >&2
    else
        echo -e "${GREEN:-}[PREFLIGHT]${NC:-} 全部检查通过${context:+（${context} 阶段）}" >&2
    fi
    return 0
}

# ── 数据迁移 v1 → v2：旧 "xray" 协议标签拆分为 sub-protocol ─
# 旧格式: DOMAIN_PROTO_<suffix>="xray" + DOMAIN_MODE=cdn/direct
# 新格式: DOMAIN_PROTO_<suffix>="xray-xhttp" / "xray-grpc" / "xray-reality"
#         mode 字段保留（用户语义、UI 显示），但协议消费方按 sub-protocol 区分
# 幂等：第二次起空跑（无 "xray" 裸标签 → 无操作）
_migrate_xray_proto_v1_to_v2() {
    local registry
    registry=$(get_state "DOMAIN_REGISTRY" "")
    [[ -z "$registry" ]] && return 0

    local migrated_count=0
    local d suffix protos mode
    for d in $registry; do
        suffix=$(_domain_state_suffix "$d")
        protos=$(get_state "DOMAIN_PROTO_${suffix}" "")
        # 老格式：协议列表中包含裸 "xray"
        case ",${protos}," in
            *,xray,*) ;;
            *) continue ;;
        esac
        mode=$(get_state "DOMAIN_MODE_${suffix}" "direct")

        local -a old_arr=()
        IFS=',' read -ra old_arr <<< "$protos"
        local new_list="" item
        for item in "${old_arr[@]}"; do
            if [[ "$item" == "xray" ]]; then
                if [[ "$mode" == "cdn" ]]; then
                    # CDN 模式：保守迁移为同时支持 xhttp + grpc（保留原有歧义）
                    # 用户后续在域名编辑器里可裁剪为单一 sub-protocol
                    new_list="${new_list:+$new_list,}xray-xhttp,xray-grpc"
                else
                    new_list="${new_list:+$new_list,}xray-reality"
                fi
            else
                new_list="${new_list:+$new_list,}$item"
            fi
        done
        # 去重仅对 CDN 域名执行：xhttp/grpc 迁移时可能产生重复标签；
        # direct 域名（reality 等）不受影响，直接写回
        # （mode 已在本循环顶部从 DOMAIN_MODE_${suffix} 读取）
        if [[ "$mode" == "cdn" ]]; then
            local _dp _seen_p="," _deduped=""
            IFS=',' read -ra _dp_arr <<< "$new_list"
            for _dp in "${_dp_arr[@]}"; do
                [[ -z "$_dp" ]] && continue
                case "$_seen_p" in *",${_dp},"*) continue ;; esac
                _deduped="${_deduped:+$_deduped,}${_dp}"
                _seen_p="${_seen_p}${_dp},"
            done
            new_list="$_deduped"
        fi
        save_state "DOMAIN_PROTO_${suffix}" "$new_list"
        migrated_count=$((migrated_count + 1))
    done

    # 槽位主域名键迁移
    local old_cdn old_direct
    old_cdn=$(get_state "DOMAIN_PRIMARY_XRAY_CDN" "")
    old_direct=$(get_state "DOMAIN_PRIMARY_XRAY_DIRECT" "")
    if [[ -n "$old_cdn" ]]; then
        # 不覆盖用户已显式设置的新键
        [[ -z "$(get_state "DOMAIN_PRIMARY_XRAY_XHTTP" "")" ]] && save_state "DOMAIN_PRIMARY_XRAY_XHTTP" "$old_cdn"
        [[ -z "$(get_state "DOMAIN_PRIMARY_XRAY_GRPC" "")" ]] && save_state "DOMAIN_PRIMARY_XRAY_GRPC"  "$old_cdn"
        save_state "DOMAIN_PRIMARY_XRAY_CDN" ""
        migrated_count=$((migrated_count + 1))
    fi
    if [[ -n "$old_direct" ]]; then
        [[ -z "$(get_state "DOMAIN_PRIMARY_XRAY_REALITY" "")" ]] && save_state "DOMAIN_PRIMARY_XRAY_REALITY" "$old_direct"
        save_state "DOMAIN_PRIMARY_XRAY_DIRECT" ""
        migrated_count=$((migrated_count + 1))
    fi

    if (( migrated_count > 0 )); then
        log_info "[迁移] xray 协议标签 v1→v2 拆分: ${migrated_count} 项更新（xray → xray-xhttp/xray-grpc/xray-reality）"
    fi
}

rebuild_protocol_domains() {
    # 启动时先做幂等迁移，确保下游按新 sub-protocol 标签运行
    _migrate_xray_proto_v1_to_v2

    local registry
    local all_d="" cdn_d="" direct_d=""
    local -a xhttp_cands=() grpc_cands=() reality_cands=()
    local -a singbox_cands=() hyst_cands=() naive_cands=()

    registry=$(get_state "DOMAIN_REGISTRY" "")

    for domain in $registry; do
        local suffix mode protocols
        suffix=$(_domain_state_suffix "$domain")
        mode=$(get_state "DOMAIN_MODE_${suffix}" "direct")
        protocols=$(get_state "DOMAIN_PROTO_${suffix}" "")
        [[ -z "$protocols" ]] && continue

        all_d="${all_d:+$all_d }$domain"
        if [[ "$mode" == "cdn" ]]; then
            cdn_d="${cdn_d:+$cdn_d }$domain"
        else
            direct_d="${direct_d:+$direct_d }$domain"
        fi

        # 按 sub-protocol 精确匹配（逗号分隔列表）
        case ",${protocols}," in *,xray-xhttp,*)   xhttp_cands+=("$domain") ;; esac
        case ",${protocols}," in *,xray-grpc,*)    grpc_cands+=("$domain") ;; esac
        case ",${protocols}," in *,xray-reality,*) reality_cands+=("$domain") ;; esac
        case ",${protocols}," in *,singbox,*)      singbox_cands+=("$domain") ;; esac
        case ",${protocols}," in *,hysteria2,*)    hyst_cands+=("$domain") ;; esac
        case ",${protocols}," in *,naiveproxy,*)   naive_cands+=("$domain") ;; esac
    done

    local xhttp_domain grpc_domain reality_domain anytls_domain hyst_domain naive_domain
    xhttp_domain=$(_resolve_protocol_primary   "XRAY_XHTTP"   "${xhttp_cands[@]}")
    grpc_domain=$(_resolve_protocol_primary    "XRAY_GRPC"    "${grpc_cands[@]}")
    reality_domain=$(_resolve_protocol_primary "XRAY_REALITY" "${reality_cands[@]}")
    anytls_domain=$(_resolve_protocol_primary  "SINGBOX"      "${singbox_cands[@]}")
    hyst_domain=$(_resolve_protocol_primary    "HYSTERIA2"    "${hyst_cands[@]}")
    naive_domain=$(_resolve_protocol_primary   "NAIVEPROXY"   "${naive_cands[@]}")

    save_state "ALL_DOMAINS"    "$all_d"
    save_state "CDN_DOMAINS"    "$cdn_d"
    save_state "DIRECT_DOMAINS" "$direct_d"
    save_state "XHTTP_DOMAIN"     "$xhttp_domain"
    save_state "GRPC_DOMAIN"      "$grpc_domain"
    save_state "REALITY_DOMAIN"   "$reality_domain"
    save_state "ANYTLS_DOMAIN"    "$anytls_domain"
    save_state "HYSTERIA2_DOMAIN" "$hyst_domain"
    save_state "NAIVE_DOMAIN"     "$naive_domain"

    # 派生完成后将本地变量同步到当前 shell，preflight 才能看到最新值
    XHTTP_DOMAIN="$xhttp_domain"
    GRPC_DOMAIN="$grpc_domain"
    REALITY_DOMAIN="$reality_domain"
    ANYTLS_DOMAIN="$anytls_domain"
    HYSTERIA2_DOMAIN="$hyst_domain"
    NAIVE_DOMAIN="$naive_domain"
    # 软诊断：rebuild 不阻塞调用方（修复流程可能正处中间状态），仅打印
    preflight_config_check "rebuild_protocol_domains" || true
}

load_domain_state() {
    ALL_DOMAINS=(); CDN_DOMAINS=(); DIRECT_DOMAINS=()
    local all_str cdn_str direct_str
    all_str=$(get_state "ALL_DOMAINS")
    cdn_str=$(get_state "CDN_DOMAINS")
    direct_str=$(get_state "DIRECT_DOMAINS")
    [[ -n "$all_str" ]] && read -ra ALL_DOMAINS <<< "$all_str"
    [[ -n "$cdn_str" ]] && read -ra CDN_DOMAINS <<< "$cdn_str"
    [[ -n "$direct_str" ]] && read -ra DIRECT_DOMAINS <<< "$direct_str"

    XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
    GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
    REALITY_DOMAIN=$(get_state "REALITY_DOMAIN")
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")
    HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
}

# ── 读取延迟档位参数 → 设置协议生成变量 ────────────────────
# 调用后可用：LATENCY_XMUX_CONCURRENCY / LATENCY_XMUX_REQUEST_TIMES /
#             LATENCY_XMUX_REUSABLE_SECS / LATENCY_GRPC_TIMEOUT / LATENCY_PROXY_TIMEOUT
load_latency_params() {
    local level
    level=$(get_state "LATENCY_LEVEL" "medium")
    case "$level" in
        low)
            LATENCY_XMUX_CONCURRENCY="8-16"
            LATENCY_XMUX_REQUEST_TIMES="300-500"
            LATENCY_XMUX_REUSABLE_SECS="1200-1800"
            LATENCY_GRPC_TIMEOUT=60
            LATENCY_PROXY_TIMEOUT=1800
            ;;
        high)
            LATENCY_XMUX_CONCURRENCY="32-64"
            LATENCY_XMUX_REQUEST_TIMES="1000-1500"
            LATENCY_XMUX_REUSABLE_SECS="3000-5400"
            LATENCY_GRPC_TIMEOUT=300
            LATENCY_PROXY_TIMEOUT=7200
            ;;
        medium|*)
            LATENCY_XMUX_CONCURRENCY="16-32"
            LATENCY_XMUX_REQUEST_TIMES="600-900"
            LATENCY_XMUX_REUSABLE_SECS="1800-3000"
            LATENCY_GRPC_TIMEOUT=120
            LATENCY_PROXY_TIMEOUT=7200
            ;;
    esac
}

# ── 模块加载：本地缓存 → 脚本同级目录 → 远程下载并缓存 ─────
load_module() {
    local module="$1"
    local cached_path="${LOCAL_MODULES_DIR}/${module}.sh"
    local local_path="${MODULES_DIR}/${module}.sh"
    local remote_url="${BASE_URL}/modules/${module}.sh"
    local first_line

    if [[ -f "$cached_path" ]]; then
        first_line=$(head -n 1 "$cached_path" 2>/dev/null || true)
        if [[ -z "$first_line" ]] || { [[ "$first_line" != '#!'* ]] && [[ "$first_line" != '#' ]]; }; then
            log_error "模块 ${module}.sh 首行安全检查失败: ${first_line:-<空>}"
            rm -f "$cached_path"
            exit 1
        fi
        # shellcheck source=/dev/null
        source "$cached_path"
    elif [[ -f "$local_path" ]]; then
        first_line=$(head -n 1 "$local_path" 2>/dev/null || true)
        if [[ -z "$first_line" ]] || { [[ "$first_line" != '#!'* ]] && [[ "$first_line" != '#' ]]; }; then
            log_error "模块 ${module}.sh 首行安全检查失败: ${first_line:-<空>}"
            rm -f "$local_path"
            exit 1
        fi
        # shellcheck source=/dev/null
        source "$local_path"
    else
        log_info "下载模块 ${module}.sh ..."
        mkdir -p "$LOCAL_MODULES_DIR"
        chmod 700 "$LOCAL_MODULES_DIR"
        if curl -fsSL "$remote_url" -o "$cached_path" 2>/dev/null; then
            chmod 600 "$cached_path"
            log_info "模块 ${module}.sh 已缓存至 ${cached_path}"
            first_line=$(head -n 1 "$cached_path" 2>/dev/null || true)
            if [[ -z "$first_line" ]] || { [[ "$first_line" != '#!'* ]] && [[ "$first_line" != '#' ]]; }; then
                log_error "远程模块 ${module}.sh 首行安全检查失败: ${first_line:-<空>}"
                rm -f "$cached_path"
                exit 1
            fi
            # shellcheck source=/dev/null
            source "$cached_path"
        else
            log_warn "下载失败，尝试直接执行远程模块..."
            # shellcheck source=/dev/null
            source <(curl -fsSL "$remote_url")
        fi
    fi
}

# ── 同步/更新所有模块到本地缓存 ─────────────────────────────
sync_modules() {
    log_step "同步模块到本地缓存 (${LOCAL_MODULES_DIR})..."
    mkdir -p "$LOCAL_MODULES_DIR"
    chmod 700 "$LOCAL_MODULES_DIR"

    if curl -fsSL "${BASE_URL}/modules/modules.list" -o "${LOCAL_MODULES_DIR}/modules.list" 2>/dev/null; then
        chmod 600 "${LOCAL_MODULES_DIR}/modules.list"
        init_module_list
        log_info "模块清单已更新: ${LOCAL_MODULES_DIR}/modules.list"
    fi

    local ok=0 fail=0
    for module in "${ALL_MODULES[@]}"; do
        local cached_path="${LOCAL_MODULES_DIR}/${module}.sh"
        local remote_url="${BASE_URL}/modules/${module}.sh"
        echo -n "  ${module}.sh ... "
        if curl -fsSL "$remote_url" -o "$cached_path" 2>/dev/null; then
            chmod 600 "$cached_path"
            echo -e "${GREEN}OK${NC}"
            (( ok++ )) || true
        else
            echo -e "${RED}失败${NC}"
            (( fail++ )) || true
        fi
    done

    echo ""
    log_info "同步完成：成功 ${ok} 个，失败 ${fail} 个"
    if [[ $fail -gt 0 ]]; then
        log_warn "失败的模块将在使用时实时从远程加载"
    fi
    log_info "本地缓存目录: ${LOCAL_MODULES_DIR}"
    log_info "如需强制更新，再次选择 s 即可覆盖所有缓存"
}

# ── 根据实际服务状态自动补全 state ──────────────────────────
_sync_inst_state() {
    command -v nginx    &>/dev/null && [[ "$(get_step INST_NGINX)"   != "1" ]] && save_state "INST_NGINX"   "1" || true
    command -v xray     &>/dev/null && [[ "$(get_step INST_XRAY)"    != "1" ]] && save_state "INST_XRAY"    "1" || true
    command -v sing-box   &>/dev/null && [[ "$(get_step INST_SINGBOX)"   != "1" ]] && save_state "INST_SINGBOX"   "1" || true
    command -v hysteria   &>/dev/null && [[ "$(get_step INST_HYSTERIA2)" != "1" ]] && save_state "INST_HYSTERIA2" "1" || true
    command -v caddy-naive &>/dev/null && [[ "$(get_step INST_NAIVE)"    != "1" ]] && save_state "INST_NAIVE"    "1" || true
    command -v wgcf       &>/dev/null && [[ "$(get_step INST_WARP)"      != "1" ]] && save_state "INST_WARP"      "1" || true
    command -v unbound  &>/dev/null && [[ "$(get_step INST_UNBOUND)" != "1" ]] && save_state "INST_UNBOUND" "1" || true
    systemctl is-active --quiet nginx    2>/dev/null && [[ -f /etc/nginx/conf.d/servers.conf ]] && [[ "$(get_step CONF_NGINX)"   != "1" ]] && save_state "CONF_NGINX"   "1" || true
    systemctl is-active --quiet xray     2>/dev/null && [[ -f /usr/local/etc/xray/config.json ]]    && [[ "$(get_step CONF_XRAY)"    != "1" ]] && save_state "CONF_XRAY"    "1" || true
    systemctl is-active --quiet sing-box 2>/dev/null && [[ -f /etc/sing-box/config.json ]]          && [[ "$(get_step CONF_SINGBOX)"   != "1" ]] && save_state "CONF_SINGBOX"   "1" || true
    systemctl is-active --quiet hysteria-server 2>/dev/null && [[ -f /etc/hysteria/config.yaml ]]   && [[ "$(get_step CONF_HYSTERIA2)" != "1" ]] && save_state "CONF_HYSTERIA2" "1" || true
    systemctl is-active --quiet caddy-naive 2>/dev/null && [[ -f /etc/caddy-naive/Caddyfile ]]       && [[ "$(get_step CONF_NAIVE)"     != "1" ]] && save_state "CONF_NAIVE"     "1" || true
    [[ -f /etc/wgcf/wgcf-profile.conf ]] && [[ -n "$(get_state WGCF_PRIVATE_KEY)" ]] && \
        [[ "$(get_step CONF_WARP)" != "1" ]] && save_state "CONF_WARP" "1" || true
    _sync_cert_state
}

_sync_cert_state() {
    [[ "$(get_step INST_CERT)" == "1" ]] && return 0

    local CF_DOMAIN_MAP="/etc/cloudflare/domain_map.conf"
    [[ -f "$CF_DOMAIN_MAP" ]] || return 0

    local xhttp grpc reality anytls
    xhttp=$(   grep "^XHTTP_DOMAIN="   "$CF_DOMAIN_MAP" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true )
    grpc=$(    grep "^GRPC_DOMAIN="    "$CF_DOMAIN_MAP" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true )
    reality=$( grep "^REALITY_DOMAIN=" "$CF_DOMAIN_MAP" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true )
    anytls=$(  grep "^ANYTLS_DOMAIN="  "$CF_DOMAIN_MAP" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true )

    local cert_ok=false
    for d in "$xhttp" "$grpc" "$reality" "$anytls"; do
        [[ -z "$d" ]] && continue
        local root
        root=$(echo "$d" | awk -F. '{print $(NF-1)"."$NF}')
        if [[ -f "/etc/letsencrypt/live/${root}/fullchain.pem" ]]; then
            cert_ok=true
            break
        fi
    done

    $cert_ok || return 0

    [[ -n "$xhttp"   ]] && save_state "XHTTP_DOMAIN"   "$xhttp"
    [[ -n "$grpc"    ]] && save_state "GRPC_DOMAIN"     "$grpc"
    [[ -n "$reality" ]] && save_state "REALITY_DOMAIN"  "$reality"
    [[ -n "$anytls"  ]] && save_state "ANYTLS_DOMAIN"   "$anytls"

    local cur_all
    cur_all=$(get_state "ALL_DOMAINS")
    if [[ -z "$cur_all" ]]; then
        local all_d="" cdn_d="" direct_d=""
        [[ -n "$xhttp"   ]] && all_d+=" $xhttp"   && cdn_d+=" $xhttp"
        [[ -n "$grpc"    ]] && all_d+=" $grpc"     && cdn_d+=" $grpc"
        [[ -n "$reality" ]] && all_d+=" $reality"  && direct_d+=" $reality"
        [[ -n "$anytls"  ]] && all_d+=" $anytls"   && direct_d+=" $anytls"
        save_state "ALL_DOMAINS"    "${all_d# }"
        save_state "CDN_DOMAINS"    "${cdn_d# }"
        save_state "DIRECT_DOMAINS" "${direct_d# }"
    fi

    save_state "INST_CERT" "1"
    log_info "已自动同步证书状态（检测到有效的 Let's Encrypt 证书）"

    [[ -n "$xhttp"   ]] && XHTTP_DOMAIN="$xhttp"
    [[ -n "$grpc"    ]] && GRPC_DOMAIN="$grpc"
    [[ -n "$reality" ]] && REALITY_DOMAIN="$reality"
    [[ -n "$anytls"  ]] && ANYTLS_DOMAIN="$anytls"
}

init_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'ENV'
# xray-nginx-deploy state file
OS_ID=''
OS_NAME=''
PKG_MANAGER=''
BBR_VERSION=''
KERNEL_UPGRADED='0'

HW_CPU_CORES=''
HW_MEM_GB=''
HW_BANDWIDTH=''
HW_DUAL_STACK=''
HW_DISK_TYPE=''
UNBOUND_SERVICE_NAME=''

XRAY_PADDING=''

XHTTP_DOMAIN=''
GRPC_DOMAIN=''
REALITY_DOMAIN=''
ANYTLS_DOMAIN=''
NAIVE_DOMAIN=''
NAIVE_USER=''
NAIVE_PASS=''
ALL_DOMAINS=''
CDN_DOMAINS=''
DIRECT_DOMAINS=''
XHTTP_PATH=''

XRAY_UUID=''
XRAY_PUBLIC_KEY=''
XRAY_PRIVATE_KEY=''
REALITY_DEST=''
REALITY_SNI=''
REALITY_SERVER_NAMES=''
REALITY_SHORT_ID=''
REALITY_SPIDER_X=''

SINGBOX_PASSWORD=''

HYSTERIA2_DOMAIN=''
HYSTERIA2_PASSWORD=''

WGCF_PRIVATE_KEY=''
WGCF_PEER_PUBKEY=''
WGCF_ADDRESS=''
WGCF_ENDPOINT=''
WGCF_ENDPOINT_HOST=''
WGCF_ENDPOINT_PORT=''

INST_KERNEL='0'
INST_SYSTEM='0'
INST_UNBOUND='0'
INST_NGINX='0'
INST_CERT='0'
INST_XRAY='0'
INST_SINGBOX='0'
INST_HYSTERIA2='0'
INST_NAIVE='0'
INST_WARP='0'

CONF_NGINX='0'
CONF_XRAY='0'
CONF_SINGBOX='0'
CONF_HYSTERIA2='0'
CONF_NAIVE='0'
CONF_WARP='0'
ENV
        chmod 600 "$STATE_FILE"
        log_info "状态文件已创建: $STATE_FILE"
    fi

    OS_ID=$(get_state "OS_ID")
    OS_NAME=$(get_state "OS_NAME")
    PKG_MANAGER=$(get_state "PKG_MANAGER")
    KERNEL_UPGRADED=$(get_state "KERNEL_UPGRADED")
    HW_CPU_CORES=$(get_state "HW_CPU_CORES")
    HW_MEM_GB=$(get_state "HW_MEM_GB")
    HW_BANDWIDTH=$(get_state "HW_BANDWIDTH")
    HW_DUAL_STACK=$(get_state "HW_DUAL_STACK")
    HW_DISK_TYPE=$(get_state "HW_DISK_TYPE")
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")
    XHTTP_DOMAIN=$(get_state "XHTTP_DOMAIN")
    GRPC_DOMAIN=$(get_state "GRPC_DOMAIN")
    REALITY_DOMAIN=$(get_state "REALITY_DOMAIN")
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    XRAY_UUID=$(get_state "XRAY_UUID")
    XRAY_PUBLIC_KEY=$(get_state "XRAY_PUBLIC_KEY")
    SINGBOX_PASSWORD=$(get_state "SINGBOX_PASSWORD")
    XRAY_PADDING=$(get_state "XRAY_PADDING")

    # ── BUG FIX：恢复 REALITY_SERVER_NAMES 数组 ──────────────
    # 原代码只保存了 REALITY_SNI（第一个元素），导致 do_conf_nginx
    # 调用 generate_sni_map 时数组为空，stream map 缺失公共域名路由。
    local _reality_sn_str
    _reality_sn_str=$(get_state "REALITY_SERVER_NAMES")
    REALITY_SERVER_NAMES=()
    if [[ -n "$_reality_sn_str" ]]; then
        read -ra REALITY_SERVER_NAMES <<< "$_reality_sn_str"
    fi

    WGCF_PRIVATE_KEY=$(get_state "WGCF_PRIVATE_KEY")
    WGCF_PEER_PUBKEY=$(get_state "WGCF_PEER_PUBKEY")
    WGCF_ADDRESS=$(get_state "WGCF_ADDRESS")
    WGCF_ENDPOINT=$(get_state "WGCF_ENDPOINT")
    WGCF_ENDPOINT_HOST=$(get_state "WGCF_ENDPOINT_HOST")
    WGCF_ENDPOINT_PORT=$(get_state "WGCF_ENDPOINT_PORT")

    _sync_inst_state

    # ── 旧格式迁移：scalar 域名变量 → DOMAIN_REGISTRY ────────
    if [[ -z "$(get_state "DOMAIN_REGISTRY")" ]]; then
        local _xhttp _grpc _reality _anytls _naive _hysteria2
        _xhttp=$(get_state "XHTTP_DOMAIN")
        _grpc=$(get_state "GRPC_DOMAIN")
        _reality=$(get_state "REALITY_DOMAIN")
        _anytls=$(get_state "ANYTLS_DOMAIN")
        _naive=$(get_state "NAIVE_DOMAIN")
        _hysteria2=$(get_state "HYSTERIA2_DOMAIN")

        [[ -n "$_xhttp" ]] && register_domain "$_xhttp" "cdn" "xray"
        # grpc 若与 xhttp 不同则单独注册
        [[ -n "$_grpc" && "$_grpc" != "$_xhttp" ]] && register_domain "$_grpc" "cdn" "xray"
        [[ -n "$_reality" ]] && register_domain "$_reality" "direct" "xray"
        [[ -n "$_anytls" ]] && register_domain "$_anytls" "direct" "singbox"
        [[ -n "$_hysteria2" ]] && register_domain "$_hysteria2" "direct" "hysteria2"
        [[ -n "$_naive" && "$_naive" != "$_anytls" ]] && register_domain "$_naive" "direct" "naiveproxy"

        if [[ -n "$(get_state "DOMAIN_REGISTRY")" ]]; then
            rebuild_protocol_domains
            log_info "域名配置已自动迁移到新格式"
        fi
    fi

    # 恢复域名数组变量（供 show_status 等使用）
    load_domain_state
}

load_os_info() {
    if [[ -n "${OS_ID:-}" ]]; then
        case "$OS_ID" in
            ubuntu|debian)
                PKG_UPDATE="apt-get update -y"
                PKG_INSTALL="apt-get install -y"
                ;;
            centos|rhel|rocky|almalinux|fedora)
                PKG_UPDATE="dnf makecache -y"
                PKG_INSTALL="dnf install -y"
                ;;
            *)
                log_error "不支持的系统: $OS_ID"
                return 1
                ;;
        esac
        return
    fi

    load_module system
    detect_os
}

restore_domain_arrays() {
    load_module sync
    sync_restore_domain_arrays
}


show_status() {
    local s_kernel s_system s_unbound s_nginx s_cert s_xray s_singbox s_hysteria2 s_naive s_warp
    local c_nginx c_xray c_singbox c_hysteria2 c_naive c_warp
    restore_domain_arrays 2>/dev/null || true
    local cf_ini_for_domain=""

    { [[ "$(get_step INST_KERNEL)"  == "1" ]] || \
      rpm -q kernel-ml >/dev/null 2>&1; } \
      && s_kernel="OK"  || s_kernel="--"

    { [[ "$(get_step INST_SYSTEM)"  == "1" ]] || \
      sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q 'bbr'; } \
      && s_system="OK"  || s_system="--"

    { [[ "$(get_step INST_UNBOUND)" == "1" ]] || \
      command -v unbound &>/dev/null; } \
      && s_unbound="OK" || s_unbound="--"

    { [[ "$(get_step INST_NGINX)"   == "1" ]] || \
      command -v nginx &>/dev/null; } \
      && s_nginx="OK"   || s_nginx="--"

    { [[ "$(get_step INST_CERT)" == "1" ]] || \
      find /etc/letsencrypt/live -name 'fullchain.pem' -quit 2>/dev/null | grep -q .; } \
      && s_cert="OK" || s_cert="--"

    { [[ "$(get_step INST_XRAY)"    == "1" ]] || \
      command -v xray &>/dev/null; } \
      && s_xray="OK"    || s_xray="--"

    { [[ "$(get_step INST_SINGBOX)" == "1" ]] || \
      command -v sing-box &>/dev/null; } \
      && s_singbox="OK" || s_singbox="--"

    { [[ "$(get_step INST_HYSTERIA2)" == "1" ]] || \
      command -v hysteria &>/dev/null; } \
      && s_hysteria2="OK" || s_hysteria2="--"

    { [[ "$(get_step INST_NAIVE)" == "1" ]] || \
      command -v caddy-naive &>/dev/null; } \
      && s_naive="OK" || s_naive="--"

    { [[ "$(get_step INST_WARP)"    == "1" ]] || \
      command -v wgcf &>/dev/null; } \
      && s_warp="OK"    || s_warp="--"

    { [[ "$(get_step CONF_NGINX)"   == "1" ]] || \
      ( systemctl is-active --quiet nginx 2>/dev/null && [[ -f /etc/nginx/conf.d/servers.conf ]] ); } \
      && c_nginx="OK"   || c_nginx="--"

    { [[ "$(get_step CONF_XRAY)"    == "1" ]] || \
      ( systemctl is-active --quiet xray 2>/dev/null && [[ -f /usr/local/etc/xray/config.json ]] ); } \
      && c_xray="OK"    || c_xray="--"

    { [[ "$(get_step CONF_SINGBOX)" == "1" ]] || \
      ( systemctl is-active --quiet sing-box 2>/dev/null && [[ -f /etc/sing-box/config.json ]] ); } \
      && c_singbox="OK" || c_singbox="--"

    { [[ "$(get_step CONF_HYSTERIA2)" == "1" ]] || \
      ( systemctl is-active --quiet hysteria-server 2>/dev/null && [[ -f /etc/hysteria/config.yaml ]] ); } \
      && c_hysteria2="OK" || c_hysteria2="--"

    { [[ "$(get_step CONF_NAIVE)" == "1" ]] || \
      ( systemctl is-active --quiet caddy-naive 2>/dev/null && [[ -f /etc/caddy-naive/Caddyfile ]] ); } \
      && c_naive="OK" || c_naive="--"

    { [[ "$(get_step CONF_WARP)"    == "1" ]] || \
      [[ -f /etc/wgcf/wgcf-profile.conf ]]; } \
      && c_warp="OK"    || c_warp="--"

    local cached_count=0
    for m in "${ALL_MODULES[@]}"; do
        [[ -f "${LOCAL_MODULES_DIR}/${m}.sh" ]] && (( cached_count++ )) || true
    done
    local total_modules=${#ALL_MODULES[@]}

    echo ""
    echo -e "${BLUE}================ 当前状态 ================${NC}"
    echo "  [安装]"
    printf "    %-20s %s\n" "Kernel"   "${s_kernel}"
    printf "    %-20s %s\n" "System"   "${s_system}"
    printf "    %-20s %s\n" "Unbound"  "${s_unbound}"
    printf "    %-20s %s\n" "Nginx"    "${s_nginx}"
    printf "    %-20s %s\n" "Cert"     "${s_cert}"
    printf "    %-20s %s\n" "Xray"     "${s_xray}"
    printf "    %-20s %s\n" "Sing-Box"  "${s_singbox}"
    printf "    %-20s %s\n" "Hysteria2" "${s_hysteria2}"
    printf "    %-20s %s\n" "NaiveProxy" "${s_naive}"
    printf "    %-20s %s\n" "WARP"      "${s_warp}"

    echo ""
    echo "  [配置]"
    printf "    %-20s %s\n" "Nginx"    "${c_nginx}"
    printf "    %-20s %s\n" "Xray"     "${c_xray}"
    printf "    %-20s %s\n" "Sing-Box"  "${c_singbox}"
    printf "    %-20s %s\n" "Hysteria2" "${c_hysteria2}"
    printf "    %-20s %s\n" "NaiveProxy" "${c_naive}"
    printf "    %-20s %s\n" "WARP"      "${c_warp}"

    echo ""
    echo "  [域名]"
    {
        local registry
        registry=$(get_state "DOMAIN_REGISTRY")
        if [[ -n "$registry" ]]; then
            for d in $registry; do
                local suffix mode protos tag
                suffix=$(echo "$d" | tr '.' '_')
                mode=$(get_state "DOMAIN_MODE_${suffix}")
                protos=$(get_state "DOMAIN_PROTO_${suffix}")
                [[ "$mode" == "cdn" ]] && tag="CDN" || tag="直连"
                printf "  %-10s : %-30s %s\n" "$protos" "$d" "$tag"
            done
        else
            echo "  暂无"
        fi
    }

    if [[ -n "${HW_CPU_CORES:-}" ]]; then
        echo ""
        echo "  [硬件]"
        echo "    CPU: ${HW_CPU_CORES} | MEM: ${HW_MEM_GB}GB | BW: ${HW_BANDWIDTH} | STACK: ${HW_DUAL_STACK} | DISK: ${HW_DISK_TYPE}"
    fi

    echo ""
    echo "  [模块缓存]  ${cached_count}/${total_modules} 个已缓存到本地（选 s 可同步更新）"

    echo -e "${BLUE}==========================================${NC}"
    echo ""
}

do_sync_modules() {
    echo ""
    log_info "从 GitHub 下载所有模块覆盖本地缓存..."
    sync_modules
    done_return
}

_ensure_wgcf() {
    [[ -z "${WGCF_PRIVATE_KEY:-}"   ]] && WGCF_PRIVATE_KEY=$(get_state "WGCF_PRIVATE_KEY")
    [[ -z "${WGCF_PEER_PUBKEY:-}"   ]] && WGCF_PEER_PUBKEY=$(get_state "WGCF_PEER_PUBKEY")
    [[ -z "${WGCF_ADDRESS:-}"       ]] && WGCF_ADDRESS=$(get_state "WGCF_ADDRESS")
    [[ -z "${WGCF_ENDPOINT:-}"      ]] && WGCF_ENDPOINT=$(get_state "WGCF_ENDPOINT")
    [[ -z "${WGCF_ENDPOINT_HOST:-}" ]] && WGCF_ENDPOINT_HOST=$(get_state "WGCF_ENDPOINT_HOST")
    [[ -z "${WGCF_ENDPOINT_PORT:-}" ]] && WGCF_ENDPOINT_PORT=$(get_state "WGCF_ENDPOINT_PORT")

    if [[ -z "${WGCF_PRIVATE_KEY:-}" ]]; then
        log_warn "未找到 WARP WireGuard 凭证，自动执行 WARP 配置（菜单选项 w）..."
        load_os_info
        load_module warp
        run_warp
        save_state "WGCF_PRIVATE_KEY"   "${WGCF_PRIVATE_KEY:-}"
        save_state "WGCF_PEER_PUBKEY"   "${WGCF_PEER_PUBKEY:-}"
        save_state "WGCF_ADDRESS"       "${WGCF_ADDRESS:-}"
        save_state "WGCF_ENDPOINT"      "${WGCF_ENDPOINT:-}"
        save_state "WGCF_ENDPOINT_HOST" "${WGCF_ENDPOINT_HOST:-}"
        save_state "WGCF_ENDPOINT_PORT" "${WGCF_ENDPOINT_PORT:-}"
        save_state "INST_WARP"          "1"
        save_state "CONF_WARP"          "1"
    fi
}

done_return() {
    echo ""
    read -rp "按回车返回主菜单..." _
}

run_menu_action() {
    local name="$1"
    shift
    "$@" || {
        log_warn "${name} 执行失败或中断，已返回主菜单"
        sleep 1
    }
}

save_system_optimization_state() {
    local mem_mb
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    HW_MEM_GB=${HW_MEM_GB:-$(awk -v m="$mem_mb" 'BEGIN{printf "%.1f", m/1024}')}
    HW_BANDWIDTH=${HW_BANDWIDTH:-unknown}
    HW_DUAL_STACK=${HW_DUAL_STACK:-unknown}
    HW_DISK_TYPE=${HW_DISK_TYPE:-unknown}

    BBR_VERSION=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "bbr")

    save_state "OS_ID"         "$OS_ID"
    save_state "OS_NAME"       "$OS_NAME"
    save_state "PKG_MANAGER"   "$PKG_MANAGER"
    save_state "BBR_VERSION"   "${BBR_VERSION}"
    save_state "HW_CPU_CORES"  "${HW_CPU_CORES:-$(nproc)}"
    save_state "HW_MEM_GB"     "${HW_MEM_GB}"
    save_state "HW_BANDWIDTH"  "${HW_BANDWIDTH}"
    save_state "HW_DUAL_STACK" "${HW_DUAL_STACK}"
    save_state "HW_DISK_TYPE"  "${HW_DISK_TYPE}"
    save_state "XRAY_PADDING"  "${XRAY_PADDING:-128-2048}"
    save_state "INST_SYSTEM"   "1"
}

do_upgrade_kernel() {
    load_module system
    run_kernel_upgrade
    save_state "INST_KERNEL" "1"

    done_return
}

do_optimize_system() {
    load_module system
    run_system_optimize
    save_system_optimization_state

    done_return
}

do_inst_unbound() {
    load_os_info
    load_module unbound
    restore_domain_arrays
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")

    if [[ -z "$(get_state "ALL_DOMAINS")" ]]; then
        log_info "提示：尚未申请证书，域名解析配置将在步骤 5 完成后自动更新"
    fi

    run_unbound

    save_state "HW_DUAL_STACK"        "${HW_DUAL_STACK:-}"
    save_state "UNBOUND_SERVICE_NAME" "${UNBOUND_SERVICE_NAME:-}"
    save_state "INST_UNBOUND"         "1"
    done_return
}

do_inst_nginx() {
    load_os_info
    load_module nginx

    if command -v nginx &>/dev/null; then
        local ver reinstall
        ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1 || true)
        log_info "Nginx 已安装: v${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_NGINX" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf

    save_state "INST_NGINX" "1"
    done_return
}

do_inst_cert() {
    load_os_info
    load_module cert
    run_cert

    save_state "XHTTP_DOMAIN"   "${XHTTP_DOMAIN:-}"
    save_state "GRPC_DOMAIN"    "${GRPC_DOMAIN:-}"
    save_state "REALITY_DOMAIN" "${REALITY_DOMAIN:-}"
    save_state "ANYTLS_DOMAIN"  "${ANYTLS_DOMAIN:-}"
    save_state "ALL_DOMAINS"    "${ALL_DOMAINS[*]:-}"
    save_state "CDN_DOMAINS"    "${CDN_DOMAINS[*]:-}"
    save_state "DIRECT_DOMAINS" "${DIRECT_DOMAINS[*]:-}"
    save_state "XHTTP_PATH"     "${XHTTP_PATH:-}"
    save_state "INST_CERT"      "1"

    XHTTP_DOMAIN="${XHTTP_DOMAIN:-}"
    GRPC_DOMAIN="${GRPC_DOMAIN:-}"
    REALITY_DOMAIN="${REALITY_DOMAIN:-}"
    ANYTLS_DOMAIN="${ANYTLS_DOMAIN:-}"



    done_return
}

do_inst_xray() {
    load_os_info
    load_module xray

    if command -v xray &>/dev/null; then
        local ver reinstall
        ver=$(xray version 2>&1 | grep -oP '[\d.]+' | head -1 || true)
        log_info "Xray 已安装: v${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_XRAY" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_xray
    save_state "INST_XRAY" "1"

    log_info "Xray 安装完成，请继续执行步骤 11"
    done_return
}

do_inst_singbox() {
    load_os_info
    load_module singbox

    if command -v sing-box &>/dev/null; then
        local ver reinstall
        ver=$(sing-box version 2>&1 | grep -oP '[\d.]+' | head -1 || true)
        log_info "Sing-Box 已安装: v${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_SINGBOX" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_singbox
    save_state "INST_SINGBOX" "1"

    log_info "Sing-Box 安装完成，请继续执行步骤 12"
    done_return
}

do_inst_hysteria2() {
    load_os_info
    load_module hysteria2

    if command -v hysteria &>/dev/null; then
        local ver reinstall
        ver=$(hysteria version 2>&1 | grep -oP '[\d.]+' | head -1 || true)
        log_info "Hysteria2 已安装: v${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_HYSTERIA2" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_hysteria2
    save_state "INST_HYSTERIA2" "1"

    log_info "Hysteria2 安装完成"
    done_return
}

do_inst_naive() {
    load_os_info
    load_module naive

    if command -v caddy-naive &>/dev/null; then
        local ver reinstall
        ver=$(caddy-naive version 2>&1 | head -1 || true)
        log_info "NaiveProxy 已安装: ${ver}"
        read -rp "是否重新安装？[y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            save_state "INST_NAIVE" "1"
            log_info "跳过安装"
            done_return
            return
        fi
    fi

    install_naive
    naive_record_forwardproxy_commit
    save_state "INST_NAIVE" "1"

    log_info "NaiveProxy 安装完成"
    done_return
}

do_conf_nginx() {
    if [[ "$(get_step INST_NGINX)" != "1" ]] && ! command -v nginx &>/dev/null; then
        log_warn "请先完成步骤 4（安装 Nginx）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi
    if command -v nginx &>/dev/null && [[ "$(get_step INST_NGINX)" != "1" ]]; then
        save_state "INST_NGINX" "1"
    fi

    local cert_ready=false
    [[ "$(get_step INST_CERT)" == "1" ]] && cert_ready=true
    find /etc/letsencrypt/live -name 'fullchain.pem' -quit 2>/dev/null | grep -q . && cert_ready=true

    if ! $cert_ready; then
        log_warn "未检测到有效 SSL 证书，请先完成步骤 5（申请 SSL 证书）"
        done_return
        return
    fi

    load_os_info
    restore_domain_arrays   # 内含 REALITY_SERVER_NAMES 恢复

    # ── state 健全性检查 ────────────────────────────────────────
    # restore_domain_arrays 只读 state，不重建；若 state 陈旧会导致
    # XHTTP_DOMAIN / GRPC_DOMAIN 为空，使 generate_servers_conf 静默
    # 跳过 gRPC merged-location，令 gRPC 节点在 :8380 上无 location 匹配。
    #
    # rebuild_protocol_domains 才是"从注册表重建并写回 state"的函数，
    # 只在 collect_domains(b/c) 和 add_domain_and_cert 里被调用；
    # 直接调 do_conf_nginx 时不会触发，state 可能持有旧值。
    _cdn_state_stale=false
    if [[ ${#CDN_DOMAINS[@]} -gt 0 && -z "${XHTTP_DOMAIN:-}" ]]; then
        _cdn_state_stale=true
    fi
    if [[ "$_cdn_state_stale" == false && -z "${GRPC_DOMAIN:-}" ]]; then
        local _sreg _sd _ss _sp
        _sreg=$(get_state "DOMAIN_REGISTRY" "")
        for _sd in $_sreg; do
            _ss=$(echo "$_sd" | tr '.' '_')
            _sp=$(get_state "DOMAIN_PROTO_${_ss}" "")
            case ",${_sp}," in
                *,xray-grpc,*) _cdn_state_stale=true; break ;;
            esac
        done
    fi
    if [[ "$_cdn_state_stale" == true ]]; then
        log_warn "CDN 协议域名 state 陈旧，自动修复中..."
        [[ -z "${XHTTP_DOMAIN:-}" ]] && log_warn "  XHTTP_DOMAIN 为空"
        [[ -z "${GRPC_DOMAIN:-}"  ]] && log_warn "  GRPC_DOMAIN  为空"
        # rebuild_protocol_domains：纯 state 读写，幂等，无交互、无证书申请、无网络调用
        rebuild_protocol_domains
        # 修复后复查：若仍为空说明 DOMAIN_REGISTRY 本身未初始化，无法自愈
        if [[ ${#CDN_DOMAINS[@]} -gt 0 && -z "${XHTTP_DOMAIN:-}" ]]; then
            log_error "自动修复失败：CDN_DOMAINS 非空但 XHTTP_DOMAIN 仍为空。"
            log_warn  "请先运行菜单选项 5（申请证书 / 重新收集域名）初始化域名配置。"
            done_return
            return
        fi
        log_info "state 修复完成：XHTTP_DOMAIN=${XHTTP_DOMAIN:-<空>}  GRPC_DOMAIN=${GRPC_DOMAIN:-<空>}"
    fi

    XHTTP_PATH=$(get_state "XHTTP_PATH")
    if [[ -z "${XHTTP_PATH}" ]]; then
        XHTTP_PATH="/$(tr -d '-' < /proc/sys/kernel/random/uuid)"
        save_state "XHTTP_PATH" "${XHTTP_PATH}"
        log_info "生成 XHTTP_PATH: ${XHTTP_PATH}"
    else
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    fi

    if ! preflight_config_check "do_conf_nginx"; then
        done_return
        return
    fi

    load_module nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    if [[ -n "${GRPC_DOMAIN:-}" ]]; then
        generate_fake_site "/var/www/${GRPC_DOMAIN}" "${GRPC_DOMAIN}"
    fi
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    generate_trap_cert
    generate_fallback_conf
    generate_servers_conf
    generate_nginx_conf
    reload_nginx
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater

    save_state "CONF_NGINX" "1"
    done_return
}

refresh_nginx_after_xray() {
    load_module sync
    sync_refresh_nginx_routes "Xray"
}

do_conf_xray() {
    if [[ "$(get_step INST_XRAY)" != "1" ]] && ! command -v xray &>/dev/null; then
        log_warn "请先完成步骤 6（安装 Xray）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi
    if command -v xray &>/dev/null && [[ "$(get_step INST_XRAY)" != "1" ]]; then
        save_state "INST_XRAY" "1"
    fi

    if [[ "$(get_step CONF_NGINX)" != "1" ]] && ! command -v nginx &>/dev/null; then
        log_warn "建议先完成步骤 10（配置 Nginx）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi

    load_os_info
    restore_domain_arrays
    XRAY_PADDING=$(get_state "XRAY_PADDING" "128-2048")

    _ensure_wgcf

    load_module xray
    local saved_path
    saved_path=$(get_state "XHTTP_PATH")
    if [[ -n "${saved_path}" ]]; then
        XHTTP_PATH="${saved_path}"
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    fi

    if ! preflight_config_check "do_conf_xray"; then
        done_return
        return
    fi

    generate_xray_params
    collect_reality_params
    generate_xray_config
    start_xray

    save_state "XRAY_UUID"             "${XRAY_UUID:-}"
    save_state "XRAY_PUBLIC_KEY"       "${XRAY_PUBLIC_KEY:-}"
    save_state "XRAY_PRIVATE_KEY"      "${XRAY_PRIVATE_KEY:-}"
    save_state "XHTTP_PATH"            "${XHTTP_PATH:-}"
    save_state "REALITY_DEST"          "${REALITY_DEST:-}"
    save_state "REALITY_SNI"           "${REALITY_SERVER_NAMES[0]:-}"
    # ── BUG FIX：保存完整 serverNames 数组供 nginx 生成 SNI map 使用 ──
    save_state "REALITY_SERVER_NAMES"  "${REALITY_SERVER_NAMES[*]:-}"
    save_state "REALITY_SHORT_ID"      "${REALITY_SHORT_IDS[1]:-}"
    save_state "REALITY_SHORT_IDS" "${REALITY_SHORT_IDS[*]:-}"
    save_state "REALITY_SPIDER_X"      "${REALITY_SPIDER_X:-}"
    save_state "CONF_XRAY"             "1"

    refresh_nginx_after_xray

    done_return
}

do_conf_singbox() {
    if [[ "$(get_step INST_SINGBOX)" != "1" ]] && ! command -v sing-box &>/dev/null; then
        log_warn "请先完成步骤 7（安装 Sing-Box）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi
    if command -v sing-box &>/dev/null && [[ "$(get_step INST_SINGBOX)" != "1" ]]; then
        save_state "INST_SINGBOX" "1"
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "建议先完成步骤 5（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi

    if [[ "$(get_step CONF_NGINX)" != "1" ]]; then
        log_info "提示：Nginx 尚未配置（步骤 10），443 SNI 分流暂不可用；"
        log_info "      Sing-Box 本身可正常启动，待 Nginx 配置完成后流量即自动接通。"
    fi

    load_os_info
    restore_domain_arrays
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")

    if ! preflight_config_check "do_conf_singbox"; then
        done_return
        return
    fi

    _ensure_wgcf

    load_module singbox
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox

    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "ANYTLS_DOMAIN"     "${ANYTLS_DOMAIN:-}"
    save_state "CONF_SINGBOX"     "1"

    sync_refresh_nginx_routes "Sing-Box"

    done_return
}

do_conf_hysteria2() {
    if [[ "$(get_step INST_HYSTERIA2)" != "1" ]] && ! command -v hysteria &>/dev/null; then
        log_warn "请先完成步骤 8（安装 Hysteria2）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi
    if command -v hysteria &>/dev/null && [[ "$(get_step INST_HYSTERIA2)" != "1" ]]; then
        save_state "INST_HYSTERIA2" "1"
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "建议先完成步骤 5（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi

    load_os_info
    restore_domain_arrays

    if ! preflight_config_check "do_conf_hysteria2"; then
        done_return
        return
    fi

    load_module hysteria2
    configure_hysteria2

    save_state "CONF_HYSTERIA2" "1"

    done_return
}

do_reconf_hysteria2() {
    read -rp "将清理 Hysteria2 配置并重新生成，确认继续吗？[y/N]: " c
    [[ "${c,,}" != "y" ]] && return

    load_module uninstall

    log_step "清理 Hysteria2 配置文件..."
    rm -f /etc/hysteria/config.yaml
    save_state "CONF_HYSTERIA2" "0"
    log_info "Hysteria2 配置清理完成，开始重新生成..."

    do_conf_hysteria2
}

do_conf_naive() {
    if [[ "$(get_step INST_NAIVE)" != "1" ]] && ! command -v caddy-naive &>/dev/null; then
        log_warn "请先完成步骤 9（安装 NaiveProxy）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi
    if command -v caddy-naive &>/dev/null && [[ "$(get_step INST_NAIVE)" != "1" ]]; then
        save_state "INST_NAIVE" "1"
    fi

    if [[ "$(get_step INST_CERT)" != "1" ]]; then
        log_warn "建议先完成步骤 5（申请 SSL 证书）"
        read -rp "是否继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && return
    fi

    load_os_info
    restore_domain_arrays

    if ! preflight_config_check "do_conf_naive"; then
        done_return
        return
    fi

    load_module naive
    configure_naive || return

    save_state "CONF_NAIVE" "1"

    if systemctl is-active --quiet nginx; then
        sync_refresh_nginx_routes "NaiveProxy"
    fi

    done_return
}

do_reconf_naive() {
    read -rp "将清理 NaiveProxy 配置并重新生成，确认继续吗？[y/N]: " c
    [[ "${c,,}" != "y" ]] && return

    load_module uninstall

    log_step "清理 NaiveProxy 配置文件..."
    rm -f /etc/caddy-naive/Caddyfile
    save_state "CONF_NAIVE" "0"
    log_info "NaiveProxy 配置清理完成，开始重新生成..."

    do_conf_naive
}

do_preflight_report() {
    load_os_info
    restore_domain_arrays 2>/dev/null || true
    echo ""
    log_step "配置健康检查（preflight）"
    if preflight_config_check "manual_report"; then
        echo ""
        log_info "结果：通过"
    else
        echo ""
        log_warn "结果：有硬失败项，请按上述提示修复后再运行 do_conf_*"
    fi
    done_return
}

do_client() {
    load_module sync
    sync_before_client_links
    load_module client
    run_client
    done_return
}

_new_uuid() {
    if command -v xray &>/dev/null; then
        xray uuid
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen
    fi
}

_new_xray_short_ids() {
    printf '%s %s %s %s %s' \
        "$(openssl rand -hex 4)" \
        "$(openssl rand -hex 4)" \
        "$(openssl rand -hex 4)" \
        "$(openssl rand -hex 6)" \
        "$(openssl rand -hex 8)"
}

_new_xhttp_path() {
    printf '/%s' "$(tr -d '-' < /proc/sys/kernel/random/uuid)"
}

_new_subscription_path() {
    local old_path machine_name sub_name new_path
    old_path=$(get_state "SUBSCRIPTION_PATH" "")
    if [[ "${old_path}" =~ ^/[A-Za-z0-9._-]+$ ]]; then
        rm -f "/var/www/html${old_path}"
    fi

    machine_name=$(hostname -s 2>/dev/null || echo "server")
    sub_name=$(printf '%s' "${machine_name:-server}" | tr -c 'A-Za-z0-9._-' '-')
    sub_name="${sub_name:-server}"
    new_path="/sub-${sub_name}-$(tr -d '-' < /proc/sys/kernel/random/uuid)"
    save_state "SUBSCRIPTION_PATH" "${new_path}"
    log_info "已生成新订阅路径: ${new_path}"
}

_is_conf_step_enabled() {
    local step="$1"
    [[ "$(get_step "$step")" == "1" ]]
}

_restart_rotated_service() {
    local service="$1" backup="$2" config="$3" keep_backup="${4:-0}"

    if systemctl restart "$service"; then
        [[ "$keep_backup" == "1" ]] || rm -f "$backup"
        return 0
    fi

    log_error "${service} 重启失败，恢复旧配置"
    mv -f "$backup" "$config" 2>/dev/null || true
    systemctl restart "$service" 2>/dev/null || true
    return 1
}

_sync_nginx_after_credential_reset() {
    _is_conf_step_enabled "CONF_NGINX" || return 0

    log_step "同步 Nginx 协议入口配置..."
    load_os_info
    restore_domain_arrays

    if ! preflight_config_check "credential_reset_nginx_sync"; then
        log_error "Nginx 同步前检查失败，已停止安全重置"
        return 1
    fi

    load_module nginx
    generate_upstreams_conf
    generate_fallback_conf
    generate_servers_conf || return 1
    generate_nginx_conf
    if ! nginx -t; then
        log_error "Nginx 配置验证失败，已停止安全重置"
        return 1
    fi
    if ! systemctl restart nginx; then
        log_error "Nginx 重启失败，已停止安全重置"
        return 1
    fi
    log_info "Nginx 已同步新 XHTTP 路径"
}

_restore_xray_after_nginx_sync_failure() {
    local config="/usr/local/etc/xray/config.json"
    [[ -n "${RESET_XRAY_BACKUP:-}" && -f "${RESET_XRAY_BACKUP}" ]] || return 0

    log_error "Nginx 同步失败，恢复 Xray 旧配置和旧 XHTTP 路径"
    mv -f "${RESET_XRAY_BACKUP}" "$config" 2>/dev/null || true
    save_state "XRAY_UUID" "${RESET_OLD_XRAY_UUID:-}"
    save_state "XRAY_PRIVATE_KEY" "${RESET_OLD_XRAY_PRIVATE_KEY:-}"
    save_state "XRAY_PUBLIC_KEY" "${RESET_OLD_XRAY_PUBLIC_KEY:-}"
    save_state "REALITY_SHORT_IDS" "${RESET_OLD_REALITY_SHORT_IDS:-}"
    save_state "REALITY_SHORT_ID" "${RESET_OLD_REALITY_SHORT_ID:-}"
    [[ -n "${RESET_OLD_XHTTP_PATH:-}" ]] && save_state "XHTTP_PATH" "${RESET_OLD_XHTTP_PATH}"
    systemctl restart xray.service 2>/dev/null || true
}

_rotate_xray_credentials() {
    local config="/usr/local/etc/xray/config.json"
    _is_conf_step_enabled "CONF_XRAY" || return 0
    [[ -f "${config}" ]] || { log_warn "跳过 Xray：未找到 ${config}"; return 0; }

    if ! command -v xray &>/dev/null; then
        log_warn "跳过 Xray：未找到 xray 命令"
        return 0
    fi

    log_step "轮换 Xray UUID / Reality 密钥 / shortIds..."
    local new_uuid keypair new_private new_public new_short_ids new_xhttp_path tmp backup
    new_uuid=$(_new_uuid)
    keypair=$(xray x25519)
    new_private=$(echo "$keypair" | grep -i "private" | awk '{print $NF}')
    new_public=$(echo "$keypair" | grep -i "public\|password" | awk '{print $NF}')
    new_short_ids=$(_new_xray_short_ids)
    new_xhttp_path=$(_new_xhttp_path)
    tmp="${config}.tmp.$$"
    backup="${config}.bak.$$"

    if ! NEW_XRAY_UUID="${new_uuid}" \
        NEW_XRAY_PRIVATE_KEY="${new_private}" \
        NEW_XRAY_SHORT_IDS="${new_short_ids}" \
        NEW_XHTTP_PATH="${new_xhttp_path}" \
        python3 - "$config" "$tmp" << 'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
tmp = Path(sys.argv[2])
with path.open() as f:
    config = json.load(f)

new_uuid = os.environ["NEW_XRAY_UUID"]
new_private_key = os.environ["NEW_XRAY_PRIVATE_KEY"]
new_short_ids = os.environ["NEW_XRAY_SHORT_IDS"].split()
new_xhttp_path = os.environ["NEW_XHTTP_PATH"]

changed = 0
for inbound in config.get("inbounds", []):
    for client in inbound.get("settings", {}).get("clients", []):
        if "id" in client:
            client["id"] = new_uuid
            changed += 1

    reality = inbound.get("streamSettings", {}).get("realitySettings")
    if reality:
        reality["privateKey"] = new_private_key
        reality["shortIds"] = new_short_ids
        changed += 1

    xhttp = inbound.get("streamSettings", {}).get("xhttpSettings")
    if xhttp and "path" in xhttp:
        xhttp["path"] = new_xhttp_path
        changed += 1

if changed == 0:
    sys.exit("no Xray client or Reality credential fields matched")

with tmp.open("w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    then
        rm -f "$tmp"
        log_error "Xray 配置字段匹配失败，已停止安全重置"
        exit 1
    fi

    if ! xray run -test -config "$tmp"; then
        rm -f "$tmp"
        log_error "Xray 配置验证失败，已停止安全重置"
        exit 1
    fi
    cp -p "$config" "$backup"
    mv -f "$tmp" "$config"

    RESET_OLD_XRAY_UUID=$(get_state "XRAY_UUID" "")
    RESET_OLD_XRAY_PRIVATE_KEY=$(get_state "XRAY_PRIVATE_KEY" "")
    RESET_OLD_XRAY_PUBLIC_KEY=$(get_state "XRAY_PUBLIC_KEY" "")
    RESET_OLD_REALITY_SHORT_IDS=$(get_state "REALITY_SHORT_IDS" "")
    RESET_OLD_REALITY_SHORT_ID=$(get_state "REALITY_SHORT_ID" "")
    RESET_OLD_XHTTP_PATH=$(get_state "XHTTP_PATH" "")
    RESET_XRAY_BACKUP="$backup"
    _restart_rotated_service "xray.service" "$backup" "$config" "1" || exit 1
    save_state "XRAY_UUID" "${new_uuid}"
    save_state "XRAY_PRIVATE_KEY" "${new_private}"
    save_state "XRAY_PUBLIC_KEY" "${new_public}"
    save_state "XHTTP_PATH" "${new_xhttp_path}"
    save_state "REALITY_SHORT_IDS" "${new_short_ids}"
    save_state "REALITY_SHORT_ID" "$(awk '{print $2}' <<< "${new_short_ids}")"
    log_info "Xray 凭据已轮换"

}

_rotate_singbox_credentials() {
    local config="/etc/sing-box/config.json"
    _is_conf_step_enabled "CONF_SINGBOX" || return 0
    [[ -f "${config}" ]] || { log_warn "跳过 Sing-Box：未找到 ${config}"; return 0; }

    log_step "轮换 Sing-Box AnyTLS 密码..."
    local new_password tmp backup
    new_password=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)
    new_password="${new_password}-$(openssl rand -hex 4)"
    tmp="${config}.tmp.$$"
    backup="${config}.bak.$$"

    if ! NEW_SINGBOX_PASSWORD="${new_password}" python3 - "$config" "$tmp" << 'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
tmp = Path(sys.argv[2])
with path.open() as f:
    config = json.load(f)

new_password = os.environ["NEW_SINGBOX_PASSWORD"]
changed = 0
for inbound in config.get("inbounds", []):
    if inbound.get("type") == "anytls":
        for user in inbound.get("users", []):
            user["password"] = new_password
            changed += 1

if changed == 0:
    sys.exit("no Sing-Box AnyTLS users matched")

with tmp.open("w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    then
        rm -f "$tmp"
        log_error "Sing-Box 配置字段匹配失败，已停止安全重置"
        exit 1
    fi

    if command -v sing-box &>/dev/null && ! sing-box check -c "$tmp"; then
        rm -f "$tmp"
        log_error "Sing-Box 配置验证失败，已停止安全重置"
        exit 1
    fi
    cp -p "$config" "$backup"
    mv -f "$tmp" "$config"

    _restart_rotated_service "sing-box.service" "$backup" "$config" || exit 1
    save_state "SINGBOX_PASSWORD" "${new_password}"
    log_info "Sing-Box AnyTLS 密码已轮换"
}

_rotate_hysteria2_credentials() {
    local config="/etc/hysteria/config.yaml"
    _is_conf_step_enabled "CONF_HYSTERIA2" || return 0
    [[ -f "${config}" ]] || { log_warn "跳过 Hysteria2：未找到 ${config}"; return 0; }

    log_step "轮换 Hysteria2 密码..."
    local new_password tmp backup
    new_password=$(openssl rand -base64 18)
    tmp="${config}.tmp.$$"
    backup="${config}.bak.$$"

    if ! NEW_HYSTERIA2_PASSWORD="${new_password}" python3 - "$config" "$tmp" << 'PY'
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
tmp = Path(sys.argv[2])
new_password = os.environ["NEW_HYSTERIA2_PASSWORD"]
text = path.read_text()
text, password_count = re.subn(r"^(\s+password:\s*).*$", rf"\g<1>{new_password}", text, flags=re.MULTILINE)
text, secret_count = re.subn(r"^(\s+secret:\s*).*$", rf"\g<1>{new_password}", text, flags=re.MULTILINE)
if password_count + secret_count == 0:
    sys.exit("no Hysteria2 password or secret fields matched")
tmp.write_text(text)
PY
    then
        rm -f "$tmp"
        log_error "Hysteria2 配置字段匹配失败，已停止安全重置"
        exit 1
    fi
    cp -p "$config" "$backup"
    mv -f "$tmp" "$config"

    _restart_rotated_service "hysteria-server.service" "$backup" "$config" || exit 1
    save_state "HYSTERIA2_PASSWORD" "${new_password}"
    log_info "Hysteria2 密码已轮换"
}

_rotate_naive_credentials() {
    local config="/etc/caddy-naive/Caddyfile"
    _is_conf_step_enabled "CONF_NAIVE" || return 0
    [[ -f "${config}" ]] || { log_warn "跳过 NaiveProxy：未找到 ${config}"; return 0; }

    log_step "轮换 NaiveProxy 用户名 / 密码 / probe_resistance..."
    local new_user new_password new_probe tmp backup
    new_user="u$(openssl rand -hex 6)"
    new_password="$(openssl rand -hex 10)"
    new_probe=$(openssl rand -hex 8)
    tmp="${config}.tmp.$$"
    backup="${config}.bak.$$"

    if ! NEW_NAIVE_USER="${new_user}" \
        NEW_NAIVE_PASS="${new_password}" \
        NEW_NAIVE_PROBE="${new_probe}" \
        python3 - "$config" "$tmp" << 'PY'
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
tmp = Path(sys.argv[2])
text = path.read_text()
text, auth_count = re.subn(
    r"^(\s*basic_auth\s+)\S+\s+\S+\s*$",
    rf"\g<1>{os.environ['NEW_NAIVE_USER']} {os.environ['NEW_NAIVE_PASS']}",
    text,
    flags=re.MULTILINE,
)
text, probe_count = re.subn(
    r"^(\s*probe_resistance\s+)[^.]+(\..*)$",
    rf"\g<1>{os.environ['NEW_NAIVE_PROBE']}\2",
    text,
    flags=re.MULTILINE,
)
if auth_count == 0 or probe_count == 0:
    sys.exit("no NaiveProxy basic_auth or probe_resistance fields matched")
tmp.write_text(text)
PY
    then
        rm -f "$tmp"
        log_error "NaiveProxy 配置字段匹配失败，已停止安全重置"
        exit 1
    fi

    if command -v caddy-naive &>/dev/null && ! caddy-naive validate --config "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log_error "NaiveProxy 配置验证失败，已停止安全重置"
        exit 1
    fi
    cp -p "$config" "$backup"
    mv -f "$tmp" "$config"

    _restart_rotated_service "caddy-naive.service" "$backup" "$config" || exit 1
    save_state "NAIVE_USER" "${new_user}"
    save_state "NAIVE_PASS" "${new_password}"
    save_state "NAIVE_PROBE_LINK" "${new_probe}"
    log_info "NaiveProxy 凭据已轮换"
}

do_reset_client_credentials() {
    log_warn "这会重置所有已配置节点的客户端凭据，旧订阅和旧节点链接将失效。"
    read -rp "确认继续？[y/N]: " c
    [[ "${c,,}" != "y" ]] && return

    _rotate_xray_credentials
    _rotate_singbox_credentials
    _rotate_hysteria2_credentials
    _rotate_naive_credentials
    _sync_nginx_after_credential_reset || {
        _restore_xray_after_nginx_sync_failure
        exit 1
    }
    rm -f "${RESET_XRAY_BACKUP:-}"
    RESET_XRAY_BACKUP=""
    _new_subscription_path

    do_client
}

do_warp() {
    load_os_info
    load_module warp
    run_warp

    save_state "WGCF_PRIVATE_KEY"   "${WGCF_PRIVATE_KEY:-}"
    save_state "WGCF_PEER_PUBKEY"   "${WGCF_PEER_PUBKEY:-}"
    save_state "WGCF_ADDRESS"       "${WGCF_ADDRESS:-}"
    save_state "WGCF_ENDPOINT"      "${WGCF_ENDPOINT:-}"
    save_state "WGCF_ENDPOINT_HOST" "${WGCF_ENDPOINT_HOST:-}"
    save_state "WGCF_ENDPOINT_PORT" "${WGCF_ENDPOINT_PORT:-}"
    save_state "INST_WARP"          "1"
    save_state "CONF_WARP"          "1"

    done_return
}

upgrade_component_method() {
    case "$1" in
        nginx)
            if command -v nginx &>/dev/null && [[ "$(nginx_install_method)" == "compiled" ]]; then
                echo "编译安装"
            else
                echo "系统仓库安装"
            fi
            ;;
        singbox) echo "系统仓库安装" ;;
        xray|hysteria2) echo "脚本安装" ;;
        naive) echo "编译安装" ;;
        *) echo "未知" ;;
    esac
}

upgrade_component_label() {
    case "$1" in
        nginx) echo "Nginx" ;;
        xray) echo "Xray" ;;
        singbox) echo "Sing-Box" ;;
        hysteria2) echo "Hysteria2" ;;
        naive) echo "NaiveProxy(Caddy)" ;;
        all) echo "全部组件" ;;
        *) echo "$1" ;;
    esac
}

upgrade_command_version() {
    case "$1" in
        nginx) nginx -v 2>&1 | grep -oP '[0-9]+(\.[0-9]+)+' | head -1 || true ;;
        xray) xray version 2>&1 | grep -oP '[0-9]+(\.[0-9]+)+' | head -1 || true ;;
        singbox) sing-box version 2>&1 | grep -oP '[0-9]+(\.[0-9]+)+' | head -1 || true ;;
        hysteria2) hysteria version 2>&1 | grep -oP '[0-9]+(\.[0-9]+)+' | head -1 || true ;;
        naive) caddy-naive version 2>&1 | grep -oP 'v?[0-9]+(\.[0-9]+)+' | head -1 | sed 's/^v//' || true ;;
    esac
}

upgrade_github_latest() {
    local repo="$1"
    curl -fsSL --max-time 5 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name"\s*:\s*"\K[^"]+' \
        | head -1 \
        | sed 's/^v//'
}

upgrade_apt_candidate() {
    local pkg="$1"
    timeout 5 apt-cache policy "$pkg" 2>/dev/null \
        | awk '/Candidate:/ {print $2}' \
        | grep -oP '[0-9]+(\.[0-9]+)+' \
        | head -1
}

upgrade_remote_version() {
    case "$1" in
        nginx)
            curl -fsSL --max-time 8 "https://nginx.org/en/CHANGES" 2>/dev/null \
                | grep -m1 'Changes with nginx' \
                | grep -oP '[0-9]+\.[0-9]+\.[0-9]+'
            ;;
        singbox)
            upgrade_github_latest SagerNet/sing-box
            ;;
        xray)      upgrade_github_latest XTLS/Xray-core ;;
        hysteria2) upgrade_github_latest apernet/hysteria ;;
        naive)     upgrade_github_latest caddyserver/caddy ;;
    esac
}

upgrade_collect_remote_versions() {
    local tmp_dir comp pids=()
    tmp_dir=$(mktemp -d)
    declare -gA UPGRADE_REMOTE_VERSIONS=()
    for comp in nginx xray singbox hysteria2 naive; do
        ( upgrade_remote_version "$comp" > "${tmp_dir}/${comp}" ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    for comp in nginx xray singbox hysteria2 naive; do
        UPGRADE_REMOTE_VERSIONS[$comp]=$(cat "${tmp_dir}/${comp}" 2>/dev/null || true)
    done
    rm -rf "$tmp_dir"
}

restart_service_if_configured() {
    local service="$1"
    local test_cmd="${2:-}"

    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ -n "$test_cmd" ]] && ! bash -c "$test_cmd"; then
        log_warn "${service} 配置检查未通过，跳过重启"
        return 0
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q "^${service}"; then
        systemctl restart "$service" || {
            log_warn "${service} 重启失败，请查看: journalctl -u ${service} --no-pager -n 50"
            return 0
        }
        log_info "${service} 已重启"
    else
        log_warn "未找到 ${service} systemd 单元，跳过重启"
    fi
}

upgrade_repo_component() {
    local component="$1"

    load_os_info
    case "$component" in
        nginx)
            if [[ "$(nginx_install_method)" == "compiled" ]]; then
                upgrade_nginx_compiled
            else
                load_module nginx
                install_nginx
            fi
            restart_service_if_configured "nginx.service" "nginx -t >/dev/null 2>&1"
            save_state "INST_NGINX" "1"
            ;;
        singbox)
            load_module singbox
            install_singbox
            restart_service_if_configured "sing-box.service" \
                '[[ ! -f /etc/sing-box/config.json ]] || sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1'
            save_state "INST_SINGBOX" "1"
            ;;
    esac
}

upgrade_script_component() {
    local component="$1"

    load_os_info
    case "$component" in
        xray)
            load_module xray
            install_xray
            configure_xray_service_limits
            restart_service_if_configured "xray.service" \
                '[[ ! -f /usr/local/etc/xray/config.json ]] || xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1'
            save_state "INST_XRAY" "1"
            ;;
        hysteria2)
            load_module hysteria2
            install_hysteria2
            restart_service_if_configured "hysteria-server.service"
            save_state "INST_HYSTERIA2" "1"
            ;;
    esac
}

# ── Nginx 安装方式检测 ─────────────────────────────────────────
# 返回 "pkg"（包管理器）/ "compiled"（编译安装）/ "none"（未安装）
nginx_install_method() {
    if dpkg -l nginx 2>/dev/null | grep -q '^ii'; then echo "pkg"; return; fi
    if rpm -q nginx 2>/dev/null | grep -qv 'is not installed'; then echo "pkg"; return; fi
    if command -v nginx &>/dev/null; then echo "compiled"; return; fi
    echo "none"
}

# ── Nginx 编译依赖 ─────────────────────────────────────────────
nginx_install_build_deps() {
    log_step "安装 Nginx 编译依赖..."
    case "$OS_ID" in
        ubuntu|debian)
            apt-get install -y build-essential libpcre3-dev libssl-dev zlib1g-dev >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|fedora)
            dnf install -y gcc make pcre-devel openssl-devel zlib-devel >/dev/null 2>&1 ;;
    esac
}

# ── Nginx 编译升级 ─────────────────────────────────────────────
upgrade_nginx_compiled() {
    local target_ver current_ver configure_args tmp_dir src_dir
    local sbin_path pid_path old_pid waited

    # ── 版本检测，已是最新则跳过 ─────────────────────────────────
    target_ver=$(upgrade_remote_version nginx)
    [[ -z "$target_ver" ]] && { log_error "无法获取 Nginx 最新版本"; exit 1; }
    current_ver=$(upgrade_command_version nginx)
    if [[ -n "$current_ver" && "$current_ver" == "$target_ver" ]]; then
        log_info "Nginx 已是最新版本 ${current_ver}，跳过"
        return 0
    fi
    log_info "当前: ${current_ver:-未知}  →  目标: ${target_ver}"

    # ── 提取原始 configure 参数（路径全部保留）────────────────────
    configure_args=$(nginx -V 2>&1 | grep -oP '(?<=configure arguments:).*' | sed 's/^ //')
    [[ -z "$configure_args" ]] && { log_error "无法提取 Nginx 编译参数（nginx -V 输出异常）"; exit 1; }
    log_info "原编译参数: ${configure_args}"

    # 从 configure 参数中提取关键路径
    sbin_path=$(echo "$configure_args" | grep -oP '(?<=--sbin-path=)\S+')
    [[ -z "$sbin_path" ]] && sbin_path=$(command -v nginx)
    pid_path=$(echo "$configure_args" | grep -oP '(?<=--pid-path=)\S+')
    [[ -z "$pid_path" ]] && pid_path="/var/run/nginx.pid"
    log_info "二进制: ${sbin_path}  PID: ${pid_path}"

    # 检查外部 --add-module= 路径是否存在
    while IFS= read -r mod; do
        [[ -n "$mod" && ! -d "$mod" ]] && log_warn "外部模块目录不存在: $mod（configure 可能失败）"
    done < <(echo "$configure_args" | grep -oP '(?<=--add-module=)[^ ]+')

    nginx_install_build_deps

    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    # ── 下载源码 ──────────────────────────────────────────────────
    log_step "下载 nginx-${target_ver} 源码..."
    curl -fsSL --max-time 120 \
        "https://nginx.org/download/nginx-${target_ver}.tar.gz" \
        -o "${tmp_dir}/nginx.tar.gz" \
        || { log_error "下载 Nginx 源码失败"; exit 1; }

    tar -xzf "${tmp_dir}/nginx.tar.gz" -C "$tmp_dir"
    src_dir=$(find "$tmp_dir" -maxdepth 1 -name 'nginx-*' -type d | head -1)
    [[ -z "$src_dir" ]] && { log_error "源码解压失败"; exit 1; }

    # ── 编译（复用原始 configure 参数，路径与原安装完全一致）──────
    pushd "$src_dir" >/dev/null
    log_step "configure..."
    # shellcheck disable=SC2086
    ./configure $configure_args 2>&1 || { popd >/dev/null; log_error "Nginx configure 失败"; exit 1; }

    log_step "make（$(nproc) 线程）..."
    make -j"$(nproc)" 2>&1 || { popd >/dev/null; log_error "Nginx make 失败"; exit 1; }

    # ── 热升级：只替换二进制，不覆盖配置 ────────────────────────
    log_step "替换二进制文件..."
    cp -f "$sbin_path" "${sbin_path}.old"   # 备份，供回滚
    cp -f objs/nginx "$sbin_path"
    chmod 755 "$sbin_path"
    popd >/dev/null

    # nginx 未在运行时直接启动，跳过热重启流程
    if [[ ! -f "$pid_path" ]] || ! kill -0 "$(cat "$pid_path" 2>/dev/null)" 2>/dev/null; then
        log_warn "Nginx 未在运行，直接启动新版本"
        systemctl start nginx 2>/dev/null || nginx 2>/dev/null || true
        rm -f "${sbin_path}.old"
        log_info "Nginx 编译升级完成: $(nginx -v 2>&1 | grep -oP '[0-9.]+' | head -1)"
        return 0
    fi

    # ── USR2：让 nginx 以新二进制启动新 master，保持旧 master 在线
    old_pid=$(cat "$pid_path")
    log_step "发送 USR2 启动新 master（旧 PID: ${old_pid}）..."
    kill -USR2 "$old_pid" || { log_error "USR2 发送失败"; cp -f "${sbin_path}.old" "$sbin_path"; exit 1; }

    # 等待新 master 生成 .oldbin PID 文件（最多 15 秒）
    waited=0
    while [[ ! -f "${pid_path}.oldbin" && $waited -lt 15 ]]; do
        sleep 1; (( waited++ ))
    done

    if [[ ! -f "${pid_path}.oldbin" ]]; then
        log_warn "新 master 启动超时，回滚二进制"
        cp -f "${sbin_path}.old" "$sbin_path"
        log_error "Nginx 热升级失败"
        exit 1
    fi

    # ── WINCH：旧 worker 停止接受新连接，优雅排干
    log_step "WINCH 旧 worker，等待连接排干..."
    kill -WINCH "$old_pid" 2>/dev/null || true
    sleep 3

    # ── QUIT：旧 master 退出，完成升级
    kill -QUIT "$old_pid" 2>/dev/null || true

    rm -f "${sbin_path}.old"
    log_info "Nginx 编译升级完成: $(nginx -v 2>&1 | grep -oP '[0-9.]+' | head -1)"
}

upgrade_compiled_component() {
    local component="$1"

    load_os_info
    case "$component" in
        naive)
            if naive_upgrade_up_to_date; then
                log_info "Caddy 与 forwardproxy@naive 均为最新，跳过重新编译"
                save_state "INST_NAIVE" "1"
                return 0
            fi
            load_module naive
            install_naive
            naive_record_forwardproxy_commit
            restart_service_if_configured "caddy-naive.service" \
                '[[ ! -f /etc/caddy-naive/Caddyfile ]] || /usr/local/bin/caddy-naive validate --config /etc/caddy-naive/Caddyfile >/dev/null 2>&1'
            save_state "INST_NAIVE" "1"
            ;;
    esac
}

# ── NaiveProxy(Caddy) 升级辅助：判定是否真的需要重新编译 ──
# 两个上游：caddyserver/caddy（latest release tag）+ klzgrad/forwardproxy@naive（HEAD commit）
# 任一变化即返回 1（需升级）；都未变返回 0（跳过）；网络失败时返回 1（保守触发编译）
naive_upgrade_up_to_date() {
    local current_caddy latest_caddy current_fp_commit latest_fp_commit
    current_caddy=$(upgrade_command_version naive 2>/dev/null || true)
    latest_caddy=$(upgrade_github_latest caddyserver/caddy 2>/dev/null || true)
    current_fp_commit=$(get_state "FORWARDPROXY_NAIVE_COMMIT" "")
    latest_fp_commit=$(curl -fsSL --max-time 5 \
        "https://api.github.com/repos/klzgrad/forwardproxy/commits/naive" 2>/dev/null \
        | grep -oP '"sha"\s*:\s*"\K[^"]+' | head -1 || true)

    local cur_fp_short="${current_fp_commit:0:12}" lat_fp_short="${latest_fp_commit:0:12}"
    log_info "Caddy: 当前=${current_caddy:-未知} 最新=${latest_caddy:-未知}"
    log_info "forwardproxy@naive: 当前=${cur_fp_short:-未知} 最新=${lat_fp_short:-未知}"

    [[ -z "$current_caddy" || -z "$latest_caddy" || -z "$latest_fp_commit" ]] && return 1
    [[ "$current_caddy" != "$latest_caddy" ]] && return 1
    [[ "$current_fp_commit" != "$latest_fp_commit" ]] && return 1
    return 0
}

# 编译成功后记录 forwardproxy@naive 的 HEAD commit，作为下次比对的基线
naive_record_forwardproxy_commit() {
    local sha
    sha=$(curl -fsSL --max-time 5 \
        "https://api.github.com/repos/klzgrad/forwardproxy/commits/naive" 2>/dev/null \
        | grep -oP '"sha"\s*:\s*"\K[^"]+' | head -1 || true)
    if [[ -n "$sha" ]]; then
        save_state "FORWARDPROXY_NAIVE_COMMIT" "$sha"
        log_info "已记录 forwardproxy@naive commit: ${sha:0:12}"
    fi
}

run_upgrade_component() {
    local component="$1"
    local label method before after

    case "$component" in
        nginx|xray|singbox|hysteria2|naive|all) ;;
        *)
            log_error "不支持的升级组件: ${component:-<空>}"
            exit 1
            ;;
    esac

    if [[ "$component" == "all" ]]; then
        for component in nginx xray singbox hysteria2 naive; do
            run_upgrade_component "$component"
        done
        return 0
    fi

    label=$(upgrade_component_label "$component")
    method=$(upgrade_component_method "$component")
    before=$(upgrade_command_version "$component")

    log_step "升级 ${label}（${method}）..."
    [[ -n "$before" ]] && log_info "当前版本: ${before}"

    case "$component" in
        nginx|singbox) upgrade_repo_component "$component" ;;
        xray|hysteria2) upgrade_script_component "$component" ;;
        naive) upgrade_compiled_component "$component" ;;
    esac

    after=$(upgrade_command_version "$component")
    [[ -n "$after" ]] && log_info "升级后版本: ${after}"
    log_info "${label} 升级任务完成"
}

start_upgrade_job() {
    local component="$1"
    local label session log_file status_file pid_file runner script_path runner_script

    label=$(upgrade_component_label "$component")
    session="xray-upgrade-${component}"
    log_file="/var/log/xray-deploy/upgrade-${component}-$(date +%Y%m%d%H%M%S).log"
    status_file="/var/log/xray-deploy/upgrade-${component}.status"
    pid_file="/var/log/xray-deploy/upgrade-${component}.pid"
    runner="/tmp/xray-deploy-upgrade-${component}-$$.sh"
    script_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

    mkdir -p /var/log/xray-deploy

    if [[ -n "$script_path" && -f "$script_path" ]]; then
        runner_script="bash '$script_path' --upgrade-component '$component'"
    else
        runner_script="bash <(curl -fsSL '${BASE_URL}/install.sh') --upgrade-component '$component'"
    fi

    cat > "$runner" << RUNNER
#!/usr/bin/env bash
# 此 set -euo pipefail 属于独立的后台 runner 子脚本（写入 \$runner），
# 与本文件顶部第 2 行的 set -euo pipefail 是两个进程，互不影响。
set -euo pipefail
echo \$\$ > "$pid_file"
exec >>"$log_file" 2>&1
finish() {
    local code="\$?"
    if [[ "\$code" -eq 0 ]]; then
        echo "SUCCESS $label \$(date '+%F %T') log=$log_file" > "$status_file"
        echo "[INFO] 升级任务成功: $label"
    else
        echo "FAILED $label \$(date '+%F %T') code=\$code log=$log_file" > "$status_file"
        echo "[ERROR] 升级任务失败: $label (exit=\$code)"
    fi
    rm -f "$pid_file" "$runner"
}
trap finish EXIT
echo "[INFO] 升级任务启动: $label (PID=\$\$)"
echo "[INFO] 日志文件: $log_file"
echo "RUNNING $label \$(date '+%F %T') log=$log_file pid=\$\$" > "$status_file"
$runner_script
echo "[INFO] 升级任务结束: $label"
RUNNER
    chmod 700 "$runner"

    if command -v screen >/dev/null 2>&1; then
        screen -dmS "$session" bash "$runner"
        log_info "已通过 screen 后台启动 ${label} 升级"
        log_info "查看会话: screen -r ${session}"
    else
        nohup bash "$runner" >/dev/null 2>&1 &
        log_info "未检测到 screen，已通过 nohup 后台启动 ${label} 升级"
    fi
    log_info "升级日志: ${log_file}"
    log_info "状态文件: ${status_file}"

    upgrade_job_initial_feedback "$component" "$label" "$log_file" "$status_file" "$pid_file"
}

upgrade_job_is_alive() {
    local pid_file="$1"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

upgrade_job_initial_feedback() {
    local component="$1" label="$2" log_file="$3" status_file="$4" pid_file="$5"
    local i=0
    # 等待 runner 写入 PID 与首行日志（最多 5 秒）
    while [[ $i -lt 10 ]]; do
        [[ -f "$pid_file" && -f "$log_file" ]] && break
        sleep 0.5
        i=$((i+1))
    done

    echo ""
    echo -e "${BLUE}================ ${label} 任务启动反馈 ================${NC}"
    if upgrade_job_is_alive "$pid_file"; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || echo "?")
        echo -e "  运行状态: ${GREEN}RUNNING${NC} (PID=${pid})"
    elif [[ -f "$status_file" ]]; then
        echo "  运行状态: $(cat "$status_file")"
    else
        echo -e "  运行状态: ${YELLOW}尚未写入 PID/状态，可能仍在初始化${NC}"
    fi
    echo ""
    echo "  实时跟踪: tail -f ${log_file}"
    echo "  快速查询: cat ${status_file}"
    echo "  菜单跟踪: 主菜单 → v → t（实时跟踪，Ctrl+C 仅退出查看）"
    echo ""
    echo -e "${BLUE}---------------- 当前日志（最后 20 行）----------------${NC}"
    if [[ -f "$log_file" ]]; then
        tail -n 20 "$log_file" 2>/dev/null || true
    else
        echo "  （日志尚未生成，稍候片刻可用上面的 tail 命令查看）"
    fi
    echo -e "${BLUE}-------------------------------------------------------${NC}"
}

tail_upgrade_log() {
    local status_dir="/var/log/xray-deploy"
    local latest_log component status_file pid_file

    if ! compgen -G "${status_dir}/upgrade-*.log" >/dev/null; then
        log_warn "暂无升级日志"
        return
    fi

    latest_log=$(ls -t "${status_dir}"/upgrade-*.log 2>/dev/null | head -1)
    component=$(basename "$latest_log" | sed -E 's/^upgrade-([^-]+)-.*\.log$/\1/')
    status_file="${status_dir}/upgrade-${component}.status"
    pid_file="${status_dir}/upgrade-${component}.pid"

    echo ""
    echo -e "${BLUE}================ 实时跟踪升级日志 ================${NC}"
    echo "  组件: ${component}"
    echo "  日志: ${latest_log}"
    [[ -f "$status_file" ]] && echo "  状态: $(cat "$status_file")"
    echo ""

    if upgrade_job_is_alive "$pid_file"; then
        echo -e "  ${GREEN}任务运行中${NC}，按 ${YELLOW}Ctrl+C${NC} 退出查看（不会终止后台任务）"
        echo ""
        sleep 1
        trap : INT
        tail -n 50 -f "$latest_log" || true
        trap - INT
        echo ""
        if [[ -f "$status_file" ]]; then
            echo "  最新状态: $(cat "$status_file")"
        fi
    else
        echo -e "  ${YELLOW}任务已结束${NC}，显示最终日志（最后 80 行）"
        echo ""
        tail -n 80 "$latest_log" 2>/dev/null || true
    fi
    echo ""
}

show_upgrade_status() {
    local status_dir="/var/log/xray-deploy"
    local status_file latest_log

    echo ""
    echo -e "${BLUE}================ 最近升级状态 ================${NC}"

    if compgen -G "${status_dir}/upgrade-*.status" >/dev/null; then
        for status_file in "${status_dir}"/upgrade-*.status; do
            [[ -f "$status_file" ]] || continue
            echo "  $(basename "$status_file" .status): $(cat "$status_file")"
        done
    else
        echo "  暂无升级状态文件"
    fi

    latest_log=$(ls -t "${status_dir}"/upgrade-*.log 2>/dev/null | head -1 || true)
    if [[ -n "$latest_log" ]]; then
        echo ""
        echo "  最新日志: ${latest_log}"
        echo "  查看命令: tail -n 80 ${latest_log}"
        echo ""
        tail -n 30 "$latest_log" 2>/dev/null || true
    fi
}

upgrade_status_label() {
    local current="$1" remote="$2"
    if [[ -z "$remote" ]]; then
        echo "远程未知"
    elif [[ -z "$current" ]]; then
        echo "未安装"
    elif [[ "$current" == "$remote" ]]; then
        echo "已最新"
    else
        echo "可升级"
    fi
}

upgrade_menu_line() {
    local idx="$1" label="$2" component="$3"
    local current remote status
    current=$(upgrade_command_version "$component")
    remote="${UPGRADE_REMOTE_VERSIONS[$component]:-}"
    status=$(upgrade_status_label "$current" "$remote")
    printf "  %s. %-11s 当前: %-10s 最新: %-10s [%s]\n" \
        "$idx" "$label" "${current:-未安装}" "${remote:-未知}" "$status"
}

do_upgrade_menu() {
    clear
    echo ""
    echo -e "${BLUE}================ 升级组件 ================${NC}"
    echo "  正在查询远程版本（5s 超时）..."
    upgrade_collect_remote_versions
    clear
    echo ""
    echo -e "${BLUE}================ 升级组件 ================${NC}"
    upgrade_menu_line 1 "Nginx"      nginx
    upgrade_menu_line 2 "Xray"       xray
    upgrade_menu_line 3 "Sing-Box"   singbox
    upgrade_menu_line 4 "Hysteria2"  hysteria2
    upgrade_menu_line 5 "NaiveProxy" naive
    echo "  6. 全部升级（仅升级有更新的组件）"
    echo "  l. 查看最近升级状态/日志"
    echo "  t. 实时跟踪最近一次升级（tail -f）"
    echo "  q. 返回主菜单"
    echo ""
    echo "  升级会在 screen 或 nohup 后台运行，SSH 断开不影响任务。"
    echo ""

    local upgrade_choice component
    read -rp "  请选择: " upgrade_choice
    echo ""

    case "$upgrade_choice" in
        1) component="nginx" ;;
        2) component="xray" ;;
        3) component="singbox" ;;
        4) component="hysteria2" ;;
        5) component="naive" ;;
        6) component="all" ;;
        l|L)
            show_upgrade_status
            done_return
            return
            ;;
        t|T)
            tail_upgrade_log
            done_return
            return
            ;;
        q|Q) return ;;
        *)
            log_error "无效选择"
            sleep 1
            return
            ;;
    esac

    if [[ "$component" == "all" ]]; then
        local pending=() c cur rem
        for c in nginx xray singbox hysteria2 naive; do
            cur=$(upgrade_command_version "$c")
            rem="${UPGRADE_REMOTE_VERSIONS[$c]:-}"
            if [[ -n "$rem" && -n "$cur" && "$cur" != "$rem" ]]; then
                pending+=("$c")
            fi
        done
        if [[ ${#pending[@]} -eq 0 ]]; then
            log_info "所有组件均已是最新版本"
            done_return
            return
        fi
        log_info "待升级: ${pending[*]}"
        local confirm
        read -rp "  确认升级以上组件？[y/N]: " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            done_return
            return
        fi
        for c in "${pending[@]}"; do
            start_upgrade_job "$c"
        done
        done_return
        return
    fi

    local current remote
    current=$(upgrade_command_version "$component")
    remote="${UPGRADE_REMOTE_VERSIONS[$component]:-}"
    if [[ -n "$remote" && -n "$current" && "$current" == "$remote" ]]; then
        local force
        read -rp "  ${component} 已是最新（${current}），强制重装？[y/N]: " force
        if [[ "${force,,}" != "y" ]]; then
            done_return
            return
        fi
    fi

    start_upgrade_job "$component"
    done_return
}

do_uninstall_menu() {
    clear
    echo ""
    echo -e "${BLUE}================ 清理 / 卸载 ================${NC}"
    echo "  1. 清理 System 优化"
    echo "  2. 清理 Unbound"
    echo "  3. 清理 Nginx"
    echo "  4. 清理证书 / Cloudflare 配置"
    echo "  5. 清理 Xray"
    echo "  6. 清理 Sing-Box"
    echo "  7. 清理 Hysteria2"
    echo "  8. 清理 NaiveProxy"
    echo "  9. 清理 Cloudflare WARP"
    echo "  10. 清理全部"
    echo "  q. 返回主菜单"
    echo ""
    read -rp "  请选择: " cleanup_choice
    echo ""

    load_module uninstall

    case "$cleanup_choice" in
        1) cleanup_system_module ;;
        2) cleanup_unbound_module ;;
        3) cleanup_nginx_module ;;
        4) cleanup_cert_module ;;
        5) cleanup_xray_module ;;
        6) cleanup_singbox_module ;;
        7) cleanup_hysteria2_module ;;
        8) cleanup_naive_module ;;
        9) cleanup_warp_module ;;
       10)
            read -rp "这会删除本脚本生成的大部分服务、配置和证书，确认继续吗？[y/N]: " confirm_cleanup
            if [[ "${confirm_cleanup,,}" != "y" ]]; then
                return
            fi
            cleanup_all_modules
            rm -f "$STATE_FILE"
            init_state
            ;;
        q|Q)
            ;;
        *)
            log_error "无效选择"
            sleep 1
            ;;
    esac
}

run_full_install_flow() {
    log_step "开始全流程安装..."
    echo ""

    load_module system
    run_kernel_upgrade
    save_state "INST_KERNEL" "1"
    run_system_optimize
    save_system_optimization_state

    load_module unbound
    restore_domain_arrays
    UNBOUND_SERVICE_NAME=$(get_state "UNBOUND_SERVICE_NAME")
    run_unbound
    save_state "HW_DUAL_STACK"        "${HW_DUAL_STACK:-}"
    save_state "UNBOUND_SERVICE_NAME" "${UNBOUND_SERVICE_NAME:-}"
    save_state "INST_UNBOUND"         "1"

    load_os_info
    load_module nginx
    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    save_state "INST_NGINX" "1"

    load_module cert
    run_cert
    save_state "XHTTP_DOMAIN"   "${XHTTP_DOMAIN:-}"
    save_state "GRPC_DOMAIN"    "${GRPC_DOMAIN:-}"
    save_state "REALITY_DOMAIN" "${REALITY_DOMAIN:-}"
    save_state "ANYTLS_DOMAIN"  "${ANYTLS_DOMAIN:-}"
    save_state "ALL_DOMAINS"    "${ALL_DOMAINS[*]:-}"
    save_state "CDN_DOMAINS"    "${CDN_DOMAINS[*]:-}"
    save_state "DIRECT_DOMAINS" "${DIRECT_DOMAINS[*]:-}"
    save_state "XHTTP_PATH"     "${XHTTP_PATH:-}"
    save_state "INST_CERT"      "1"



    restore_domain_arrays
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    if [[ -z "${XHTTP_PATH}" ]]; then
        XHTTP_PATH="/$(tr -d '-' < /proc/sys/kernel/random/uuid)"
        save_state "XHTTP_PATH" "${XHTTP_PATH}"
        log_info "生成 XHTTP_PATH: ${XHTTP_PATH}"
    else
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    fi

    load_module warp
    run_warp
    save_state "WGCF_PRIVATE_KEY"   "${WGCF_PRIVATE_KEY:-}"
    save_state "WGCF_PEER_PUBKEY"   "${WGCF_PEER_PUBKEY:-}"
    save_state "WGCF_ADDRESS"       "${WGCF_ADDRESS:-}"
    save_state "WGCF_ENDPOINT"      "${WGCF_ENDPOINT:-}"
    save_state "WGCF_ENDPOINT_HOST" "${WGCF_ENDPOINT_HOST:-}"
    save_state "WGCF_ENDPOINT_PORT" "${WGCF_ENDPOINT_PORT:-}"
    save_state "INST_WARP"          "1"
    save_state "CONF_WARP"          "1"

    load_module xray
    install_xray
    save_state "INST_XRAY" "1"

    XRAY_PADDING=$(get_state "XRAY_PADDING" "128-2048")
    XHTTP_PATH=$(get_state "XHTTP_PATH")
    if [[ -n "${XHTTP_PATH}" ]]; then
        log_info "复用已有 XHTTP_PATH: ${XHTTP_PATH}"
    fi
    generate_xray_params
    collect_reality_params
    generate_xray_config
    start_xray
    save_state "XRAY_UUID"            "${XRAY_UUID:-}"
    save_state "XRAY_PUBLIC_KEY"      "${XRAY_PUBLIC_KEY:-}"
    save_state "XRAY_PRIVATE_KEY"     "${XRAY_PRIVATE_KEY:-}"
    save_state "XHTTP_PATH"           "${XHTTP_PATH:-}"
    save_state "REALITY_DEST"         "${REALITY_DEST:-}"
    save_state "REALITY_SNI"          "${REALITY_SERVER_NAMES[0]:-}"
    save_state "REALITY_SERVER_NAMES" "${REALITY_SERVER_NAMES[*]:-}"
    save_state "REALITY_SHORT_IDS" "${REALITY_SHORT_IDS[*]:-}"
    save_state "REALITY_SHORT_ID"     "${REALITY_SHORT_IDS[1]:-}"
    save_state "REALITY_SPIDER_X"     "${REALITY_SPIDER_X:-}"
    save_state "CONF_XRAY"            "1"

    # nginx 在 xray 之后生成，确保 REALITY_SERVER_NAMES 已保存
    load_module nginx
    create_nginx_dirs
    generate_fake_site "/var/www/html" "Welcome"
    if [[ -n "${GRPC_DOMAIN:-}" ]]; then
        generate_fake_site "/var/www/${GRPC_DOMAIN}" "${GRPC_DOMAIN}"
    fi
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    generate_trap_cert
    generate_fallback_conf
    generate_servers_conf
    generate_nginx_conf
    reload_nginx
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater
    save_state "CONF_NGINX" "1"

    load_module singbox
    install_singbox
    save_state "INST_SINGBOX" "1"

    restore_domain_arrays
    ANYTLS_DOMAIN=$(get_state "ANYTLS_DOMAIN")
    HYSTERIA2_DOMAIN=$(get_state "HYSTERIA2_DOMAIN")
    NAIVE_DOMAIN=$(get_state "NAIVE_DOMAIN")
    generate_singbox_params
    collect_singbox_params
    generate_singbox_config
    start_singbox
    save_state "SINGBOX_PASSWORD" "${SINGBOX_PASSWORD:-}"
    save_state "ANYTLS_DOMAIN"     "${ANYTLS_DOMAIN:-}"
    save_state "CONF_SINGBOX"     "1"

    sync_refresh_nginx_routes "Sing-Box"

    log_info "全流程安装完成"
}

do_full_install() {
    run_full_install_flow
    done_return
}

# ── 重新配置（先清理配置再重新生成）─────────────────────
do_reconf_nginx() {
	read -rp "将清理 Nginx 配置并重新生成，确认继续吗？[y/N]: " c
	[[ "${c,,}" != "y" ]] && return

	load_module uninstall

	log_step "清理 Nginx 配置文件..."
	rm -f /etc/nginx/cloudflare_real_ip.conf
	rm -f /etc/nginx/conf.d/00-upstreams.conf
	rm -f /etc/nginx/conf.d/fallback.conf
	rm -f /etc/nginx/conf.d/servers.conf
	rm -f /etc/nginx/nginx.conf

	save_state "CONF_NGINX" "0"
	log_info "Nginx 配置清理完成，开始重新生成..."

	do_conf_nginx
}

do_reconf_xray() {
	read -rp "将清理 Xray 配置并重新生成，确认继续吗？[y/N]: " c
	[[ "${c,,}" != "y" ]] && return

	load_module uninstall

	log_step "清理 Xray 配置文件..."
	rm -f /usr/local/etc/xray/config.json

	save_state "XRAY_UUID"            ""
	save_state "XRAY_PUBLIC_KEY"      ""
	save_state "XRAY_PRIVATE_KEY"     ""
	save_state "REALITY_DEST"         ""
	save_state "REALITY_SNI"          ""
	save_state "REALITY_SERVER_NAMES" ""
	save_state "REALITY_SHORT_ID"     ""
	save_state "REALITY_SHORT_IDS"    ""
	save_state "REALITY_SPIDER_X"     ""
	save_state "CONF_XRAY" "0"
	log_info "Xray 配置清理完成，开始重新生成..."

	rm -f "${LOCAL_MODULES_DIR}/xray.sh"
	rm -f "${LOCAL_MODULES_DIR}/uninstall.sh"

	do_conf_xray
}

do_reconf_singbox() {
	read -rp "将清理 Sing-Box 配置并重新生成，确认继续吗？[y/N]: " c
	[[ "${c,,}" != "y" ]] && return

	load_module uninstall

	log_step "清理 Sing-Box 配置文件..."
	rm -f /etc/sing-box/config.json
	save_state "SINGBOX_PASSWORD" ""

	save_state "CONF_SINGBOX" "0"
	log_info "Sing-Box 配置清理完成，开始重新生成..."

	do_conf_singbox
}

do_selinux_mgmt() {
    clear
    echo ""
    echo -e "${BLUE}================ SELinux 管理 ================${NC}"
    echo ""

    if ! command -v getenforce >/dev/null 2>&1; then
        log_info "当前系统未安装 SELinux，无需管理"
        echo ""
        read -rp "按回车返回主菜单..." _
        return
    fi

    local status
    status=$(getenforce 2>/dev/null || echo "Unknown")
    echo "  当前 SELinux 状态: ${status}"

    local ports_ok=true
    if command -v semanage >/dev/null 2>&1; then
        local existing
        existing=$(semanage port -l 2>/dev/null | grep '^http_port_t' || true)
        local ports=(8380 8390 8400 8360 8320 8330)
        for port in "${ports[@]}"; do
            if ! echo "$existing" | grep -qw "\\b${port}\\b"; then
                echo "  ! 端口 ${port}/tcp 缺少 http_port_t 标签"
                ports_ok=false
            fi
        done
        $ports_ok && echo "  端口标签: 已全部配置"
    else
        echo "  ! semanage 不可用，无法检查端口标签"
        ports_ok=false
    fi

    local bool_ok=true
    if command -v getsebool >/dev/null 2>&1; then
        local hcc
        hcc=$(getsebool httpd_can_network_connect 2>/dev/null | awk '{print $NF}')
        if [[ "$hcc" != "on" ]]; then
            echo "  ! httpd_can_network_connect = ${hcc:-unknown}"
            bool_ok=false
        else
            echo "  httpd_can_network_connect: on"
        fi
    fi

    echo ""

    case "$status" in
        Enforcing)
            echo "  1. 切换到 Permissive 模式"
            echo "  q. 返回主菜单"
            echo ""
            read -rp "  请选择 [1/q]: " mgmt_choice
            case "${mgmt_choice:-}" in
                1)
                    setenforce 0 2>/dev/null && \
                        log_info "已切换到 Permissive 模式" || \
                        log_error "切换失败"
                    ;;
            esac
            ;;
        Permissive)
            if $ports_ok && $bool_ok; then
                echo "  1. 切换到 Enforcing 模式（策略已就绪）"
                echo "  q. 返回主菜单"
                echo ""
                read -rp "  请选择 [1/q]: " mgmt_choice
                case "${mgmt_choice:-}" in
                    1)
                        setenforce 1 2>/dev/null && \
                            log_info "已切换到 Enforcing 模式" || \
                            log_error "切换失败"
                        ;;
                esac
            else
                echo "  1. 切换到 Enforcing 模式（策略不完整，不建议）"
                echo "  2. 先修复缺失的 SELinux 策略再切换"
                echo "  q. 返回主菜单"
                echo ""
                read -rp "  请选择: " mgmt_choice
                case "${mgmt_choice:-}" in
                    1)
                        log_warn "端口标签或布尔值不完整，强制切换 Enforcing 可能导致服务异常"
                        read -rp "确认切换？[y/N]: " c
                        if [[ "${c,,}" == "y" ]]; then
                            setenforce 1 2>/dev/null && \
                                log_info "已切换到 Enforcing 模式" || \
                                log_error "切换失败"
                        fi
                        ;;
                    2)
                        load_module system
                        setup_selinux_policy
                        log_info "策略修复完成，请重新选择切换"
                        sleep 1
                        do_selinux_mgmt
                        return
                        ;;
                esac
            fi
            ;;
        Disabled)
            log_info "SELinux 已完全禁用，无需管理"
            ;;
    esac

    echo ""
    read -rp "按回车返回主菜单..." _
    return
}

do_reinstall_all() {
    read -rp "这会先清理全部，再重新执行完整安装流程，确认继续吗？[y/N]: " reinstall_all
    if [[ "${reinstall_all,,}" != "y" ]]; then
        return
    fi

    load_module uninstall
    cleanup_all_modules
    rm -f "$STATE_FILE"
    init_state
    run_full_install_flow
}

# ── 主循环 ─────────────────────────────────────────────────
main_menu_loop() {
    while true; do
        clear
        echo ""
        echo -e "${BLUE}==========================================${NC}"
        echo -e "${BLUE}   Xray + Nginx + Sing-Box 部署工具${NC}"
        echo -e "${BLUE}   GitHub: cctvhd/xray-nginx-deploy${NC}"
        echo -e "${BLUE}==========================================${NC}"

        show_status

        echo "  === 安装 ==="
        echo "  1. 升级内核"
        echo "  2. 优化系统"
        echo "  3. 安装并配置 Unbound"
        echo "  4. 安装 Nginx"
        echo "  5. 申请 SSL 证书"
        echo "  6. 安装 Xray"
        echo "  7. 安装 Sing-Box"
        echo "  8. 安装 Hysteria2"
        echo "  9. 安装 NaiveProxy"
        echo ""
        echo "  === 配置 ==="
        echo "  10. 配置 Nginx"
        echo "  11. 配置 Xray"
        echo "  12. 配置 Sing-Box"
        echo "  13. 配置 Hysteria2"
        echo "  14. 配置 NaiveProxy"
        echo " n. 重新配置 Nginx（先清理再生成）"
        echo " x. 重新配置 Xray（先清理再生成）"
        echo " g. 重新配置 Sing-Box（先清理再生成）"
        echo " h. 重新配置 Hysteria2（先清理再生成）"
        echo " i. 重新配置 NaiveProxy（先清理再生成）"
        echo ""
        echo "  === 其他 ==="
        echo "  a. 生成客户端链接"
        echo "  k. 重置所有节点凭据并生成新订阅"
        echo "  b. 查看当前状态"
        echo "  c. 检查配置健康（preflight）"
        echo "  s. 同步/更新模块到本地缓存"
        echo "  v. 升级组件（后台运行）"
        echo "  w. 配置 WARP WireGuard 凭证（步骤 11/12 的前置依赖）"
        echo "  u. 卸载 / 清理模块"
        echo "  p. SELinux 管理"
        echo "  r. 全部重装（先清理再执行全流程）"
        echo "  0. 全流程一键安装（含内核升级与系统优化）"
        echo "  q. 退出"
        echo ""
        echo -e "  再次运行: ${CYAN}bash <(curl -fsSL ${BASE_URL}/install.sh)${NC}"
        echo ""
        read -rp "  请选择: " choice
        echo ""

        case "$choice" in
            1) run_menu_action "内核升级"          do_upgrade_kernel ;;
            2) run_menu_action "系统优化"          do_optimize_system ;;
            3) run_menu_action "安装 Unbound"      do_inst_unbound ;;
            4) run_menu_action "安装 Nginx"        do_inst_nginx ;;
            5) run_menu_action "申请证书"          do_inst_cert ;;
            6) run_menu_action "安装 Xray"         do_inst_xray ;;
            7) run_menu_action "安装 Sing-Box"     do_inst_singbox ;;
            8) run_menu_action "安装 Hysteria2"    do_inst_hysteria2 ;;
            9) run_menu_action "安装 NaiveProxy"   do_inst_naive ;;
           10) run_menu_action "配置 Nginx"        do_conf_nginx ;;
           11) run_menu_action "配置 Xray"         do_conf_xray ;;
           12) run_menu_action "配置 Sing-Box"     do_conf_singbox ;;
           13) run_menu_action "配置 Hysteria2"    do_conf_hysteria2 ;;
           14) run_menu_action "配置 NaiveProxy"   do_conf_naive ;;
          n|N) run_menu_action "重新配置 Nginx"      do_reconf_nginx ;;
          x|X) run_menu_action "重新配置 Xray"       do_reconf_xray ;;
          g|G) run_menu_action "重新配置 Sing-Box"   do_reconf_singbox ;;
          h|H) run_menu_action "重新配置 Hysteria2"  do_reconf_hysteria2 ;;
          i|I) run_menu_action "重新配置 NaiveProxy" do_reconf_naive ;;
            a|A) run_menu_action "生成客户端链接"   do_client ;;
            k|K) run_menu_action "重置所有节点凭据并生成新订阅" do_reset_client_credentials ;;
            b|B)
                run_menu_action "查看状态" show_status
                read -rp "按回车返回主菜单..." _
                ;;
            c|C) run_menu_action "配置健康检查"   do_preflight_report ;;
            s|S) run_menu_action "同步模块"        do_sync_modules ;;
            v|V) run_menu_action "升级组件"        do_upgrade_menu ;;
            w|W) run_menu_action "配置 WARP"       do_warp ;;
            u|U) run_menu_action "卸载/清理"       do_uninstall_menu ;;
            p|P) run_menu_action "SELinux 管理"    do_selinux_mgmt ;;
            r|R) run_menu_action "全部重装"        do_reinstall_all ;;
            0) run_menu_action "一键安装"          run_full_install_flow ;;
            q|Q) exit 0 ;;
            *)
                log_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

if [[ "${1:-}" == "--upgrade-component" ]]; then
    check_root
    acquire_upgrade_lock
    init_state
    run_upgrade_component "${2:-}"
    exit 0
fi

check_root
acquire_lock
init_state
main_menu_loop
