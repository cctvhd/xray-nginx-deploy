# CLAUDE.md

## 测试与工作约定

- **本机就是测试机**：所有验证一律在活机真实源码、真实服务上进行。**禁止沙箱**（`unshare` 隔离、`/tmp` 补丁副本）、**禁止打桩**（mock/stub 级联函数）。沙箱全绿不算通过依据——历史教训：沙箱 101/101 全绿，活机却漏出「回填污染」缺陷。
- **测试目标是脚本本身**：活机发现问题 → 修脚本 → 提交脚本。UUID、密钥、密码、令牌等运行时生成物可随时重置，不需要保护、不需要备份（仅在需要对照前后差异时才临时备份到 `/tmp`）。
- **测试脚本放 `/tmp`**；restart 后用**轮询端口监听**代替固定 `sleep`（最多 15 秒）。
- **不做 git 操作**（add/commit/push），除非我明确点头。只读 git（`git show`/`git diff`）可用。

## 仓库边界

**禁止提交到仓库**：本机真实域名、服务器 IP、`config.txt`、`.config.tsv`、`/etc/xray-deploy` 下的 state、`server-audit/` 目录、任何运行时生成的订阅和链接文件。仓库里只放**与协议逻辑相关的脚本和通用资源**。修改脚本时，示例和默认值里**不得写入本机真实域名**。

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

## 决策记录

- **gRPC 不迁移 XHTTP（F7，已关闭，不再提）**：gRPC-CDN 通道维持现状，不迁移到 XHTTP stream-up H2。xray 启动日志里的「gRPC deprecated」告警忽略即可。

## 关键架构约定

### 配置表 = 域名的唯一来源

`/etc/xray-deploy/.config.tsv`（`edit_nodes.py` 编辑）是域名分配的**唯一事实来源**：第 3 行 = `xhttp-reality`、第 4 行 = `vless-reality`（Reality 两槽），第 6 行 = Hysteria2。**填域 = 该槽用自有域自建；留空 = 借公共大站 SNI**。state（`/etc/xray-deploy/config.env`）由表派生。

### Reality SNI 来源解耦

`REALITY_SNI_MODE` / `XHTTP_REALITY_SNI_MODE` ∈ `self` / `public`。自建模式 `reality-direct` 的 dest = 本地伪装站 **8321 / 8326**；公共模式生成 `dokodemo-reality` 回落到公共站 **4431 / 4432**。切换走 `apply_reality_sni_switch <slot> <域|""> [self|public]`（事务化：快照 → 切 → 产物断言 → 失败回滚）。切换时 **xray / nginx / state / 配置表四层必须同步**。关键函数：`apply_reality_sni_switch`（自建/公共三态分支）、`_reality_reset_public_params`、`sync_hydrate_client_state`（self 模式不回填 `REALITY_SNI`/`SERVER_NAMES`/`DEST`）。**配置表与 state 分叉时表永远赢**——改 state 的清理操作要同时写表。

### 两条独立更新通道（分发陷阱）

install.sh（启动时读一次）与 modules（`load_module` 按 `/etc/xray-deploy/modules/` 缓存 → 仓库 `modules/` → `${BASE_URL}` 远端下载）各自更新。**模块不能依赖 install.sh 里后加的函数**（要用什么就自己提供，或只依赖 `log_*`/`get_state`/`save_state`）。改模块**必须 commit + push 到 `BASE_URL` 分支**，否则 `bash <(curl ...)` 模式其它机器拉到旧模块。**CDN（raw.githubusercontent.com）逐文件独立缓存，只有 `cmp` 逐字节比对是判据**（`x-cache: HIT` 不可信）。

### bash 关键坑

- 模块被 `source` 进 `load_module` **函数体** → 文件作用域的 `declare`/`declare -A` 变局部变量、函数返回即丢；跨函数共享只能用 `declare -g` 或直接赋值。
- 动态作用域：被调方裸 `for domain in ...` 会改掉调用方同名 `local`；复用循环变量（`domain`/`dir`/`i`）必须 `local`。
- 用 **stdout 回传值**的函数（如 `resolve_edit_nodes_script`）里不能直接调 `log_*`（全是裸 `echo`），否则警告被调用方一起捕获成多行「路径」。

### 当前组件状态

- **Hysteria2 伪装四选一**（`modules/hysteria2.sh`）：`1 不使用 / 2 ECH / 3 salamander / 4 gecko`；ECH 与 obfs 互斥。选 ECH 写 `ech: keyPath: /etc/hysteria/ech.pem`（已存在则复用、绝不轮换），客户端链接注入 `&ech=`（只取 `ECH CONFIGS` 块、裸 base64）。菜单 13 的所有交互 `read` 走 `_read_hysteria2`（EOF → `exit 1` 干净中止，不静默回退默认值并重启）。
- **DoH 入口 = 主菜单 `y`**（`modules/mosdns.sh`）：装 mosdns-x + 配入口域名/路径。入口 `doh.conf`/`doh_location.conf` 可绑 CDN/Reality 域（shared 落点注入 `servers.conf` 对应 vhost）；nginx `limit_req` 限流 key 必须 `$final_real_ip` 且 `limit_req_log_level notice`（否则限流拒绝喂 CrowdSec 自封 24h）。
- **PT 域屏蔽三处同源**（`xray.sh`/`singbox.sh`/`hysteria2.sh` 各一套语法，改要一起改）：5 个 PT 域做域级拒绝、放在 cn 分流规则之前；语义是「断开」不是改道。

### 客户端订阅

`modules/client.sh` 从 state 读各协议参数生成链接。改协议配置后订阅自动跟着变，但**服务端能力变化（撤 ECH、改 Reality 落点）必须重新下发订阅**——客户端侧不降级。

## 媒体/伪装站资产策略（assets/）
- 伪装站主题模板在 `assets/`（eu 档案馆 / na-cia / na-la），`download-media.sh` 用 yt-dlp 拉媒体。
- **mp4/mp3 等大媒体不入 git**，部署时在对应 webroot 目录链接或重命名短名称文件。

## 严格禁止事项（绝对铁律）
- **永远不要** `git add`、`git commit`、`git push` `server-audit/` 目录下的任何文件
- `server-audit/` 包含服务器敏感审计数据，必须始终保持在 `.gitignore` 中
- 执行任何 git 操作前，先确认 `server-audit/` 不在暂存区
