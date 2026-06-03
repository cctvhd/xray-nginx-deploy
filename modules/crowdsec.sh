#!/usr/bin/env bash
# ============================================================
# modules/crowdsec.sh
# CrowdSec 安装、配置与更新
# ============================================================

_crowdsec_os_family() {
    local os_id os_like
    os_id=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
    os_like=$(grep "^ID_LIKE=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')

    case "$os_id" in
        debian|ubuntu) echo "debian"; return ;;
        rhel|centos|rocky|almalinux|fedora) echo "rhel"; return ;;
    esac
    if echo "$os_like" | grep -qiE 'debian|ubuntu'; then
        echo "debian"
    elif echo "$os_like" | grep -qiE 'rhel|fedora|centos'; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

_crowdsec_pkg_installed() {
    local pkg="$1"
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
    elif command -v rpm >/dev/null 2>&1; then
        rpm -q "$pkg" >/dev/null 2>&1
    else
        return 1
    fi
}

_crowdsec_install_pkg() {
    local pkg="$1"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg"
    else
        log_error "未找到支持的包管理器，无法安装 ${pkg}"
        return 1
    fi
}

_crowdsec_update_pkgs() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install --only-upgrade -y crowdsec crowdsec-firewall-bouncer-nftables || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf upgrade -y crowdsec crowdsec-firewall-bouncer-nftables || true
    elif command -v yum >/dev/null 2>&1; then
        yum update -y crowdsec crowdsec-firewall-bouncer-nftables || true
    fi
}

_crowdsec_ensure_repo() {
    local family repo_file
    family=$(_crowdsec_os_family)

    if ! curl -fsS --max-time 8 https://packagecloud.io >/dev/null 2>&1; then
        log_error "无法访问 packagecloud.io，请检查网络或代理"
        return 1
    fi

    case "$family" in
        debian)
            repo_file="/etc/apt/sources.list.d/crowdsec_crowdsec.list"
            if [[ -f "$repo_file" ]] || grep -Rqs "packagecloud.io/crowdsec/crowdsec" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
                log_info "CrowdSec apt 仓库已存在"
            else
                log_step "添加 CrowdSec apt 仓库..."
                curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
            fi
            apt-get update -qq >/dev/null 2>&1 || true
            ;;
        rhel)
            repo_file="/etc/yum.repos.d/crowdsec_crowdsec.repo"
            if [[ -f "$repo_file" ]] || grep -Rqs "packagecloud.io/crowdsec/crowdsec" /etc/yum.repos.d 2>/dev/null; then
                log_info "CrowdSec rpm 仓库已存在"
            else
                log_step "添加 CrowdSec rpm 仓库..."
                curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.rpm.sh | bash
            fi
            ;;
        *)
            log_error "暂不支持的发行版，无法自动添加 CrowdSec 仓库"
            return 1
            ;;
    esac
}

_crowdsec_bouncer_conf() {
    local candidate
    for candidate in \
        /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml \
        /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yml \
        /etc/crowdsec/bouncers/crowdsec-firewall-bouncer-nftables.yaml \
        /etc/crowdsec/bouncers/crowdsec-firewall-bouncer-nftables.yml; do
        [[ -f "$candidate" ]] && { echo "$candidate"; return; }
    done
    find /etc/crowdsec/bouncers -maxdepth 1 -type f \( -name '*firewall*bouncer*.yaml' -o -name '*firewall*bouncer*.yml' \) -print 2>/dev/null | sort | head -1
}

_crowdsec_set_yaml_key() {
    local file="$1" key="$2" value="$3"
    if grep -qiE "^[[:space:]]*${key}:" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}:.*|${key}: ${value}|I" "$file"
    else
        printf '\n%s: %s\n' "$key" "$value" >> "$file"
    fi
}

