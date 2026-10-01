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
- **Reality 域职责反转（00085c6，2026-09-06）**：菜单 5→6 从「唯一设自建域入口」改为**只预分配**（`offer_reality_preassign` 写 advisory 的 `REALITY_PREALLOC`/`XHTTP_REALITY_PREALLOC`，不挂标签、不改 `*_DOMAIN`、不级联）；菜单 11/x = **SNI 真分配**（`collect_reality_params` 两段式：Stage A 逐槽独立选「保持自建/切回借公共/改用自有域」或「借公共→选自建」，候选=预分配优先 + `_reality_self_capable` 名额门控，无候选则隐藏自建；Stage B 公共参数原样复用）。overview 里 Reality 借公共 SNI 改中性「公共伪装」，不再 ⚠缺口。活机验证：菜单 11/x 里 xhttp 现自建 laz 域应弹「保持/切回/改选」、vless 公共无候选应静默。⚠️ **本条里的 Stage A 交互已于 2026-09-30 作废**（`ee67e81` 删除，SNI 来源改由配置表第 3/4 行决定，见下方「配置表成为域名的唯一来源」）；`*_PREALLOC` 也随之失去影响生成结果的读者。菜单 5→6 只预分配的语义仍在，但已无下游消费。

- **Hysteria2 伪装模式四选一 + ECH（`8cb46c2`，2026-09-30）**：`modules/hysteria2.sh` 的 `# ── 7` 段从三选一（不使用/salamander/gecko）改为**四选一，且旧序号 2/3 后移为 3/4**：`1 不使用 / 2 ECH / 3 salamander / 4 gecko`。ECH 与 obfs 是**互斥的替代方案**而非可叠加开关（官方文档原话：obfs 已把整包混淆成无特征随机字节，ECH adds nothing）。选 2 时不写 `obfs:` 块、写 `ech: keyPath: /etc/hysteria/ech.pem`、state 落 `HYSTERIA2_ECH=1` + `HYSTERIA2_ECH_PUBLIC=<外层假名>`；选 1/3/4 清空这两个 state。密钥 `/etc/hysteria/ech.pem`（权限 600，含私钥）**已存在则原样复用、绝不自动轮换**——轮换 = 所有已配 ECH 的客户端立即断连（客户端 ECH 失败即硬失败，不降级）。生成链：`hysteria ech`（2.12.3+）→ **没产出文件**则回退 `sing-box generate ech-keypair` → 两者都失败则降级为「不使用伪装」且**不写 `ech:` 段**（写了会因文件缺失导致服务端起不来）。外层假名内置 5 个候选（cloudflare / jsdelivr / amazon / samsung / akamai，均实测响应头带 `alt-svc: h3`）随机取默认、可手输覆盖，软校验只告警不拦截。`modules/client.sh` 的 `gen_hysteria2_url` 注入 `&ech=`：**只取 `ECH CONFIGS` 块**（同文件的 `ECH KEYS` 是服务端私钥，绝不能进订阅），编码用 `urllib.parse.quote(cfg, safe='')`（`+`→`%2B`、`/`→`%2F`、`=`→`%3D`，**不是 base64url**；基准是与 `hysteria share -c` 的输出逐字节一致）。**注意**：`ech.keyPath` 在 hysteria 2.12.2 上就已被识别，yaml 无需版本门控。**回退**：`git revert 8cb46c2` 后重跑菜单重配 hysteria2 即可（`HYSTERIA2_ECH` 一并清空）；若 `ech.pem` 不再需要，手工删 `/etc/hysteria/ech.pem` 与 config.yaml 的 `ech:` 段。**回退时务必重新下发订阅**——服务端一旦不再支持 ECH，已按 ECH 配好的客户端会硬失败（客户端侧不降级），必须让它们换回不带 `&ech=` 的链接。**生效需重配并重启服务**（会断开当前连接）。

  **客户端侧填法两种内联写法恰好相反，别混用**（均 2026-09-30 实机验证）：hysteria 官方客户端 `tls.ech:` 要**裸 base64**——填多行 PEM 会 FATAL，它先按 base64 解析，失败后把整串当**文件路径** open（报 `neither a valid base64 config list nor a readable file`）；sing-box `tls.ech.config: [...]` 要 **PEM 原文**（带 `-----BEGIN/END ECH CONFIGS-----` 头尾，填裸 base64 会 `FATAL invalid ECH configs pem` 起不来）。两者也都接受**指向文件的路径**（文件内容 base64 或 PEM 块皆可）。⚠️ **空白敏感**：sing-box 的 PEM **不接受前导空格**（带缩进粘贴即 FATAL），hysteria 对 base64 的前导空格则容忍——所以 `show_client_links` 里这两段**一律顶格输出**，改动时别为了排版加缩进。给客户端的值**只能取 `ECH CONFIGS` 块**。**Passwall 不识别 URI 里的 `ech=`**——它的解析器会静默丢弃该参数，节点仍能连（服务端向后兼容，实测纯裸连照样通）但 SNI 明文暴露、等于没开 ECH；若主力客户端是 Passwall，需权衡是否改用 salamander（obfs 是服务端全局二选一，不能按客户端分别配）。

  ⚠️ **分发陷阱（本次踩坑的根因，务必记住）**：`install.sh` 加载模块的顺序是 **`/etc/xray-deploy/modules/` 缓存 → 仓库同级 `modules/` → `${BASE_URL}` 远端下载**（`load_module()`，`BASE_URL` 指向 GitHub 的 `cctvhd/xray-nginx-deploy` 分支）。**用 `bash <(curl ...)` 方式运行时 `MODULES_DIR` 不是真实目录，会强制从远端拉取并覆盖缓存**——所以**模块改动没 commit + push 到 `BASE_URL` 指向的分支，就不会生效**：服务端可能已是新版（直接 source 仓库模块应用过），而客户端链接生成却仍走远端旧模块，表现为「服务端有 `ech:` 段、链接里却没有 `&ech=`」。同类隐患：从菜单重配 hysteria2 会拉回不含 ECH 选项的旧模块，可能把已配好的 `ech:` 段和 `HYSTERIA2_ECH` 状态一起清掉。改完模块要么 commit+push，要么就用仓库里的 `./install.sh`（本地模式会用仓库模块并刷新缓存，见 `install.sh:1119-1123`）。

