#!/usr/bin/env bash
# ============================================================
# modules/nginx.sh
# Nginx 安装 + 配置文件生成
# ============================================================

# ── 安装 Nginx 官方最新稳定版 ────────────────────────────────
install_nginx() {
    log_step "安装 Nginx 官方最新稳定版..."

    case "$OS_ID" in
        ubuntu|debian)
            if ! grep -q 'nginx\.org' /etc/apt/sources.list.d/nginx.list 2>/dev/null; then
                curl -fsSL https://nginx.org/keys/nginx_signing.key | \
                    gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

                # 优先读 /etc/os-release 的 VERSION_CODENAME：
                # lsb_release 依赖 lsb-release 包，精简系统常未安装，
                # 而 Debian/Ubuntu 的 VERSION_CODENAME 即 nginx.org 仓库 codename
                local codename
                codename=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
                [[ -z "${codename}" ]] && codename=$(lsb_release -cs 2>/dev/null)
                echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/${OS_ID} ${codename} nginx" \
                    > /etc/apt/sources.list.d/nginx.list

                cat > /etc/apt/preferences.d/99nginx << PREF
Package: nginx
Pin: origin nginx.org
Pin-Priority: 900
PREF
                log_info "已添加 nginx 官方 apt 仓库"
            else
                log_info "nginx 官方 apt 仓库已存在，跳过"
            fi

            apt-get update -y >/dev/null 2>&1
            apt-get install -y nginx >/dev/null 2>&1
            ;;

        centos|rhel|rocky|almalinux)
            if [[ ! -f /etc/yum.repos.d/nginx.repo ]]; then
                cat > /etc/yum.repos.d/nginx.repo << REPO
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
REPO
                log_info "已添加 nginx 官方 yum 仓库"
            else
                log_info "nginx 官方 yum 仓库已存在，跳过"
            fi

            dnf install -y nginx >/dev/null 2>&1
            ;;

        fedora)
            # nginx.org 不发布 Fedora 软件包（仅有 centos/debian/ubuntu 等源），
            # Fedora 走发行版自带 nginx；其仓库候选版本由 install.sh 的
            # upgrade_repo_candidate(dnf) 读取，与安装通道一致。
            log_info "Fedora 使用发行版仓库安装 nginx（nginx.org 无 Fedora 源）"
            dnf install -y nginx >/dev/null 2>&1
            ;;
    esac

    if ! command -v nginx &>/dev/null; then
        log_error "Nginx 安装失败"
        exit 1
    fi

    local nginx_ver
    nginx_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)
    log_info "Nginx 安装成功: v${nginx_ver}"

    local nginx_nofile="${GLOBAL_NOFILE_LIMIT:-1048576}"
    mkdir -p /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/99-xray-limits.conf << LIMITS
[Service]
LimitNOFILE=${nginx_nofile}
LIMITS
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_info "Nginx systemd nofile 限制: ${nginx_nofile}"

    systemctl enable --now nginx
}

# ── 创建目录结构 ─────────────────────────────────────────────
create_nginx_dirs() {
    log_step "创建 Nginx 目录结构..."

    local dirs=(
        /etc/nginx/conf.d
        /etc/nginx/ssl
        /var/log/nginx
        /var/www/trap
        /var/cache/nginx
        /etc/nginx/certs
    )

    # ⚠️ 这两个 `local` 不能省：bash 是动态作用域，循环变量会一路改到【调用方】
    # 同名的局部变量上。2026-09-30 活机实测：mosdns.sh 的 _doh_entry_apply 有
    # `local domain`，它调 sync_refresh_nginx_routes → 本函数，循环结束后那个局部
    # 变量就成了 ALL_DOMAINS 的最后一个元素，于是日志里报出了错误的 DoH 域名
    # （state / 磁盘配置都对，只有那行提示错 —— 用户照着它配就会配错）。
    local dir domain
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chmod 755 "$dir"
    done

    for domain in "${ALL_DOMAINS[@]}"; do
        mkdir -p "/var/www/${domain}"
        chmod 755 "/var/www/${domain}"
    done

    chown -R nginx:nginx /var/log/nginx /var/cache/nginx 2>/dev/null || \
    chown -R www-data:www-data /var/log/nginx /var/cache/nginx 2>/dev/null || true

	# 删除 nginx 官方包自带的默认 server 块，避免与自定义配置冲突
	rm -f /etc/nginx/conf.d/default.conf
	rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
log_info "目录结构创建完成"
}

# ── 生成 8400 陷阱端口自签证书（P3修复：让TLS握手能完成）──
generate_trap_cert() {
    log_step "生成 SNI 陷阱端口自签证书..."

    local cert_dir="/etc/nginx/certs"
    local key="${cert_dir}/trap.key"
    local crt="${cert_dir}/trap.crt"

    if [[ -f "$key" && -f "$crt" ]]; then
        log_info "陷阱证书已存在，跳过生成"
        return
    fi

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$key" \
        -out    "$crt" \
        -days   3650 \
        -subj   "/CN=localhost" \
        -quiet 2>/dev/null

    chmod 600 "$key"
    chmod 644 "$crt"
    log_info "陷阱自签证书已生成: ${cert_dir}/trap.{key,crt}"
}

