#!/usr/bin/env bash
# ============================================================
# modules/uninstall.sh
# Cleanup / uninstall helpers for xray-nginx-deploy
# ============================================================

remove_path_if_exists() {
    local target="$1"
    if [[ -e "$target" || -L "$target" ]]; then
        rm -rf "$target"
        log_info "已删除: $target"
    fi
}

remove_crontab_entry() {
    local pattern="$1"
    local current
    current=$(crontab -l 2>/dev/null || true)
    if [[ -n "$current" ]] && grep -Fq "$pattern" <<< "$current"; then
        printf '%s\n' "$current" | grep -Fv "$pattern" | crontab -
        log_info "已移除 crontab 项: $pattern"
    fi
}

remove_package_if_possible() {
    local pkg="$1"
    load_os_info

    case "$OS_ID" in
        ubuntu|debian)
            apt-get purge -y "$pkg" >/dev/null 2>&1 || \
            apt-get remove -y "$pkg" >/dev/null 2>&1 || true
            apt-get autoremove -y >/dev/null 2>&1 || true
            ;;
        centos|rhel|rocky|almalinux|fedora)
            dnf remove -y "$pkg" >/dev/null 2>&1 || \
            yum remove -y "$pkg" >/dev/null 2>&1 || true
            ;;
    esac
}

get_saved_root_domains() {
    local domain root
    local -A seen=()

    restore_domain_arrays

    for domain in \
        "${XHTTP_DOMAIN:-}" \
        "${GRPC_DOMAIN:-}" \
        "${REALITY_DOMAIN:-}" \
        "${ANYTLS_DOMAIN:-}" \
        "${ALL_DOMAINS[@]:-}"; do
        [[ -n "$domain" ]] || continue
        root=$(echo "$domain" | awk -F. 'NF >= 2 {print $(NF-1)"."$NF}')
        [[ -n "$root" ]] || continue
        if [[ -z "${seen[$root]:-}" ]]; then
            echo "$root"
            seen["$root"]=1
        fi
    done
}

reset_system_state() {
    save_state "OS_ID" ""
    save_state "OS_NAME" ""
    save_state "PKG_MANAGER" ""
    save_state "BBR_VERSION" ""
    save_state "HW_CPU_CORES" ""
    save_state "HW_MEM_GB" ""
    save_state "HW_BANDWIDTH" ""
    save_state "HW_DUAL_STACK" ""
    save_state "HW_DISK_TYPE" ""
    save_state "XRAY_PADDING" ""
    save_state "INST_SYSTEM" "0"
}

reset_unbound_state() {
    save_state "UNBOUND_SERVICE_NAME" ""
    save_state "INST_UNBOUND" "0"
}

reset_nginx_state() {
    save_state "INST_NGINX" "0"
    save_state "CONF_NGINX" "0"
}

reset_cert_state() {
    save_state "XHTTP_DOMAIN" ""
    save_state "GRPC_DOMAIN" ""
    save_state "REALITY_DOMAIN" ""
    save_state "ANYTLS_DOMAIN" ""
    save_state "ALL_DOMAINS" ""
    save_state "CDN_DOMAINS" ""
    save_state "DIRECT_DOMAINS" ""
    save_state "INST_CERT" "0"
}

reset_xray_state() {
    save_state "XRAY_UUID" ""
    save_state "XRAY_PUBLIC_KEY" ""
    save_state "XRAY_PRIVATE_KEY" ""
    save_state "REALITY_DEST" ""
    save_state "REALITY_SNI" ""
    save_state "REALITY_SHORT_ID" ""
    save_state "REALITY_SPIDER_X" ""
    save_state "INST_XRAY" "0"
    save_state "CONF_XRAY" "0"
}

reset_singbox_state() {
    save_state "SINGBOX_PASSWORD" ""
    save_state "INST_SINGBOX" "0"
    save_state "CONF_SINGBOX" "0"
}

reset_warp_state() {
    save_state "WARP_PROXY_PORT" "40000"
    save_state "INST_WARP" "0"
    save_state "CONF_WARP" "0"
}