- **DoH 入口固化进仓库（`9ec1cc9` → `0423d02`，2026-09-30）**：原先 `/etc/nginx/conf.d/servers.conf` 里那个 `location = /dns-query`（反代 mosdns-x，承担家里 EasyMosdns 的 ECS 透传）是**活机手工件**——`generate_servers_conf` 一重跑，家里当场全量解析失败而 VPS 侧看起来一切正常，是当时最大的单点风险。`modules/nginx.sh` 新增 `ensure_doh_conf()` 把入口挪进**独立文件 `/etc/nginx/conf.d/doh.conf`**（不写在 `servers.conf` 里，故抗重生成；同 `unbound.sh` 只 `rm -f` 固定文件名的思路），并由 `generate_sni_map()` 往 `nginx.conf` 的 stream map 加一条 `<域> 127.0.0.1:8410`（8410 当时空闲）。域名**运行时由使用者选**（`_doh_candidates` 复用 `xray.sh` 的 `_reality_domain_usable_fast` 判「443 SNI 空闲」——它的排除表恰好就是占用 TCP/443 的全集，hysteria2 走 UDP 不在内；菜单按 direct/CDN 分组，某组为空也照样打出组标题并注明「无可用」，不静默消失），路径随机（`openssl rand -hex 6`）或手输，生成后落 state **`DOH_DOMAIN` / `DOH_PATH`**（清空这两个 state 重跑即可换域名/路径）。**后端 `127.0.0.1:15353` 是 mosdns-x，而仓库里没有 `modules/mosdns.sh`** → 新机器上该入口会 502（自检对此只 WARN 不算失败，属预期）；那台的 mosdns-x 配置见下方「活机探索记录」，但**那节的 unbound-DoH 是另一条路线**（手工、未进脚本、其 `/dns-query-unbound` location 在该机上仍是遗留）。⚠️ **本条里的两处已被 2026-09-30 的 `d959062`/`7de4b65` 取代**：① 「仓库里没有 `modules/mosdns.sh`」不再成立（已新增，见下方「DoH 入口从『配置 Nginx』独立成主菜单项」）；② 域名不再「运行时由使用者选」、也不再按 direct/CDN 分组罗列 —— 问答搬到了主菜单 `y`（原 `15`），`ensure_doh_conf` 只认 state。

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

    三层封堵（缺一不可）：**(1)** `cert.sh` 解析完 TSV 后硬拦 —— 只要域名列出现 `example.com`（RFC 2606 保留域，不可能有真证书）就断定表没被填过，在**任何写操作之前** `return 1`；**(2)** `_purge_stale_domains` 内部加人工确认（列清将删的域名、要求输入 `yes`，非 tty 一律中止），调用点检查返回值并在未确认时中止整条流程 —— 这道挡的是其余一切让它跑歪的原因（手滑删行、域名打错、换根域名）；**(3)** `edit_nodes.py` 按 S 时若仍有 `example.com` 先警告并要求 `Y` 二次确认，从源头拦住「把默认表落盘」。回归用例 E 复现该事故，断言 `_purge_stale_domains` 不被调用、无任何域名/证书写操作。
    **回退**：`git revert f5be08f`（**不建议** —— 回退即恢复该自毁路径）。

  - **历史落点回退（`b0c2083`）**：用户**另一台**机器报警的是 `⚠ 未找到 /root/.config.tsv` —— 落点是 `/root`，而 `/root` 只可能来自 `7db1482`~`5d5afdd` 之间那版 cert.sh（`EDIT_NODES_DATA_DIR:=/root`）；`STATE_DIR` 从建立起就一直是 `/etc/xray-deploy`（逐提交核过，`git log -S'STATE_DIR:=/root'` 无结果）。也就是说那台机器是「**新 edit_nodes.py + 旧 cert.sh**」的组合。与其继续追版本组合，不如从根上认下这件事：**表是用户资产**，不该因为脚本换了个算法就「找不到自己的配置」而白屏 `example.com`。现在 `run_cert` 在主目录 `${STATE_DIR}` 里没有 `.config.tsv` 时，依次回退到 `/root` 与 `$(dirname "$edit_nodes_script")`（= `5d5afdd` 那版的仓库根落点），命中即用并打警告 + 给出迁移命令。**只在「确实存在表」时才回退** —— 空目录回退没有意义，还会把真正的首次安装伪装成「找到过」；回退后**读与写共用同一个目录**，不制造第二个分叉。**回退**：`git revert b0c2083`。

  ⚠️ **push 完别立刻断言「远端已生效」**：`raw.githubusercontent.com` 是 Fastly CDN，响应头 `cache-control: max-age=300`、`x-cache: HIT`，**push 后仍可能继续供旧文件，实测约 90 秒后刷新**（`install.sh` 自己因为每次都被 curl 新拉所以没事，但**单文件缓存是各自独立**的 —— 同一提交里 `cert.sh` 已刷新而 `edit_nodes.py` 还是旧的很正常）。带 `?cb=<随机>` 也绕不过去，`x-cache` 仍是 `HIT`。**唯一可靠的判据是逐字节比对**：`curl -fsSL "$BASE_URL/<file>" -o /tmp/_r && cmp /tmp/_r <file>`。这一坑当轮就踩到了 —— 拿 CDN 旧货覆盖了活机缓存，等于把刚写的诊断行又抹掉。所以 push 后要让远程机器验证，先 `cmp` 一遍再说「重跑就好了」。

- **证书子菜单 6→3，域名配置统一走配置表（`8a609c1`，2026-09-30）**：`run_cert()` 从 6 项并为 3 项 —— `1 配置域名表 / 2 检查更新 Certbot / 3 刷新修复域名协议分配`。原 2/3/4（新增 CF 账号 / 新增域名 / 仅补证书）是三条**与配置表完全平行**的交互式流程，现已全部由配置表按内容自动判定；填表的语义本就是它们的超集（按表里 token 无条件重写 `cf_account_N.ini` / `domain_<root>.ini`、按表注册域名与槽位、`check_existing_certs` 只补缺的证书），唯一缺的是收尾重建，本次补上。表格流程加了三处：**(a)** `python3` 前后各取一次 `.config.tsv` 的 md5，**未变动则「沿用现有表继续」而不报错**（`edit_nodes.py` 只在按 S 时写文件；旧代码在「表存在但按了 Q」时直接 `return 1` 报「未找到配置表」，把原「仅补证书」的用法打死了，也与紧邻注释「视为无更改」自相矛盾）；**(b)** `_purge_stale_domains` **之前**加空表护栏 —— 该函数没有空表保护，`_keep` 为空会把 `OLD_DOMAINS` 全判为陈旧 → 清 `DOMAIN_REGISTRY`、删 `domain_*.ini`、`certbot delete` **删掉所有证书**，合并后填表成为唯一入口，必须拦（确实要停用全部域名走主菜单 u）；**(c)** 照抄 `refresh_domain_assignments` 的槽位 before/diff/派发范式，末尾按 `_slot_tag` 映射调 `regen_after_domain_change`（内含 `do_conf_nginx` 全量，原菜单 2/3 那步单独调用的 `do_conf_nginx` 一并涵盖）。顺带删掉已无调用点的老流程 `add_cf_account` / `add_domain_and_cert` / `_filter_dup_cf_accounts` / `_cf_account_label` / `_is_old_cf_dup`（-348 行）；**`_cf_self_ipv4` / `_cf_self_ipv6` 保留** —— 它们被存活的 `scan_cf_domain_inventory` 调用，只是恰好夹在待删函数后面（上一轮的审计就差点误删）。`install.sh` preflight 修复入口提示同步改名「配置域名表」。**⚠️ 旧序号 2/3/4 的输入现在落到「配置域名表」；2 号的含义从「新增 CF 账号」变为「更新 Certbot」。** **回退**：`git revert 8a609c1` 后重跑主菜单 5 即恢复 6 项菜单；表格数据文件不受影响。**改完必须 commit + push 到 `BASE_URL` 指向的分支**，否则 `bash <(curl ...)` 模式的其它机器仍会拉到旧菜单（同上方 Hysteria2 那节的分发陷阱）。**顺带发现（未修）**：`cert_txn_begin/commit/rollback` 整套配置事务机制当前**不可达** —— 仅有的三个调用点（`collect_domains` 1294、`setup_cf_accounts` 652/674）本身都是无调用点的死代码；`get_cf_account_by_domain` 同样是既有死代码。

