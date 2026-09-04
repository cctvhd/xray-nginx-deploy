#!/usr/bin/env bash
# ============================================================
# modules/cleanup.sh
# 系统清理 / 维护模块
# 可逆、幂等的日常清理：日志轮转与超大日志截断、包缓存、
# snap 旧版本、kdump 内存预留处理、旧内核体检（只报告不删除）
# 不触碰防火墙规则 / 服务配置 / 旧内核降级回退项
# ============================================================

# ── 兼容独立运行：主脚本已定义时不要覆盖 ─────────────────────
if ! declare -F log_step >/dev/null; then
    log_step() { echo -e "\e[36m[STEP]\e[0m $*"; }
fi
if ! declare -F log_info >/dev/null; then
    log_info()  { echo -e "\e[32m[INFO]\e[0m $*"; }
fi
if ! declare -F log_warn >/dev/null; then
    log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
fi
if ! declare -F log_error >/dev/null; then
    log_error() { echo -e "\e[31m[ERROR]\e[0m $*"; }
fi

# 单文件截断阈值：超过该字节数即就地截断（200MB）
_CLEANUP_LOG_TRUNCATE_BYTES=$((200 * 1024 * 1024))
# system 级 syslog 目标（与补写的 /etc/logrotate.d/syslog 一致）
_CLEANUP_SYSLOG_FILES=(cron maillog messages secure)

# ── 补 /etc/logrotate.d/syslog（缺失时会话机 messages 从不轮转而膨胀）─
_cleanup_ensure_logrotate() {
    local conf="/etc/logrotate.d/syslog"
    [[ -f "$conf" ]] && return 0
    log_info "补齐日志轮转配置: ${conf}"
    cat > "$conf" <<'EOF'
/var/log/cron
/var/log/maillog
/var/log/messages
/var/log/secure
{
    missingok
    notifempty
    compress
    delaycompress
    daily
    rotate 4
    size 200M
    create 0600 root root
    sharedscripts
    postrotate
        /usr/bin/systemctl kill -s HUP rsyslog.service 2>/dev/null || true
    endscript
}
EOF
    chmod 644 "$conf"
}

# ── 就地截断超大 syslog 文件（服务持有 fd，truncate 安全）────
_cleanup_truncate_syslogs() {
    local f path size
    for f in "${_CLEANUP_SYSLOG_FILES[@]}"; do
        path="/var/log/${f}"
        [[ -f "$path" ]] || continue
        size=$(stat -c%s "$path" 2>/dev/null || echo 0)
        if (( size > _CLEANUP_LOG_TRUNCATE_BYTES )); then
            truncate -s 0 "$path"
            log_info "截断 ${path}（原 $(( size / 1024 / 1024 ))MB）"
        fi
    done
}

# ── journal 限容（保留最近 50M）───────────────────────────────
_cleanup_journal() {
    command -v journalctl >/dev/null 2>&1 || return 0
    if journalctl --vacuum-size=50M >/dev/null 2>&1; then
        log_info "journal 已限容至 50M"
    fi
}

# ── 包缓存清理：按命令存在分派，不依赖 OS_ID ─────────────────
_cleanup_pkg_cache() {
    if command -v dnf >/dev/null 2>&1; then
        dnf clean all >/dev/null 2>&1 && log_info "dnf 缓存已清理" || log_warn "dnf clean 失败"
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get clean >/dev/null 2>&1 && log_info "apt 缓存已清理" || log_warn "apt clean 失败"
    fi
}

# ── 移除 snap 中仅 disabled 的旧版本（当前启用版不受影响）────
_cleanup_snap_old() {
    command -v snap >/dev/null 2>&1 || return 0
    local name rev removed=0
    while read -r name rev; do
        [[ -z "$name" || ! "$rev" =~ ^[0-9]+$ ]] && continue
        if snap remove "$name" --revision="$rev" >/dev/null 2>&1; then
            log_info "snap 移除旧版本: ${name} (rev ${rev})"
            removed=$(( removed + 1 ))
        fi
    done < <(snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}')
    if (( removed == 0 )); then
        log_info "snap 无 disabled 旧版本"
    fi
}

