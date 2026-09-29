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
| `nginx.sh` | Nginx 安装 + 全套配置生成（SNI map/servers/伪装 webroot/CF real-ip/8321 dest） |
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

**回退通用步骤**：某次变更出问题 → `git revert <sha>`，再重跑 `install.sh` 对应组件菜单（unbound 用菜单 2「重新配置」或 4「仅刷新域名配置」）即重新生成配置。unbound 活机改动前的配置文件已备份在 `/etc/unbound/unbound.conf.bk.*`（活机本机，不进 git）。活机真实域名/IP/服务快照等敏感运维事实见自动记忆 `live-unbound-2026-09`。

## 媒体/伪装站资产策略（assets/）
- 伪装站主题模板在 `assets/`（eu 档案馆 / na-cia / na-la），`download-media.sh` 用 yt-dlp 拉媒体。
- **mp4/mp3 等大媒体不入 git**，部署时在对应 webroot 目录链接或重命名短名称文件。

## 严格禁止事项（绝对铁律）
- **永远不要** `git add`、`git commit`、`git push` `server-audit/` 目录下的任何文件
- `server-audit/` 包含服务器敏感审计数据，必须始终保持在 `.gitignore` 中
- 执行任何 git 操作前，先确认 `server-audit/` 不在暂存区