- **配置表成为域名的唯一来源：清掉最后三处手输与「表/交互打架」（`3d101c4` + `ee67e81` + `1196dda`，2026-09-30）**：用户的长期诉求是「配置表填一次，其它组件自动读表」，但当时还有三处活的交互在要域名。三处一起改，各自独立成提交便于单条回退。

  **(1) `cert.sh`（`3d101c4`）**：新增读表工具 `config_table_slot_domains`（stdout 每行 `槽位标签\t域名`）与 `config_table_domain_for_slot <槽位>`，配 `_config_table_file` 解析落点（优先用 `run_cert` 算好的全局 `TSV_FILE`，因为那含「历史落点回退」的结果；5→3 等**不经过 `run_cert`** 的路径走 `EDIT_NODES_DATA_DIR`→`STATE_DIR` 兜底链）。`refresh_domain_assignments` 里 Hysteria2 那段「罗列全部 registry 域名 + `read` 手输」改为直接查表第 6 行：填了就登记、留空则给指路后跳过，**不再接受手输**。

  ⚠️ **本次最大的坑（通用教训，值得记牢）：模块里的文件作用域 `declare` 会失效。** 模块是被 `install.sh` 的 `load_module()` 里的 `source` 加载的，而 `source` 发生在**函数体内** —— 于是文件作用域的 `declare -A protocol_map=(...)` 变成 `load_module` 的**局部**变量，函数一返回就没了。症状极隐蔽：报 `cert.sh: line 3046: vless: unbound variable`，因为 `${protocol_map[$protocol]:-}` 面对一个**未声明**的数组会按**算术下标**求值（`vless-xhttp` → `vless - xhttp` → `vless` 未定义）。**结论：需要跨函数共享的变量只能用 `declare -g` 或直接赋值（不带 declare）；要 `declare` 就得在真正使用它的函数内部。** 因此 `protocol_map` 最终仍留在 `run_cert` 内，读表工具把「行号 → 槽位」的映射内联成自己的 `local -a`。从没跑过活机就发布的话，这会表现为「表里填了却不生效」甚至直接中止，属于必须靠沙箱回归才抓得到的错。

  **(2) `cert.sh` 步骤 7/7b —— 补上「表里清空」这个表达不出来的缺口**：步骤 7 原先只在行里有域名时**写**槽位键、从不清理，看似「表里清空 = 切回借公共」；**实际是个 no-op**，因为紧接着的第 8 步 `rebuild_protocol_domains`（`install.sh:798-804`）会**按 `DOMAIN_PROTO_<域>` 标签无条件重推覆盖**这 7 个键，而 `register_domain` 是 **merge 语义**（`install.sh:245` `merge_domain_protocols`，**只加标签、从不摘除**）。所以旧域身上仍挂着 `xray-reality` 标签，`REALITY_DOMAIN` 会被原样填回来 —— 这正是「表说借公共、state 说自建」的根因。补 7b：两个 Reality 槽在表里留空时显式调 `reality_untag_self_domain`（按需 `load_module xray`）摘标签。**⚠️ 偏离原计划**：原计划是把 7 个槽位**全部**改成「表里空就清空键」，读到 `rebuild_protocol_domains` + merge 语义后判定那是无效动作，改为只对**两个 Reality 槽做标签级**处理 —— 其余 5 槽既没有通用的 untag helper，也不是用户点名的地方。

  **(3) `xray.sh`（`ee67e81`）**：删掉 `collect_reality_params` 里的 Stage A 逐槽提问（「保持自建 / 切回借公共 / 改用其它域」）与孤儿函数 `_reality_ask_slot_sni`（-89 行），改为**只 log 表的决定**（自建域 / 借公共）。**保留**「同域双标」防御（域层错误态修复，非提问）、`_reality_own_candidates`（`cert.sh:2204` 仍在用）、`_reality_pick_target_list`（公共伪装站点是第三方站点、不是用户的域）。⚠️ **遗留（只报告未删）**：`*_PREALLOC` 的最后一个**影响生成结果**的读者随本提交消失，现在只被 `_reality_own_candidates` 读取、用于给菜单 **5→6 自己的候选列表排序** —— 即 5→6 `offer_reality_preassign` 已变成「只写不读、不影响任何生成结果」。是否下线 5→6 待用户决定。

  **(4) `nginx.sh`（`1196dda`）**：`ensure_doh_conf` 原按直连/CDN 分组罗列候选、让用户输序号挑（另一个与表平行的手输来源）。改为默认值 = `DOMAIN_REGISTRY`（表里已注册的域）顺序里**第一个直连域**，没有直连才退而取第一个 CDN 域，回车即采用；log 说明取自哪里。**手输入口刻意保留**（用户明确要求别一刀切删掉）：**无候选时不再像以前那样直接 `return 0`**，而是转入手输并照旧走 `_reality_domain_usable_fast` 的 443 SNI 占用校验；`0 = 不启用` 与自定义域覆盖默认值的能力一并保留。想换域名：清空 state 的 `DOH_DOMAIN`/`DOH_PATH` 后重跑。