# ── 一键安全清理：日志 + 缓存 + snap ─────────────────────────
_cleanup_safe_all() {
    log_step "---------- 一键安全清理 ----------"
    local used_before used_after saved
    used_before=$(df -P / | awk 'NR==2{print $3}')
    _cleanup_ensure_logrotate
    _cleanup_truncate_syslogs
    _cleanup_journal
    _cleanup_pkg_cache
    _cleanup_snap_old
    used_after=$(df -P / | awk 'NR==2{print $3}')
    saved=$(( used_before - used_after ))
    log_info "本次清理释放约 $(( saved / 1024 ))MB（根分区）"
    log_step "---------- 一键安全清理完成 ----------"
}

# ── kdump / crashkernel 预留处理（需重启生效，不自动重启）────
_cleanup_kdump() {
    local active="" c
    systemctl is-active kdump >/dev/null 2>&1 && active="active"
    if [[ -z "$active" ]] && ! grep -q 'crashkernel' /proc/cmdline 2>/dev/null; then
        log_info "kdump 未启用且无 crashkernel 预留，跳过"
        return 0
    fi
    log_warn "kdump/crashkernel 会预留数百 MB 内存，小内存 VPS 上不划算"
    read -rp "确认禁用 kdump 并移除 crashkernel 启动参数？（重启后释放内存；本操作不自动重启）[y/N]: " c
    [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }

    systemctl disable --now kdump >/dev/null 2>&1 || true
    log_info "kdump 服务已禁用"

    if command -v grubby >/dev/null 2>&1; then
        grubby --update-kernel=ALL --remove-args=crashkernel >/dev/null 2>&1 || true
        log_info "已从 grub 引导项移除 crashkernel"
    fi
    if [[ -f /etc/default/grub ]] && grep -q 'crashkernel' /etc/default/grub; then
        sed -ri 's/\bcrashkernel=[^ "]*//g' /etc/default/grub
        log_info "已从 /etc/default/grub 移除 crashkernel"
    fi
    rm -f /boot/initramfs-*kdump.img 2>/dev/null || true
    log_info "已删除 kdump initramfs 镜像"

    log_warn "内存预留需重启后释放：请择机重启（勿立即重启代理节点）"
}

# ── 旧内核体检（只报告，保留作降级回退，不删除）───────────────
_cleanup_kernel_report() {
    log_step "---------- 旧内核体检（只读）----------"
    local cur name ksize
    cur=$(uname -r)
    log_info "当前运行内核: ${cur}"
    for d in /lib/modules/*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        ksize=$(du -sh "${d%/}" 2>/dev/null | awk '{print $1}')
        if [[ "$name" == "$cur" ]]; then
            log_info "  [当前] ${name}  ${ksize}"
        else
            log_warn "  旧内核模块: ${name}  ${ksize}（保留作回退，未删除）"
        fi
    done
    echo ""
    log_info "/boot 内核镜像（保留，未删除）:"
    ls -lh /boot/vmlinuz-* 2>/dev/null | awk '{print "  " $NF "  " $5}' || true
    log_step "---------- 仅报告，未做任何删除 ----------"
}

# ── 模块入口：单次性子菜单 ───────────────────────────────────
run_cleanup() {
    clear
    echo ""
    echo -e "\e[34m================ 系统清理 / 维护 ================\e[0m"
    echo "  1. 一键安全清理（日志轮转/截断 + 包缓存 + snap 旧版本）"
    echo "  2. kdump 内存预留处理（禁用 + 移除 crashkernel，重启生效）"
    echo "  3. 旧内核体检（仅报告，保留降级回退）"
    echo "  q. 返回"
    echo ""
    read -rp "  请选择: " cleanup_choice
    echo ""

    case "$cleanup_choice" in
        1) _cleanup_safe_all ;;
        2) _cleanup_kdump ;;
        3) _cleanup_kernel_report ;;
        q|Q) ;;
        *)
            log_error "无效选择"
            sleep 1
            ;;
    esac
}

# 独立运行（bash modules/cleanup.sh）时直接进菜单
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_cleanup
fi