_crowdsec_enable_bouncer_ipv6() {
    local file="$1"
    python3 - "$file" <<'PY' 2>/dev/null || true
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
pattern = re.compile(r"(^\s*ipv6:\s*\n(?:^[ \t]+.*\n?)*)", re.M)
match = pattern.search(text)
if not match:
    path.write_text(text.rstrip() + "\n\nipv6:\n  enabled: true\n")
    sys.exit(0)

block = match.group(1)
if re.search(r"(?im)^\s+enabled\s*:", block):
    block = re.sub(r"(?im)^(\s+enabled\s*:\s*).*$", r"\g<1>true", block)
else:
    block = block.rstrip() + "\n  enabled: true\n"
path.write_text(text[:match.start(1)] + block + text[match.end(1):])
PY
}

_crowdsec_configure_bouncer() {
    local conf ipv6_support
    conf=$(_crowdsec_bouncer_conf)
    if [[ -z "$conf" ]]; then
        log_error "未找到 CrowdSec firewall bouncer 配置文件"
        return 1
    fi

    [[ -f "$conf" ]] && cp -f "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
    _crowdsec_set_yaml_key "$conf" "mode" "nftables"

    ipv6_support="false"
    [[ -n "$(ip -6 addr show scope global 2>/dev/null)" ]] && ipv6_support="true"
    if [[ "$ipv6_support" == "true" ]]; then
        _crowdsec_enable_bouncer_ipv6 "$conf"
    fi

    log_info "Bouncer 配置文件: ${conf}"
    log_info "Bouncer 模式: nftables | IPv6: ${ipv6_support}"
    save_state "CROWDSEC_BOUNCER_CONF" "$conf"
    save_state "CROWDSEC_BOUNCER_IPV6" "$ipv6_support"
}

_crowdsec_acquis_target() {
    if [[ -d /etc/crowdsec/acquis.d ]]; then
        echo "/etc/crowdsec/acquis.d/xray-nginx-deploy-nginx.yaml"
    else
        echo "/etc/crowdsec/acquis.yaml"
    fi
}

_crowdsec_detect_nginx_logs() {
    local candidate logpath logs=()
    for candidate in \
        /var/log/nginx/access.log \
        /var/log/nginx/error.log \
        /usr/local/nginx/logs/access.log \
        /usr/local/nginx/logs/error.log; do
        [[ -f "$candidate" ]] && logs+=("$candidate")
    done

    if command -v nginx >/dev/null 2>&1; then
        while IFS= read -r logpath; do
            [[ -z "$logpath" ]] && continue
            [[ " ${logs[*]} " == *" ${logpath} "* ]] || logs+=("$logpath")
        done < <(nginx -T 2>/dev/null \
            | awk '/^[[:space:]]*(access_log|error_log)[[:space:]]+/ { print $2 }' \
            | sed 's/;//;s/^stderr$//;s/^off$//' \
            | grep '^/' \
            | sort -u)
    fi

    printf '%s\n' "${logs[@]}"
}