- **域名「一览」改成真表格 + 表行号直通配置表（`4979b66`，2026-09-30）**：上面那批改完后用户否掉了我对问题的理解并给出原话 —— **「我要的是表格呈现」**，随后补一句 **「表格方式呈现，我一目了然，需要添加或者修改域名在里面方便」**。即：问题不在「还要不要手输」，而在**那张表本身是歪的、且看不出该去哪改**。

  **根因（通用坑，凡是用 printf 排版中英混排都会踩）**：`printf "%-16s"` 按**字符数**补空格，而中文/全角符号在终端占 **2 列**。旧 `print_domain_protocol_overview` 的表头是中文（`协议槽位` 4 字符=8 列）而数据是 ASCII（`VLESS-XHTTP` 11 字符=11 列），于是**表头与数据行从第二列起就错开 3 列**，手写的 `────────────────`（16 字符=32 列）又比它要划的表头宽一倍，`(借公共 SNI: …)` 超长时更把第三列顶飞。**「表格」的全部价值在对齐，歪了就等于没排。** `edit_nodes.py` 早就做对了（`cw()`/`wlen()` 用 `unicodedata.east_asian_width(ch) in "WF"`），问题只在 shell 这边没跟上。

  **改动**：`install.sh` 新增通用 **`render_table()`**（紧挨 `log_*` 定义，install.sh:90-117）——东亚宽度感知，stdin 每行 `\x01` 分隔的单元格、`$1` 是逗号分隔的各列显示宽度、单行 `__RT_SEP__` 输出 `─` 分隔线；用一次性 `python3 -c` 实现（`python3` 是既有依赖：`edit_nodes.py` 就要它）。`print_domain_protocol_overview` 与 `show_domain_allocation` 的 `[域名分配]` 都改走它。

  **「便于新增/修改」的落法**：一览表新增 **「表行」列**（1-7），**行序也一并改成与配置表一致**（`edit_nodes.py` 的 `data` 常量：xhttp/grpc/xhttp-reality/reality/AnyTLS/Hysteria2/Naiveproxy；旧打印序是 Reality 在前、XHTTP-Reality 在后，**与表相反**），表尾三行 log 直接说明：改哪一行、备用空行是第 8-10 行、Reality 两槽「留空=借公共 / 填域=自建」。**没做**的是「在屏幕上直接编辑这张表」——`edit_nodes.py` 的 curses 表本来就是那个编辑器，再加一处就地编辑等于又造一个与表平行的入口（正是前一批刚清掉的东西）。

  ⚠️ **写测试时才发现的子 shell 坑**：表格**必须先攒进数组、再整段交给 `render_table`**，不能写 `{ ...; _unconf+=(); ... } | render_table` —— 管道会把整个生成循环丢进子 shell，函数后面用来打「以下协议尚未配置」的 `_unconf` 汇总**永远是空的**（且不报错，只是提示消失）。已在测试里专门回归。

  **验证**：新增 `/tmp/cert_tablealign_test.sh`（17 项断言全绿）——核心断言是**逐行比对各列的起始显示列必须完全一致**（真机数据下为 `(0,7,24,59)`），分隔线段宽必须等于列宽；**同一套断言喂旧 printf 的输出会判定「表是歪的」**（各行列起始集合 `{(0,17,48),(0,21,56)}`），证明断言不是恒真。另有行序/表行号/「✓ 共用」「公共伪装」「(未配置)」/指路文案/子 shell 回归/render_table 边界（缺列行、分隔线、中文与等宽 ASCII 的第二列起始列相同）等项。既有 5 套沙箱全绿；`bash -n` 全绿；活机只读跑真实 state：7 行域名（`lv/ltu/lt/lti/eo/lt/lva`）全部对齐，`(0,7,24,59)`。**回退**：`git revert 4979b66`（`render_table` 与两处调用同一提交；`[证书到期]` 补占位列也在内）。**改完必须 push 到 `BASE_URL` 分支**（`install.sh` + `cert.sh` 两个文件，见上方分发陷阱）。

  - ⚠️🩸 **`4979b66` 有个设计缺陷，当天就被 `6856fff` 修掉 —— 实机表现为整张表变成一行报错**：`/etc/xray-deploy/modules/cert.sh: line 2140: render_table: command not found`。根因不是缓存/CDN，而是 **`render_table` 只定义在 `install.sh` 里，而 install.sh 与模块是两条独立的更新通道**：install.sh 由用户启动的那份决定（本地 checkout / `bash <(curl ...)` 一次拉取），模块却可能被单独刷新（curl 模式每次拉、或菜单 `s`「同步/更新模块到本地缓存」）。于是出现**「模块是新的、install.sh 是旧的」**这一组合，新 cert.sh 调到一个不存在的函数，表格整块消失（只剩一行报错，且脚本继续往下跑，不报失败）。
    **修法**：`cert.sh` 顶部加 `if ! declare -F render_table; then render_table() {…}; fi` 兜底（两份**同实现**，各自注释里互相点名要求同步改）；测试里加了一条**「只 source cert.sh、不 source install.sh」**的回归用例，并逐字比对两份函数体防漂移。
    **通用教训（值得记牢）**：**模块不能依赖 `install.sh` 里「后加」的函数** —— 模块要用什么就得自己能提供，或者只依赖 `log_*` / `get_state` / `save_state` 这类早已稳定的核心函数。反方向（install.sh 调模块函数）是安全的：install.sh 旧了就是旧行为，不会崩。这条和「模块里的 `declare` 会失效」（`3d101c4`）是同一个根因的两种表现 —— **`source` 进函数体的模块，与宿主脚本不是同一个命名空间假设**。
  - 同批还改了两处显示：**空槽留空白**（用户原话「即使没有配置相关域名和选项你可以显示空白」）—— 删掉 `(未配置)` / `(借公共 SNI: …)` 占位文字，空即为空，借公共的 SNI 挪到备注列写作 `借公共 <域>`（信息不丢），没配的协议仍由表尾那行 WARN 汇总；**列宽收到 `6,14,22,26`**（合计 73 列，刻意压在 80 列终端内 —— 表格一旦折行就全废，加宽前先算总宽）。**回退**：`git revert 6856fff`（会退回「模块依赖 install.sh」的缺陷态，不建议）。

  - 🩸 **「表格」= 带框的表：给 `render_table` 画上 ASCII 边框（`92a2853`，2026-09-30）**。`6856fff` 修完报错后，用户对着**已经对齐、空槽也留白**的一览表仍然说 **「你这是逗我吗. 我要的是表格,先不要关其他 的」**。真正的原因到这一刻才清楚：**我把「表格」当成了「空格对齐的文本」，而在他眼里那不是表格。**
    **判据（决定性）**：他每天在配置表里看到的就是 `edit_nodes.py` 的 `draw_table` —— `+`/`-`/`|` **画出来的 ASCII 框**（`hline()` 用 `"+" + "+".join("-"*(w+2)) + "+"`）。**边框是他认「这是个表格」的视觉标志**；只有空格对齐、一根竖线都没有的输出，读起来就是「一列列文本」。凡是他嘴里说「表格」而屏幕上是一片对齐文本时，先怀疑缺的是**边框**，不是对齐。
    **改动**：`render_table` 两处同实现（`install.sh` + `modules/cert.sh` 兜底）改为输出**带框**：首尾自动补 `+---+` 横线、`__RT_SEP__` 行输出中横线、列间 `|` 贯通，风格与 `edit_nodes.py` **完全一致**（ASCII，不用 Unicode 制表符）。计宽**忽略 ANSI 颜色序列**（`\x1b[..m` 记 0 宽）→ 据此把 `install.sh` 的 `[证书到期]` 子表也改走 `render_table`（同一屏两张表一张带框一张不带框，看着像两个来源；该表第三列带颜色，正是当初没走 render_table 的原因，现在不是理由了）。**超宽单元格折行**而不是撑破边框：真实数据里 `借公共 solanolibrary.com`（24 列）就撑破过 23 宽的列，一撑破整张表就散 —— 空格优先断行、长域名硬切，`units()` 保证 ANSI 序列不被拦腰截断。一览列宽 `6,14,22,26` → **`6,14,20,24`**（带框后每列多占 3 字符，总宽 79 ≤ 80）。
    **验证**：`/tmp/cert_tablealign_test.sh` 改写成六节全绿 —— 新增「**必须有 +---+ 边框与贯通竖线**」一节，内含**反向自检**（抹掉边框后本节判据必须拒绝该输出，证明断言不是恒真）、按显示列比对竖线位置、横线分段长 = 列宽+2、ANSI 不计宽、超宽折行后各行等宽；原行序/表行号/空白槽/指路/子 shell/模块兜底各节保留；既有 5 套沙箱全绿；`bash -n` 全绿。活机只读跑真实 state：一览 79 列、`[域名分配]` 68 列、`[证书到期]` 61 列，**每张表内部逐行等宽**（`python3` 按东亚宽度复核，含带 ANSI 的那张）。
    ⚠️ **测试里的一个反复踩到的点**：比「竖线位置」要按**显示列**算（`w(l[:i])`），不能按字符下标 —— 中文占 2 列，各行的字符下标天然不同，按 `enumerate()` 的 i 比等于什么都没比（旧断言就是这么错的）；同理规则行要用 `re.match(...).group(0)` 再切段，`(-{2,}\+)+` 的 `group(1)` 只留最后一次重复。
    **回退**：`git revert 92a2853`（回到无边框的对齐文本；不建议，等于退回用户已明确否掉的样子）。**改完必须 push 到 `BASE_URL` 分支**（`install.sh` + `cert.sh`；CDN 逐文件独立缓存，只有 `cmp` 是可信判据）。

  - 🩸 **真正的答案：他要的是「那张能改的表出现在刷新这条路上」（`c60e9f2`，2026-09-30）**。带框表上线后用户仍说 **「仍然不是」**，并贴出**选项 1 的截屏**（`edit_nodes.py` 的 curses 表：`方向键移动 | Enter 编辑/切换 | S 保存 | Q 退出` + 10 行带框表格）+ 一句 **「为什么不能像1这样显示完整表格修改」**。到这一刻诉求才完全落地 ——
    **「刷新修改域名以表格的方式呈现」= 刷新那条路（5→3）上要先出现选项 1 那张完整的、能改的表**，而不是一张只读的 7 行汇总。带框与否只是他中途否定的一种表述；**核心始终是「在哪儿改域名」**：他在 5→3 看不到可改的表，只能退回 5→1。
    **改法（最小改动，一行 `if` 的事，别搬代码）**：`run_cert` 里选项 3 不再直接调 `refresh_domain_assignments`，改为置 `_also_refresh=1` 后**与选项 1 共用同一条填表流程**（打开表 → 应用表内容 → 级联重建），只在函数末尾 `(( _also_refresh ))` 时补一轮 `refresh_domain_assignments`（重建映射、清陈旧标签、最后打出那张带框一览）。菜单文案同步改成「3. 刷新/修复域名协议分配（同样先打开这张表，改完再刷新）」。按 Q 未改表的用法与旧的纯刷新一致。
    **验证**：新增 `/tmp/cert_menu3_test.sh`（unshare+tmpfs 沙箱；重活 `install_certbot`/`request_certificates`/`regen_after_domain_change`/`refresh_domain_assignments` 全 stub，`python3` 顶成「按 S 保存」写出含真实域名的表）三节全绿 —— **3 的顺序必须「先开表 → 后刷新」**、1 不得出现刷新、2 只查 certbot。既有 6 套沙箱全绿；`bash -n` 全绿。
    **回退**：`git revert c60e9f2`（退回 3 = 纯刷新 + 只读汇总）。
    ⚠️ **教训（比技术更重要）**：用户三次说「表格」，我三次改了**渲染**（对齐 → 边框 → 折行），而他真正要的是**交互位置**（那条路上有没有那张能改的表）。**他的抱怨句里如果有动词（「修改」「刷新」），先按「流程/入口」找问题，别急着改排版。** 判据是他贴的截图：他贴哪张屏，就是拿哪张屏当标准 —— 这次贴的是选项 1 的表，答案就是「让那条路也变成这张表」。