# ── 生成伪装站页面 ───────────────────────────────────────────
generate_fake_site() {
    local dir="$1"
    local _slot="${2:-0}"

    local _mod_dir
    _mod_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _assets="${_mod_dir}/../assets"

    # 已安装部署时 assets 跟随 install.sh 复制到 /etc/xray-deploy/assets/
    local _assets_installed="/etc/xray-deploy/assets"

    # 只取前缀：na/xxx 和 na 均视为 na
    local _prefix="${HW_REGION%%/*}"

    local _template=""

    # 北美：按 slot 自动轮换分配不同主题，每个域名外观各异
    # 顺序固定：已知主题按此优先级排列，新增主题追加到末尾（字母序）
    if [[ "$_prefix" == "na" ]]; then
        local -a _known_order=(usa usa1 html)
        local _na_base=""
        for _nb in "${_assets}/fake-site-na" "${_assets_installed}/fake-site-na"; do
            if [[ -d "$_nb" ]]; then _na_base="$_nb"; break; fi
        done

        # 构建有序列表：先按 _known_order 挑存在的，再追加未知的（字母序）
        local -a _na_dirs=()
        local _d
        for _d in "${_known_order[@]}"; do
            [[ -f "${_na_base}/${_d}/index.html" ]] && _na_dirs+=("$_d")
        done
        if [[ -n "$_na_base" ]]; then
            while IFS= read -r -d '' _extra; do
                _extra="$(basename "$_extra")"
                [[ -f "${_na_base}/${_extra}/index.html" ]] || continue
                local _known=0
                for _d in "${_known_order[@]}"; do [[ "$_d" == "$_extra" ]] && _known=1 && break; done
                [[ $_known -eq 0 ]] && _na_dirs+=("$_extra")
            done < <(find "$_na_base" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
        fi

        if [[ ${#_na_dirs[@]} -gt 0 ]]; then
            # _na_dirs 前段 = 存在的通用主题(slot 池)；其余为「专属主题」池
            local _n_generic=0 _gn
            for _gn in "${_known_order[@]}"; do
                [[ -f "${_na_base}/${_gn}/index.html" ]] && _n_generic=$(( _n_generic + 1 ))
            done

            local _subdir="" _dom_bn="${dir##*/}"
            _dom_bn="${_dom_bn,,}"
            local _di _pd _pdl _want _excluded=""
            # 专属主题 = 精确绑定单个域名，不再「域名含目录名即套同款」：
            #   · 主题目录名 == 整域名（如 fake-site-na/lax.shoes-bv.tk/）→ 1:1 命中
            #   · 主题目录内 .domain 数据文件内容 == 域名 → 命中（既有关键词式主题钉扎旗舰，
            #   · 裸子串关键词不再生效；未命中的专属主题不进 slot 轮换池
            for (( _di = _n_generic; _di < ${#_na_dirs[@]}; _di++ )); do
                _pd="${_na_dirs[$_di]}"
                _pdl="${_pd,,}"
                if [[ "$_pdl" == "$_dom_bn" ]]; then
                    _subdir="$_pd"                      # 整域名主题：1:1 且名称最长，天然优先
                    continue
                fi
                # 注意：$(<file) 只在无附加重定向时才是 bash 读文件特例；
                # 附 2>/dev/null 会退化为「空命令 + 重定向」→ 读不到内容，故用 -f 先行判断
                _want=""
                if [[ -f "${_na_base}/${_pd}/.domain" ]]; then
                    _want="$(<"${_na_base}/${_pd}/.domain")"
                fi
                _want="${_want%%$'\r'}"
                if [[ -n "$_want" && "$_want" == "$_dom_bn" ]]; then
                    if [[ -z "$_subdir" ]] || [[ "${#_pd}" -gt "${#_subdir}" ]]; then
                        _subdir="$_pd"
                    fi
                elif [[ "$_dom_bn" == *"$_pdl"* ]]; then
                    # 该域含此关键词但主题已钉扎别域/无钉扎 → 记入排除名单供引导
                    _excluded="${_excluded:+$_excluded }$_pd"
                fi
            done
            if [[ -z "$_subdir" && -n "$_excluded" ]]; then
                log_warn "专属主题 <${_excluded}> 已固定给其它域名；${_dom_bn} 若需独立外观，请新增预置主题 assets/fake-site-na/${_dom_bn}/index.html"
            fi
            # 未命中专属主题 → 仅从通用主题按 slot 轮换，保证同域名外观稳定
            if [[ -z "$_subdir" ]]; then
                local _pool_n=${#_na_dirs[@]}
                [[ $_n_generic -gt 0 ]] && _pool_n=$_n_generic
                _subdir="${_na_dirs[$(( _slot % _pool_n ))]}"
            fi
            for _f in \
                "${_assets}/fake-site-na/${_subdir}/index.html" \
                "${_assets_installed}/fake-site-na/${_subdir}/index.html"; do
                if [[ -f "$_f" ]]; then _template="$_f"; break; fi
            done
        fi

        if [[ -z "$_template" ]]; then
            log_warn "generate_fake_site: 未找到本地北美模板，将尝试远程下载"
        fi
    fi

    # 欧洲/亚洲/默认：统一用欧洲档案馆主题
    if [[ -z "$_template" ]]; then
        for _f in \
            "${_assets}/fake-site-eu.html" \
            "${_assets_installed}/fake-site-eu.html" \
            "/var/www/Example/lietuva-heritage (1).html"; do
            if [[ -f "$_f" ]]; then _template="$_f"; break; fi
        done
    fi

    if [[ -n "$_template" ]]; then
        install -m 644 "$_template" "${dir}/index.html"
        log_info "已安装伪装页面: ${dir}/index.html  (来源: $_template)"

        # 若模板目录下有 Music/ 子目录，一并复制（如 usa1 含 MP3 文件）
        local _tmpl_dir
        _tmpl_dir="$(dirname "$_template")"
        if [[ -d "${_tmpl_dir}/Music" ]]; then
            cp -r "${_tmpl_dir}/Music" "${dir}/Music"
            find "${dir}/Music" -type f -exec chmod 644 {} \;
            log_info "已复制音乐文件: ${dir}/Music/"
        fi

        return
    fi

    # 尝试从远程下载对应主题
    if command -v curl >/dev/null 2>&1; then
        local _remote_html=""
        if [[ "$_prefix" == "na" ]]; then
            local -a _known_na=(usa usa1 html)
            local _remote_subdir="${_known_na[$(( _slot % ${#_known_na[@]} ))]}"
            _remote_html="${BASE_URL}/assets/fake-site-na/${_remote_subdir}/index.html"
        else
            _remote_html="${BASE_URL}/assets/fake-site-eu.html"
        fi
        if curl -fsSL "$_remote_html" -o "${dir}/index.html" 2>/dev/null; then
            chmod 644 "${dir}/index.html"
            log_info "已从远程下载伪装页面: ${dir}/index.html"
            return
        fi
    fi

    # 最终回退：按地区自动生成主题伪装页
    log_warn "generate_fake_site: 无模板文件可用，自动生成 ${_prefix:-eu} 主题页"
    case "${_prefix:-eu}" in

        na)
    cat > "${dir}/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pacific Research Library — Digital Collections</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:Georgia,'Times New Roman',serif;background:#f8f6f2;color:#1a1a1a}
header{background:#1c3a5e;color:#fff;padding:20px 40px;border-bottom:4px solid #c8a84b}
header h1{font-size:1.5rem;letter-spacing:.04em}
header p{font-size:.82rem;color:#a8bfd0;margin-top:4px}
nav{background:#24507a;padding:0 40px;display:flex;gap:24px}
nav a{color:#d0e4f0;text-decoration:none;font-size:.8rem;padding:10px 0;letter-spacing:.06em;text-transform:uppercase}
nav a:hover{color:#fff}
.hero{background:linear-gradient(135deg,#1c3a5e,#24507a);color:#fff;padding:60px 40px}
.hero h2{font-size:1.9rem;max-width:580px;line-height:1.3;font-weight:normal}
.hero p{margin-top:14px;color:#b8d0e4;max-width:500px;line-height:1.7;font-size:.92rem}
main{max-width:1060px;margin:40px auto;padding:0 40px;display:grid;grid-template-columns:2fr 1fr;gap:28px}
.card{background:#fff;border:1px solid #ddd;padding:22px;border-radius:3px}
.card h3{color:#1c3a5e;margin-bottom:8px;font-size:.95rem}
.card p{font-size:.87rem;color:#555;line-height:1.65}
footer{background:#111;color:#666;text-align:center;padding:18px;font-size:.78rem;margin-top:40px}
</style>
</head>
<body>
<header>
  <h1>Pacific Research Library</h1>
  <p>Digital Collections &amp; Archives &middot; Established 1924</p>
</header>
<nav><a href="#">Collections</a><a href="#">Research</a><a href="#">Digital Archive</a><a href="#">About</a><a href="#">Contact</a></nav>
<div class="hero">
  <h2>Preserving Knowledge for Future Generations</h2>
  <p>Access over 2.4 million digitized documents, photographs, maps and recordings from regional collections dating back to the 18th century.</p>
</div>
<main>
  <div>
    <div class="card" style="margin-bottom:18px">
      <h3>Featured: Pacific Coast Survey Records 1847&ndash;1920</h3>
      <p>Newly digitized survey records documenting early settlement patterns, land grants, and environmental change along the Pacific Coast are now available for public research access.</p>
    </div>
    <div class="card">
      <h3>Digital Archive Search</h3>
      <p>Search our complete catalog of digitized materials including manuscripts, photographs, oral history recordings, and government documents.</p>
    </div>
  </div>
  <div>
    <div class="card" style="margin-bottom:18px">
      <h3>Library Hours</h3>
      <p>Mon&ndash;Fri: 9:00 AM &ndash; 6:00 PM<br>Saturday: 10:00 AM &ndash; 4:00 PM<br>Sunday: Closed</p>
    </div>
    <div class="card">
      <h3>Research Assistance</h3>
      <p>Reference librarians available for genealogy research, historical inquiries, and archival requests.</p>
    </div>
  </div>
</main>
<footer>&copy; 2024 Pacific Research Library &middot; All Rights Reserved</footer>
</body>
</html>
HTML
            ;;

        as)
    cat > "${dir}/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Asia-Pacific Research Network — Open Data Portal</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,'Segoe UI',sans-serif;background:#f4f6fa;color:#1a1f2e}
header{background:#1a2a4a;color:#fff;padding:15px 48px;display:flex;justify-content:space-between;align-items:center}
header h1{font-size:1.05rem;font-weight:500;letter-spacing:.02em}
nav a{color:#90a8c8;text-decoration:none;font-size:.8rem;margin-left:24px}
nav a:hover{color:#fff}
.hero{background:linear-gradient(135deg,#1a2a4a,#0d3060);color:#fff;padding:52px 48px}
.hero h2{font-size:1.75rem;font-weight:400;max-width:540px;line-height:1.4}
.hero p{margin-top:14px;color:#90a8c8;max-width:460px;line-height:1.7;font-size:.88rem}
.stats{display:flex;gap:40px;margin-top:30px}
.stat span{display:block;font-size:1.7rem;font-weight:700;color:#4a9eff}
.stat small{font-size:.76rem;color:#7090b0}
main{max-width:1060px;margin:36px auto;padding:0 48px;display:grid;grid-template-columns:repeat(2,1fr);gap:18px}
.card{background:#fff;border-radius:5px;padding:22px;box-shadow:0 1px 4px rgba(0,0,0,.08)}
.card h3{font-size:.9rem;color:#1a2a4a;margin-bottom:7px}
.card p{font-size:.84rem;color:#5a6a8a;line-height:1.62}
footer{background:#1a2a4a;color:#4a6a8a;text-align:center;padding:18px;font-size:.76rem;margin-top:40px}
</style>
</head>
<body>
<header>
  <h1>Asia-Pacific Research Network</h1>
  <nav><a href="#">Datasets</a><a href="#">Publications</a><a href="#">Projects</a><a href="#">About</a></nav>
</header>
<div class="hero">
  <h2>Open Science Data Portal</h2>
  <p>A collaborative research infrastructure providing open access to datasets, publications and tools across the Asia-Pacific scientific community.</p>
  <div class="stats">
    <div class="stat"><span>18,400+</span><small>Datasets</small></div>
    <div class="stat"><span>340</span><small>Member Institutions</small></div>
    <div class="stat"><span>28</span><small>Countries</small></div>
  </div>
</div>
<main>
  <div class="card"><h3>Climate &amp; Environment</h3><p>Long-term observational records, satellite imagery archives and environmental monitoring data from across the Pacific region.</p></div>
  <div class="card"><h3>Biodiversity</h3><p>Species occurrence records, ecological surveys and conservation status data aggregated from member research stations.</p></div>
  <div class="card"><h3>Social Sciences</h3><p>Longitudinal survey data, demographic studies and urban development research from partner universities and institutes.</p></div>
  <div class="card"><h3>Marine Research</h3><p>Oceanographic measurements, coral reef monitoring data and fisheries research from Pacific Ocean observation networks.</p></div>
</main>
<footer>&copy; 2024 Asia-Pacific Research Network &middot; Open Data Initiative</footer>
</body>
</html>
HTML
            ;;

        # eu 及其他未知前缀均使用欧洲学术档案主题
        *)
    cat > "${dir}/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Nordic Heritage Institute — Digital Repository</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Palatino Linotype',Palatino,Georgia,serif;background:#0f1a14;color:#e0ddd0;min-height:100vh}
header{background:linear-gradient(180deg,#000,#0f1a14);border-bottom:1px solid rgba(180,140,40,.3);padding:26px 60px;display:flex;justify-content:space-between;align-items:center}
.logo h1{font-size:1.35rem;letter-spacing:.08em;color:#e8d890}
.logo p{font-size:.72rem;letter-spacing:.2em;text-transform:uppercase;color:#8a9a84;margin-top:4px}
nav a{color:#8a9a84;text-decoration:none;font-size:.76rem;letter-spacing:.1em;text-transform:uppercase;margin-left:30px}
nav a:hover{color:#e8d890}
.banner{padding:76px 60px;background:radial-gradient(ellipse at 30% 50%,#162410,#0f1a14 70%);border-bottom:1px solid rgba(180,140,40,.12)}
.banner h2{font-size:2.1rem;color:#e8d890;max-width:560px;line-height:1.28;font-weight:normal}
.banner p{margin-top:18px;color:#a0b090;line-height:1.8;max-width:480px;font-size:.92rem}
main{max-width:980px;margin:56px auto;padding:0 60px;display:grid;grid-template-columns:repeat(3,1fr);gap:22px}
.card{border:1px solid rgba(180,140,40,.18);padding:22px;background:rgba(255,255,255,.02)}
.card h3{color:#c8a040;font-size:.82rem;letter-spacing:.1em;text-transform:uppercase;margin-bottom:10px;font-weight:normal}
.card p{font-size:.86rem;color:#909880;line-height:1.7}
footer{border-top:1px solid rgba(180,140,40,.12);text-align:center;padding:22px;font-size:.72rem;color:#4a5a44;letter-spacing:.08em;margin-top:60px}
</style>
</head>
<body>
<header>
  <div class="logo"><h1>Nordic Heritage Institute</h1><p>Digital Repository &amp; Cultural Archives</p></div>
  <nav><a href="#">Collections</a><a href="#">Research</a><a href="#">Publications</a><a href="#">About</a></nav>
</header>
<div class="banner">
  <h2>Preserving the Living Memory of the North</h2>
  <p>A curated digital archive of folk traditions, oral histories, and cultural heritage from the Nordic and Baltic regions, spanning eight centuries of documented history.</p>
</div>
<main>
  <div class="card"><h3>Manuscripts</h3><p>Over 140,000 digitized manuscript pages from monastic and civic archives, spanning the 13th to 20th centuries.</p></div>
  <div class="card"><h3>Folk Music</h3><p>Audio recordings of traditional songs and instrumental pieces collected through fieldwork expeditions from 1948 to the present.</p></div>
  <div class="card"><h3>Oral Histories</h3><p>Transcribed and recorded testimonies documenting community life, seasonal traditions, and historical memory across the region.</p></div>
</main>
<footer>NORDIC HERITAGE INSTITUTE &middot; DIGITAL REPOSITORY &middot; MMXXIV</footer>
</body>
</html>
HTML
            ;;
    esac
}

# ── 生成 cloudflare_real_ip.conf ─────────────────────────────
generate_cf_realip_conf() {
    log_step "生成 Cloudflare 真实IP配置..."

    cat > /etc/nginx/cloudflare_real_ip.conf << CONF
# ======================================================================
# Cloudflare Real IP 配置
# 自动生成，请勿手动编辑 | 更新时间: $(date '+%Y-%m-%d %H:%M:%S')
# ======================================================================

# ── 信任本地环回（stream → nginx 的本地转发必须信任）────────────────
set_real_ip_from 127.0.0.1;
set_real_ip_from ::1;

# ── 信任 Cloudflare 官方节点（IPv4）──────────────────────────────────
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;

# ── 信任 Cloudflare 官方节点（IPv6）──────────────────────────────────
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;

# ── 核心：从 Stream 层传来的 PROXY Protocol 中提取物理连接 IP ─────────
# 注意：不能用 CF-Connecting-IP，该 Header 可被任意伪造
real_ip_header    proxy_protocol;
real_ip_recursive on;

# ── 判断物理 IP 是否属于 CF 官方节点 ─────────────────────────────────
geo \$remote_addr \$from_cf {
    default 0;
    127.0.0.1        0;
    ::1              0;
    173.245.48.0/20  1;
    103.21.244.0/22  1;
    103.22.200.0/22  1;
    103.31.4.0/22    1;
    141.101.64.0/18  1;
    108.162.192.0/18 1;
    190.93.240.0/20  1;
    188.114.96.0/20  1;
    197.234.240.0/22 1;
    198.41.128.0/17  1;
    162.158.0.0/15   1;
    104.16.0.0/13    1;
    104.24.0.0/14    1;
    172.64.0.0/13    1;
    131.0.72.0/22    1;
    2400:cb00::/32   1;
    2606:4700::/32   1;
    2803:f800::/32   1;
    2405:b500::/32   1;
    2405:8100::/32   1;
    2a06:98c0::/29   1;
    2c0f:f248::/32   1;
}

# ── 健壮型真实 IP 映射 ────────────────────────────────────────────────
map "\$from_cf:\$http_cf_connecting_ip" \$final_real_ip {
    "1:"       \$remote_addr;
    "~^1:.+"   \$http_cf_connecting_ip;
    default    \$remote_addr;
}

# ── 媒体文件扩展名检测 ─────────────────────────────────────────────────
# 非 CF 流量访问媒体文件时应直接返回文件，而非跳转 /_fake 伪装页
map \$uri \$is_media_ext {
    ~*\.(mp4|mp3|ogg|m4a|wav|webm|flac|aac)(\?.*)?$  1;
    default                                            0;
}

# ── 伪装页跳转判断：仅对非 CF 流量 + 非媒体文件触发 ─────────────────
map "\${from_cf}_\${is_media_ext}" \$redirect_to_fake {
    "0_0"   1;
    default 0;
}
CONF

    log_info "Cloudflare 真实IP配置生成完成"
}

# ── 安装 Cloudflare IP 自动更新脚本 ──────────────────────────
install_cf_ip_updater() {
    log_step "安装 Cloudflare IP 自动更新脚本..."

    mkdir -p /usr/local/bin /var/backups/nginx /var/log/nginx

    cat > /usr/local/bin/update_cf_ip.sh << 'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

CF_CONF="/etc/nginx/cloudflare_real_ip.conf"
TMP_CF_CONF="/tmp/real_ip.conf.tmp"
BACKUP_DIR="/var/backups/nginx"
LOG_FILE="/var/log/nginx/cloudflare_ip_update.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()        { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
error_exit() { log "${RED}ERROR: $1${NC}"; exit 1; }

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

command -v nginx >/dev/null 2>&1 || error_exit "未找到 nginx 命令"
[[ -f "$CF_CONF" ]] || error_exit "未找到目标配置文件: $CF_CONF"

log "${YELLOW}开始更新 Cloudflare IP 地址段...${NC}"

get_cloudflare_ips() {
    local retries=3 delay=5
    for i in $(seq 1 "$retries"); do
        CF_IPV4=$(curl -fsSL --connect-timeout 10 --max-time 20 https://www.cloudflare.com/ips-v4)
        CF_IPV6=$(curl -fsSL --connect-timeout 10 --max-time 20 https://www.cloudflare.com/ips-v6)
        [[ -n "${CF_IPV4:-}" && -n "${CF_IPV6:-}" ]] && {
            log "成功获取 Cloudflare IP (第 $i 次)"
            return 0
        }
        log "获取失败，重试 $i/$retries，等待 ${delay}s..."
        sleep "$delay"
    done
    error_exit "无法获取 Cloudflare IP 地址段"
}

validate_ips() {
    local v4 v6
    v4=$(echo "$CF_IPV4" | grep -v '^$' | wc -l)
    v6=$(echo "$CF_IPV6" | grep -v '^$' | wc -l)
    (( v4 >= 10 && v6 >= 5 )) || error_exit "IP 数量异常 (IPv4: $v4, IPv6: $v6)"
    log "IP 验证通过 (IPv4: $v4, IPv6: $v6)"
}

get_cloudflare_ips
validate_ips

cat > "$TMP_CF_CONF" << HEREDOC
# ======================================================================
# Cloudflare Real IP 配置
# 自动生成，请勿手动编辑 | 更新时间: $(date '+%Y-%m-%d %H:%M:%S')
# ======================================================================

set_real_ip_from 127.0.0.1;
set_real_ip_from ::1;

$(echo "$CF_IPV4" | grep -v '^[[:space:]]*$' | sed 's/^/set_real_ip_from /;s/$/;/')

$(echo "$CF_IPV6" | grep -v '^[[:space:]]*$' | sed 's/^/set_real_ip_from /;s/$/;/')

real_ip_header    proxy_protocol;
real_ip_recursive on;

geo \$remote_addr \$from_cf {
    default 0;
    127.0.0.1 0;
    ::1 0;
$(echo "$CF_IPV4" | grep -v '^[[:space:]]*$' | sed 's/^/    /;s/$/ 1;/')
$(echo "$CF_IPV6" | grep -v '^[[:space:]]*$' | sed 's/^/    /;s/$/ 1;/')
}

map "\$from_cf:\$http_cf_connecting_ip" \$final_real_ip {
    "1:"       \$remote_addr;
    "~^1:.+"   \$http_cf_connecting_ip;
    default    \$remote_addr;
}

map \$uri \$is_media_ext {
    ~*\.(mp4|mp3|ogg|m4a|wav|webm|flac|aac)(\?.*)?$  1;
    default                                            0;
}

map "\${from_cf}_\${is_media_ext}" \$redirect_to_fake {
    "0_0"   1;
    default 0;
}
HEREDOC

BACKUP_FILE=""
if [[ -f "$CF_CONF" ]]; then
    BACKUP_FILE="$BACKUP_DIR/real_ip.conf.$(date +%Y%m%d-%H%M%S)"
    cp "$CF_CONF" "$BACKUP_FILE"
fi

mv "$TMP_CF_CONF" "$CF_CONF"
chmod 644 "$CF_CONF"

if nginx -t >/dev/null 2>&1; then
    command -v restorecon >/dev/null 2>&1 && restorecon "$CF_CONF" || true
    if systemctl reload nginx 2>/dev/null; then
        log "${GREEN}Cloudflare IP 更新成功，Nginx 已平滑重载${NC}"
    else
        log "${YELLOW}Nginx 重载失败，但配置已更新${NC}"
    fi
else
    log "${RED}nginx -t 未通过，正在从备份恢复旧配置...${NC}"
    if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
        cp "$BACKUP_FILE" "$CF_CONF"
        log "${YELLOW}已恢复旧配置：$BACKUP_FILE${NC}"
    else
        log "${RED}无可用备份，请手动检查 $CF_CONF${NC}"
    fi
    rm -f "$TMP_CF_CONF"
    error_exit "新配置 nginx -t 未通过，已回滚"
fi

find "$BACKUP_DIR" -name "real_ip.conf.*" -type f | sort -r | tail -n +11 | xargs -r rm -f || true
log "${GREEN}Cloudflare IP 更新完成${NC}"
SCRIPT_EOF

    chmod +x /usr/local/bin/update_cf_ip.sh
    log_info "Cloudflare IP 更新脚本已安装"
}

# ── 配置 Cloudflare IP 自动更新任务 ─────────────────────────
setup_cf_ip_updater() {
    log_step "配置 Cloudflare IP 自动更新任务..."

    cat > /etc/cron.weekly/update_cf_ip << 'CRON_EOF'
#!/usr/bin/env bash
/usr/local/bin/update_cf_ip.sh
CRON_EOF
    chmod +x /etc/cron.weekly/update_cf_ip

    (crontab -l 2>/dev/null | grep -v "update_cf_ip.sh"; \
     echo "23 4 * * 0 /usr/local/bin/update_cf_ip.sh >/dev/null 2>&1") | crontab -

    log_info "已配置每周自动更新 Cloudflare IP"
}

# ── 立即执行一次 Cloudflare IP 更新 ─────────────────────────
run_cf_ip_updater() {
    log_step "刷新 Cloudflare 官方 IP 地址段..."

    if /usr/local/bin/update_cf_ip.sh; then
        log_info "Cloudflare IP 地址段已刷新"
    else
        log_warn "Cloudflare IP 自动更新失败，保留当前静态模板配置"
    fi
}

# ── 生成 ssl/common.conf ─────────────────────────────────────
generate_ssl_conf() {
    log_step "生成 SSL 通用配置..."

    local ipv6_resolver
    if is_ipv6_preferred 2>/dev/null; then
        ipv6_resolver="ipv6=on"
    else
        ipv6_resolver="ipv6=off"
    fi

    cat > /etc/nginx/ssl/common.conf << CONF
# ===================================================
# /etc/nginx/ssl/common.conf
# ===================================================

ssl_protocols TLSv1.3 TLSv1.2;
ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;
ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
ssl_prefer_server_ciphers on;
ssl_conf_command Curves X25519:P-256:P-384;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_early_data off;
ssl_buffer_size 4k;
ssl_stapling off;
ssl_stapling_verify off;

resolver 127.0.0.1:53 valid=300s ${ipv6_resolver};
resolver_timeout 5s;

add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
# CSP 和 CORS 已从全局移除：CSP 仅在伪装页 location 内添加，CORS 仅在 xhttp location 内添加
# 代理 location 不需要 CSP（干扰流式传输），CORS 全局设置会污染伪装页响应
CONF

    log_info "SSL 通用配置生成完成"
}

# ── 选择 nginx 动态档位 ───────────────────────────────────────
select_nginx_profile() {
    local cpu_cores="$1"
    local mem_mb="$2"

    if [[ $cpu_cores -le 1 || $mem_mb -lt 2048 ]]; then
        NGINX_PROFILE="small"
        NGINX_WORKER_CONNECTIONS=4096
        # P5修复：全局 keepalive 改小，在 location 内单独覆盖长连接
        NGINX_KEEPALIVE_TIMEOUT=65
        NGINX_KEEPALIVE_REQUESTS=5000
        NGINX_OPEN_FILE_CACHE_MAX=2000
        NGINX_OPEN_FILE_CACHE_INACTIVE=120
        NGINX_OPEN_FILE_CACHE_VALID=60
        NGINX_OPEN_FILE_CACHE_MIN_USES=2
    elif [[ $cpu_cores -le 2 || $mem_mb -lt 8192 ]]; then
        NGINX_PROFILE="medium"
        NGINX_WORKER_CONNECTIONS=8192
        NGINX_KEEPALIVE_TIMEOUT=65
        NGINX_KEEPALIVE_REQUESTS=8000
        NGINX_OPEN_FILE_CACHE_MAX=100000
        NGINX_OPEN_FILE_CACHE_INACTIVE=240
        NGINX_OPEN_FILE_CACHE_VALID=120
        NGINX_OPEN_FILE_CACHE_MIN_USES=1
    else
        NGINX_PROFILE="large"
        NGINX_WORKER_CONNECTIONS=16384
        NGINX_KEEPALIVE_TIMEOUT=65
        NGINX_KEEPALIVE_REQUESTS=10000
        NGINX_OPEN_FILE_CACHE_MAX=200000
        NGINX_OPEN_FILE_CACHE_INACTIVE=300
        NGINX_OPEN_FILE_CACHE_VALID=120
        NGINX_OPEN_FILE_CACHE_MIN_USES=1
    fi
}

# ── 获取有效内存 ─────────────────────────────────────────────
get_effective_memory_mb() {
    local mem_mb

    if [[ -n "${HW_MEM_GB:-}" ]] && [[ "${HW_MEM_GB}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v v="${HW_MEM_GB}" 'BEGIN { print int(v * 1024 + 0.5) }'
        return
    fi

    mem_mb=$(awk '/MemTotal/{print int($2/1024 + 0.5)}' /proc/meminfo)

    if (( mem_mb >= 1792 && mem_mb < 2048 )); then
        echo 2048
    elif (( mem_mb >= 3584 && mem_mb < 4096 )); then
        echo 4096
    elif (( mem_mb >= 7168 && mem_mb < 8192 )); then
        echo 8192
    else
        echo "$mem_mb"
    fi
}

# ── 生成 nginx.conf ──────────────────────────────────────────
generate_nginx_conf() {
    log_step "生成 nginx.conf..."

    local cpu_cores
    cpu_cores=$(nproc)

    local worker_processes="auto"
    [[ $cpu_cores -eq 1 ]] && worker_processes="1"

    local mem_mb mem_gb_display
    if [[ -n "${HW_MEM_GB:-}" ]] && [[ "${HW_MEM_GB}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        mem_mb=$(awk -v v="${HW_MEM_GB}" 'BEGIN { print int(v * 1024 + 0.5) }')
        mem_gb_display="${HW_MEM_GB}"
    else
        mem_mb=$(get_effective_memory_mb)
        mem_gb_display=$(awk -v m="${mem_mb}" 'BEGIN { printf "%.1f", m / 1024 }')
    fi

    select_nginx_profile "$cpu_cores" "$mem_mb"

    # 代理转发会同时占用客户端和上游连接，按 worker_connections 动态留余量。
    local worker_rlimit_nofile=$(( NGINX_WORKER_CONNECTIONS * 2 + 8192 ))

    if [[ -f /etc/nginx/nginx.conf ]]; then
        rm -f /etc/nginx/nginx.conf.bak.*
        cp /etc/nginx/nginx.conf \
           "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)"
    fi

    cat > /etc/nginx/nginx.conf << CONF
# ============================================================
# /etc/nginx/nginx.conf
# 自动生成 | nginx $(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1 || echo "unknown")
# CPU: ${cpu_cores}C | MEM: ${mem_gb_display}G | $(date '+%Y-%m')
# PROFILE: ${NGINX_PROFILE}
# ============================================================
user nginx;
worker_processes ${worker_processes};
# 按代理连接峰值动态设置，和 systemd LimitNOFILE/内核 fd 上限保持匹配
worker_rlimit_nofile ${worker_rlimit_nofile};
worker_cpu_affinity auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections ${NGINX_WORKER_CONNECTIONS};
    multi_accept       on;
    use                epoll;
    accept_mutex       off;
}

http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    include /etc/nginx/cloudflare_real_ip.conf;

    log_format main '\$final_real_ip - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" rt=\$request_time ut="\$upstream_response_time"';

    # P8修复：403 安全事件单独保留，其余 4xx 继续过滤
    map \$status \$loggable {
        403     1;
        ~^4     0;
        default 1;
    }

    map \$http_user_agent \$bad_ua {
        ~*zgrab               1;
        ~*masscan             1;
        ~*python-requests     1;
        ~*Go-http-client      1;
        ~*InternetMeasurement 1;
        default               0;
    }

    map "\${loggable}\${bad_ua}" \$do_log {
        "10"    1;
        default 0;
    }

    access_log /var/log/nginx/access.log main buffer=128k flush=10s if=\$do_log;

    sendfile    on;
    tcp_nopush  on;
    tcp_nodelay on;

    # P5修复：全局 keepalive 改为 65s，xhttp/grpc 在 location 内单独覆盖
    keepalive_timeout  ${NGINX_KEEPALIVE_TIMEOUT}s;
    keepalive_requests ${NGINX_KEEPALIVE_REQUESTS};

    client_max_body_size        0;
client_body_timeout 60s;  # 修复: 7200→60s 防慢速攻击；代理 location 内显式覆盖 7200s
    client_header_timeout       300s;
    # P7修复：缓冲区按实际需求收缩，避免峰值内存超物理内存
    client_body_buffer_size     128k;
    client_header_buffer_size   4k;
    large_client_header_buffers 4 16k;
send_timeout 60s;  # 修复: 7200→60s 非代理 location 不需要长超时

    server_tokens             off;
    reset_timedout_connection on;
    server_names_hash_bucket_size 128;
    server_names_hash_max_size    1024;
    types_hash_max_size           2048;

    lingering_time    60s;
    lingering_timeout 10s;

    proxy_buffering          off;
    proxy_request_buffering  off;
    proxy_max_temp_file_size 0;
    proxy_buffer_size        64k;
    proxy_buffers            8 64k;
    proxy_busy_buffers_size  128k;
    proxy_connect_timeout    15s;
    proxy_send_timeout       7200s;
    proxy_read_timeout       7200s;
    proxy_socket_keepalive   on;
    proxy_http_version       1.1;

    proxy_next_upstream         off;
    proxy_next_upstream_timeout 0;
    proxy_next_upstream_tries   0;

    open_file_cache          max=${NGINX_OPEN_FILE_CACHE_MAX} inactive=${NGINX_OPEN_FILE_CACHE_INACTIVE}s;
    open_file_cache_valid    ${NGINX_OPEN_FILE_CACHE_VALID}s;
    open_file_cache_min_uses ${NGINX_OPEN_FILE_CACHE_MIN_USES};
    open_file_cache_errors   on;

    gzip off;

    limit_req_zone  \$final_real_ip zone=websocket:20m rate=200r/s;
    limit_req_zone  \$final_real_ip zone=health:1m    rate=10r/s;
    limit_conn_zone \$final_real_ip zone=conn_limit:20m;

    include /etc/nginx/ssl/*.conf;
    include /etc/nginx/conf.d/*.conf;
}

# ============================================================
# Stream 块 - SNI 分流
# ============================================================
stream {
    log_format stream_basic '\$remote_addr [\$time_local] '
                             '\$protocol \$status \$bytes_sent \$bytes_received '
                             '\$session_time "\$ssl_preread_server_name"';

    map \$ssl_preread_server_name \$stream_loggable {
        ""      0;
        default 1;
    }

    access_log /var/log/nginx/stream.log stream_basic if=\$stream_loggable;

    map \$ssl_preread_server_name \$backend {
$(generate_sni_map)
        # -- SNI 陷阱兜底 -----------------------------------------
        default               127.0.0.1:8400;
    }

    server {
        listen 443 fastopen=256;
        listen [::]:443 fastopen=256;
        ssl_preread           on;
        proxy_pass            \$backend;
        proxy_connect_timeout 10s;
        proxy_timeout         7200s;
        proxy_protocol        on;
    }

    # -- 中间层: 消费 proxy_protocol 后转发给 sing-box ----------
    server {
        listen 127.0.0.1:8360 proxy_protocol;
        proxy_pass            127.0.0.1:8330;
        proxy_connect_timeout 10s;
        proxy_timeout         7200s;
    }

    # -- 中间层: 消费 proxy_protocol 后转发给 caddy-naive -------
    server {
        listen 127.0.0.1:8370 proxy_protocol;
        proxy_pass            127.0.0.1:8340;
        proxy_connect_timeout 10s;
        proxy_timeout         7200s;
    }
}
CONF

    log_info "nginx.conf 生成完成"
}

# ── 生成 SNI 路由映射 ────────────────────────────────────────
# P4修复：Reality serverNames 里的所有域名都加进 stream map 指向 8320
generate_sni_map() {
    local had_output=0
    local sn
    local -A seen_sni=()

    # Reality 自有域名
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        [[ $had_output -eq 0 ]] && echo "        # -- Reality 自建域名 → 8320 --------------------------"
        echo "        ${REALITY_DOMAIN}     127.0.0.1:8320;"
        seen_sni["${REALITY_DOMAIN}"]=1
        had_output=1
    fi

    # XHTTP-Reality 自有域名 → 8325（xhttp-reality inbound）
    if [[ -n "${XHTTP_REALITY_DOMAIN:-}" && -z "${seen_sni[${XHTTP_REALITY_DOMAIN}]:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- xhttp-reality 自有域名 → 8325 -------------------"
        echo "        ${XHTTP_REALITY_DOMAIN}     127.0.0.1:8325;"
        seen_sni["${XHTTP_REALITY_DOMAIN}"]=1
        had_output=1
    fi

    # Reality 公共 serverNames：仅公共 SNI 模式（未分配自有 Reality 域名）才路由到 8320
    # 自建域名模式：serverNames 已收敛为 REALITY_DOMAIN；即便 state 残留公共名
    #   （旧版本产物），也绝不写 8320 死路由——公共名此时只可能是 xhttp-reality SNI(8325)。
    # P4修复：Reality serverNames 里的公共域名加进 stream map 指向 8320，
    #         但 XHTTP_REALITY_SNI / XHTTP_REALITY_DOMAIN 必须留给 8325，
    #         否则 seen_sni 去重会把 8325 的 xhttp-reality 路由吞掉（节点不可达）。
    if [[ -z "${REALITY_DOMAIN:-}" && -n "${REALITY_SERVER_NAMES:-}" ]]; then
        [[ $had_output -eq 0 ]] && echo "        # -- Reality serverNames 全部路由到 8320 ---------------"
        for sn in "${REALITY_SERVER_NAMES[@]}"; do
            [[ -n "$sn" ]] || continue
            # 保留给 xhttp-reality 的 SNI 不能被 8320 抢占
            [[ "$sn" == "${XHTTP_REALITY_SNI:-}" || "$sn" == "${XHTTP_REALITY_DOMAIN:-}" ]] && continue
            [[ -n "${seen_sni[$sn]:-}" ]] && continue
            echo "        ${sn}     127.0.0.1:8320;"
            seen_sni["$sn"]=1
        done
        had_output=1
    fi

    # XHTTP_REALITY_SNI 单独路由到 8325（可能同时出现在 REALITY_SERVER_NAMES，已在上面跳过）
    if [[ -n "${XHTTP_REALITY_SNI:-}" && -z "${seen_sni[${XHTTP_REALITY_SNI}]:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- xhttp-reality 公共 SNI → 8325 --------------------"
        echo "        ${XHTTP_REALITY_SNI}     127.0.0.1:8325;"
        seen_sni["${XHTTP_REALITY_SNI}"]=1
        had_output=1
    fi

    if [[ -n "${XHTTP_DOMAIN:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        if [[ -n "${GRPC_DOMAIN:-}" && "${GRPC_DOMAIN}" == "${XHTTP_DOMAIN}" ]]; then
            echo "        # -- xhttp + gRPC CDN 回源（同域名合并到 8380，按 path 分流）--"
        else
            echo "        # -- xhttp CDN 回源 -----------------------------------"
        fi
        echo "        ${XHTTP_DOMAIN}        127.0.0.1:8380;"
        had_output=1
    fi

    if [[ -n "${GRPC_DOMAIN:-}" && "${GRPC_DOMAIN}" != "${XHTTP_DOMAIN:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- gRPC CDN 回源 ------------------------------------"
        echo "        ${GRPC_DOMAIN}         127.0.0.1:8390;"
        had_output=1
    fi

    if [[ -n "${ANYTLS_DOMAIN:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- AnyTLS -> nginx 中间层 -> sing-box ---------------"
        echo "        ${ANYTLS_DOMAIN}       127.0.0.1:8360;"
    fi

    if [[ -n "${NAIVE_DOMAIN:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- NaiveProxy -> nginx 中间层 -> caddy-naive ------"
        echo "        ${NAIVE_DOMAIN}       127.0.0.1:8370;"
    fi

    # DoH 入口（独立落点才走这里）。域名在 modules/mosdns.sh 的
    # configure_doh_entry 里选定。
    #
    # ⚠️ 域名【必须】从 state 读，不能只用内存里的 $DOH_DOMAIN。
    # $DOH_DOMAIN 只是 ensure_doh_conf 顺手赋的全局，而下面这两条路径都
    # 直接调 generate_nginx_conf、不经过 ensure_doh_conf：
    #   · modules/sync.sh:157  —— 模块热更新
    #   · run_nginx()          —— nginx.sh 自己的完整流程
    # 那样本段会被静默跳过：443 上该域落到 default 陷阱端口、DoH 全断，
    # 而脚本一路报成功（与 ensure_doh_conf 门控是同一类「静默少一条」故障）。
    # state 才是「当前生效配置」的事实来源，读它就不依赖调用顺序。
    # 同时要求 doh.conf 存在：路由只在 server 块确实存在时才该出现，
    # 否则 443 会把该 SNI 转到没人监听的 8410。
    #
    # ⚠️ 只有【独立落点】才写这条：共用落点下该域的 443 必须继续指向协议
    # 自己的后端（8380/8390/8320/8325），写了这条会把协议流量全抢到 8410 ——
    # 协议当场断，且症状是「协议连不上而 DoH 反而是好的」，极难联想。
    # 落点由 _doh_target_mode 读 state 得出，与调用顺序无关。
    local _doh_domain="${DOH_DOMAIN:-$(get_state 'DOH_DOMAIN' '')}"
    if [[ -n "$_doh_domain" && "$(_doh_target_mode "$_doh_domain")" == "standalone" \
          && -f /etc/nginx/conf.d/doh.conf \
          && -z "${seen_sni[$_doh_domain]:-}" ]]; then
        [[ $had_output -eq 1 ]] && echo ""
        echo "        # -- DoH 入口 -> 8410 ---------------------------------"
        echo "        ${_doh_domain}       127.0.0.1:8410;"
        seen_sni["$_doh_domain"]=1
    fi
}

# ── DoH 入口（反代本机 mosdns-x）─────────────────────────────
# 入口本体是 /etc/nginx/doh_location.conf 里那一个 location 块，落点有两种：
#   · 独立落点：该域没有别的协议占 443 → 本函数写 conf.d/doh.conf 的 8410
#     vhost，location 在它里面，443 路由由 generate_sni_map 指向 8410。
#   · 共用落点：该域的 443 已经被 xhttp/grpc/Reality 的 vhost 占了 → 那个
#     vhost（在 servers.conf 里，每次重配都会被重写）include 同一个 location
#     文件，【不再写 8410 那条路由】—— 写了会把协议流量全抢走。
# 两种落点的 doh.conf 都必须存在，见下面 body 里的说明。
# TLS 在 nginx 终结，后端是 127.0.0.1:15353/dns-query（明文 http）。
# state: DOH_DOMAIN（空 = 不启用）/ DOH_PATH（生成后保存）/
#        DOMAIN_PROTO_<域> 的标签决定落点。
# ⚠️ 本函数【只认 state，不提问】：域名/路径的问答在 modules/mosdns.sh 的
# configure_doh_entry（主菜单 y「安装 mosdns-x」）—— DoH 入口的后端就是
# mosdns-x，配入口属于装 mosdns-x 的一部分，不该长在「配置 Nginx」中间。
#
# DoH 候选域名与「能否共用」的判据见上面 _doh_domain_usable。
# _doh_candidates 现在只被 modules/mosdns.sh 调用（本文件内已无读者），保留。

# ── DoH 候选与落点判定 ───────────────────────────────────────
# DoH 的入口本体是一个 nginx 的 location 块，所以【能不能和别的协议共用域名】
# 只取决于：该域 443 分流过去之后，TLS 是在谁那里终结的。nginx 终结 → 把
# location 塞进那个 vhost 即可共用；别的组件终结 → nginx 那段根本不跑。
# 2026-09-30 在测试机逐协议实测（临时往各 vhost 注入 location 后打真查询）：
# 所以下面的过滤只排除 singbox / naiveproxy，其余一律可用。

# 该域能否作为 DoH 落点：TLS 在 nginx 终结（即不属于那两个组件）+ 证书已签。
# 证书路径解析与 generate_servers_conf 完全一致。
_doh_domain_usable() {
    local domain="$1"
    [[ -n "$domain" ]] || return 1
    local suffix protos
    suffix=$(printf '%s' "$domain" | tr '.' '_')
    protos=$(get_state "DOMAIN_PROTO_${suffix}" "")
    case ",${protos}," in
        *,singbox,*|*,naiveproxy,*) return 1 ;;
    esac
    local root cert_path
    root=$(printf '%s' "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    cert_path=$(get_state "CERT_PATH_${root//./_}" "")
    [[ -z "$cert_path" ]] && cert_path="/etc/letsencrypt/live/${root}"
    [[ -f "${cert_path}/fullchain.pem" ]]
}

# DoH 落点模式（由 DOH_DOMAIN 的 DOMAIN_PROTO_ 标签决定），$1 省略时读 state：
#   off        未启用
#   blocked    该域的 TLS 由 AnyTLS/Naive 自己终结，nginx 挂不上 DoH
#   standalone 该域没有 TCP/443 的 nginx vhost → 独立 8410 vhost（doh.conf）
#   xhttp / grpc / reality / xhttp-reality → 塞进对应的那个 vhost，共用域名
# 判定只读 state，不依赖内存全局，故任何调用顺序下都一致。
_doh_target_mode() {
    local domain="${1:-$(get_state 'DOH_DOMAIN' '')}"
    [[ -n "$domain" ]] || { echo "off"; return 0; }
    local suffix protos
    suffix=$(printf '%s' "$domain" | tr '.' '_')
    protos=$(get_state "DOMAIN_PROTO_${suffix}" "")
    case ",${protos}," in
        *,singbox,*|*,naiveproxy,*) echo "blocked";       return 0 ;;
        *,xray-xhttp,*)             echo "xhttp";         return 0 ;;
        *,xray-grpc,*)              echo "grpc";          return 0 ;;
        *,xray-reality,*)           echo "reality";       return 0 ;;
        *,xhttp-reality,*)          echo "xhttp-reality"; return 0 ;;
    esac
    echo "standalone"
}

# stdout 每行 "域名<TAB>mode<TAB>protos"。纯查询：不加载模块。
_doh_candidates() {
    local registry d suffix
    registry=$(get_state "DOMAIN_REGISTRY" "")
    for d in $registry; do
        [[ -n "$d" ]] || continue
        _doh_domain_usable "$d" || continue
        suffix=$(echo "$d" | tr '.' '_')
        printf '%s\t%s\t%s\n' "$d" \
            "$(get_state "DOMAIN_MODE_${suffix}" "direct")" \
            "$(get_state "DOMAIN_PROTO_${suffix}" "")"
    done
}

# 写 DoH 的 location 正文 —— 全仓库唯一一份实现，两种落点共用：
#   · 独立落点 → conf.d/doh.conf 的 8410 vhost include 它
#   · 共用落点 → servers.conf 里对应协议的 vhost include 它
# 放 /etc/nginx/ 而不是 conf.d/：conf.d/*.conf 是在 http 块里【整段】include 的，
# 这里装的是 location 块，放进 conf.d 会变成 http 级指令 → nginx -t 直接报错。
# 内容一致时不重写（mtime 稳定，便于用 cmp 核对是否真的变过）。
_doh_write_location_file() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    local out="/etc/nginx/doh_location.conf"
    local want
    want=$(cat << CONF
# ===================================================================
# /etc/nginx/doh_location.conf — DoH 的 location 正文（只此一份）
# 自动生成，请勿手动编辑 | 由 modules/nginx.sh 的 _doh_write_location_file 写出
#
# 两种落点共用本文件：
#   · 独立落点（hysteria2 域 / 无协议的空闲域）→ conf.d/doh.conf 的 8410 vhost
#   · 共用落点（xhttp / grpc / Reality 域）→ servers.conf 里对应协议的 vhost
# 路径取自 state 的 DOH_PATH；换路径 = 主菜单 y 改完重跑。
# ===================================================================
location = ${path} {
    # DoH 只需 GET/POST（RFC 8484）
    limit_except GET POST { deny all; }
    # zone=doh 定义在 conf.d/doh.conf —— 两种落点都会生成那份文件，且它在
    # conf.d 里 glob 排在 servers.conf 之前（nginx 是 parse 期按名查 zone 的）。
    # 直连域名（无 Cloudflare 一层），防滥用只能靠这里。
    limit_req zone=doh burst=900 nodelay;
    # ⚠️ 必须同时降日志级别，否则限流拒绝会变成「客户端被封 24h」。
    # 默认 limit_req_log_level=error，拒绝时往 error.log 写
    # "limiting requests, excess: ... by zone \\"doh\\""；
    # 而 /etc/crowdsec/acquis.yaml 采集的就是 /var/log/nginx/error.log，
    # 场景 crowdsecurity/nginx-req-limit-exceeded（leakspeed 60s / capacity 5）
    # 只要同一 IP 在 60 秒内拒 5 次就下 24h ban。后果不是「丢几个包」而是
    # 整个 IP 被 nftables 丢掉、连重试都进不来 —— 自家路由器一触发就是
    # 全量 DNS 断 24h 且无法自愈，且是自激的（拒绝→解析器重试→更多拒绝）。
    # 注意【把 doh.log 移出采集目录挡不住这条路】：触发物在 error.log。
    # 本机 error_log 级别是 warn，notice 低于阈值会被直接丢弃、不落盘；
    # 限流本身照常生效（照样回 503），503 仍记在上面那行 access_log 里。
    limit_req_log_level notice;
    client_max_body_size 4k;
    # 独立目录，避开 CrowdSec 的 /var/log/nginx/*.log 采集
    access_log /var/log/nginx-doh/doh.log main;

    proxy_pass         http://127.0.0.1:15353/dns-query;
    proxy_http_version 1.1;
    proxy_set_header   X-Real-IP \$final_real_ip;
    proxy_set_header   X-Forwarded-For \$final_real_ip;
    proxy_connect_timeout 5s;
    proxy_send_timeout    10s;
    proxy_read_timeout    10s;
    proxy_buffering    off;
}
CONF
)
    if [[ -f "$out" ]] && [[ "$(cat "$out")" == "$want" ]]; then
        return 0
    fi
    printf '%s\n' "$want" > "${out}.new" && mv -f "${out}.new" "$out"
}

ensure_doh_conf() {
    local conf="/etc/nginx/conf.d/doh.conf"

    DOH_DOMAIN=$(get_state "DOH_DOMAIN" "")
    DOH_PATH=$(get_state "DOH_PATH" "")

    # ── 日志目录：刻意【不】放 /var/log/nginx/ ──────────────────
    # CrowdSec 的 /etc/crowdsec/acquis.d/setup.nginx.yaml 采集
    # /var/log/nginx/*.log 并按 type: nginx 解析。DoH 日志里每条都带
    # 访问路径（路径本身就是口令），且家里路由器查询量大，落进采集范围
    # 既泄露口令、又可能被通用 http 场景判成攻击而把路由器封掉（家里 DNS 全灭）。
    # 放独立目录 + 独立 logrotate，绕开那个通配。注意 logrotate.d/nginx
    # 只 glob /var/log/nginx/*.log，本目录必须自带轮转配置，否则无限增长。
    mkdir -p /var/log/nginx-doh
    chmod 755 /var/log/nginx-doh
    chown -R nginx:nginx /var/log/nginx-doh 2>/dev/null || \
    chown -R www-data:www-data /var/log/nginx-doh 2>/dev/null || true

    # ── 落点模式 ─────────────────────────────────────────────
    # 只读 state 的协议标签（不看内存全局），与 generate_sni_map /
    # generate_servers_conf 读到的是同一个答案，故任何调用顺序下都一致。
    local mode
    mode=$(_doh_target_mode "$DOH_DOMAIN")

    # 该域的 TLS 由 AnyTLS/Naive 组件自己终结，nginx 的 location 挂不上去
    # （实测：AnyTLS 域 HTTP2 framing 错、Naive 域被 Caddy 自己回了 404）。
    # 不静默 —— 把原因喊出来，并清掉可能残留的产物，否则残留的 doh.conf 配上
    # 旧路由会让 443 一直被转到没人应答的 8410（同一类「静默少一条」故障）。
    if [[ "$mode" == "blocked" ]]; then
        log_error "DoH 落点 ${DOH_DOMAIN} 不可用：该域 TLS 由 AnyTLS/Naive 组件自己终结，nginx 挂不上 DoH"
        log_error "  改选 xhttp/grpc/Reality 域，或一个没有被协议占用的空闲域（主菜单 y）"
        rm -f "$conf" /etc/nginx/doh_location.conf
        return 0
    fi

    # ⚠️ 这里【没有】「文件已存在就早返回」的幂等分支（旧版有）。加它会让
    # 「落点模式变了」变成静默 no-op：state 说共用、磁盘上还是旧的 8410 vhost，
    # 而 generate_sni_map 已经按新模式不写那条路由 → 443 上该域既不路由到 8410、
    # 也没人 include location，DoH 全断而脚本一路报成功。现在一律按 state 重算，
    # 只在内容真的不同时才落盘（mtime 稳定，可用 cmp 核对）。

    # ── 未启用则【静默跳过】，本函数不再提问 ─────────────────
    # 域名/路径的问答属于「安装/配置 mosdns-x」那条菜单（modules/mosdns.sh 的
    # configure_doh_entry）—— DoH 入口的后端是 mosdns-x，配它属于装 mosdns-x
    # 的一部分。长在「配置 Nginx」流程中间时，重配一次 Nginx 就被问一次，而
    # 这件事跟 Nginx 关系不大（用户原话：「这个设置不合理,应该列一个单独的选项」）。
    # 现在本函数只认 state：DOH_DOMAIN 为空 = 未启用，直接返回，不阻塞、不重写。
    if [[ -z "$DOH_DOMAIN" ]]; then
        log_info "未启用 DoH 入口（启用/修改：主菜单 y「安装 mosdns-x」）"
        return 0
    fi

    log_step "配置 DoH 入口..."

    # ── 路径：state 里有就用，没有则随机生成（仓库里不写死默认值）──
    # 同样不提问：正常路径下 DOH_PATH 由 mosdns.sh 落 state，这里只是兜底
    # （例如用户手工把 DOH_DOMAIN 写进 state 的情况）。
    if [[ -z "$DOH_PATH" ]]; then
        DOH_PATH="/dns-$(openssl rand -hex 6)"
        save_state "DOH_PATH" "$DOH_PATH"
    fi

    # ── location 正文（两种落点共用同一份，先落盘）──────────
    # 后面 doh.conf / servers.conf 都只是 include 它，实现只有这一处。
    if ! _doh_write_location_file "$DOH_PATH"; then
        log_error "DoH location 文件写出失败（DOH_PATH='${DOH_PATH}'），跳过 DoH 入口"
        return 0
    fi

    local want_conf mode_note=""
    if [[ "$mode" == "standalone" ]]; then
        # ── 证书（复用 generate_servers_conf 的解析方式）────────
        local root cert_path
        root=$(printf '%s' "$DOH_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
        cert_path=$(get_state "CERT_PATH_${root//./_}" "")
        [[ -z "$cert_path" ]] && cert_path="/etc/letsencrypt/live/${root}"
        if [[ ! -f "${cert_path}/fullchain.pem" ]]; then
            log_error "证书不存在: ${cert_path}/fullchain.pem，跳过 DoH 入口"
            DOH_DOMAIN=""
            return 0
        fi

        want_conf=$(cat << CONF
# ===================================================================
# /etc/nginx/conf.d/doh.conf — DoH 入口（反代本机 mosdns-x）
# 落点：独立（该域没有别的协议占 443）。由 install.sh 生成；
# 内容一致时重复执行不会改写本文件。
# 换域名/路径：主菜单 y「安装 mosdns-x」（它会先删本文件再重生成）。
# 443 路由在 nginx.conf 的 stream map 里指向 127.0.0.1:8410。
# location 正文不在这里，见 /etc/nginx/doh_location.conf。
# ===================================================================

# 限流 key 必须用 \$final_real_ip，不能用 \$remote_addr：请求经 stream 的
# SNI 分流从 127.0.0.1:8410 进来，\$remote_addr 对所有人都恒为 127.0.0.1，
# 一个桶装全部客户端，一触发限流就是全员被拒。
# \$final_real_ip 的 map 在 /etc/nginx/cloudflare_real_ip.conf，由 nginx.conf:26
# 加载，早于 conf.d（nginx.conf:109），此处 parse 期可解析。
# 阈值按实测定：单个客户端峰值 301 次/秒（12 小时样本里有 12 个秒超 60/s）。
# 取 300r/s + burst 900 让真实突发整体通过，只拦持续洪水（5000/s 会被削到
# ~300/s）。凭直觉写小值（如 20r/s + burst 60）会把自家路由器的缓存未命中
# 突发打掉 —— 那等于自己把家里 DNS 弄挂，比不限流更糟。
# ⚠️ 共用落点时不生成 8410 vhost，但【本文件的 zone 定义照旧生成】—— zone=doh
# 得有个家，且 conf.d 里 doh.conf 的 glob 顺序排在 servers.conf 之前
# （d < s），而 nginx 是 parse 期按名查 zone 的。改名/挪走会让 nginx 起不来。
limit_req_zone \$final_real_ip zone=doh:10m rate=300r/s;

server {
    listen 127.0.0.1:8410 ssl proxy_protocol;
    http2  on;
    server_name ${DOH_DOMAIN};

    ssl_certificate     ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;

    server_tokens off;

    include /etc/nginx/doh_location.conf;

    location / {
        return 404;
    }
}
CONF
)
    else
        # ── 共用落点：location 由 servers.conf 里对应协议的 vhost include ──
        # 本文件只负责 zone 定义与「DoH 已启用」标记。
        want_conf=$(cat << CONF
# ===================================================================
# /etc/nginx/conf.d/doh.conf — DoH 限流区（反代本机 mosdns-x）
# 落点：与 ${DOH_DOMAIN} 的 ${mode} vhost 共用域名 —— server 块与
# location 在 servers.conf 的那个 vhost 里（include
# /etc/nginx/doh_location.conf），本文件不生成 8410 vhost。
# 由 install.sh 生成；内容一致时重复执行不会改写本文件。
# ===================================================================

# 限流 key 必须用 \$final_real_ip，不能用 \$remote_addr（见 doh_location.conf 说明）。
# \$final_real_ip 的 map 在 /etc/nginx/cloudflare_real_ip.conf，由 nginx.conf:26
# 加载，早于 conf.d（nginx.conf:109），此处 parse 期可解析。
# 阈值按实测定：单个客户端峰值 301 次/秒；取 300r/s + burst 900 让真实突发
# 整体通过，只拦持续洪水。写小值会把自家路由器的缓存未命中突发打掉。
# ⚠️ 本文件即使在不生成 8410 vhost 的共用落点下也【必须】存在：zone=doh 得
# 有个家，且 conf.d 里它 glob 排在 servers.conf 之前（d < s），而 nginx 是
# parse 期按名查 zone 的。改名/挪走会让 nginx 起不来。
limit_req_zone \$final_real_ip zone=doh:10m rate=300r/s;
CONF
)
        mode_note="（与 ${DOH_DOMAIN} 的 ${mode} vhost 共用域名，未占用 8410）"
    fi

    if [[ ! -f "$conf" ]] || [[ "$(cat "$conf")" != "$want_conf" ]]; then
        printf '%s\n' "$want_conf" > "${conf}.new" && mv -f "${conf}.new" "$conf"
    fi

    # 该目录不在 /etc/logrotate.d/nginx 的 /var/log/nginx/*.log 通配内，
    # 必须自带轮转，否则无限增长。
    cat > /etc/logrotate.d/nginx-doh << 'CONF'
/var/log/nginx-doh/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0644 nginx nginx
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 $(cat /run/nginx.pid) 2>/dev/null || true
    endscript
}
CONF

    log_info "DoH 入口已生成: https://${DOH_DOMAIN}${DOH_PATH}${mode_note}"
}

# servers.conf 里是否存在「server_name == $1 且块内 include 了
# /etc/nginx/doh_location.conf」的 vhost。逐 server 块解析，不整文件 grep：
# 共用落点时 include 只在目标 vhost 里，而文件里有六七个 vhost，全文匹配会把
# 「include 跑到别的 vhost 去了」也判成通过。
_doh_servers_has_include() {
    awk -v d="$1" '
        /^server *\{/ { inb=1; hit=0; name=0; next }
        inb && /server_name/ { for (i=2; i<=NF; i++) { gsub(/;/,"",$i); if ($i==d) name=1 } }
        inb && /include[ \t]+\/etc\/nginx\/doh_location\.conf/ { hit=1 }
        inb && /^\}/ { if (name && hit) found=1; inb=0 }
        END { exit !found }
    ' /etc/nginx/conf.d/servers.conf
}

# ── DoH 入口自检（由 reload_nginx 在重启后调用）────────────────
# 为什么需要：这个入口最危险的故障模式是【静默】的 —— 配置生成成功、
# nginx 重启成功、脚本一路报成功，而 443 上这个域其实落到了 default
# 陷阱端口/伪装站（SNI map 缺条目），或打到了没装 mosdns-x 的后端。
# 用户侧表现为「家里 DNS 全挂」，服务端侧看起来一切正常。
# 实测过的两种失败外观：
#   · 路由没生效 → HTTP/1.1 + text/html（落到了伪装站）
#   · 后端没起   → HTTP/2  + 502
# 所以判据用 http_version/content_type，不用 HTTP 状态码。
# 从 127.0.0.1 连 443、不直连 8410：8410 要 proxy_protocol，直连必然失败，
# 且只有走 443 才真正经过那张会静默出错的 SNI map。
verify_doh_entry() {
    local domain path mode
    domain=$(get_state 'DOH_DOMAIN' '')
    path=$(get_state 'DOH_PATH' '')

    # 未启用 DoH → 静默通过（绝大多数机器走这条，不留噪音）
    [[ -z "$domain" ]] && return 0

    if [[ ! -f /etc/nginx/doh_location.conf ]]; then
        log_error "DoH 自检失败：state 里有 DOH_DOMAIN='${domain}'，但 /etc/nginx/doh_location.conf 不存在"
        log_error "  location 正文没落盘，入口等于不存在。重跑「配置 Nginx」重新生成。"
        return 1
    fi

    mode=$(_doh_target_mode "$domain")

    # ① 先确定性地断言「这个域的 vhost 里确实挂了 DoH 的 location」。
    # 放在 curl 之前，因为这是本功能唯一会【静默】出错的环节，而它的判定
    # 不依赖网络结果 —— 反过来说，挂不上时 curl 只会给出 000 或「打到了
    # 别处」这类模糊结果，照着那个报错去查会查错方向（实测踩过：报成
    # 「443 无响应」，真因是 map 里少了这一行）。
    case "$mode" in
        blocked)
            log_error "DoH 自检失败：${domain} 的 TLS 由 AnyTLS/Naive 组件自己终结，nginx 挂不上 DoH"
            log_error "  换个落点域名：主菜单 y"
            return 1
            ;;
        standalone)
            if ! awk -v d="$domain" '$1==d && $2=="127.0.0.1:8410;"{f=1} END{exit !f}' \
                 /etc/nginx/nginx.conf; then
                log_error "DoH 自检失败：nginx.conf 的 stream SNI map 里没有这条路由"
                log_error "      ${domain}       127.0.0.1:8410;"
                log_error "  443 上该域会落到 default 陷阱端口 —— DoH 全断，而其它步骤全部正常。"
                log_error "  修：重跑「配置 Nginx」（generate_sni_map 会从 state 补回该条目并重启）"
                return 1
            fi
            ;;
        *)
            # 共用落点：断言 include 行确实在【该域那个 vhost】里。不能整文件
            # grep —— servers.conf 里有六七个 vhost，include 跑到别的 vhost 里
            # 一样会被判成通过，而实际入口是不通的。
            if ! _doh_servers_has_include "$domain"; then
                log_error "DoH 自检失败：servers.conf 里没有「server_name ${domain} 且 include /etc/nginx/doh_location.conf」的 vhost"
                log_error "  443 上该域回到了协议自己的后端，DoH 全断而协议本身正常（最容易被忽略的一种）"
                log_error "  修：重跑「配置 Nginx」（generate_servers_conf 会按 state 重新注入 include）"
                return 1
            fi
            ;;
    esac

    # CDN 回源落点（xhttp/grpc）不做本机端到端探测，而且是【必然失败】——
    # 那两个 vhost 开头有 `if (\$redirect_to_fake) { rewrite ^ /_fake last; }`，
    # 它按 `geo \$remote_addr` 判「是不是从 Cloudflare 来的」，而 127.0.0.1
    # 一律判为不是 → 当场被 rewrite 到伪装页。经 CF 打进来才是正常的。
    # 后端是否活着由 verify_mosdns（直连 127.0.0.1:15353）另外保证。
    case "$mode" in
        xhttp|grpc)
            log_info "DoH 自检通过（确定性）: https://${domain}${path} → 已并入 ${mode} vhost"
            log_info "  ⚠️ 该域的反探测规则会把本机探测重写到伪装页，端到端必须从 CF 侧验"
            return 0
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        log_warn "DoH 自检：落点已确认，但本机无 curl，无法确认端到端是否真的通"
        return 0
    fi

    # ② 端到端探一次。走 443 的 SNI 正路，顺带验证证书与后端。
    local out http_ver ctype code
    out=$(curl -s -o /dev/null --noproxy '*' --max-time 10 \
              --resolve "${domain}:443:127.0.0.1" \
              -H 'accept: application/dns-message' \
              -w '%{http_version} %{content_type} %{http_code}' \
              "https://${domain}${path}?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB" \
          2>/dev/null) || out=""
    read -r http_ver ctype code <<<"$out"

    # 健康：HTTP/2 + application/dns-message（实测 RFC 8484 示例查询）
    if [[ "$ctype" == application/dns-message* ]]; then
        log_info "DoH 自检通过: https://${domain}${path} → HTTP/${http_ver} + application/dns-message"
        return 0
    fi

    # 502/504 → SNI 路由通、TLS 通，只是后端没起。后端是 mosdns-x，由
    # modules/mosdns.sh 安装（主菜单 y）。老机器上若 DoH 入口是手工配的、
    # 后端从未装过，这里也是同一副样子——故只告警不失败。
    if [[ "$code" == "502" || "$code" == "504" ]]; then
        log_warn "DoH 自检：入口已通，但后端 127.0.0.1:15353 无响应（HTTP ${code}）"
        log_warn "  后端是 mosdns-x：systemctl status mosdns 看是否在跑"
        log_warn "  未安装/未运行 → 主菜单 y「安装 mosdns-x」"
        return 0
    fi

    log_error "DoH 自检失败：${domain} 的 443 没有落到 DoH 入口"
    log_error "  实到 HTTP/${http_ver:-<无响应>} + ${ctype:-<无>}（HTTP ${code:-000}）"
    log_error "  应为 HTTP/2 + application/dns-message。查："
    log_error "    ss -lntp | grep -E ':443|:8410'        443/8410 是否在听"
    log_error "    cscli decisions list                    是否被 CrowdSec 封了"
    log_error "    nginx -T | grep -A2 'map .*ssl_preread' 该域是否被别的条目先匹配"
    return 1
}

# ── 生成 00-upstreams.conf ───────────────────────────────────
generate_upstreams_conf() {
    log_step "生成 upstream 配置..."

    cat > /etc/nginx/conf.d/00-upstreams.conf << 'CONF'
# ============================================================
# /etc/nginx/conf.d/00-upstreams.conf
# ============================================================
upstream vless_xhttp_backend {
    server 127.0.0.1:8300 max_fails=0 fail_timeout=30s;
    keepalive          256;
    keepalive_requests 10000;
# 与 Xray xhttp hMaxReusableSecs(1800-3600s) 形成梯度
# nginx(300s) < Xray 上限(3600s)，确保 nginx 先回收，避免持有对 Xray 已关闭的连接
keepalive_timeout 300s;
}

upstream vless_grpc_backend {
    server 127.0.0.1:8310 max_fails=0 fail_timeout=30s;
    keepalive          128;
    keepalive_requests 1000;
    # Fix: nginx must recycle before xray grpc idle_timeout(60s)
    # nginx(50s) < xray(60s): nginx closes idle conn first, preventing reuse of connections xray has already closed
    # See: nginx ngx_http_upstream_module keepalive_timeout docs
    keepalive_timeout  50s;
}
CONF

    log_info "upstream 配置生成完成"
}

# ── 生成 fallback.conf ───────────────────────────────────────
# P1修复：xhttp location 路径使用 ${XHTTP_PATH} 变量（与 xray 保持一致）
generate_fallback_conf() {
    log_step "生成 fallback 配置..."

    if declare -F load_latency_params &>/dev/null; then
        load_latency_params
    else
        LATENCY_GRPC_TIMEOUT=120
        LATENCY_PROXY_TIMEOUT=7200
    fi

    cat > /etc/nginx/conf.d/fallback.conf << CONF
# ============================================================
# /etc/nginx/conf.d/fallback.conf
# Reality Fallback 入口
# P1修复：xhttp path 与 xray 保持一致（均使用 XHTTP_PATH 变量）
# 注意：Xray Reality fallback xver=0，不发送 PROXY header，
# 因此 listen 不加 proxy_protocol
# ============================================================
server {
listen 127.0.0.1:8350;
    server_name   _;
    access_log    off;
    server_tokens off;
    gzip          on;
    gzip_vary     on;
    gzip_comp_level 2;
    gzip_min_length 1000;
    gzip_types    text/plain text/css application/json application/javascript
                  text/xml application/xml application/xml+rss text/javascript
                  image/svg+xml;

    # P1修复：路径与 xray xhttpSettings.path 保持一致
    location ${XHTTP_PATH} {
        gzip off;
        proxy_pass              http://vless_xhttp_backend;
        proxy_http_version      1.1;
        # Fix: "close" disables upstream keepalive reuse; xhttp half-close causes broken-pipe with Connection ""
        proxy_set_header        Connection "close";
        proxy_set_header        Host \$host;
 # fallback 经 xver=0 转发，无 proxy_protocol，使用 \$final_real_ip 获取真实 IP
        proxy_set_header        X-Real-IP \$final_real_ip;
        proxy_set_header        X-Forwarded-For \$final_real_ip;
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_cache             off;
        proxy_next_upstream         off;
        proxy_next_upstream_timeout 0;
        proxy_next_upstream_tries   0;
        client_max_body_size    0;
        proxy_connect_timeout   15s;
        proxy_send_timeout      ${LATENCY_PROXY_TIMEOUT}s;
        proxy_read_timeout      ${LATENCY_PROXY_TIMEOUT}s;
        # P5修复：fallback 长连接单独覆盖
        keepalive_timeout       ${LATENCY_PROXY_TIMEOUT}s;
    }

    location /${GRPC_SERVICE_NAME} {
        gzip off;
        grpc_pass            grpc://vless_grpc_backend;
        grpc_set_header      Host \$host;
        grpc_next_upstream   off;
        grpc_connect_timeout 15s;
        grpc_send_timeout    ${LATENCY_GRPC_TIMEOUT}s;
        grpc_read_timeout    ${LATENCY_GRPC_TIMEOUT}s;
        # fallback 直连长连接，跟 Reality 入口保持长超时
        grpc_buffer_size     128k;
        grpc_socket_keepalive on;
        keepalive_timeout    ${LATENCY_GRPC_TIMEOUT}s;
        client_max_body_size 0;
        client_body_timeout ${LATENCY_GRPC_TIMEOUT}s;
        send_timeout ${LATENCY_GRPC_TIMEOUT}s;
    }

    location / {
        root      /var/www/${REALITY_DOMAIN:-${XHTTP_DOMAIN:-html}};
        index     index.html;
        try_files \$uri \$uri/ /index.html;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Cache-Control "public, max-age=3600" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
    }
}
CONF

    log_info "fallback 配置生成完成"
}

# ── 清理已不在域名表中的伪装站目录 ───────────────────────────
# 域名表（ALL_DOMAINS，由注册表派生）是唯一事实来源：表里没有的域，它的
# /var/www/<域> 就是换域留下的孤儿。规则与 CF 账号孤儿一致——不按「换了几个」
# 分支，只看「在不在表里」。
# 三重护栏，宁可漏删不可误删：
#   1. 表为空 → 整体跳过（state 异常时绝不把 /var/www 清空）
#   2. 只删含点的目录名 → trap / html / Example 这类非域名目录天然免疫
#      （Example 是 download-media.sh 的媒体库 + 欧洲主题模板来源，不能动）
#   3. 本次 servers.conf 仍引用的路径一律保留 → 表与配置短暂不一致也不打断服务
_purge_orphan_webroots() {
    local all_domains
    all_domains=$(get_state "ALL_DOMAINS" "")

    if [[ -z "$all_domains" ]]; then
        log_warn "ALL_DOMAINS 为空，跳过 /var/www 孤儿目录清理（避免误删）"
        return 0
    fi

    local -A _keep=()
    local _d
    for _d in $all_domains; do
        [[ -n "$_d" ]] && _keep["$_d"]=1
    done

    # 本次生成的配置仍在引用的目录
    local _ref
    while read -r _ref; do
        [[ -n "$_ref" ]] && _keep["${_ref##*/}"]=1
    done < <(grep -o 'root *[^;]*;' /etc/nginx/conf.d/servers.conf 2>/dev/null \
             | sed 's/^root *//; s/;$//' || true)

    local _dir _name
    for _dir in /var/www/*/; do
        [[ -d "$_dir" ]] || continue
        _name=$(basename "$_dir")
        [[ "$_name" == *.* ]] || continue           # 非域名目录不动
        [[ -n "${_keep[$_name]:-}" ]] && continue    # 表内或仍被引用
        rm -rf "$_dir"
        log_info "已删除配置表不再引用的伪装站目录: /var/www/${_name}"
    done
}

# ── 生成 servers.conf ────────────────────────────────────────
generate_servers_conf() {
    log_step "生成 servers.conf..."

    # Preflight 互锁：servers.conf 是 SNI 路由的最终落地，写入前最后一道闸
    if declare -F preflight_config_check &>/dev/null; then
        if ! preflight_config_check "generate_servers_conf"; then
            log_error "servers.conf 生成已阻止"
            return 1
        fi
    fi

    if declare -F load_latency_params &>/dev/null; then
        load_latency_params
    else
        LATENCY_GRPC_TIMEOUT=120
        LATENCY_PROXY_TIMEOUT=7200
    fi

    # ── 先写临时文件，写完再原子替换 ──────────────────────────
    # 原实现是 `: > servers.conf` 就地截断，之后逐段 >> 追加。这样中途失败
    # （set -e 下任意报错、或 heredoc 里变量展开出错）就会把线上文件留成
    # 0 字节或半截 —— 而 DoH 入口和其它所有代理都挂在这个文件上。
    # 更阴的是菜单路径：run_menu_action 用 `"$@" || {...}` 调用，
    # 整个函数体的 errexit 被关掉，中途失败不会中止，只会安静地写出半截文件。
    # 临时文件名以 .new 结尾，不匹配 nginx 的 conf.d/*.conf 通配，不会被 include。
    # 刻意不预先 `: >` 建文件：首个 cat >> 自会创建，这样「首次写入前就炸」
    # 不留任何残留；写到一半才炸也只留一个不被 include 的临时文件。
    local _out="/etc/nginx/conf.d/servers.conf.new"

    get_root_domain() {
        echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
    }

    # ── DoH 共用落点：把 location include 进目标协议的 vhost ────
    # 落点模式读 state（不看内存全局），与 ensure_doh_conf / generate_sni_map
    # 读到的是同一个答案。location 正文由 _doh_write_location_file 落到
    # /etc/nginx/doh_location.conf，这里只是「在谁里面 include 它」。
    # ⚠️ 注入必须在这里做（而不是像独立落点那样单开一个文件），因为共用落点的
    # server 块【就是】servers.conf 里这些 vhost —— 而 servers.conf 每次重配都
    # 被整体重写，手工往 vhost 里加 location 一定会被抹掉（当年 DoH 入口被从
    # servers.conf 里拎出来独立成文件，正是因为它扛不住重写；共用落点的解法
    # 不是绕开重写，而是让重写本身产出正确的注入）。
    local _doh_domain _doh_mode _doh_inc=""
    _doh_domain=$(get_state 'DOH_DOMAIN' '')
    _doh_mode=$(_doh_target_mode "$_doh_domain")
    case "$_doh_mode" in
        xhttp|grpc|reality|xhttp-reality)
            local _doh_path
            _doh_path=$(get_state 'DOH_PATH' '')
            if [[ -n "$_doh_path" ]] && _doh_write_location_file "$_doh_path"; then
                # 前导换行、结尾不带：空值时整段消失，输出与改造前逐字节一致
                _doh_inc=$(printf '\n    # DoH 入口 —— 与 %s 共用本域，别删（删了入口就断）\n    # location 正文在 /etc/nginx/doh_location.conf，由 state 的 DOH_PATH 生成\n    include /etc/nginx/doh_location.conf;' "$_doh_mode")
            else
                log_warn "DoH 落点 ${_doh_domain} 缺 DOH_PATH 或写不出 location 文件，本次不注入"
                _doh_mode="off"
            fi
            ;;
    esac

    # 只注入到「server_name 就是落点域名」的那份 vhost。按域名比对而不是按模式名：
    # xhttp 与 grpc 同域合并成一份 vhost 时也能正确落到那一份上。
    local _doh_inc_xhttp="" _doh_inc_grpc="" _doh_inc_reality="" _doh_inc_xr=""
    if [[ -n "$_doh_inc" ]]; then
        if [[ "${XHTTP_DOMAIN:-}" == "$_doh_domain" ]]; then _doh_inc_xhttp="$_doh_inc"; fi
        if [[ "${GRPC_DOMAIN:-}" == "$_doh_domain" ]]; then _doh_inc_grpc="$_doh_inc"; fi
        if [[ "${REALITY_DOMAIN:-}" == "$_doh_domain" ]]; then _doh_inc_reality="$_doh_inc"; fi
        if [[ "${XHTTP_REALITY_DOMAIN:-}" == "$_doh_domain" ]]; then _doh_inc_xr="$_doh_inc"; fi
    fi

    # xhttp CDN server 块
    if [[ -n "${XHTTP_DOMAIN:-}" ]]; then
        local xhttp_root cert_path
        xhttp_root=$(get_root_domain "${XHTTP_DOMAIN}")
        cert_path=$(get_state "CERT_PATH_${xhttp_root//./_}" "")
        [[ -z "$cert_path" ]] && cert_path="/etc/letsencrypt/live/${xhttp_root}"

        mkdir -p "/var/www/${XHTTP_DOMAIN}"
        generate_fake_site "/var/www/${XHTTP_DOMAIN}" 0

        # 同域名合并：xhttp 与 gRPC 共用同一域名时，gRPC location 并入此 server 块
        local grpc_merged_location=""
        if [[ -n "${GRPC_DOMAIN:-}" && "${GRPC_DOMAIN}" == "${XHTTP_DOMAIN}" ]]; then
            grpc_merged_location=$(cat << CONF

    # 同域名合并：gRPC location 并入 xhttp server 块（按 path 分流）
    location /${GRPC_SERVICE_NAME} {
        gzip       off;
        access_log off;
        limit_req  zone=websocket burst=100 nodelay;
        limit_conn conn_limit 200;

        grpc_pass             grpc://vless_grpc_backend;
        grpc_set_header       Host \$host;
        grpc_set_header       X-Real-IP \$final_real_ip;
        grpc_set_header       X-Forwarded-For \$final_real_ip;
        grpc_set_header       X-Forwarded-Proto \$scheme;
        grpc_set_header       Te "trailers";
        grpc_set_header       Content-Type "application/grpc";

        grpc_connect_timeout  15s;
        grpc_send_timeout     ${LATENCY_GRPC_TIMEOUT}s;
        grpc_read_timeout     ${LATENCY_GRPC_TIMEOUT}s;
        grpc_socket_keepalive on;
        grpc_next_upstream    off;
        # CF 免费版硬限制约 100s，中延迟默认 120s，高延迟用 300s
        grpc_buffer_size      128k;
        keepalive_timeout     ${LATENCY_GRPC_TIMEOUT}s;

        client_max_body_size  0;
        client_body_timeout   ${LATENCY_GRPC_TIMEOUT}s;
        send_timeout          ${LATENCY_GRPC_TIMEOUT}s;
    }
CONF
)
        fi

        cat >> "$_out" << CONF

# ===================================================================
# CDN ${XHTTP_DOMAIN} — xhttp
# P1修复：location 路径与 xray xhttpSettings.path 保持一致
# ===================================================================
server {
    listen 127.0.0.1:8380 ssl proxy_protocol;
    http2  on;
    server_name ${XHTTP_DOMAIN};
    gzip   on;
    gzip_vary       on;
    gzip_comp_level 2;
    gzip_min_length 1000;
    gzip_types      text/plain text/css application/json application/javascript
                    text/xml application/xml application/xml+rss text/javascript
                    image/svg+xml;

    ssl_certificate     ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;

    access_log /var/log/nginx/${XHTTP_DOMAIN}.log    main buffer=32k flush=5m;
    error_log  /var/log/nginx/${XHTTP_DOMAIN}.err.log warn;

    resolver 127.0.0.1 valid=300s;
    resolver_timeout 5s;
    server_tokens off;

    if (\$redirect_to_fake) {
        rewrite ^ /_fake last;
    }

    # P1修复：路径与 xray xhttpSettings.path 保持一致
    location ${XHTTP_PATH} {
        gzip       off;
        access_log off;
        limit_req  zone=websocket burst=100 nodelay;
        limit_conn conn_limit 200;

        proxy_pass              http://vless_xhttp_backend;
        proxy_http_version      1.1;
        # Fix: "close" disables upstream keepalive reuse; xhttp half-close causes broken-pipe with Connection ""
        proxy_set_header        Connection "close";
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$final_real_ip;
        proxy_set_header        X-Forwarded-For \$final_real_ip;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;

 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header X-Accel-Buffering "no" always;
 add_header Access-Control-Allow-Origin "*" always;
 add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
 add_header Access-Control-Allow-Headers "*" always;
        proxy_hide_header Via;
        proxy_hide_header X-Cache;
        proxy_hide_header X-Cache-Status;

        proxy_connect_timeout       15s;
        proxy_send_timeout          ${LATENCY_PROXY_TIMEOUT}s;
        proxy_read_timeout          ${LATENCY_PROXY_TIMEOUT}s;
        proxy_buffering             off;
        proxy_request_buffering     off;
        chunked_transfer_encoding   on;
        proxy_cache                 off;
        proxy_socket_keepalive      on;
        proxy_redirect              off;
        proxy_next_upstream         off;
        proxy_next_upstream_timeout 0;
        proxy_next_upstream_tries   0;
        client_max_body_size        0;
        client_body_timeout         ${LATENCY_PROXY_TIMEOUT}s;
        send_timeout                ${LATENCY_PROXY_TIMEOUT}s;
        # P5修复：长连接在 location 内单独覆盖
        keepalive_timeout           ${LATENCY_PROXY_TIMEOUT}s;
        keepalive_requests          5000;
    }
${grpc_merged_location}
${_doh_inc_xhttp}
    location = /health {
        limit_req  zone=health burst=5 nodelay;
        access_log off;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Content-Type  "text/plain" always;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        return 200 "healthy\n";
    }

    location /_fake {
        internal;
        root      /var/www/${XHTTP_DOMAIN};
        index     index.html;
        try_files /index.html =200;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Cache-Control "public, max-age=3600" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
        access_log off;
    }

    location / {
        root  /var/www/${XHTTP_DOMAIN};
        index index.html;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires    30d;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }
        try_files \$uri \$uri/ /index.html;
    }
}
CONF
    fi

    # gRPC CDN server 块
    # 同域名时已合并进 xhttp server 块（8380），跳过独立 gRPC 块以避免端口/SNI 冲突
    if [[ -n "${GRPC_DOMAIN:-}" && "${GRPC_DOMAIN}" != "${XHTTP_DOMAIN:-}" ]]; then
        local grpc_root cert_path
        grpc_root=$(get_root_domain "${GRPC_DOMAIN}")
        cert_path=$(get_state "CERT_PATH_${grpc_root//./_}" "")
        [[ -z "$cert_path" ]] && cert_path="/etc/letsencrypt/live/${grpc_root}"

        mkdir -p "/var/www/${GRPC_DOMAIN}"
        generate_fake_site "/var/www/${GRPC_DOMAIN}" 1

        cat >> "$_out" << CONF

# ===================================================================
# CDN ${GRPC_DOMAIN} — gRPC
# ===================================================================
server {
    listen 127.0.0.1:8390 ssl proxy_protocol;
    http2  on;
    server_name ${GRPC_DOMAIN};
    gzip   on;
    gzip_vary       on;
    gzip_comp_level 2;
    gzip_min_length 1000;
    gzip_types      text/plain text/css application/json application/javascript
                    text/xml application/xml application/xml+rss text/javascript
                    image/svg+xml;

    ssl_certificate     ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;

    access_log /var/log/nginx/${GRPC_DOMAIN}.log    main buffer=32k flush=5m;
    error_log  /var/log/nginx/${GRPC_DOMAIN}.err.log warn;

    resolver 127.0.0.1 valid=300s;
    resolver_timeout 5s;
    server_tokens off;

    if (\$redirect_to_fake) {
        rewrite ^ /_fake last;
    }

    location /${GRPC_SERVICE_NAME} {
        gzip       off;
        access_log off;
        limit_req  zone=websocket burst=100 nodelay;
        limit_conn conn_limit 200;

        grpc_pass             grpc://vless_grpc_backend;
        grpc_set_header       Host \$host;
        grpc_set_header       X-Real-IP \$final_real_ip;
        grpc_set_header       X-Forwarded-For \$final_real_ip;
        grpc_set_header       X-Forwarded-Proto \$scheme;
        grpc_set_header       Te "trailers";
        grpc_set_header       Content-Type "application/grpc";

        grpc_connect_timeout  15s;
        grpc_send_timeout     ${LATENCY_GRPC_TIMEOUT}s;
        grpc_read_timeout     ${LATENCY_GRPC_TIMEOUT}s;
        grpc_socket_keepalive on;
        grpc_next_upstream    off;
        # CF 免费版硬限制约 100s，中延迟默认 120s，高延迟用 300s
        grpc_buffer_size      128k;
        keepalive_timeout     ${LATENCY_GRPC_TIMEOUT}s;

        client_max_body_size  0;
        client_body_timeout   ${LATENCY_GRPC_TIMEOUT}s;
        send_timeout          ${LATENCY_GRPC_TIMEOUT}s;
    }
${_doh_inc_grpc}
    location = /health {
        limit_req  zone=health burst=5 nodelay;
        access_log off;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Content-Type  "text/plain" always;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        return 200 "healthy\n";
    }

    location /_fake {
        internal;
        root      /var/www/${GRPC_DOMAIN};
        index     index.html;
        try_files /index.html =200;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
        add_header Cache-Control "public, max-age=3600" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
        access_log off;
    }

    location / {
        root  /var/www/${GRPC_DOMAIN};
        index index.html;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires    30d;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
            add_header Cache-Control "public, no-transform";
            access_log off;
        }
        try_files \$uri \$uri/ /index.html;
    }
}
CONF
    fi

    # Reality dest 伪装站（8321）：仅在使用自有域名时生成
    # xray 的 realitySettings.dest 指向此处，Reality 从本地真实证书读取指纹
    # 非 Xray 访客直接看到伪装网站，天然无外部流量可偷
    if [[ -n "${REALITY_DOMAIN:-}" ]]; then
        local reality_root reality_cert_path
        reality_root=$(get_root_domain "${REALITY_DOMAIN}")
        reality_cert_path=$(get_state "CERT_PATH_${reality_root//./_}" "")
        [[ -z "$reality_cert_path" ]] && reality_cert_path="/etc/letsencrypt/live/${reality_root}"

        mkdir -p "/var/www/${REALITY_DOMAIN}"
        generate_fake_site "/var/www/${REALITY_DOMAIN}" 2

        cat >> "$_out" << CONF

# ===================================================================
# Reality dest 伪装站 ${REALITY_DOMAIN}（8321）
# 不加 proxy_protocol（Reality xver=0 直连）
# ===================================================================
server {
    listen 127.0.0.1:8321 ssl;
    server_name ${REALITY_DOMAIN};

    ssl_certificate     ${reality_cert_path}/fullchain.pem;
    ssl_certificate_key ${reality_cert_path}/privkey.pem;
    include /etc/nginx/ssl/common.conf;

    root        /var/www/${REALITY_DOMAIN};
    index       index.html;
    server_tokens off;
    access_log  off;
${_doh_inc_reality}
    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "public, max-age=3600" always;
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options DENY always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Content-Security-Policy "default-src 'self' fonts.googleapis.com fonts.gstatic.com; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' fonts.googleapis.com; font-src 'self' fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none';" always;
    }
}
CONF
    fi

    # XHTTP-Reality dest 伪装站（8326）：使用自有域名时生成
    # xray 的 vless-xhttp-reality realitySettings.dest 指向此处
    # 主题 slot 3：NA 地区 3 主题时回绕到 usa（与 XHTTP_DOMAIN 相同）；
    # 如需独立主题，可在 assets/fake-site-na/ 新增第 4 个子目录
    if [[ -n "${XHTTP_REALITY_DOMAIN:-}" ]]; then
        local xhttp_reality_root xhttp_reality_cert_path
        xhttp_reality_root=$(get_root_domain "${XHTTP_REALITY_DOMAIN}")
        xhttp_reality_cert_path=$(get_state "CERT_PATH_${xhttp_reality_root//./_}" "")
        [[ -z "$xhttp_reality_cert_path" ]] && xhttp_reality_cert_path="/etc/letsencrypt/live/${xhttp_reality_root}"

        mkdir -p "/var/www/${XHTTP_REALITY_DOMAIN}"
        generate_fake_site "/var/www/${XHTTP_REALITY_DOMAIN}" 3

        cat >> "$_out" << CONF

# ===================================================================
# XHTTP-Reality dest 伪装站 ${XHTTP_REALITY_DOMAIN}（8326）
# ===================================================================
server {
    listen 127.0.0.1:8326 ssl;
    server_name ${XHTTP_REALITY_DOMAIN};

    ssl_certificate     ${xhttp_reality_cert_path}/fullchain.pem;
    ssl_certificate_key ${xhttp_reality_cert_path}/privkey.pem;
    include /etc/nginx/ssl/common.conf;

    root        /var/www/${XHTTP_REALITY_DOMAIN};
    index       index.html;
    server_tokens off;
    access_log  off;
${_doh_inc_xr}
    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "public, max-age=3600" always;
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options DENY always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Content-Security-Policy "default-src 'self' fonts.googleapis.com fonts.gstatic.com; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' fonts.googleapis.com; font-src 'self' fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none';" always;
    }
}
CONF
    fi

    # 兜底 server 块
    cat >> "$_out" << 'CONF'

# ===================================================================
# 兜底：SNI 不匹配拒绝握手
# ===================================================================
server {
    listen 127.0.0.1:8380 ssl default_server proxy_protocol;
    ssl_reject_handshake on;
}

server {
    listen 127.0.0.1:8390 ssl default_server proxy_protocol;
    ssl_reject_handshake on;
}
CONF

    # P3修复：8400 加自签证书完成 TLS 握手，返回伪装页而非 RST
    cat >> "$_out" << 'CONF'

# ===================================================================
# SNI 陷阱伪装站（8400）
# P3修复：加自签证书让扫描器能完成 TLS 握手，返回正常伪装页
#         而非直接 RST（更难被识别为代理节点）
# ===================================================================
server {
    listen 127.0.0.1:8400 ssl proxy_protocol;
    ssl_certificate     /etc/nginx/certs/trap.crt;
    ssl_certificate_key /etc/nginx/certs/trap.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    server_name         _;
    server_tokens       off;
        client_header_timeout 10s;
        send_timeout 10s;
        keepalive_timeout 10s;
    access_log          off;
    gzip                on;
    gzip_vary           on;
    gzip_comp_level     2;
    gzip_min_length     1000;
    gzip_types          text/plain text/css application/json application/javascript
                        text/xml application/xml application/xml+rss text/javascript
                        image/svg+xml;
    root                /var/www/trap;
    index               index.html;

    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control          "public, max-age=3600" always;
 add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
 add_header X-Content-Type-Options nosniff always;
 add_header X-Frame-Options DENY always;
 add_header Referrer-Policy "strict-origin-when-cross-origin" always;
 add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
 add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests;" always;
    }
}
CONF

    # HTTP 重定向
    # ⚠️ `local domain` 同上（动态作用域会污染调用方的同名局部变量）
    local all_domain_names="" domain
    for domain in "${ALL_DOMAINS[@]}"; do
        all_domain_names+=" ${domain}"
    done

    cat >> "$_out" << CONF

# ===================================================================
# HTTP → HTTPS 重定向（证书用 DNS-Cloudflare，无需 webroot 验证）
# ===================================================================
server {
    listen 80;
    listen [::]:80;
    server_name ${all_domain_names};

    location / {
        return 301 https://\$host\$request_uri;
    }
}
CONF

    # 伪装站目录收尾：servers.conf 已定稿，此刻的引用关系才是权威
    _purge_orphan_webroots

    # 同目录 rename，原子替换；失败则线上文件原样保留
    if ! mv -f "$_out" /etc/nginx/conf.d/servers.conf; then
        log_error "servers.conf 原子替换失败，已保留原文件"
        rm -f "$_out"
        return 1
    fi

    log_info "servers.conf 生成完成"
}

# ── nginx 配置快照 / 还原（「改完 → nginx -t → 失败回滚」的底座）──
# 为什么需要：reload_nginx 在 nginx -t 失败时只 `exit 1`，什么都不还原 ——
# 坏配置留在磁盘上、跑着的还是旧 worker，当场看不出问题，但下次任何一次
# reload 都会把坏配置推上去。切换类改动（如 Reality SNI 来源）必须能回滚。
# ⚠️ 判据（决定了「还原后要不要 reload」）：nginx -t 失败 ⇒ 从未 reload ⇒
# **运行中的服务仍是旧配置**，所以还原只需把磁盘文件换回来，不需要 reload；
# 还原后要复跑 nginx -t，确认旧配置集仍自洽（否则说明坏的不只是新改动）。
# ⚠️ stdout 回传快照目录，函数内不得调 log_*（同 cert.sh resolve_edit_nodes_script）。
nginx_config_snapshot() {
    local _root="${1:-${STATE_DIR:-/etc/xray-deploy}}"
    local _dir="${_root}/nginx-snap-$$"
    rm -rf "$_dir"
    mkdir -p "$_dir" || return 1
    # /usr/bin/cp：本机 cp 被别名成 -i，覆盖时会等交互（见 env-shell-gotchas）
    if ! /usr/bin/cp -a /etc/nginx "$_dir/nginx" 2>/dev/null; then
        rm -rf "$_dir"
        return 1
    fi
    printf '%s\n' "$_dir"
}

# 还原快照。只在快照里确实有 nginx.conf 时才动手（防止半截快照把整目录清空）。
nginx_config_restore() {
    local _dir="$1"
    [[ -n "$_dir" && -f "${_dir}/nginx/nginx.conf" ]] || return 1
    # 清**内容**而不是删目录本身：/etc/nginx 在容器/挂载点/沙箱里可能是挂载点，
    # 那时 `rm -rf /etc/nginx` 报 EBUSY 且**一个文件都没删**，紧接着的 cp -a 会把
    # 快照整棵树当成 /etc/nginx/nginx 塞进去 —— 目录结构错位、nginx.conf 消失，
    # 比不回滚更糟（2026-10-01 沙箱实测）。清内容对「普通目录」与「挂载点」都正确。
    find /etc/nginx -mindepth 1 -delete 2>/dev/null
    /usr/bin/cp -a "${_dir}/nginx/." /etc/nginx/ || return 1
    return 0
}

# ── 验证并重启 Nginx ─────────────────────────────────────────
reload_nginx() {
    log_step "验证 Nginx 配置..."
    if nginx -t 2>&1; then
        systemctl restart nginx
        log_info "Nginx 配置验证通过并已重启，资源限制已生效"
    else
        log_error "Nginx 配置验证失败，请检查配置文件"
        nginx -t
        exit 1
    fi

    # DoH 入口自检。放在这里是因为本函数是所有会重写 nginx.conf 的路径的
    # 唯一汇合点（install.sh 的「配置 Nginx」/全量安装、modules/sync.sh 的
    # 模块热更新、run_nginx），挂这一处就全覆盖，不必逐个调用点补。
    # 必须在 restart 之后：SNI map 是 nginx.conf 的一部分，重启前跑等于探旧配置。
    # 注：未启用 DoH 时本函数立即返回 0，不产生任何输出。
    if declare -F verify_doh_entry >/dev/null; then
        verify_doh_entry || \
            log_error "DoH 入口不可用（上面有具体原因）；其余组件不受影响，但家里的 DoH 解析会是断的"
    fi
}

# ── 模块入口 ─────────────────────────────────────────────────
run_nginx() {
    log_step "========== Nginx 安装配置 =========="
    install_nginx
    create_nginx_dirs
    generate_fake_site "/var/www/trap" 2
    generate_cf_realip_conf
    generate_ssl_conf
    generate_upstreams_conf
    generate_fallback_conf
    generate_servers_conf
    generate_trap_cert          # P3：生成陷阱端口自签证书
    generate_nginx_conf
    reload_nginx
    install_cf_ip_updater
    setup_cf_ip_updater
    run_cf_ip_updater
    log_info "========== Nginx 安装配置完成 =========="
}
