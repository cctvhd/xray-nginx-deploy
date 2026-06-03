#!/usr/bin/env bash
# ============================================================
# modules/security.sh
# SSH 登录安全检查与加固
# ============================================================

_security_ssh_service() {
    if systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        echo "sshd"
    elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

_security_sshd_config_test() {
    if command -v sshd >/dev/null 2>&1; then
        sshd -t
    elif [[ -x /usr/sbin/sshd ]]; then
        /usr/sbin/sshd -t
    else
        log_error "未找到 sshd 命令，无法验证 SSH 配置"
        return 1
    fi
}

_security_sshd_effective_config() {
    if command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null
    elif [[ -x /usr/sbin/sshd ]]; then
        /usr/sbin/sshd -T 2>/dev/null
    else
        return 1
    fi
}

_security_sshd_effective_value() {
    local key="$1"
    awk -v k="$key" '$1 == k { $1=""; sub(/^ /, ""); print; exit }' <<< "${SSHD_EFFECTIVE_CONFIG:-}"
}

_security_current_ssh_ports() {
    local ports effective_ports
    effective_ports=$(awk '$1 == "port" { print $2 }' <<< "${SSHD_EFFECTIVE_CONFIG:-}" \
        | sort -n -u \
        | tr '\n' ' ' \
        | sed 's/[[:space:]]*$//')
    if [[ -n "$effective_ports" ]]; then
        echo "$effective_ports"
        return
    fi

    ports=$(ss -tlnp 2>/dev/null \
        | awk '/sshd|ssh/{print $4}' \
        | grep -oE '[0-9]+$' \
        | sort -n -u \
        | tr '\n' ' ' \
        | sed 's/[[:space:]]*$//')
    [[ -n "$ports" ]] && echo "$ports" || echo "22"
}

_security_validate_ports() {
    local port
    for port in $1; do
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        (( port >= 1 && port <= 65535 )) || return 1
    done
}

_security_has_authorized_key() {
    local path
    if (( ${#SECURITY_AUTHORIZED_KEY_FILES[@]} == 0 )); then
        SECURITY_AUTHORIZED_KEY_FILES=("/root/.ssh/authorized_keys")
    fi
    for path in "${SECURITY_AUTHORIZED_KEY_FILES[@]}"; do
        [[ -s "$path" ]] && return 0
    done
    return 1
}

_security_root_authorized_key_files() {
    local configured="${1:-}" entry expanded
    configured="${configured:-.ssh/authorized_keys}"

    SECURITY_AUTHORIZED_KEY_FILES=()
    for entry in $configured; do
        case "$entry" in
            AuthorizedKeysCommand*) continue ;;
            none) continue ;;
            ./*) expanded="/root/${entry#./}" ;;
            /*) expanded="$entry" ;;
            *) expanded="/root/$entry" ;;
        esac
        SECURITY_AUTHORIZED_KEY_FILES+=("$expanded")
    done

    if (( ${#SECURITY_AUTHORIZED_KEY_FILES[@]} == 0 )); then
        SECURITY_AUTHORIZED_KEY_FILES=("/root/.ssh/authorized_keys")
    fi
}

_security_primary_authorized_key_file() {
    echo "${SECURITY_AUTHORIZED_KEY_FILES[0]:-/root/.ssh/authorized_keys}"
}

_security_ensure_dropin_include() {
    local main_conf="/etc/ssh/sshd_config"
    [[ -f "$main_conf" ]] || return 0

    if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main_conf"; then
        return 0
    fi

    cp -f "$main_conf" "${main_conf}.bak.$(date +%Y%m%d%H%M%S)"
    {
        echo "Include /etc/ssh/sshd_config.d/*.conf"
        sed '/^[[:space:]]*Include[[:space:]]\+\/etc\/ssh\/sshd_config\.d\/\*\.conf/I d' "$main_conf"
    } > "${main_conf}.tmp.$$"
    mv -f "${main_conf}.tmp.$$" "$main_conf"
    log_info "已在 ${main_conf} 启用 sshd_config.d drop-in"
}

_security_managed_directives() {
    cat <<'EOF'
port
pubkeyauthentication
authorizedkeysfile
authenticationmethods
permitrootlogin
passwordauthentication
kbdinteractiveauthentication
challengeresponseauthentication
hostbasedauthentication
permitemptypasswords
gssapiauthentication
usepam
clientaliveinterval
clientalivecountmax
x11forwarding
gatewayports
allowagentforwarding
allowtcpforwarding
maxauthtries
logingracetime
maxsessions
maxstartups
permittunnel
allowstreamlocalforwarding
addressfamily
listenaddress
tcpkeepalive
kexalgorithms
ciphers
macs
strictmodes
ignorerhosts
printmotd
printlastlog
banner
syslogfacility
loglevel
EOF
}

_security_managed_directives_regex() {
    _security_managed_directives | paste -sd'|' -
}

_security_dropin_files() {
    local dropin_dir="$1"
    [[ -d "$dropin_dir" ]] || return 0
    find "$dropin_dir" -maxdepth 1 -type f -name "*.conf" -print 2>/dev/null | sort
}

_security_dropin_conflicts() {
    local target="$1" dropin_dir file keys
    dropin_dir=$(dirname "$target")
    keys=$(_security_managed_directives_regex)

    while IFS= read -r file; do
        [[ "$file" == "$target" ]] && continue
        awk -v keys="$keys" '
            BEGIN {
                split(keys, items, "|")
                for (i in items) managed[items[i]] = 1
            }
            /^[[:space:]]*($|#)/ { next }
            {
                key = tolower($1)
                if (managed[key]) {
                    print FILENAME ":" FNR ": " $0
                }
            }
        ' "$file"
    done < <(_security_dropin_files "$dropin_dir")
}

_security_comment_conflicting_dropins() {
    local target="$1" dropin_dir file keys tmp changed total=0
    dropin_dir=$(dirname "$target")
    keys=$(_security_managed_directives_regex)

    while IFS= read -r file; do
        [[ "$file" == "$target" ]] && continue
        changed=0
        tmp="${file}.tmp.$$"
        awk -v keys="$keys" '
            BEGIN {
                split(keys, items, "|")
                for (i in items) managed[items[i]] = 1
            }
            /^[[:space:]]*($|#)/ { print; next }
            {
                key = tolower($1)
                if (managed[key]) {
                    print "# disabled by xray-nginx-deploy security module: " $0
                    changed = 1
                    next
                }
                print
            }
            END { exit changed ? 10 : 0 }
        ' "$file" > "$tmp" || changed=$?

        if [[ "$changed" == "10" ]]; then
            cp -f "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
            mv -f "$tmp" "$file"
            log_info "已注释冲突项: ${file}"
            total=$((total + 1))
        else
            rm -f "$tmp"
        fi
    done < <(_security_dropin_files "$dropin_dir")

    (( total > 0 )) && log_info "已处理 ${total} 个 SSH drop-in 配置文件"
}

_security_latest_backup() {
    local pattern="$1" latest=""
    while IFS= read -r backup; do
        latest="$backup"
        break
    done < <(find "$(dirname "$pattern")" -maxdepth 1 -type f -name "$(basename "$pattern")" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | awk '{print $2}')
    [[ -n "$latest" ]] && echo "$latest"
}

_security_add_authorized_key_interactive() {
    local key key_file key_dir
    key_file=$(_security_primary_authorized_key_file)
    key_dir=$(dirname "$key_file")
    mkdir -p "$key_dir"
    chmod 700 "$key_dir"

    echo ""
    log_warn "未检测到 root 可用 SSH 公钥。"
    log_info "将写入: ${key_file}"
    read -rp "是否现在粘贴一个 SSH 公钥？[y/N]: " add_key
    [[ "${add_key,,}" != "y" ]] && return 1

    echo "请粘贴单行公钥（推荐 ssh-ed25519 AAAA... comment）："
    read -r key
    if [[ ! "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]+ ]]; then
        log_error "公钥格式看起来不正确，已取消写入"
        return 1
    fi
    if [[ "$key" == ssh-rsa* ]]; then
        log_warn "检测到 ssh-rsa 公钥；建议优先使用 ED25519 新密钥"
    fi

    touch "$key_file"
    chmod 600 "$key_file"
    if grep -qxF "$key" "$key_file"; then
        log_info "该公钥已存在，跳过追加"
    else
        printf '%s\n' "$key" >> "$key_file"
        log_info "公钥已追加到 ${key_file}"
    fi
}

run_security_ssh() {
    log_step "========== SSH 登录安全检查与加固 =========="

    local service current_ports ssh_ports root_login allow_forward gateway_ports permit_tunnel alive_interval
    local current_root_login current_password_auth current_pubkey_auth current_auth_keys
    local current_allow_forward current_gateway_ports current_permit_tunnel current_alive_interval conflicts
    service=$(_security_ssh_service)
    SSHD_EFFECTIVE_CONFIG=$(_security_sshd_effective_config || true)
    current_ports=$(_security_current_ssh_ports)
    current_root_login=$(_security_sshd_effective_value "permitrootlogin")
    current_password_auth=$(_security_sshd_effective_value "passwordauthentication")
    current_pubkey_auth=$(_security_sshd_effective_value "pubkeyauthentication")
    current_auth_keys=$(_security_sshd_effective_value "authorizedkeysfile")
    current_allow_forward=$(_security_sshd_effective_value "allowtcpforwarding")
    current_gateway_ports=$(_security_sshd_effective_value "gatewayports")
    current_permit_tunnel=$(_security_sshd_effective_value "permittunnel")
    current_alive_interval=$(_security_sshd_effective_value "clientaliveinterval")
    _security_root_authorized_key_files "$current_auth_keys"

    echo ""
    log_info "SSH 服务: ${service}.service"
    log_info "当前监听端口: ${current_ports}"
    log_info "当前 root 登录策略: ${current_root_login:-unknown}"
    log_info "当前密码登录: ${current_password_auth:-unknown} | 公钥登录: ${current_pubkey_auth:-unknown}"
    log_info "当前 AuthorizedKeysFile: ${current_auth_keys:-.ssh/authorized_keys}"
    log_info "root 密钥检查路径: ${SECURITY_AUTHORIZED_KEY_FILES[*]}"
    read -rp "SSH 端口（多个用空格分隔）[默认: ${current_ports}]: " ssh_ports
    ssh_ports="${ssh_ports:-$current_ports}"
    if ! _security_validate_ports "$ssh_ports"; then
        log_error "SSH 端口格式无效: ${ssh_ports}"
        return 1
    fi

    if ! _security_has_authorized_key; then
        _security_add_authorized_key_interactive || {
            log_warn "没有确认可用 SSH 公钥，本次不会禁用密码登录或重启 sshd。"
            save_state "SSH_PORTS" "$ssh_ports"
            save_state "CONF_SECURITY_SSH" "0"
            return 0
        }
    fi

    if ! _security_has_authorized_key; then
        log_warn "authorized_keys 仍为空，本次不会写入加固配置。"
        save_state "SSH_PORTS" "$ssh_ports"
        save_state "CONF_SECURITY_SSH" "0"
        return 0
    fi

    echo ""
    echo "Root 登录策略:"
    echo "  1. prohibit-password（推荐，仅允许密钥登录）"
    echo "  2. no（完全禁止 root 登录）"
    echo "  3. 保持当前值 (${current_root_login:-prohibit-password})"
    read -rp "输入序号 [1-3，默认 1]: " root_choice
    case "${root_choice:-1}" in
        2) root_login="no" ;;
        3) root_login="${current_root_login:-prohibit-password}" ;;
        *) root_login="prohibit-password" ;;
    esac

    read -rp "是否允许 TCP/Agent 转发？代理场景建议保留 [Y/n/keep]: " forward_choice
    case "${forward_choice,,}" in
        n) allow_forward="no" ;;
        keep|k) allow_forward="${current_allow_forward:-yes}" ;;
        *) allow_forward="yes" ;;
    esac

    read -rp "是否允许远程转发绑定非 loopback？[y/N/keep]: " gateway_choice
    case "${gateway_choice,,}" in
        y) gateway_ports="yes" ;;
        keep|k) gateway_ports="${current_gateway_ports:-no}" ;;
        *) gateway_ports="no" ;;
    esac

    read -rp "是否允许 SSH tun 隧道？[y/N/keep]: " tunnel_choice
    case "${tunnel_choice,,}" in
        y) permit_tunnel="yes" ;;
        keep|k) permit_tunnel="${current_permit_tunnel:-no}" ;;
        *) permit_tunnel="no" ;;
    esac

    read -rp "ClientAliveInterval 秒数 [默认: ${current_alive_interval:-60}]: " alive_interval
    alive_interval="${alive_interval:-${current_alive_interval:-60}}"
    if ! [[ "$alive_interval" =~ ^[0-9]+$ ]] || (( alive_interval < 30 )); then
        log_error "ClientAliveInterval 必须是 >= 30 的数字"
        return 1
    fi

    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin="${dropin_dir}/99-xray-deploy-security.conf"
    mkdir -p "$dropin_dir"
    _security_ensure_dropin_include

    conflicts=$(_security_dropin_conflicts "$dropin")
    if [[ -n "$conflicts" ]]; then
        echo ""
        log_warn "检测到 sshd_config.d 中存在与本模块冲突的指令，将自动注销这些配置项并备份原文件。"
        printf '%s\n' "$conflicts"
        _security_comment_conflicting_dropins "$dropin"
    fi

    [[ -f "$dropin" ]] && cp -f "$dropin" "${dropin}.bak.$(date +%Y%m%d%H%M%S)"

    {
        echo "# Auto-generated by xray-nginx-deploy security module"
        for port in $ssh_ports; do
            echo "Port ${port}"
        done
        echo "AddressFamily inet"
        echo "ListenAddress 0.0.0.0"
        echo "PubkeyAuthentication yes"
        echo "AuthorizedKeysFile ${current_auth_keys:-.ssh/authorized_keys}"
        echo "AuthenticationMethods publickey"
        echo "PermitRootLogin ${root_login}"
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "ChallengeResponseAuthentication no"
        echo "HostbasedAuthentication no"
        echo "PermitEmptyPasswords no"
        echo "GSSAPIAuthentication no"
        echo "UsePAM yes"
        echo "ClientAliveInterval ${alive_interval}"
        echo "ClientAliveCountMax 10"
        echo "X11Forwarding no"
        echo "GatewayPorts ${gateway_ports}"
        echo "AllowAgentForwarding ${allow_forward}"
        echo "AllowTcpForwarding ${allow_forward}"
        echo "MaxAuthTries 3"
        echo "LoginGraceTime 30"
        echo "MaxSessions 3"
        echo "MaxStartups 3:30:10"
        echo "PermitTunnel ${permit_tunnel}"
        echo "AllowStreamLocalForwarding no"
        echo "StrictModes yes"
        echo "IgnoreRhosts yes"
        echo "TCPKeepAlive yes"
        echo "PrintMotd no"
        echo "PrintLastLog yes"
        echo "Banner none"
        echo "KexAlgorithms curve25519-sha256,diffie-hellman-group16-sha512"
        echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
        echo "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
        echo "SyslogFacility AUTHPRIV"
        echo "LogLevel VERBOSE"
    } > "$dropin"

    log_info "已写入 ${dropin}"
    log_step "验证 SSH 配置语法..."
    if ! _security_sshd_config_test; then
        local latest_backup
        log_error "SSH 配置验证失败，已恢复备份（如存在）"
        latest_backup=$(_security_latest_backup "${dropin}.bak.*")
        if [[ -n "$latest_backup" ]]; then
            cp -f "$latest_backup" "$dropin"
        else
            rm -f "$dropin"
        fi
        return 1
    fi

    echo ""
    log_warn "不要关闭当前 SSH 会话。重启后请新开终端测试端口: ${ssh_ports}"
    read -rp "确认现在重启 ${service}.service？[y/N]: " restart_ssh
    if [[ "${restart_ssh,,}" != "y" ]]; then
        log_warn "已写入配置但未重启 SSH，配置尚未生效"
        save_state "SSH_PORTS" "$ssh_ports"
        save_state "CONF_SECURITY_SSH" "0"
        return 0
    fi

    systemctl restart "${service}.service"
    save_state "SSH_PORTS" "$ssh_ports"
    save_state "SSH_ROOT_LOGIN" "$root_login"
    save_state "SSH_ALLOW_FORWARD" "$allow_forward"
    save_state "SSH_GATEWAY_PORTS" "$gateway_ports"
    save_state "SSH_PERMIT_TUNNEL" "$permit_tunnel"
    save_state "SSH_CLIENT_ALIVE_INTERVAL" "$alive_interval"
    save_state "SSH_AUTHORIZED_KEYS_FILE" "$(_security_primary_authorized_key_file)"
    save_state "CONF_SECURITY_SSH" "1"

    log_info "SSH 已重启。请立即用新终端测试: ssh -p $(awk '{print $1}' <<< "$ssh_ports") root@<服务器IP>"
    log_info "========== SSH 登录安全检查与加固完成 =========="
}