- **配置表支持鼠标：单击选中 / 双击 = Enter（`edit_nodes.py`，2026-09-30）**：用户问「表格可以设置双击输入吗」。改的是 `edit_nodes.py` 一个文件（`bash <(curl ...)` 模式经 `${BASE_URL}/edit_nodes.py` 拉取，**改完必须 push 到 `BASE_URL` 分支**；本机缓存 `${STATE_DIR}/edit_nodes.py` 由 `resolve_edit_nodes_script` 每次重拉）。`main` 里 `curses.mousemask(ALL_MOUSE_EVENTS)`，不支持则 `MOUSE_OK=False`（提示行也就不写「双击」那半句）；`draw_table` 顺手把行/列落点记进 `HIT_ROWS`/`HIT_COLS`（**行高随折行变、列宽随内容变，只有它知道落点**，别另算一份），`hit_test` 换算成 `(行,列)`，`mouse_click` 返回 `('move'|'edit', 行, 列)`，`edit` 走的就是 Enter 那条 `edit_cell`（模式列＝切换）。
  ⚠️ **双击有两条路径，缺一条就「按不出来」**（pty 探针实测，不是推理）：**① 间隔 < ~166ms**：ncurses 按自己的 mouseinterval 合并，只交**一个** `BUTTON1_DOUBLE_CLICKED` 事件（**第一次单击被它吞掉**）→ 必须直接判 `bstate & BUTTON1_DOUBLE_CLICKED`；**② 166ms~600ms**：终端给**两个**独立事件，ncurses 不管，只能自己按时间窗判（`MOUSE_DOUBLE_MS=600`）。**Python 的 curses 没暴露 `curses.mouseinterval`**，调不了它的阈值，所以慢速双击只可能靠自己那条路兜住。另有一处防抖：同一物理点击在部分终端/协议下报成「按下+抬起」两个事件（实测 `TERM=xterm-256color` 下 ncurses 只报 **RELEASED** 一个），50ms 内的第二个事件并掉 —— 否则一次单击会被自己数成两击。
  ⚠️ **`KEY_MOUSE` 必须 `getmouse()` 取走**：`input_line` 的 `get_wch()` 分支不处理它就会**空转死循环**（下一次 `get_wch` 立刻再吐一个 `KEY_MOUSE`）。`edit_cell` 进入时清 `_last_click`，免得改完随手再点一下又进编辑。
  ⚠️ **鼠标上报是「独占」的，必须给一个当场开关**：开了之后终端把**所有**鼠标动作原样转发给程序 —— 用户立刻就来问「为什么我鼠标不能复制粘贴到表格」：拖选文字选不中（变成给程序的拖拽事件）、**右键粘贴**（Xshell/FinalShell/PuTTY 的默认习惯）变成 `BUTTON3` 事件被丢弃、中键粘贴同理。故表格里加了 **`M` 键开关**（`set_mouse()`：`mousemask(ALL_MOUSE_EVENTS)` ↔ `mousemask(0)`，ncurses 会在下次 refresh 下发/收回 `\x1b[?1000h/l`），**提示行文案跟着翻**（`M 关鼠标` / `M 开鼠标`），按一下就把鼠标还给终端，再按一下收回。临时手段仍是 **Shift+拖选**、**Shift+Insert / Ctrl+Shift+V** 粘贴（终端里 `Ctrl+V` 本来就不是粘贴键）。tmux 里需 `set -g mouse on` 才会转发点击。**键盘这条路实测可用**（用户选了它）：粘贴就是一次性灌进一串字符，52 字符（与真机 CF 令牌等长）**一字不差**地进表格并落盘，ncurses 的 typeahead 不吞长串 —— pty 测试里专门回归了这条（灌入 → 回车 → 按 S → 直接读 `.config.tsv` 核对）。
  ⚠️ **`curses.mousemask()` 返回的是元组 `(availmask, oldmask)`，不是整数** —— 写成 `mousemask(...) != 0` **恒为真**：关掉后 `MOUSE_OK` 不翻（提示行不改、再也开不回来），且**终端不支持鼠标时也谎报支持**。测试当场抓到（按 M 的断言全红）。正确写法是取 `r[0]` 判真假（兼容万一返回整数）。
  **回退**：`git revert <sha>`（单文件，无需重跑安装；回退后鼠标点击等于没点，键盘照旧）。
  **验证**：新增 `/tmp/ed_nodes_mouse_unit_test.py`（假 `curses`/`time`，24 项：命中边界含折行行、越界/边框/滚轮/表格外、防抖合并、600ms 窗口、快双击 `DOUBLE_CLICKED`、`TRIPLE`、`set_mouse` 开关与元组返回值、编辑后清计时）与 `/tmp/ed_nodes_mouse_pty_test.py`（**真 pty + 真鼠标转义序列**：SGR 1006 自动识别、屏幕网格还原后**从画面上读回**「域名」列坐标再点，断言单击只选中（状态行 `当前 [域名]: …` 佐证）、快双击弹出 `修改[域名]`、慢速双击 300ms 切换「模式」列、按 M 后**输出里出现 `…l` 关闭序列且提示行翻成「M 开鼠标」**、再按 M 恢复且点击又能选中、Esc 取消后 Q 仍能退出）全绿；7 套既有沙箱套件全绿；`python3 -m py_compile` 通过。