_crowdsec_write_nginx_acquis() {
    local target="$1" logs=("$@") log
    logs=("${logs[@]:1}")
    (( ${#logs[@]} > 0 )) || return 0

    mkdir -p "$(dirname "$target")"
    [[ -f "$target" ]] && cp -f "$target" "${target}.bak.$(date +%Y%m%d%H%M%S)"
    {
        echo "---"
        echo "filenames:"
        for log in "${logs[@]}"; do
            echo "  - ${log}"
        done
        echo "labels:"
        echo "  type: nginx"
    } > "$target"
    log_info "已写入 nginx acquis: ${target}"
    save_state "CROWDSEC_NGINX_ACQUIS" "$target"
}

_crowdsec_install_collections() {
    local col collections=(crowdsecurity/linux crowdsecurity/sshd)
    if command -v nginx >/dev/null 2>&1 || [[ "$(get_step CONF_NGINX)" == "1" ]]; then
        collections+=(crowdsecurity/nginx)
    fi

    cscli hub update
    for col in "${collections[@]}"; do
        log_step "安装/更新 collection: ${col}"
        cscli collections install "$col" 2>/dev/null || cscli collections upgrade "$col" 2>/dev/null || true
    done
}

_crowdsec_configure_nginx_acquis_interactive() {
    local target logs=() input
    mapfile -t logs < <(_crowdsec_detect_nginx_logs)
    if (( ${#logs[@]} == 0 )); then
        log_warn "未检测到 nginx 日志文件，nginx 就绪后可重新运行 CrowdSec 配置"
        return 0
    fi

    log_info "检测到 nginx 日志路径:"
    printf '  %s\n' "${logs[@]}"
    read -rp "是否写入 CrowdSec nginx 日志采集配置？[Y/n]: " input
    [[ "${input,,}" == "n" ]] && return 0

    target=$(_crowdsec_acquis_target)
    _crowdsec_write_nginx_acquis "$target" "${logs[@]}"
}

_crowdsec_enroll_console_interactive() {
    local input key
    echo ""
    log_info "CrowdSec 控制台注册地址: https://app.crowdsec.net"
    read -rp "是否现在注册到 CrowdSec 控制台？[y/N]: " input
    [[ "${input,,}" == "y" ]] || return 0
    read -rp "请粘贴 Enrollment Key: " key
    if [[ -z "$key" ]]; then
        log_warn "未输入 enrollment key，跳过注册"
        return 0
    fi
    cscli console enroll "$key" || {
        log_warn "注册失败，稍后可手动执行: cscli console enroll <your-enrollment-key>"
        return 0
    }
    log_info "注册成功，请到 CrowdSec 控制台 Accept 该 Security Engine"
}

_crowdsec_verify() {
    local svc
    for svc in crowdsec crowdsec-firewall-bouncer; do
        if systemctl is-active --quiet "$svc"; then
            log_info "${svc}: active"
        else
            log_warn "${svc}: inactive"
        fi
    done
    cscli bouncers list 2>/dev/null || true
    cscli collections list 2>/dev/null || true
    cscli decisions list 2>/dev/null || true
    nft list ruleset 2>/dev/null | grep -A5 -i "crowdsec" || log_warn "暂无 crowdsec nftables 规则，等待决策生效后会出现"
}

run_crowdsec_install_config() {
    log_step "========== CrowdSec 安装与配置 =========="

    if ! systemctl is-active --quiet nftables 2>/dev/null; then
        log_warn "nftables 未运行，建议先执行 nftables 防火墙安装/配置"
    fi

    _crowdsec_ensure_repo

    if _crowdsec_pkg_installed "crowdsec"; then
        log_info "CrowdSec 已安装"
    else
        _crowdsec_install_pkg "crowdsec"
    fi

    if _crowdsec_pkg_installed "crowdsec-firewall-bouncer-nftables"; then
        log_info "CrowdSec nftables bouncer 已安装"
    else
        _crowdsec_install_pkg "crowdsec-firewall-bouncer-nftables"
    fi

    systemctl enable --now crowdsec
    _crowdsec_configure_bouncer
    systemctl enable --now crowdsec-firewall-bouncer
    _crowdsec_install_collections
    _crowdsec_configure_nginx_acquis_interactive
    systemctl restart crowdsec
    systemctl restart crowdsec-firewall-bouncer
    _crowdsec_enroll_console_interactive
    _crowdsec_verify

    save_state "INST_CROWDSEC" "1"
    save_state "CONF_CROWDSEC" "1"
    log_info "CrowdSec 安装配置完成"
}

run_crowdsec_update() {
    log_step "========== CrowdSec 更新 =========="

    if ! _crowdsec_pkg_installed "crowdsec" || ! _crowdsec_pkg_installed "crowdsec-firewall-bouncer-nftables"; then
        log_warn "CrowdSec 或 nftables bouncer 未安装，转入安装/配置流程"
        run_crowdsec_install_config
        return
    fi

    _crowdsec_ensure_repo
    _crowdsec_update_pkgs
    _crowdsec_configure_bouncer
    _crowdsec_install_collections
    _crowdsec_configure_nginx_acquis_interactive
    cscli hub update
    cscli hub upgrade || true
    systemctl restart crowdsec
    systemctl restart crowdsec-firewall-bouncer
    _crowdsec_verify

    save_state "INST_CROWDSEC" "1"
    save_state "CONF_CROWDSEC" "1"
    log_info "CrowdSec 更新完成"
}