restore_default_resolv_conf() {
    chattr -i /etc/resolv.conf 2>/dev/null || true

    if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
        systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
        if [[ -e /run/systemd/resolve/resolv.conf ]]; then
            ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
            log_info "已恢复 systemd-resolved 的 resolv.conf"
            return
        fi
    fi

    cat > /etc/resolv.conf << 'RESOLV'
nameserver 1.1.1.1
nameserver 8.8.8.8
options ndots:1 timeout:2 attempts:2
RESOLV
    log_info "已恢复默认 resolv.conf"
}

cleanup_system_module() {
    log_step "清理 system 模块生成的优化配置..."

    remove_path_if_exists "/etc/systemd/system/xray.service.d"
    remove_path_if_exists "/etc/systemd/system/xray@.service.d"
    remove_path_if_exists "/etc/sysctl.d/98-xray-service-limits.conf"
    remove_path_if_exists "/etc/sysctl.d/99-xray-optimize.conf"
    remove_path_if_exists "/etc/security/limits.d/99-xray.conf"
    remove_path_if_exists "/etc/systemd/system.conf.d/99-xray.conf"
    remove_path_if_exists "/etc/modules-load.d/nf_conntrack.conf"
    remove_path_if_exists "/etc/modules-load.d/tcp_bbr.conf"

    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reexec >/dev/null 2>&1 || true

    reset_system_state
    log_info "system 模块清理完成"
}

cleanup_unbound_module() {
    log_step "清理 Unbound..."

    local conf_dir service_name
    load_os_info

    systemctl disable --now unbound >/dev/null 2>&1 || true

    service_name=$(get_state "UNBOUND_SERVICE_NAME")
    if [[ -n "$service_name" ]]; then
        case "$OS_ID" in
            ubuntu|debian) conf_dir="/etc/unbound/unbound.conf.d" ;;
            *) conf_dir="/etc/unbound/conf.d" ;;
        esac
        remove_path_if_exists "${conf_dir}/${service_name}.conf"
    fi

    remove_path_if_exists "/etc/unbound/unbound.conf.d/local-recursive.conf"
    remove_path_if_exists "/etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf"
    remove_path_if_exists "/etc/unbound/unbound.conf.d/remote-control.conf"
    remove_path_if_exists "/etc/unbound/conf.d/root-auto-trust-anchor-file.conf"
    remove_path_if_exists "/etc/unbound/conf.d/remote-control.conf"
    remove_path_if_exists "/usr/local/bin/update-root-hints.sh"
    remove_path_if_exists "/etc/cron.weekly/update-root-hints"
    remove_path_if_exists "/var/log/unbound-root-update.log"
    remove_path_if_exists "/var/lib/unbound/root.hints"
    remove_path_if_exists "/var/lib/unbound/root.key"
    remove_path_if_exists "/var/lib/unbound/root-hints-backup"
    remove_path_if_exists "/var/lib/unbound/root-update.timestamp"
    remove_crontab_entry "update-root-hints.sh"

    restore_default_resolv_conf
    remove_package_if_possible "unbound"

    reset_unbound_state
    log_info "Unbound 清理完成"
}

cleanup_nginx_module() {
    log_step "清理 Nginx..."

    local domain
    load_os_info
    restore_domain_arrays

    systemctl disable --now nginx >/dev/null 2>&1 || true

    remove_path_if_exists "/usr/local/bin/update_cf_ip.sh"
    remove_path_if_exists "/etc/cron.weekly/update_cf_ip"
    remove_path_if_exists "/var/backups/nginx"
    remove_crontab_entry "update_cf_ip.sh"

    remove_path_if_exists "/etc/nginx/cloudflare_real_ip.conf"
    remove_path_if_exists "/etc/nginx/ssl"
    remove_path_if_exists "/etc/nginx/conf.d/00-upstreams.conf"
    remove_path_if_exists "/etc/nginx/conf.d/fallback.conf"
    remove_path_if_exists "/etc/nginx/conf.d/servers.conf"
    remove_path_if_exists "/etc/nginx/nginx.conf"

    remove_path_if_exists "/var/log/nginx"
    remove_path_if_exists "/var/cache/nginx"
    remove_path_if_exists "/var/www/html"
    for domain in "${ALL_DOMAINS[@]:-}"; do
        remove_path_if_exists "/var/www/${domain}"
    done

    remove_package_if_possible "nginx"

    case "$OS_ID" in
        ubuntu|debian)
            remove_path_if_exists "/etc/apt/sources.list.d/nginx.list"
            remove_path_if_exists "/etc/apt/preferences.d/99nginx"
            remove_path_if_exists "/usr/share/keyrings/nginx-archive-keyring.gpg"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            remove_path_if_exists "/etc/yum.repos.d/nginx.repo"
            ;;
    esac

    reset_nginx_state
    log_info "Nginx 清理完成"
}