- **DoH 入口从「配置 Nginx」独立成主菜单项：新增 `modules/mosdns.sh`（`d959062` + `7de4b65`，2026-09-30）**：用户贴着实机日志说 —— **「这个设置不合理,应该列一个单独的选项:安装moods-x 和配置相关页面,现在好像是隐藏了」**。两个问题一个症状：

  ⚠️ **条目位置当日又改过一次，读本节时以新版为准（`e26f6ba`）**：初版编号 **`15.`**、挂在「**=== 配置 ===**」段末尾（`14. 配置 NaiveProxy` 之后）。用户随即回一句 **「我要的是菜单页面有安装mods的选项」** —— 标题里虽然写着「安装」，但**它出现在配置段的清单里，就不是他要的那一项**；他最初的原话也正是「应该列一个单独的选项:**安装**moods-x…」。现改为挂在「**=== 安装 ===**」段（`9. 安装 NaiveProxy` 之后）：**`y. 安装 mosdns-x（DoH 入口：装后端 + 配置入口域名/路径）`**，配置段里**不留重复条目**，`15` 这个键**释放**。
  ⚠️ **用字母键 `y` 而不是数字是刻意的**：安装段 `1~9` 已占满，塞一个数字就得把「`10. 配置 Nginx`」起的 **1~14 全部后移** —— 与下方「1~14 的序号一律不动」的同一约定。`y` 是主菜单里少数未占用的字母（`o` 与数字 `0` 易混，弃用）。**判据是「他贴的/他指的那一段清单里有没有」，不是条目标题里有没有写「安装」** —— 与 [[feedback-table-presentation]] 记的「他要的是交互位置」是同一个模式。全仓库引用（`modules/nginx.sh` 四处指路文案、`/tmp/mosdns_test.sh` 断言、`/tmp/cert_domainsrc_test.sh` 注释）已一并由 `主菜单 15` 改为 `主菜单 y`；`do_inst_mosdns` 的动作名同步为「安装 mosdns-x」。
  ⚠️ **别再把「模块同步了」当成「菜单更新了」** —— 用户这次没看到菜单项，还有第二层原因：他跑的是**推送之前拉的 `install.sh`**，而 `install.sh` 是**启动时读一次**的、按 `s` 同步模块**碰不到它**（`s` 只刷新 `modules/`，所以 `[模块缓存]` 从 17/18 变成 18/18，看起来「都更新了」）。`c2d7e88` 已在 `do_sync_modules` 收尾加两行 WARN 把这话说透（git 模式给 `./install.sh`、curl 模式给 `bash <(curl ...)`）。**这是「两条独立更新通道」的第三次显形**，同类见 [[project-module-vs-installsh]]。

  ⚠️ **已安装后不再每进一次就重装，且补上了「只换 `/` 后面那段」**（`b92b180`）：用户接着说 **「有了但是设置不合理,每次点进去都要重新安装一次,如果我只是配置更换域名或者/ 后面的设置」** —— 又是**一句里点了两件事**（「每次重装」+「`/` 后面的设置」），两句都得答：
  - **重装**：原 `run_mosdns` 进来就是一条龙（装二进制弹 y/N → 生成配置每次留一份 `.bk` → 重写 unit → **重启服务**，家里解析瞬断）→ 才轮到问 DoH 入口。而入口只动 nginx 的 `doh.conf`，**跟 mosdns-x 本身无关**。现在 `mosdns_installed` 为真就走 `_mosdns_menu_installed` 子菜单，**默认项直接是「配置 DoH 入口」**（回车即走），另给 `2. 重装 mosdns-x 并重启服务`（`install_mosdns_binary --force`，不再多问一次 y/N）与 `0. 返回`；未安装时仍是原一条龙、不弹子菜单。
  - **`/` 后面的路径**：原「已启用」分支只给「回车保持 / `0` 关闭 / 输新域名」三条路 —— **路径只在首次启用时问过一次，之后没有任何入口能改**。现在多一个 **`p` = 只换访问路径**（路径提问抽成 `_doh_prompt_path()`，首次启用那段也改用它）。⚠️ 该函数把结果写进全局 `DOH_PATH_NEW` 而**不是用 stdout 回传** —— `log_*` 全是裸 echo，走 stdout 会被调用方一起捕获成一个多行「路径」（同 `resolve_edit_nodes_script` 那条坑）。
  - **验证**：`/tmp/mosdns_test.sh` 加第 4b（`p` 换路径后 state 与 `doh.conf` 同步换、域名不被顺手改掉、回车=随机重生）与第 9 节（三个选项的动作分流 + 「未安装状态成立」反向自检），**68 项全绿**；其余 6 套沙箱 + 2 套 python 套件 exit 0。
  - **回退**：`git revert b92b180`（回到「每次进来一条龙 + 路径改不了」）。

  ⚠️ **子菜单第 3 项「检查更新」**（`ef39a05`）：用户接着说 **「还有这7个域名都可以使用吗,会不会和其他协议冲突.还有可以提供一个更新选项」** —— 又是**一句里两件事**（域名能不能复用 / 要个更新入口）。更新做在子菜单里（`3. 检查更新（比对 GitHub 最新发布版）`），两个新函数 `_mosdns_latest_version`（自己 curl GitHub `releases/latest` 解析 tag 的数字部分，**刻意不调 install.sh 的 `upgrade_github_latest`** —— 模块不能依赖 install.sh 里后加的函数，见 [[project-module-vs-installsh]]）与 `_mosdns_check_update`。**两边都取数字部分比对**（本机取 `build time`）：拿二进制自报的 `v4.6.0` 去比 tag `v26.05.25` 会**永远**判「有新版」而下载回来的其实一模一样。已最新 → 一个动作都不发生（不白下一遍）；有新版 → 问 `y/N`；**取不到版本号 → 明确报错并 `return 1`，绝不静默当成「已最新」**。更新动作与选项 2 同一条路径（`install_mosdns_binary --force` → 重写 unit → 重启 → `verify_mosdns` 只告警），**绝不重跑 `generate_mosdns_config`**（禁忌同下）。另：全局 `v. 升级组件` 菜单里本就有 `6. mosdns-x`，这一项是给「就在 mosdns 这条路上」的人用的。**回退**：`git revert ef39a05`（只影响第 3 项，1/2/0 与 DoH 入口都不受影响）。

  ⚠️ **测试脚本两个坑（这次双双踩到，写新沙箱前先看这两条）**：**(1)** `/tmp/mosdns_test.sh` 是 `source <(sed -n '1,…' install.sh)` 取 install.sh 前缀的，而**从第 1 行开始截就把它的 `set -euo pipefail` 一并 source 了进来** —— 于是「断言一个**预期失败**的调用」（更新检查那条 `printf '3\n' | run_mosdns` 返回 1）会让整个脚本**静默中止**：屏幕上一堆 ✓ 却没有汇总行，看起来像「跑到一半崩了」。测试要的是逐条断言、不是 fail-fast，故在 source 之后显式 `set +e`，要判退出码的地方自己收 `$?`。**(2)** `mosdns_installed` 是 `[[ -x "$MOSDNS_BIN" ]] || command -v mosdns` —— 上一节往 `$WORK/bin` 写过一个 `mosdns` 桩而 `$WORK/bin` 在 `PATH` 里，于是「未安装时仍走一条龙」的反向自检**永远失败**（它一直判「已安装」）。删桩或换个不冲突的名字再测。修完 9 节 **79 项全绿**。

  **(1) 位置错**：DoH 入口的域名/路径问答长在 `modules/nginx.sh` 的 `ensure_doh_conf()` 里，**混在「配置 Nginx」流程中间** —— 重配一次 Nginx 就被问一次，而入口的后端是 mosdns-x，这事跟 Nginx 关系不大。

  **(2) 能力缺失才是「隐藏了」的真身**：`grep mosdns modules/*.sh` 当时只命中 `modules/nginx.sh` 的注释 —— **仓库里根本没有 mosdns 模块**。`ensure_doh_conf` 生成的入口 `proxy_pass http://127.0.0.1:15353/dns-query` 在新机器上必然 502，自检里只能写一句「需另装 mosdns-x…新机器上属预期」。活机那台是**手工装好**的。⚠️ **通用教训**：用户说「某个选项藏起来了」时，**先确认那件事在仓库里到底存不存在**，别只查它是不是可达 —— 这次「藏起来」的字面意思是「活机有、脚本里没有」。

  **新增 `modules/mosdns.sh`（`run_mosdns()` 为入口）**：GitHub releases 装二进制（`pmkol/mosdns-x`，资产 `mosdns-linux-<arch>.zip`；x86_64 **刻意取普通 amd64 不取 `-v3`** —— v3 在只支持 x86-64-v2 的机器上直接 SIGILL，而这一跳是纯转发、性能收益可忽略）；写 config + **自己写 systemd unit**（不用 `mosdns service install`，后者产出不可控，仓库里其它组件一律显式写 unit）；`verify_mosdns` 两层（`ss` 看 15353 在不在听 → **明文直连** `curl http://127.0.0.1:15353/dns-query?dns=…` 要 `application/dns-message`。直连而非走 443，让「mosdns 没起」与「nginx 入口没配对」是两条**独立**判据）；`configure_doh_entry` 承接从 nginx.sh 搬来的问答，收尾走 `sync_refresh_nginx_routes` 而**不是**自己调 `generate_nginx_conf`（后者依赖 `REALITY_DOMAIN` 等一批内存全局，不先恢复域名数组就会生成一份**丢掉全部 SNI 路由**的 `nginx.conf`）。

  ⚠️ **`/etc/mosdns/config.yaml` 绝不自动覆盖**（活机那份是用户按自家网络**手工调过**的，带两份 `.bk`，覆盖 = 他的 ECS 分流行为当场变化）：`generate_mosdns_config` 见到已存在的文件只备份成 `config.yaml.bk.<ts>` + `log_warn` 保留，**升级路径也只重装二进制、绝不重跑它**。模板以**活机实测可用**的那份为准（DoT `tls://8.8.8.8` 主 + `tls://8.8.4.4` 备、`enable_pipeline`；`_edns0_filter_ecs_only` → `cache` → primary/secondary `fast_fallback:1500` → `_return`），**不用**用户笔记里那版 `https://dns.google/dns-query`（笔记早于 DoT 那次实测，`udpme://` 是明文 UDP 已废弃）。也**刻意不写语法自检**：`config check` 这类子命令名随版本变过，猜错只是噪音；真判据是随后真的起、真的答。

  ⚠️ **版本比较必须用 build time，不能用自报版本**：发布 tag 是 `v26.05.25`，而二进制 `mosdns version` 自报 `version: v4.6.0, build time: 26.05.25` —— `v4.6.0` 是 mosdns-x 自己的版本号，拿它去比 tag 会**永远误报「可升级」**。故 `upgrade_command_version mosdns` 取的是 `build time`。

  ⚠️ **`ensure_doh_conf` 是「幂等早返回」函数，新调用方必须小心**：它开头是 `[[ -n "$DOH_DOMAIN" && -f "$conf" ]] → return 0`。`_doh_entry_apply` 若直接调它，**换域名会变成静默 no-op** —— state 已是新域名、磁盘上还是旧文件，下一次 `generate_sni_map` 又拿着新域名去找文件（文件在，条件成立）→ 443 上把新域路由到 8410，而 8410 的 server 块 `server_name` 还是旧的 → 该 SNI 命中 default 陷阱端口，**DoH 断而脚本报成功**。故 `_doh_entry_apply` **先 `rm -f /etc/nginx/conf.d/doh.conf` 再调**，且**事后断言文件确实存在**（因为 `ensure_doh_conf` 在证书缺失等情况下会**静默 `return 0`**，此时文件已被我们删掉且没重建）。**推广**：① 复用带早返回的函数前，先读它的早返回条件；② 一个会静默 `return 0` 的函数，调用方必须在它之后**断言产物存在**，不能靠返回值判成败。这与「模块不能依赖 install.sh 后加的函数」同属一类「静默少一条」故障。

  ⚠️ **模块里用 `declare -F` 做的门控要小心「模块还没载」**：`configure_doh_entry` 开头原本是 `if ! declare -F ensure_doh_conf; then warn; return 0; fi` —— 而本菜单可以**独立于「配置 Nginx」先跑**（装完 mosdns-x 就地配入口正是主要用法），此时 nginx 模块根本没载，整件事被**静默跳过**且不给原因。现在先 `load_module nginx` 再判。

  **接线**：`DEFAULT_MODULES` / `modules/modules.list` 加 `mosdns`（**curl 模式靠 modules.list 决定下哪些模块，漏了会静默少模块**）；主菜单加 **`y. 安装 mosdns-x（DoH 入口）`**，放在「=== 安装 ===」段（详见本节顶部那条当日修正），**1~14 的序号一律不动**（改序号会让用户肌肉记忆失效）；卸载菜单加 `13. 清理 mosdns-x`（含删 `doh.conf` + 清 `DOH_DOMAIN`/`DOH_PATH`，否则「配置 Nginx」会继续生成一个指向已卸载后端的入口）；升级菜单 `6. mosdns-x`（**原 `6. 全部升级` 顺延为 `7.`，这处序号必须动否则两个 6**）；preflight 内部端口表加 `[15353]`、计数 `13 → 14`。**`run_full_install_flow`（菜单 0）刻意不动** —— 一键安装的机器还没配域名表，DoH 要选域，塞进全流程会中途打断（这是我的判断，可推翻）。

  **`nginx.sh` 侧退回纯自动化（`7de4b65`，可单独回退）**：`ensure_doh_conf` 删掉三段 `read`，改为**只认 state**（`DOH_DOMAIN` 空 → 指路主菜单 y → `return 0`，不提问不阻塞不重写；`DOH_PATH` 空 → 直接随机生成并落 state）；`verify_doh_entry` 的 502 分支文案改指主菜单 y；**限流、日志目录、`limit_req_log_level notice`、CrowdSec 那套注释一个字不动**。

  **回退**：`git revert d959062`（回到「无 mosdns 模块」，老机器照旧、新机器照旧 502）与 `git revert 7de4b65`（DoH 提问回到「配置 Nginx」里；**这是唯一会让用户看见行为变化的半条，单独回退不影响 mosdns 模块**）。**本次不碰客户端链接生成，回退不必重新下发订阅。** **改完必须 push 到 `BASE_URL` 分支**（`install.sh` + 4 个模块文件 + `modules.list`），见下方分发陷阱。

  **验证**：`bash -n` 全绿；新增 `/tmp/mosdns_test.sh` **八节 45 项**断言全绿（第 8 节即「条目必须在安装段、`15` 必须已释放」的四条断言，含一条防「配置段抓成空的」的反向自检） —— 含四条**反向自检**（把域名从 stdin 喂进去也不被采纳、`config.yaml` 不存在时确实会写出来、`DOH_DOMAIN` 有值时同一条路径确实会写 `doh.conf`、「换域名」用例在**不删旧文件**的实现上会红）；既有 7 套沙箱 + 2 套 python 套件全绿（其中 `/tmp/cert_domainsrc_test.sh` 的 I1/I1b/I2 三条 DoH 用例**改调用点**到 `configure_doh_entry`，行为断言一条不少 —— 落点变了但能力没删）；活机（本机）**只读**核对：`verify_mosdns` 通过（HTTP 200 + `application/dns-message`）、`ensure_doh_conf` 幂等早返回后 `/etc/nginx/conf.d/doh.conf` 与 `/etc/mosdns/config.yaml` 的 md5 **均未变**。顺带把 `__pycache__/` 加进 `.gitignore`（测试跑 py 时生成的 `.pyc` 会被 `git add .` 扫进去）。

  ⚠️🩸 **push 后 CDN 逐字节核对又抓到「逐文件独立缓存」**：本轮 6 个文件里 **5 个立即可见、`modules/modules.list` 仍是旧货**（`x-cache: HIT`、`source-age: 267`，`max-age:300`）。**这个文件恰好是最危险的那个** —— curl 模式下它决定「下哪些模块」，拿到旧的（无 `mosdns`）而 `install.sh` 是新的（`DEFAULT_MODULES` 含 mosdns），菜单项会因为模块没下载而失败。**只有 `cmp` 是判据，且必须逐文件比对。**

