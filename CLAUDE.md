# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

## 项目定位（2026-09-05 更新）

一键部署 + 多发行版的代理服务器栈。支持 Debian/Ubuntu（apt）与 RHEL 系（dnf：Alma/RHEL/**Fedora**/amzn/ol，靠 `ID_LIKE` 与包管理器分派而非 OS_ID 字面量）。

覆盖：Nginx（伪装站/反代/CDN 回源）+ Xray（VLESS-Reality / VLESS-XHTTP / gRPC-CDN）+ Sing-Box（AnyTLS）+ Hysteria2 + NaiveProxy（Caddy-naive）+ Unbound（本地 DNS）+ WARP（wgcf 凭证内嵌出站）+ nftables 防火墙 + CrowdSec + 内核/BBR 优化。附：域名分配级联重建、客户端订阅生成、单组件升级（`--upgrade-<comp>`）、整体卸载。

## 功能模块总览（modules/*.sh）

| 模块 | 作用 |
|---|---|
| `install.sh` | 主入口：多级菜单、安装/配置/卸载编排、state 读写 |
| `system.sh` | 内核/BBR/系统优化 |
| `nginx.sh` | Nginx 安装 + 全套配置生成（SNI map/servers/伪装 webroot/CF real-ip/8321 dest/**DoH 入口 8410 + 自检**） |
| `cert.sh` | Cloudflare DNS + letsencrypt 证书申请、deploy hook |
| `xray.sh` | Xray 安装 + Reality/XHTTP 等入站配置生成 |
| `singbox.sh` | Sing-Box 安装 + AnyTLS 配置生成 |
| `hysteria2.sh` / `naive.sh` | Hysteria2 / NaiveProxy（xcaddy Caddy+forwardproxy） |
| `unbound.sh` | Unbound 本地 DNS：**纯转发模式**（DoT 上游），配置按真实二进制能力探测 |
| `firewall.sh` / `crowdsec.sh` | nftables 防火墙 / CrowdSec + bouncer（各自 `_os_family()` ID_LIKE 分派） |
| `warp.sh` | 旧 cloudflare-warp 清理 + wgcf 按架构下载凭证，Xray/Sing-Box 内嵌 wireguard 出站 |
| `upgrade.sh` / `sync.sh` / `modules.list` | 单组件版本取数（读本机仓库候选）/ 模块热更新清单 |
| `uninstall.sh` | 逐组件清理 + 全清；卸载菜单含 CrowdSec 与 nftables 单项 |
| `security.sh` / `client.sh` | 加固 / 客户端订阅 |
| `cleanup.sh` | 系统清理/维护：日志轮转与超大日志截断、包缓存、snap 旧版本清理、kdump 内存预留处理、旧内核体检（只报告） |

state：`/etc/xray-deploy/config.env`（install.sh `save_state`/`get_state` 读写），保存安装开关、网络栈、域名分配等，是「当前生效配置」的事实来源；各生成 `.conf` 头部带自动生成时间戳。

## 近期变更与回退指引（2026-08 ~ 2026-09，`feature/hysteria2-naive` 已多次合入 main）

- **distro 审计批**：nginx 版本判定只对 Stable 线且读发行版仓库真实候选（c1706f4）；`install_nginx` 补 Fedora 分支（599c354）；codename 优先读 `/etc/os-release` 兜底 lsb_release（cfd65fd）；`load_os_info` 放行 amzn/ol 等 ID_LIKE 衍生系统（500fa32）；sing-box 版本取数改读本机仓库候选、回退 GitHub latest（b40515e）；wgcf 按架构选二进制 + rpm 清理按包管理器分派（a8482c8）。
- **unbound 能力探测（d22d59a）**：`_unbound_supports <opt> [样例值]` 以真实 `unbound-checkconf` 探测新指令，老包（如 EL8 1.7.x）自动省略 `serve-expired-client-timeout/reply-ttl`、`tls-system-cert`。注意整数型选项探测必须传**整数样例**，默认 `yes` 会误判。
- **uninstall 补全（301a73c / 73fb20f）**：OS_ID 字面量→包管理器分派；新增 crowdsec/nftables 清理函数与卸载菜单项。
- **unbound 收窄 + 去定时（1cf593d，2026-09-05，已并入 main@b8b8f09）**：v6 监听从公网通配 `[::]` 收窄为回环 `[::1]`（resolv.conf 走 127.0.0.1、v6 模式走 ::1，均在回环覆盖内）；`install_root_update_job` 改为 `remove_root_update_job`（纯转发模式 root.hints 从不参与解析，移除每月无谓下载+重启的 timer）。
- **Reality 域职责反转（00085c6，2026-09-06）**：菜单 5→6 从「唯一设自建域入口」改为**只预分配**（`offer_reality_preassign` 写 advisory 的 `REALITY_PREALLOC`/`XHTTP_REALITY_PREALLOC`，不挂标签、不改 `*_DOMAIN`、不级联）；菜单 11/x = **SNI 真分配**（`collect_reality_params` 两段式：Stage A 逐槽独立选「保持自建/切回借公共/改用自有域」或「借公共→选自建」，候选=预分配优先 + `_reality_self_capable` 名额门控，无候选则隐藏自建；Stage B 公共参数原样复用）。overview 里 Reality 借公共 SNI 改中性「公共伪装」，不再 ⚠缺口。活机验证：菜单 11/x 里 xhttp 现自建 laz 域应弹「保持/切回/改选」、vless 公共无候选应静默。

- **Hysteria2 伪装模式四选一 + ECH（`8cb46c2`，2026-09-30）**：`modules/hysteria2.sh` 的 `# ── 7` 段从三选一（不使用/salamander/gecko）改为**四选一，且旧序号 2/3 后移为 3/4**：`1 不使用 / 2 ECH / 3 salamander / 4 gecko`。ECH 与 obfs 是**互斥的替代方案**而非可叠加开关（官方文档原话：obfs 已把整包混淆成无特征随机字节，ECH adds nothing）。选 2 时不写 `obfs:` 块、写 `ech: keyPath: /etc/hysteria/ech.pem`、state 落 `HYSTERIA2_ECH=1` + `HYSTERIA2_ECH_PUBLIC=<外层假名>`；选 1/3/4 清空这两个 state。密钥 `/etc/hysteria/ech.pem`（权限 600，含私钥）**已存在则原样复用、绝不自动轮换**——轮换 = 所有已配 ECH 的客户端立即断连（客户端 ECH 失败即硬失败，不降级）。生成链：`hysteria ech`（2.12.3+）→ **没产出文件**则回退 `sing-box generate ech-keypair` → 两者都失败则降级为「不使用伪装」且**不写 `ech:` 段**（写了会因文件缺失导致服务端起不来）。外层假名内置 5 个候选（cloudflare / jsdelivr / amazon / samsung / akamai，均实测响应头带 `alt-svc: h3`）随机取默认、可手输覆盖，软校验只告警不拦截。`modules/client.sh` 的 `gen_hysteria2_url` 注入 `&ech=`：**只取 `ECH CONFIGS` 块**（同文件的 `ECH KEYS` 是服务端私钥，绝不能进订阅），编码用 `urllib.parse.quote(cfg, safe='')`（`+`→`%2B`、`/`→`%2F`、`=`→`%3D`，**不是 base64url**；基准是与 `hysteria share -c` 的输出逐字节一致）。**注意**：`ech.keyPath` 在 hysteria 2.12.2 上就已被识别，yaml 无需版本门控。**回退**：`git revert 8cb46c2` 后重跑菜单重配 hysteria2 即可（`HYSTERIA2_ECH` 一并清空）；若 `ech.pem` 不再需要，手工删 `/etc/hysteria/ech.pem` 与 config.yaml 的 `ech:` 段。**回退时务必重新下发订阅**——服务端一旦不再支持 ECH，已按 ECH 配好的客户端会硬失败（客户端侧不降级），必须让它们换回不带 `&ech=` 的链接。**生效需重配并重启服务**（会断开当前连接）。

  **客户端侧填法两种内联写法恰好相反，别混用**（均 2026-09-30 实机验证）：hysteria 官方客户端 `tls.ech:` 要**裸 base64**——填多行 PEM 会 FATAL，它先按 base64 解析，失败后把整串当**文件路径** open（报 `neither a valid base64 config list nor a readable file`）；sing-box `tls.ech.config: [...]` 要 **PEM 原文**（带 `-----BEGIN/END ECH CONFIGS-----` 头尾，填裸 base64 会 `FATAL invalid ECH configs pem` 起不来）。两者也都接受**指向文件的路径**（文件内容 base64 或 PEM 块皆可）。⚠️ **空白敏感**：sing-box 的 PEM **不接受前导空格**（带缩进粘贴即 FATAL），hysteria 对 base64 的前导空格则容忍——所以 `show_client_links` 里这两段**一律顶格输出**，改动时别为了排版加缩进。给客户端的值**只能取 `ECH CONFIGS` 块**。**Passwall 不识别 URI 里的 `ech=`**——它的解析器会静默丢弃该参数，节点仍能连（服务端向后兼容，实测纯裸连照样通）但 SNI 明文暴露、等于没开 ECH；若主力客户端是 Passwall，需权衡是否改用 salamander（obfs 是服务端全局二选一，不能按客户端分别配）。

  ⚠️ **分发陷阱（本次踩坑的根因，务必记住）**：`install.sh` 加载模块的顺序是 **`/etc/xray-deploy/modules/` 缓存 → 仓库同级 `modules/` → `${BASE_URL}` 远端下载**（`load_module()`，`BASE_URL` 指向 GitHub 的 `cctvhd/xray-nginx-deploy` 分支）。**用 `bash <(curl ...)` 方式运行时 `MODULES_DIR` 不是真实目录，会强制从远端拉取并覆盖缓存**——所以**模块改动没 commit + push 到 `BASE_URL` 指向的分支，就不会生效**：服务端可能已是新版（直接 source 仓库模块应用过），而客户端链接生成却仍走远端旧模块，表现为「服务端有 `ech:` 段、链接里却没有 `&ech=`」。同类隐患：从菜单重配 hysteria2 会拉回不含 ECH 选项的旧模块，可能把已配好的 `ech:` 段和 `HYSTERIA2_ECH` 状态一起清掉。改完模块要么 commit+push，要么就用仓库里的 `./install.sh`（本地模式会用仓库模块并刷新缓存，见 `install.sh:1119-1123`）。

- **DoH 入口固化进仓库（`9ec1cc9` → `0423d02`，2026-09-30）**：原先 `/etc/nginx/conf.d/servers.conf` 里那个 `location = /dns-query`（反代 mosdns-x，承担家里 EasyMosdns 的 ECS 透传）是**活机手工件**——`generate_servers_conf` 一重跑，家里当场全量解析失败而 VPS 侧看起来一切正常，是当时最大的单点风险。`modules/nginx.sh` 新增 `ensure_doh_conf()` 把入口挪进**独立文件 `/etc/nginx/conf.d/doh.conf`**（不写在 `servers.conf` 里，故抗重生成；同 `unbound.sh` 只 `rm -f` 固定文件名的思路），并由 `generate_sni_map()` 往 `nginx.conf` 的 stream map 加一条 `<域> 127.0.0.1:8410`（8410 当时空闲）。域名**运行时由使用者选**（`_doh_candidates` 复用 `xray.sh` 的 `_reality_domain_usable_fast` 判「443 SNI 空闲」——它的排除表恰好就是占用 TCP/443 的全集，hysteria2 走 UDP 不在内；菜单按 direct/CDN 分组，某组为空也照样打出组标题并注明「无可用」，不静默消失），路径随机（`openssl rand -hex 6`）或手输，生成后落 state **`DOH_DOMAIN` / `DOH_PATH`**（清空这两个 state 重跑即可换域名/路径）。**后端 `127.0.0.1:15353` 是 mosdns-x，而仓库里没有 `modules/mosdns.sh`** → 新机器上该入口会 502（自检对此只 WARN 不算失败，属预期）；那台的 mosdns-x 配置见下方「活机探索记录」，但**那节的 unbound-DoH 是另一条路线**（手工、未进脚本、其 `/dns-query-unbound` location 在该机上仍是遗留）。

  ⚠️ **限流拒绝会经 error.log 喂给 CrowdSec，把客户端封 24h**（本轮实机踩到）：`limit_req` 默认 `limit_req_log_level=error`，拒绝时往 `error.log` 写 `limiting requests, excess: ... by zone "doh"`，而 `/etc/crowdsec/acquis.yaml` 采集的正是 `error.log`；场景 `crowdsecurity/nginx-req-limit-exceeded`（leakspeed 60s / capacity 5）同一 IP **60 秒内拒 5 次**即下 24h ban。实测本机公网 IP 被自己封了（decision 27781280），症状是 curl 全 `000`、nginx 日志一行都没有——包在 input 链就被 crowdsec 的 nftables set 丢了，很反直觉。对自家路由器等于**DNS 断 24h 且无法自愈**（被 ban 后连重试的包都进不来），而且是**自激**的：拒绝 → 解析器重试 → 更多拒绝。修法是 location 里加 **`limit_req_log_level notice;`**（本机 `error_log` 级别是 `warn`，notice 低于阈值直接丢弃不落盘；限流照常生效，503 仍记在 doh 的 access_log 里）。**⚠️ 把 access log 移出采集目录完全挡不住这条路——触发物在 error.log。** 既有的 `websocket`/`health` 两个限流区是同一机制，本次未动。阈值取 `rate=300r/s burst=900`（实测单客户端峰值 301/s；凭直觉写小值会把自家路由器的缓存未命中突发打掉，那比不限流更糟）。限流 key 必须是 **`$final_real_ip`** 而非 `$remote_addr`——请求经 stream 的 SNI 分流从 `127.0.0.1:8410` 进来，`$remote_addr` 对所有人恒为 `127.0.0.1`，一个桶装全部客户端，一限流就是全员被拒。

  ⚠️ **`generate_sni_map()` 的 DoH 域名必须从 state 读，不能只用内存全局 `$DOH_DOMAIN`**：那个全局只是 `ensure_doh_conf` 顺手赋的，而 `modules/sync.sh:157`（模块热更新）与 `run_nginx()` 都**直接调 `generate_nginx_conf`、不经过 `ensure_doh_conf`** → 该段被静默跳过，443 上该域落到 `default` 陷阱端口（8400）、**DoH 全断而脚本一路报成功**。已改为读 state + 附加「`doh.conf` 存在」条件。**由此引出的通用教训：别拿 `nginx -T` 当「配置已生效」的证据**——它只解析磁盘文件，根本不反映 worker 在跑什么。排查这类问题要用**响应头探针**（临时 `add_header` 看新配置是否真在跑）或**行为探针**：DoH 健康 = `HTTP/2` + `application/dns-message`，落到伪装站 = `HTTP/1.1` + `text/html`；而路由缺失时只会得到模糊的 `000`，照那个去查 443 监听/证书会查错方向。

  **自检**：`verify_doh_entry()` 挂在 `reload_nginx()` 的 `systemctl restart` **之后**——那是所有会重写 `nginx.conf` 的路径的唯一汇合点（「配置 Nginx」/全量安装/`sync.sh`/`run_nginx`），挂一处即全覆盖，不必逐个调用点补；且必须在 restart 之后，重启前跑等于探旧配置。它**先用 `awk` 确定性地断言 map 里有那条路由、再 curl 端到端**（顺序是刻意的，见上段），未启用 DoH 时静默返回 0。**回退**：`git revert 0423d02 ce86cdd 9ec1cc9` 后重跑「配置 Nginx」；要彻底移除入口则清空 state 的 `DOH_DOMAIN`/`DOH_PATH` 并删 `/etc/nginx/conf.d/doh.conf`，重跑即不再生成（`generate_sni_map` 因改读 state 也不会再写那条路由）。**回退前先确认家里不再依赖该入口**——443 一旦不再路由到 8410，家里解析当场全断。

- **配置表目录固定为 `$STATE_DIR`（`5d5afdd` → `8c80a34`，2026-09-30）**：`edit_nodes.py` 的数据目录原本是 `: "${EDIT_NODES_DATA_DIR:=/root}"`，即**机器默认路径** —— 换台机器（$HOME 不同、也没有上一轮留下的表）就报 `[ERROR] 未找到 edit_nodes.py 生成的配置文件 /root/.config.tsv`。`5d5afdd` 先改成「跟随 edit_nodes.py 脚本所在目录」，**但那个方案有缺陷、当天就被 `8c80a34` 推翻了**：同一台机器上「脚本位置」有两个答案 —— git 模式解析到**仓库根**那份，curl 模式（`bash <(curl ...)`）`MODULES_DIR` 不是真实目录、`resolve_edit_nodes_script` 落到缓存 `${STATE_DIR}/edit_nodes.py`，于是**两种启动方式各看各的表、互相看不见**（在 curl 模式里按 S 存下去，回 `./install.sh` 就「没这回事」，表现为表格显示内置默认值 `example.com` 而不是自己的域名）。现方案：数据目录固定为 **`$STATE_DIR` = `/etc/xray-deploy`**，两种模式同一个值，且令牌完全不进 git 工作区。**写（argv[1]）与读（`TSV_FILE`）共用同一个 `edit_nodes_dir` 局部变量**故不可能分叉；`edit_nodes.py` 无 argv 单独跑时 `BASE_DIR` 兜底也是 `/etc/xray-deploy`（这一点是安全考虑：旧兜底是脚本自身目录，直接 `python3 edit_nodes.py` 会把**令牌写进仓库工作区**）。显式 `export EDIT_NODES_DATA_DIR` 仍是逃生口。仓库 `.gitignore` 里 `config.txt` / `.config.tsv` 两条保留作兜底（万一有人把数据目录指回仓库）。**回退**：`git revert 8c80a34 5d5afdd`。⚠️ `5d5afdd` 那一版**未动** `do_inst_cert` 里那两行 `save_state "XHTTP_PATH"/"GRPC_SERVICE_NAME"` —— 曾怀疑它们把 state 写成空串，**已实机证伪**：`init_state`（install.sh:1417-1418）本就装载这两个键，那两行是同值回写。

  **由此得出的一条排查经验**：这种「同一逻辑在两处各自算路径」的 bug，症状是**静默显示默认值**（`example.com`）而不是报错，很容易误判成「文件没存上」。判断用户走的哪种模式，看 `/etc/xray-deploy/modules` 的**目录 mtime** —— curl 模式启动时 `_clear_module_cache_if_remote` 会 `rm -rf` 该目录，git 模式不会；目录 mtime 陈旧即说明近期没走过 curl 模式。

- **配置表读不到不再静默 + curl 模式强制刷新 `edit_nodes.py`（`b29daff`，2026-09-30）**：修完目录后用户**仍然**报「表格 DOMAIN 列还是 `example.com`」。逐项查证数据侧**没有问题**：`/etc/xray-deploy/.config.tsv` 与 `/root/.config.tsv` 都含 7 个真实域名（二者同源，01:33 那次保存的），唯一会成为空表的是**仓库根**（`5d5afdd` 那版算出的落点，已被删），也就是说那次跑的是修复前的代码；`EDIT_NODES_DATA_DIR` / `STATE_DIR` 也没有被 profile 或环境变量劫持（已 grep 排除）。但让这事**反复发生**的元凶是「静默」：`load_file()` 找不到表时一个字都不说、直接显示写死在源码 `data` 常量里的 `example.com`，而 TUI 第一件事就是 `stdscr.clear()` —— 把 cert.sh 在此之前打的 `配置表目录: ...` 一并抹掉。于是「没读到表」与「读到了表」在屏幕上**长得一模一样**，只能猜。

  - `load_file()` 现在把结果记进全局 `LOAD_NOTE`，在标题行下**顶格单独一行**显示：读到表 → `数据目录 /etc/xray-deploy`；没读到 → `⚠ 未找到 <路径> — 下表是内置默认值，不是本机配置！按 S 才会写出`（`A_BOLD` 强调，读到时为 `A_DIM`）。⚠️ 这行是屏幕清空后**唯一**能当场判断「读到哪去了」的依据，改排版时别为了省这一行把它删掉 —— `draw_table` 里 `hline(2)`/`row_block(3,…)` 的 y 偏移与 `base` 高度都是照着多这一行算的，动一处要连带动。
  - `resolve_edit_nodes_script()` 在 curl 模式改为**每次重新拉取**（与 `load_module` 的 `install.sh:1094-1096` 同理）：原先 `[[ -s "$_EDIT_NODES_CACHE" ]]` 命中就 `return`，而缓存一旦写出**再也不会刷新** —— 改 `edit_nodes.py` 等于没改，只是换个地方重演同一个「缓存掩盖修复」。现在先落 `.tmp.$$` 再 `mv -f`（`curl` 中途失败不留半截脚本），下载失败仍回退缓存。**活机上的 `/etc/xray-deploy/edit_nodes.py` 曾是 18:36 下载的旧版**（兜底 `/root`），已手工刷新。
  - ⚠️ **回退分支的 `log_warn` 必须写 `>&2`**：本函数用 **stdout 回传脚本路径**，而 `log_info/log_warn/log_error/log_step` 全是裸 `echo`（`install.sh:85-88`，不区分流）。不重定向的话警告会被调用方的 `edit_nodes_script=$(resolve_edit_nodes_script)` 一起捕获，拼成一个**多行「路径」**传给 `python3`，必挂。**推广**：任何「用 stdout 回传值」的函数里都别直接调 `log_*`（`resolve_edit_nodes_script` 是既有的第一例，别的地方新写时要照此办理）。
  - **回退**：`git revert b29daff`。

  **这条的通用教训**：一个会「静默回落到内置默认值」的读取失败，比直接报错危险得多 —— 它把「没读到」伪装成「读到了但内容不对」，把人支到错误方向去查存储。**凡是有内置默认值的加载逻辑，都要把「用的是默认值」这件事显式吼出来**。

  - **历史落点回退（`b0c2083`）**：用户**另一台**机器报警的是 `⚠ 未找到 /root/.config.tsv` —— 落点是 `/root`，而 `/root` 只可能来自 `7db1482`~`5d5afdd` 之间那版 cert.sh（`EDIT_NODES_DATA_DIR:=/root`）；`STATE_DIR` 从建立起就一直是 `/etc/xray-deploy`（逐提交核过，`git log -S'STATE_DIR:=/root'` 无结果）。也就是说那台机器是「**新 edit_nodes.py + 旧 cert.sh**」的组合。与其继续追版本组合，不如从根上认下这件事：**表是用户资产**，不该因为脚本换了个算法就「找不到自己的配置」而白屏 `example.com`。现在 `run_cert` 在主目录 `${STATE_DIR}` 里没有 `.config.tsv` 时，依次回退到 `/root` 与 `$(dirname "$edit_nodes_script")`（= `5d5afdd` 那版的仓库根落点），命中即用并打警告 + 给出迁移命令。**只在「确实存在表」时才回退** —— 空目录回退没有意义，还会把真正的首次安装伪装成「找到过」；回退后**读与写共用同一个目录**，不制造第二个分叉。**回退**：`git revert b0c2083`。

  ⚠️ **push 完别立刻断言「远端已生效」**：`raw.githubusercontent.com` 是 Fastly CDN，响应头 `cache-control: max-age=300`、`x-cache: HIT`，**push 后仍可能继续供旧文件，实测约 90 秒后刷新**（`install.sh` 自己因为每次都被 curl 新拉所以没事，但**单文件缓存是各自独立**的 —— 同一提交里 `cert.sh` 已刷新而 `edit_nodes.py` 还是旧的很正常）。带 `?cb=<随机>` 也绕不过去，`x-cache` 仍是 `HIT`。**唯一可靠的判据是逐字节比对**：`curl -fsSL "$BASE_URL/<file>" -o /tmp/_r && cmp /tmp/_r <file>`。这一坑当轮就踩到了 —— 拿 CDN 旧货覆盖了活机缓存，等于把刚写的诊断行又抹掉。所以 push 后要让远程机器验证，先 `cmp` 一遍再说「重跑就好了」。

- **证书子菜单 6→3，域名配置统一走配置表（`8a609c1`，2026-09-30）**：`run_cert()` 从 6 项并为 3 项 —— `1 配置域名表 / 2 检查更新 Certbot / 3 刷新修复域名协议分配`。原 2/3/4（新增 CF 账号 / 新增域名 / 仅补证书）是三条**与配置表完全平行**的交互式流程，现已全部由配置表按内容自动判定；填表的语义本就是它们的超集（按表里 token 无条件重写 `cf_account_N.ini` / `domain_<root>.ini`、按表注册域名与槽位、`check_existing_certs` 只补缺的证书），唯一缺的是收尾重建，本次补上。表格流程加了三处：**(a)** `python3` 前后各取一次 `.config.tsv` 的 md5，**未变动则「沿用现有表继续」而不报错**（`edit_nodes.py` 只在按 S 时写文件；旧代码在「表存在但按了 Q」时直接 `return 1` 报「未找到配置表」，把原「仅补证书」的用法打死了，也与紧邻注释「视为无更改」自相矛盾）；**(b)** `_purge_stale_domains` **之前**加空表护栏 —— 该函数没有空表保护，`_keep` 为空会把 `OLD_DOMAINS` 全判为陈旧 → 清 `DOMAIN_REGISTRY`、删 `domain_*.ini`、`certbot delete` **删掉所有证书**，合并后填表成为唯一入口，必须拦（确实要停用全部域名走主菜单 u）；**(c)** 照抄 `refresh_domain_assignments` 的槽位 before/diff/派发范式，末尾按 `_slot_tag` 映射调 `regen_after_domain_change`（内含 `do_conf_nginx` 全量，原菜单 2/3 那步单独调用的 `do_conf_nginx` 一并涵盖）。顺带删掉已无调用点的老流程 `add_cf_account` / `add_domain_and_cert` / `_filter_dup_cf_accounts` / `_cf_account_label` / `_is_old_cf_dup`（-348 行）；**`_cf_self_ipv4` / `_cf_self_ipv6` 保留** —— 它们被存活的 `scan_cf_domain_inventory` 调用，只是恰好夹在待删函数后面（上一轮的审计就差点误删）。`install.sh` preflight 修复入口提示同步改名「配置域名表」。**⚠️ 旧序号 2/3/4 的输入现在落到「配置域名表」；2 号的含义从「新增 CF 账号」变为「更新 Certbot」。** **回退**：`git revert 8a609c1` 后重跑主菜单 5 即恢复 6 项菜单；表格数据文件不受影响。**改完必须 commit + push 到 `BASE_URL` 指向的分支**，否则 `bash <(curl ...)` 模式的其它机器仍会拉到旧菜单（同上方 Hysteria2 那节的分发陷阱）。**顺带发现（未修）**：`cert_txn_begin/commit/rollback` 整套配置事务机制当前**不可达** —— 仅有的三个调用点（`collect_domains` 1294、`setup_cf_accounts` 652/674）本身都是无调用点的死代码；`get_cf_account_by_domain` 同样是既有死代码。

## 活机探索记录：unbound 自带 DoH 当反代上游（2026-09-30，**未进脚本，仅活机手工配置**）

背景：想给家里路由器提供自建 DoH（`https://<域名>/dns-query`）时，除了装 mosdns-x，也可以直接用 unbound 自带的 DoH 服务端（1.12+ 支持；活机 1.24.2 实测全指令可用）。两个**很容易再踩一次、且很难第一时间联想到**的坑：

- ⚠️ **unbound 的 DoH 只支持 HTTP/2，而 nginx `proxy_pass` 默认发 HTTP/1.1**。症状是 **502 + error_log 里 `upstream prematurely closed connection while reading response header from upstream`**——看着像 unbound 挂了，其实握手/协议层不匹配。实测：`curl --http1.1 https://127.0.0.1:8443/dns-query` 直接失败，`curl --http2` 才 200。**解法是 `proxy_http_version 2;`**（写在 `location` 里 `proxy_pass` 之前）。
- ⚠️ **`proxy_http_version 2` 需要 nginx ≥ 1.30**（活机 1.30.5 实测可用）。**老版本 nginx 上这行不生效** —— 也就是说「nginx 反代 unbound DoH」这条路在 nginx <1.30 的机器上走不通，只能退回复用 mosdns-x 之类说 HTTP/1.1 的组件。

其余实测要点：**DoH 监听在 `interface:` 后面的端口上，`https-port` 只是筛选条件**（`interface: 127.0.0.1@15354` + `https-port: 8443` → 8443 完全不监听）；**同一端口同时还会提供明文 DNS(UDP/TCP)**，所以必须绑回环、由 nginx 对外，**绝不能直接对公网暴露**（ACL 一放开就是开放解析器）；`tls-service-key` 会顺带启用 DoT(tls-port 默认 853) 于各 interface（均回环，无对外影响）；unbound 以 `unbound` 用户运行，读 letsencrypt 私钥需 `usermod -aG certaccess unbound` 并重启（**实测重启后 `/proc/<pid>/status` 的 Groups 保留 certaccess**，续期由既有 `naive-cert.sh` hook 修 640 certaccess 权限，无需新增 hook）。

**权限与持久性**：`/etc/unbound/conf.d/doh.conf` 能扛过「重配」——`modules/unbound.sh` 是完全替换 `unbound.conf`、conf.d 只 `rm -f` 固定的几个文件名（`${UNBOUND_SERVICE_NAME}.conf` / `remote-control.conf` / `example.com.conf` / `unbound-local-root.conf`），自己的文件名不在清单内。但 **nginx 那段 location 仍会随 `servers.conf` 重生成而丢失**（同下方通用提醒）。

**ECS 结论（若要「就近解析」，先看这条；2026-09-30 三条实测，曾误判过一次）**：

1. **CF 中转不拦 ECS**（**曾误判为「CF 不支持 ECS」**）：实测临时把 mosdns-x 上游改直连 `8.8.8.8:53`，走公网 `客户端 → CF → nginx → mosdns-x → 8.8.8.8` 往返，响应里 `CLIENT-SUBNET: 1.2.3.0/24/0` **完整回显**。原因：ECS 在 DoH 的 `application/dns-message` **body** 里，CF 只当中转、根本不解析 DNS 报文。之前测到的「CF 不认 ECS」指的是 **CF 的公共解析器 `1.1.1.1`**，跟「CF 中转你的 DoH」是两码事，别混。
2. **unbound 无法透传客户端 ECS**（文档 + 实测双证）：unbound 的 ECS 是用 `send-client-subnet` / `client-subnet-zone` 白名单**按查询来源 IP 自己生成**的（文档原文 `Send client source address to this authority`，且明说适用场景是 "resolver and the clients belong to different networks / open resolver"）；**客户端带进来的 ECS 它不转发**。**`client-subnet-always-forward: yes` 不是透传开关**——它只是「客户端查询已带 ECS 时跳过 send-client-subnet 的地址检查，并跳过常规缓存查询」。实测：客户端 `+subnet=1.2.3.0/24` 打进去，中间插的观察者看到上游收到的仍是「无 ECS」（加不加该选项都一样）。**所以「客户端带 ECS + unbound 透传」这条路根本不存在**，不要再照着配。
3. **mosdns-x 的 `fast_forward` 原样透传客户端 ECS**（观察者实测收到 `family=1 24/0 addr=1.2.3.0`）。**要 ECS 就近解析 = 让 mosdns-x 上游直连 `8.8.8.8:53`，不要经过 unbound**（当前活机 `/dns-query` 上游是 `127.0.0.1:53` = unbound，ECS 到这就断了）。两个前提：① **必须由客户端（家里 mosdns）自己带 ECS**——服务端只能看到回环/CF 边缘，生成不出真实 subnet；② **上游要认 ECS**：`8.8.8.8` 认、`1.1.1.1` 不认，因此若坚持走 unbound 还得把上游顺序改 Google 在前（但按第 2 条，改了也白改，unbound 这跳已经断了）。

**回退通用步骤**：某次变更出问题 → `git revert <sha>`，再重跑 `install.sh` 对应组件菜单（unbound 用菜单 2「重新配置」或 4「仅刷新域名配置」）即重新生成配置。unbound 活机改动前的配置文件已备份在 `/etc/unbound/unbound.conf.bk.*`（活机本机，不进 git）。活机真实域名/IP/服务快照等敏感运维事实见自动记忆 `live-unbound-2026-09`。

## 媒体/伪装站资产策略（assets/）
- 伪装站主题模板在 `assets/`（eu 档案馆 / na-cia / na-la），`download-media.sh` 用 yt-dlp 拉媒体。
- **mp4/mp3 等大媒体不入 git**，部署时在对应 webroot 目录链接或重命名短名称文件。

## 严格禁止事项（绝对铁律）
- **永远不要** `git add`、`git commit`、`git push` `server-audit/` 目录下的任何文件
- `server-audit/` 包含服务器敏感审计数据，必须始终保持在 `.gitignore` 中
- 执行任何 git 操作前，先确认 `server-audit/` 不在暂存区