cleanup_cert_module() {
    log_step "清理证书和 Cloudflare 配置..."

    local root_domain
    remove_path_if_exists "/etc/cloudflare"
    remove_path_if_exists "/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"
    remove_path_if_exists "/etc/letsencrypt/renewal-hooks/deploy/xray-deploy-reload.sh"
    remove_path_if_exists "/etc/letsencrypt/renewal-hooks/deploy/xray-nginx-deploy-reload.sh"
    remove_path_if_exists "/etc/xray-deploy/certs"
    remove_crontab_entry "certbot renew --quiet"

    while IFS= read -r root_domain; do
        [[ -n "$root_domain" ]] || continue
        if command -v certbot >/dev/null 2>&1; then
            certbot delete --cert-name "$root_domain" --non-interactive \
                >/dev/null 2>&1 || true
        fi
        remove_path_if_exists "/etc/letsencrypt/live/${root_domain}"
        remove_path_if_exists "/etc/letsencrypt/archive/${root_domain}"
        remove_path_if_exists "/etc/letsencrypt/renewal/${root_domain}.conf"
    done < <(get_saved_root_domains)

    save_state "CONF_NGINX" "0"
    save_state "CONF_SINGBOX" "0"
    reset_cert_state
    log_info "证书模块清理完成"
}

cleanup_xray_module() {
    log_step "清理 Xray..."

    systemctl disable --now xray >/dev/null 2>&1 || true
    systemctl disable --now xray@config >/dev/null 2>&1 || true

    remove_path_if_exists "/usr/local/etc/xray"
    remove_path_if_exists "/usr/local/share/xray"
    remove_path_if_exists "/var/log/xray"
    remove_path_if_exists "/usr/local/bin/xray"
    remove_path_if_exists "/usr/local/bin/xray-linux-64.zip"
    remove_path_if_exists "/etc/systemd/system/xray.service"
    remove_path_if_exists "/etc/systemd/system/xray@.service"
    remove_path_if_exists "/usr/bin/xray"

    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    reset_xray_state
    log_info "Xray 清理完成"
}

cleanup_singbox_module() {
    log_step "清理 Sing-Box..."

    load_os_info
    systemctl disable --now sing-box >/dev/null 2>&1 || true

    remove_path_if_exists "/etc/sing-box"
    remove_path_if_exists "/var/lib/sing-box"
    remove_package_if_possible "sing-box"

    case "$OS_ID" in
        ubuntu|debian)
            remove_path_if_exists "/etc/apt/keyrings/sagernet.asc"
            remove_path_if_exists "/etc/apt/sources.list.d/sagernet.sources"
            remove_path_if_exists "/etc/apt/sources.list.d/sagernet.list"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            remove_path_if_exists "/etc/yum.repos.d/sing-box.repo"
            ;;
    esac

    reset_singbox_state
    log_info "Sing-Box 清理完成"
}

cleanup_warp_module() {
    log_step "清理 Cloudflare WARP..."

    load_os_info
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    systemctl disable --now warp-svc >/dev/null 2>&1 || true

    remove_package_if_possible "cloudflare-warp"

    case "$OS_ID" in
        ubuntu|debian)
            remove_path_if_exists "/etc/apt/sources.list.d/cloudflare-client.list"
            remove_path_if_exists "/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            remove_path_if_exists "/etc/yum.repos.d/cloudflare-warp.repo"
            ;;
    esac

    remove_path_if_exists "/var/lib/cloudflare-warp"
    reset_warp_state
    log_info "Cloudflare WARP 清理完成"
}

cleanup_all_modules() {
    cleanup_singbox_module
    cleanup_xray_module
    cleanup_nginx_module
    cleanup_cert_module
    cleanup_warp_module
    cleanup_unbound_module
    cleanup_system_module

    remove_path_if_exists "$STATE_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true
    log_info "全部模块清理完成"
}