- **二次配置 DoH 入口：候选列表只在一边列、序号只在一边认（2026-10-01，用户报「没有显示备选域名 / 其他机器好像没有重新设置 nginx 相关配置」）**：`configure_doh_entry` 的**「已启用」分支不给候选列表**——只打「回车保持 / p 换路径 / 0 关闭 / 或直接输入新域名」四行，想换域名只能盲输；更要命的是**序号在这条分支上不被接受**（`ans` 直接丢给 `_doh_domain_usable`，`2` 这种输入被判成「域名 2 不可用」后 `return 1`，state 一个字不动）。所以从第一次配置就学会「输序号」的人，二次配置时**按编号换域名是个死键**：屏幕上没有任何候选、编号没用、入口自然「一点没动」——这正是用户说的「好像没有重新设置 nginx 相关配置」。**候选收集与排序原先是写在「未启用」分支里的**，两个分支各写一份就是这类漂移的温床。修法：① 候选收集**上提到函数开头**（`_cdn` / `_plain` / `_reality` → `_all`，CDN → 直连 → Reality），两个分支共用同一份，序号含义不可能再分叉；② 新增 `_doh_print_domain_list <当前域> <候选…>`，两处都打（已启用时当前那个标 `← 当前`），无候选时**一个字不打且返回 1**，调用方据此决定提示里写不写「或输入序号」；③ 已启用分支**认序号**，且**选到「当前」那一条不是空操作**——照样走 `_doh_entry_apply`，等于给了用户一个「不改域名、只把 nginx 路由重新应用一遍」的入口（这正好是「没重新设置 nginx 相关配置」时他会想按的那个键）。
  ⚠️ **排查过程中实测到的两件事（别推翻）**：**(a) 二次配置本身是好的** —— 新建 `/tmp/doh_reconfig_test.sh`（unshare+tmpfs，**不 stub** `sync_refresh_nginx_routes`，跑真的 `generate_servers_conf` / `generate_nginx_conf`）验证 shared→shared、shared→standalone、p 换路径三种二次改动，`servers.conf` 的 include 会跟着挪 vhost、`nginx.conf` 的 8410 路由会补/撤、旧域不再残留，25 项全绿。**既有的 `/tmp/mosdns_test.sh` 把 `sync_refresh_nginx_routes` 打了桩**（只验 state 与 `doh.conf`），「nginx 侧到底有没有跟着变」在仓库里**从来没被测过**——这是本轮唯一新增的测试面。**(b) 真的会「nginx 没被重新设置」的路径只有一条**：`_doh_entry_apply` 先 `rm -f` 再 `ensure_doh_conf`、**写完 state/doh.conf 之后**才调 `sync_refresh_nginx_routes`，后者被 `preflight_config_check` 拦下（实测触发：注册表里有个协议标签为空的悬空域，Check 5b）就直接 `return 1` —— 此时 **state 与新 `doh.conf` 已落盘、`nginx.conf`/`servers.conf` 还是旧的**，磁盘上两套配置不一致而只有一行 `PREFLIGHT` 报错。现在这里改成**显式说明「改动没生效、443 上跑的还是旧的那套」并给出下一步**（没有做事务回滚 —— 那是更大的改动，需要时另开）。
  **验证**：`/tmp/mosdns_test.sh` 新增 4e 节 **12 项**（已启用分支必须列候选 / 当前域必须标「← 当前」/ **序号必须被当成候选序号采纳** / 超范围序号必须拒绝且不改 state / 选当前域=重新应用且确实重跑路由刷新），全绿时 **99 项**；**反向自检**：同一套断言喂 `git archive HEAD` 的旧模块 → **9 项红**（新增断言不是恒真）。`/tmp/doh_reconfig_test.sh` **28 项**全绿（含 C2 序号换域后的真 nginx 重生成、F 路由刷新失败时的三行说明）。既有 `doh_shared_test.sh` 78 项、6 套 cert 沙箱、2 套 python 套件全绿；`bash -n` 全绿。**回退**：`git revert`（单文件 `modules/mosdns.sh`）。**改完必须 push 到 `BASE_URL` 指向的分支**（curl 模式下 `load_module mosdns` 每次重拉，本地改了不 push 等于没改；push 后仍要 `cmp` 逐字节确认 CDN 已刷新）。⚠️ 顺带记一笔：本轮跑测试时 `cert_stateclobber_test.sh` / `cert_menu_test.sh` 会报「另一个 xray-nginx-deploy 实例正在运行」——那两套没盖 `STATE_DIR`，被**用户自己开着的 `bash <(fd)` 会话**（活机菜单就停在 DoH 那个提问上）持有的 `/etc/xray-deploy/install.lock` 挡住，属环境所致，不是回归。

  - **追加：候选列表要逐行标出「CDN / 直连」（2026-10-01，用户原话「在备用域名中 应该显示那些是cnd的 那些是直连」）**：上面那份列表只打域名，看不出哪个经 Cloudflare、哪个直连本机——而这**正是选落点的唯一依据**（CDN 域 `$final_real_ip` 拿得到真实客户端 IP，直连域只能看到客户端自己的地址，Reality 域连这个也退化）。改法最小：`_all` 的每一项由「域名」变成 **`域名|标签`**，标签按分桶取 `CDN` / `直连` / `直连 (Reality)`；`_doh_print_domain_list` 拆 `%%|*` 显示、`#*|` 取标签，并多打一行标签含义；**取域名时**（已启用分支的序号、未启用分支的序号，共两处）`${_all[..]%%|*}` 切回来 —— 序号、`${#_all[@]}` 越界判断、`_default` 全部不动。⚠️ **别把标签拼进 `_all` 之外的第三个数组**：显示顺序与 `_all` 的下标必须**同源**，一旦另建一份就又会分叉（这正是上一轮把候选收集上提到函数开头要消灭的东西）。**回退**：`git revert`（同一个单文件提交）。**验证**：`/tmp/mosdns_test.sh` 的 4e / 4c 断言改为带标签的形态并新增两条（Reality 域必须是 `[直连 (Reality)]`、必须有标签含义说明行），全绿 **101 项**；**反向自检**：同一套喂 `git archive HEAD` 的旧模块 → **5 项红**（全是标签相关，证明断言不是恒真）。`/tmp/doh_reconfig_test.sh` 28 项仍全绿；`bash -n` 全绿。

