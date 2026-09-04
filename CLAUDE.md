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

**回退通用步骤**：某次变更出问题 → `git revert <sha>`，再重跑 `install.sh` 对应组件菜单（unbound 用菜单 2「重新配置」或 4「仅刷新域名配置」）即重新生成配置。unbound 活机改动前的配置文件已备份在 `/etc/unbound/unbound.conf.bk.*`（活机本机，不进 git）。活机真实域名/IP/服务快照等敏感运维事实见自动记忆 `live-unbound-2026-09`。

## 媒体/伪装站资产策略（assets/）
- 伪装站主题模板在 `assets/`（eu 档案馆 / na-cia / na-la），`download-media.sh` 用 yt-dlp 拉媒体。
- **mp4/mp3 等大媒体不入 git**，部署时在对应 webroot 目录链接或重命名短名称文件。

## 严格禁止事项（绝对铁律）
- **永远不要** `git add`、`git commit`、`git push` `server-audit/` 目录下的任何文件
- `server-audit/` 包含服务器敏感审计数据，必须始终保持在 `.gitignore` 中
- 执行任何 git 操作前，先确认 `server-audit/` 不在暂存区