- **DoH 入口可以绑「已被别的协议占用的域名」（CDN 域 / Reality 域）（2026-09-30）**：用户原话 —— **「你没有明白,doh应该绑定cdn 的域名和hysteria2协议,不是固定那个域名.按照你的说法其他协议和域名都不能用,你到底有测试吗.还是猜的,这个机器是测试机,如果可能你可以每个协议都测试一下是否可以和doh共用一个域名」**。他说得对，我错了：此前我**没测就下结论**，说不开 CDN 的域才能做 DoH，理由是「一个 SNI 只能有一个后端」。**那个推理只对了一半** —— stream 的 `map $ssl_preread_server_name $backend` 确实是一 SNI 一后端，但**如果那个后端是 nginx 自己的 HTTP vhost，就能把 DoH 的 `location` 塞进那个 vhost**，域名照样共用。


  **改动**：`modules/nginx.sh` 拆出落点判定与正文两件东西 —— `_doh_domain_usable <域>`（能否共用）、`_doh_target_mode <域>`（`off` / `standalone` / `shared`）、`_doh_candidates`；location 正文**只写一份**到独立文件 `/etc/nginx/doh_location.conf`（⚠️ 不能写在 `conf.d/*.conf` 里 —— 那是 http 级 include，裸 `location` 块在那会语法错），两种落点各自 include 它：
    - **standalone**（域没被占）：仍生成 127.0.0.1:**8410** 的 vhost + SNI map 里加一条 `<域> 127.0.0.1:8410`（老行为，逐字节不变）；
    - **shared**（域已被占）：**不生成 8410**、SNI map 里**不加条目**（该域本来就有路由），改为在 `generate_servers_conf` 生成 vhost 时，给**`server_name` 正是落点域名**的那一份注入 `include /etc/nginx/doh_location.conf;`。注入点选在 `generate_servers_conf` 里而不是手改文件，是为了**扛重生成**（这正是当初 DoH 入口被挪进 `doh.conf` 的原因）。
  `doh.conf` 两种落点都生成（落点不同只影响注释与是否带 8410 server 块），**`limit_req_zone ... zone=doh` 的定义留在里面** —— 老机器的旧 `doh.conf` 里还带着那行，若新版只在 standalone 下写它，共用落点上就会出现「zone 无处定义」，而 `conf.d` 是 glob、`doh.conf`（d）排在 `servers.conf`（s）之前、`limit_req` 是 **parse 期按名查 zone** —— 顺序与共存都必须保住。`modules/mosdns.sh` 的候选问答同步放开（分 `_cdn` / `_plain` / `_reality` 三桶，默认取**第一个 CDN 域**，可输序号或域名，`0` = 不启用）；`modules/uninstall.sh` 两个文件一起删。




  **两条已知代价（要真实 IP 就别选 Reality 落点）**：落点若选 Reality 域（`reality` / `xhttp-reality`），请求是 xray 的 fallback 转给 nginx 的，**转过去时不带真实源地址**（reality inbound 是 `xver=0`、不发 PROXY protocol，8321/8326 的 `listen` 也没开 `proxy_protocol`）→ `$final_real_ip` 退化成 `127.0.0.1`：限流变成**一个桶装所有客户端**、access log 记不到真实 IP。当选这类落点时脚本会打 5 行 WARN 明说（实测确认，不是推断）。另一条：**CDN 落点只对「经 CF 进来」的请求生效**（见上条 `$redirect_to_fake`）—— 家里必须走 `https://<域><路径>` 经 CF，直连源站那条路会被伪装页接走。

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
