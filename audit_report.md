# 配置审查报告

> 审查时间：2026-06-10　主机：cctv (AlmaLinux, 4C/2G, eth0)
> 对比对象：仓库脚本（install.sh + modules/）预期逻辑　vs　系统实际运行配置
> 节点架构：单机 nginx:443 统一入口 + SNI 分流，后端 Xray / Sing-Box / Caddy-Naive 回环监听，Hysteria2 独立 UDP

---

## 总体结论

**当前所有服务均在运行，证书链完整，`nginx -t` 通过，反代链路逐跳验证一致——没有正在发生的服务中断（无 🔴 级在线故障）。**

主要问题集中在**「仓库脚本」与「线上实际」的来源不一致**：线上的防火墙、部分 nginx upstream 参数明显由更早版本的脚本（或手工）生成，与当前仓库脚本生成的结果存在差异。其中**防火墙差异是真正的隐患**——若现在用当前 `firewall.sh` 重新生成规则，会立即切断 HTTP(80) 和 Hysteria2 端口跳跃(UDP 32000-36000)。

---

## 🔴 严重问题（会导致服务不可用）

**无正在发生的在线故障。** 所有 8 个 systemd 单元均 active，监听端口齐全，证书有效，链路连通。

唯一接近「严重」的是下面这条**潜伏**问题（一旦触发就是 🔴，故单列）：

### S1 — 当前 firewall.sh 若重跑会切断 80 端口与 Hysteria2 端口跳跃
- **现状**：线上 `/etc/sysconfig/nftables.conf` 放行 `tcp dport {80,443}` 和 `udp dport {443, 32000-38000}`，服务正常。
- **脚本预期**：当前 `modules/firewall.sh:226-227` 只放行 `tcp dport 443` 和 `udp dport 443`，**既不放行 80，也不放行端口跳跃 UDP 段**。端口跳跃段需用户手工填入 `extra_udp`，脚本不会从 `HYSTERIA2_PH_START/END` 自动推导。
- **证据**：状态文件 `/etc/xray-deploy/config.env` 中**没有任何 `FIREWALL_*` 键**，说明当前版本 `firewall.sh` 从未在本机运行过；线上规则的 ICMP 限速(5/s 无 burst)、SSH 规则(简单 limit rate)格式也与当前脚本(10/s burst 20、meter+reject)不同，证实线上防火墙来自更早版本。
- **影响**：现在不影响运行；但任何人执行「防火墙配置」菜单后，HTTP→HTTPS 跳转 + Hysteria2 端口跳跃立即失效。
- **建议**：在 `firewall.sh` 中（a）补回 `tcp dport 80`；（b）读取 `HYSTERIA2_PH_START/END` 自动并入放行 UDP 段。

---

## 🟡 配置差异（脚本预期 vs 实际现状）

### Y1 — nginx xhttp upstream keepalive_timeout：线上 15s vs 脚本 300s　✅ 已同步（2026-06-10）
- **线上** `/etc/nginx/conf.d/00-upstreams.conf`：`vless_xhttp_backend` 中 `keepalive_timeout 15s`，注释为「keepalive 池已被 Connection:close 绕过，每次请求建新连接」。
- **脚本** `modules/nginx.sh:776`：生成的是 `keepalive_timeout 300s`，注释为「与 Xray hMaxReusableSecs 形成梯度」。
- **判断**：线上文件是**手工改过**（或更早版本生成），与当前仓库不一致。两种思路都自洽（因 `Connection: close` 确实使该 upstream 池形同虚设，15s/300s 实际都不影响），但**仓库与线上已脱钩**——重跑 nginx 配置会把它覆盖回 300s。
- **gRPC upstream**：线上与脚本均为 `keepalive_timeout 50s` ✓ 一致（最新提交 c927c0d 的 90s→50s 已落地）。
- **处置（2026-06-10）**：已用仓库生成版覆盖线上 `00-upstreams.conf`（15s→300s），`nginx -t` 通过、`systemctl reload nginx` 成功、服务 active。线上与仓库就此对齐。原文件已备份至 `/root/config-backup-20260610/` 及 `00-upstreams.conf.bak.*`。详见附录 B。

### Y2 — Hysteria2 端口跳跃范围：脚本默认 47000-48000 vs 实际 32000-36000
- **脚本默认** `hysteria2.sh:306-308`：起始 47000、结束 48000。
- **实际**（状态文件 + config.yaml `listen: :443,32000-36000`）：32000-36000。
- **判断**：这是**用户安装时交互输入**的值，覆盖了脚本默认，属正常；状态文件、hysteria 配置、hysteria 自建 NAT 表三者一致。**仅防火墙放行段(32000-38000)与之不符**（见 C1）。

### Y3 — Reality 默认参数：脚本注释值 vs 实际
- **实际**：`dest=www.mpg.de:443`、`serverNames` 含 mpg.de/trumpf/ethz/cuni 等 7 个、`spiderX=/`。
- **脚本**：`collect_reality_params` 为交互选择，提交 c927c0d 已把注释更新为当前正确值（dest=www.mpg.de:443, spiderX=/）。
- **判断**：一致，无差异。客户端侧 `client.sh` 的 spiderX 默认 `/api/health` 与实际 `/` 不同，但 Reality 的 spiderX 由服务端决定、客户端仅参考，不影响连通。

### Y4 — Xray 服务 User=nobody（官方单元，非脚本生成）
- **现象**：`journalctl -u xray` 每次启动告警 `Special user nobody configured, this is not safe!`。
- **来源**：`/etc/systemd/system/xray.service` 由 Xray 官方安装脚本生成（`User=nobody` + Ambient `CAP_NET_ADMIN/CAP_NET_BIND_SERVICE`）。仓库 `xray.sh` 不生成单元文件，仅 `systemctl enable --now`。
- **判断**：可运行，告警为 systemd 对 nobody 共享账户的提示。非本项目脚本问题。

---

## 🟠 潜在冲突（现在没问题但有风险）

### C1 — Hysteria2 端口跳跃存在「双重 NAT + 范围不一致」
线上同时存在两套 UDP→443 重定向：
| 来源 | 表名 | 范围 | 动作 |
|------|------|------|------|
| 部署脚本旧版 nftables.conf | `table ip/ip6 nat` | 32000-**38000** | dnat to :443 |
| Hysteria 二进制自建 | `table ip hysteria_73bb65fb` / `ip6 hysteria_d355f523` | 32000-**36000** | redirect to :443 |

- Hysteria v2.9.2 启动时会**自行创建** nft redirect 表（范围严格等于 config 的 32000-36000），这一套已足够。
- 旧 nftables.conf 里的 `nat` 表是冗余的，且上界 38000 比实际跳跃段 36000 宽 2000，属历史残留。
- **风险**：两套规则叠加、范围不一致，排障时易混淆；防火墙 `input` 链放行到 38000 而实际只用到 36000，多开了 36001-38000/udp。
- **建议**：移除旧 nftables.conf 的手工 `nat` 表，统一交给 Hysteria 自管理；防火墙放行段对齐为 32000-36000。
- **验证确认（2026-06-10，用户拍板）**：`nft list ruleset` 实机确认 hysteria 自建表 `ip hysteria_73bb65fb` / `ip6 hysteria_d355f523` 正在 prerouting+output 链做 `udp dport 32000-36000 redirect to :443`，**这是真正生效的端口跳跃机制**。`table ip/ip6 nat` 的 `dnat 32000-38000 → :443` 经确认为**旧版冗余残留**：与 hysteria 表同优先级共存、结果同为 :443，36001-38000 段 hysteria 根本不跳。**设计结论：端口跳跃归 hysteria 自建 redirect 表接管，NAT DNAT 表无功能价值**。本次按用户决定**不触碰线上 nftables 规则**（冗余 nat 表将在下次重跑 firewall 菜单时随 flush 自然清除）。

### C2 — Cockpit 管理控制台监听 9090（脚本预期外的服务）
- **现象**：`*:9090`（all-interfaces）由 `cockpit.socket` 监听，`enabled`。
- **脚本预期**：仓库脚本完全未涉及 cockpit，属系统自带/手工启用。
- **风险**：监听在所有接口；当前防火墙未放行 9090（仅 80/443/2200/udp443+跳跃段），所以**外部不可达**——目前安全。但若防火墙策略变更或 9090 被加入放行，会暴露管理面板。
- **建议**：确认是否需要 cockpit；不需要则 `systemctl disable --now cockpit.socket`。

### C3 — Sing-Box AnyTLS 持续 `unknown user password` 错误
- **现象**：sing-box 日志大量 `process connection from 127.0.0.1: unknown user password: fallback disabled`，源均为 127.0.0.1（经 nginx 8360→8330）。
- **判断**：这是**扫描器/探测**命中 SNI `lt.usa-al.cf` 后被 stream 正确分流到 sing-box，因无正确 AnyTLS 密码而被拒——属**预期防御行为**，不是配置错误。nginx error.log 对应的 `recv() failed (104)` 也是同一批连接被 sing-box 主动 RST 所致。
- **建议**：无需修复。若日志噪音大，可降低 sing-box 日志级别或在 nginx 层加 SNI 白名单（会削弱伪装，不推荐）。

### C4 — 证书续期 hook 存在重复/冗余
`/etc/letsencrypt/renewal-hooks/deploy/` 下有 4 个脚本：
- `xray-nginx-deploy-reload.sh`：reload nginx + restart xray + restart sing-box
- `reload-nginx.sh`：仅 reload nginx（**与上一个功能重叠的旧脚本**）
- `hysteria-cert.sh` / `naive-cert.sh`：复制证书到各自目录 + restart
- **风险**：任一域名续期时全部 hook 都会触发，`reload-nginx.sh` 与 `xray-nginx-deploy-reload.sh` 重复 reload nginx；hysteria/naive hook 不论哪个域名续期都会按配置域名复制证书（幂等，但会无谓 restart）。功能正确，仅有冗余。
- **建议**：删除遗留的 `reload-nginx.sh`。

---

## 🟢 优化建议（性能 / 安全 / 维护性）

1. **`http2_push_preload` 已废弃**：`nginx -t` 告警 `servers.conf:39 directive is obsolete`。仓库 `nginx.sh:995` 仍生成该指令，建议删除（仅告警，不影响功能）。
2. **线上配置与仓库已脱钩**：nginx upstream(Y1)、防火墙(S1) 均显示线上由更早版本生成。建议确定「以仓库为准」后，用当前脚本统一重生成一次（**注意先修复 S1 的 80 端口与端口跳跃放行，否则重生成防火墙会断网**）。
3. **证书目录权限**：`/etc/letsencrypt/{live,archive}` 为 `0700 root:root`，sing-box(User=sing-box) 靠单元里的 `CAP_DAC_READ_SEARCH` 读取证书，可行但依赖特权能力；hysteria/naive 则改为复制证书到自有目录(已 chown)。两种策略并存，属正常设计。
4. **WARP 出站凭证一致性**：Xray 与 Sing-Box 内嵌的 WireGuard 私钥/peer/endpoint 与状态文件 `WGCF_*` 完全一致 ✓，无分叉。
5. **DNS 链路统一**：unbound(127.0.0.1:53) ← resolv.conf、xray dns、hysteria resolver 全部指向本地递归 ✓，设计干净。

---

## 📋 端口使用清单

| 端口 | 协议 | 服务（实际监听） | 监听地址 | 脚本预期 | 实际状态 |
|------|------|------------------|----------|----------|----------|
| 80 | TCP | nginx (跳转/ACME) | 0.0.0.0 + :: | nginx 监听✓；**防火墙脚本未放行** | ✓监听，旧防火墙放行 |
| 443 | TCP | nginx (SNI stream 分流) | 0.0.0.0 + :: | ✓ | ✓ |
| 443 | UDP | hysteria (QUIC) | 0.0.0.0 | ✓ | ✓ |
| 2200 | TCP | sshd | 0.0.0.0 | SSH_PORTS=2200✓ | ✓ |
| 53 | TCP/UDP | unbound | 127.0.0.1, ::1 | ✓ | ✓ |
| 8300 | TCP | xray VLESS-xhttp | 127.0.0.1 | ✓ | ✓ |
| 8310 | TCP | xray VLESS-gRPC | 127.0.0.1 | ✓ | ✓ |
| 8320 | TCP | xray Reality | 127.0.0.1 | ✓ | ✓ |
| 8330 | TCP | sing-box AnyTLS | 127.0.0.1 | ✓ | ✓ |
| 8340 | TCP/UDP | caddy-naive | 127.0.0.1 | ✓ | ✓ |
| 8350 | TCP | nginx Reality fallback | 127.0.0.1 | ✓ | ✓ |
| 8360 | TCP | nginx 中间层→sing-box | 127.0.0.1 | ✓ | ✓ |
| 8370 | TCP | nginx 中间层→caddy-naive | 127.0.0.1 | ✓ | ✓ |
| 8380 | TCP | nginx xhttp CDN 入口 | 127.0.0.1 | ✓ | ✓ |
| 8390 | TCP | nginx gRPC CDN 入口 | 127.0.0.1 | ✓ | ✓ |
| 8400 | TCP | nginx SNI 陷阱伪装站 | 127.0.0.1 | ✓ | ✓ |
| 10660 | TCP | hysteria trafficStats | 127.0.0.1 | 随机10001-65534✓ | ✓ |
| 8080 | TCP | crowdsec LAPI | 127.0.0.1 | 隐含（crowdsec）✓ | ✓ |
| 6060 | TCP | crowdsec metrics/pprof | 127.0.0.1 | 隐含 | ✓ |
| 323 | UDP | chronyd | 127.0.0.1 | 系统自带 | ✓ |
| 32000-36000 | UDP | →NAT 443 (端口跳跃) | 0.0.0.0 | 脚本默认47000-48000，用户改32000-36000 | ✓ (hysteria 自建 NAT) |
| 32001-38000 | UDP | 旧 nat 表冗余放行 | — | ❌ 非当前脚本生成 | 🟠冗余(见C1) |
| **9090** | TCP | **cockpit.socket** | **\*** (all) | **❌ 脚本未涉及** | 🟠 监听但被防火墙挡住(见C2) |
| 41777 | UDP | sing-box WARP 出站 | eth0 | 临时端口(wireguard) | ✓ 正常 |
| 64505 | UDP | xray WARP 出站 | * | 临时端口(wireguard) | ✓ 正常 |

> 无端口被多个服务争抢；8300-8400 段回环端口与脚本硬编码完全一致。

---

## 📋 证书路径清单

| 服务 | 配置里引用的路径 | 实际是否存在 | 备注 |
|------|------------------|--------------|------|
| nginx CDN (lit/lt.roadtrip.gq) | `/etc/letsencrypt/live/roadtrip.gq/{fullchain,privkey}.pem` | ✅ 存在 (CN=roadtrip.gq, 至 2026-07-27) | 通配符 *.roadtrip.gq ✓ |
| sing-box AnyTLS (lt.usa-al.cf) | `/etc/letsencrypt/live/usa-al.cf/{fullchain,privkey}.pem` | ✅ 存在 (CN=usa-al.cf, 至 2026-07-27) | 直接引用 LE 目录，靠 CAP_DAC_READ_SEARCH 读取 |
| hysteria2 (lt.roadfog.tk) | `/etc/hysteria/{fullchain,privkey}.pem` | ✅ 存在 (CN=roadfog.tk, 至 2026-08-27) | 由 hysteria-cert.sh 从 live/roadfog.tk 复制，chown hysteria |
| caddy-naive (lt.roadfog.tk) | `/etc/caddy-naive/{fullchain,privkey}.pem` | ✅ 存在 (CN=roadfog.tk, 至 2026-08-27) | 由 naive-cert.sh 复制，chown caddy-naive |
| nginx SNI 陷阱站 (8400) | `/etc/nginx/certs/trap.{crt,key}` | ✅ 存在 (自签 EC P-256) | 与脚本 F5 修复一致 |

> 三套域名证书（roadtrip.gq / usa-al.cf / roadfog.tk）全部存在且未过期，所有服务引用路径与实际文件**完全一致**，无悬空引用。

---

## 📋 Nginx 反代链路

入口统一为 `nginx stream :443`，按 `$ssl_preread_server_name` 分流：

| SNI / Server Block | 中间跳转 | 最终 proxy_pass/grpc_pass | 后端实际监听 | 是否匹配 |
|--------------------|----------|---------------------------|--------------|----------|
| lu.usa-al.cf + 7个Reality serverNames | stream→127.0.0.1:8320 | (Reality 直连，fallback→8350) | xray :8320 ✓ / nginx fallback :8350 ✓ | ✅ |
| lit.roadtrip.gq (xhttp) | stream→:8380 | http://vless_xhttp_backend | xray :8300 ✓ | ✅ |
| lt.roadtrip.gq (gRPC) | stream→:8390 | grpc://vless_grpc_backend | xray :8310 ✓ | ✅ |
| lt.usa-al.cf (AnyTLS) | stream→:8360 (消费 proxy_protocol) | 127.0.0.1:8330 | sing-box :8330 ✓ | ✅ |
| lt.roadfog.tk (NaiveProxy) | stream→:8370 (消费 proxy_protocol) | 127.0.0.1:8340 | caddy-naive :8340 ✓ | ✅ |
| default (未知 SNI) | stream→:8400 | (SNI 陷阱伪装页，自签证书) | nginx :8400 ✓ | ✅ |
| Reality fallback xhttp/grpc | xray fallback→:8350 | vless_xhttp/grpc_backend | xray :8300/:8310 ✓ | ✅ |

- **upstream 定义**：`vless_xhttp_backend→127.0.0.1:8300`、`vless_grpc_backend→127.0.0.1:8310`，与 xray inbound 监听完全一致 ✓。
- **proxy_protocol 链**：stream :443 加 `proxy_protocol on` → 8380/8390 用 `ssl proxy_protocol`、8360/8370 中间层 `proxy_protocol` 消费、8350 fallback **不加** proxy_protocol（对齐 xray Reality `xver:0`）✓ —— 全链 proxy_protocol 头收发逻辑自洽。
- **路径一致性**：nginx location `/ff15552f7f124a6089e81dcfa73374f6` 与 xray `xhttpSettings.path`、状态文件 `XHTTP_PATH` 三者一致 ✓；gRPC `serviceName=grpc.Service` 一致 ✓。
- Hysteria2 不经 nginx，独立 UDP/443 + 端口跳跃，符合脚本设计 ✓。

**结论：6 条 SNI 分流 + Reality fallback 全部逐跳验证，proxy_pass 目标与后端实际监听 100% 匹配，无断链。**

---

# 附录 A — S1 修复深度分析（2026-06-10 追加）

## A.1 三问核实结论

**Q1 — `HYSTERIA2_PH_START/END` 来源**
- 定义：`hysteria2.sh:305-308` 交互输入（默认兜底 47000/48000），`:335-336` `save_state` 写入 `/etc/xray-deploy/config.env`；未启用时存空串（`:339-340`）。
- 实机值：`HYSTERIA2_PH_START='32000'` / `HYSTERIA2_PH_END='36000'`。
- **`firewall.sh` 全文从不读取这两个键**（唯一 `get_state` 在 `:117` 读 `SSH_PORTS`）。→ 让 firewall 读 state 放行是「新增能力」，非现有逻辑。

**Q2 — 重跑 firewall.sh 会否覆盖冗余旧 nat 表**
- `firewall.sh:204` 第一行 `flush ruleset` 清**整个** nftables（不分表）。
- 更关键：`nftables.service` 的 `ExecStop=/sbin/nft flush ruleset`，即 `systemctl restart nftables`（`firewall.sh:297`）**本身就会先 flush**。
- flush 后各表命运：

| 表 | 来源 | firewall 重建? | 自愈? |
|----|------|----------------|-------|
| `inet filter` | firewall 脚本 | ✅ | — |
| `ip/ip6 nat`（旧冗余 32000-38000） | 旧 `/etc/sysconfig/nftables.conf` | ❌ 当前脚本不生成 nat 表 | 永久消失（实为好事，解决半个 C1） |
| `ip/ip6 crowdsec*` | crowdsec-firewall-bouncer 进程 | ❌ | ✅ **每 10s 自愈**（`update_frequency: 10s`） |
| `ip/ip6 hysteria_*`（端口跳跃 redirect） | hysteria 进程启动时自建 | ❌ | ❌ **不重启 hysteria 不会回来** |

**Q3 — `http2_push_preload` 警告**
- 实机 `nginx -t` 退出码 **0**，`[warn]...obsolete...ignored` + `test is successful`。reload/restart 不受影响。纯噪音，不紧急。

## A.2 端口跳跃机制的真相（决定方案的核心发现）

- hysteria v2.9.2 **自建** nft redirect 表（随机表名 `hysteria_73bb65fb`，范围严格等于 config 的 32000-36000），在 **prerouting / dstnat 优先级 -100** 把跳跃段包改写为 443。
- input 链（filter 优先级 0）在 prerouting 之后执行：包到达 input 时 **dport 已是 443**，被现有 `udp dport 443 accept` 覆盖。
- **推论：在 input 链放行 32000-36000 是冗余的** ——
  - redirect 存在时：包已变 443，range 规则用不上；
  - redirect 不存在时：包停在原端口，但**没有任何进程监听** 32000-36000（`ss` 证实 hysteria 只 bind `*:443`），放行了也无人收。
- **因此用户请求的「item #3：firewall 自动放行 PH 段」对 hysteria 自管理的端口跳跃在功能上不起作用。** 让端口跳跃工作的是 redirect 表，不是 input 放行。正确修复 = 保证 redirect 表在 flush 后被重建（重启 hysteria），而非给 firewall 加放行。
- 跨重启已验证此模型成立：`nftables.service` ExecStart 只加载 filter 表（`/etc/sysconfig/nftables.conf` 不含 hysteria/crowdsec 表），每次重启后靠 hysteria/crowdsec 各自进程重新注入——系统本就这样存活。

## A.3 S1 修复方案 v2（✅ 已实施 — 80 放行 + 方案 A）

> 用户拍板：① 80 端口放行；② flush 策略选方案 A（接受 hysteria 重启几秒空窗）。
> 已修改 `modules/firewall.sh`（+24 −1），`bash -n` 通过；**未触碰线上 nftables 规则与 `/etc/sysconfig/nftables.conf`**，服务零中断。

### flush 策略：采用方案 A
- **关键约束**：`systemctl restart nftables` 自带 `ExecStop=nft flush ruleset`，即使删掉脚本里的 `flush ruleset` 仍会全表清空。
- **方案 A（已采用）**：保留 restart nftables，apply 后「端口跳跃启用且 hysteria active 时」`systemctl restart hysteria-server` 重建 redirect 表。
  - crowdsec 表 10s 自愈；hysteria 重启几秒空窗（发生在管理员主动改防火墙时刻，可接受）；旧冗余 nat 表顺带清除（修好半个 C1）。
  - 符合「端口跳跃归 hysteria 自管理」的系统既有设计。

### 改动清单（仅 modules/firewall.sh，共 4 处，已落地）
| # | 实际行 | 类型 | 内容 |
|---|------|------|------|
| 1 | `:240` | 改 | `tcp dport 443` → `tcp dport { 80, 443 }`（80 定位为跳转便民，非 ACME 必需；证书走 DNS-01） |
| 2 | `:157-170` | 新增函数 | `_firewall_build_porthopping_udp()` 读 state PH_START/END，三重校验后生成 `udp dport S-E accept` |
| 3 | `:244` | 新增调用 | `$(_firewall_build_porthopping_udp)` |
| 4 | `:315-322` | 新增 | 端口跳跃启用且 hysteria active 时 `systemctl restart hysteria-server`（方案 A 核心） |

### 重要诚实标注（保留）
- **改动 #2/#3（input 放行 PH 段）在当前 hysteria 自管理模式下不参与实际转发**：包经 redirect 改写为 443 后进 input，range 规则命中不到。保留它仅为防御性纵深（万一未来 hysteria 改用 DNAT 或不自建 nft 表）。不夸大为「修复了端口跳跃」。真正让端口跳跃在 firewall 重跑后存活的是改动 #4。
- **改动 #1（80 端口）**：证书是 Cloudflare DNS-01，不依赖 80；80 仅用于 HTTP→HTTPS 301 跳转便利。放行无害但非必需。

### 最终 diff
```diff
@@ _firewall_build_extra_udp 之后新增 @@
+# Hysteria2 端口跳跃 UDP 段放行（从状态文件读取范围）
+# 注意：当前 hysteria 自建 nft redirect 表（prerouting 阶段把跳跃段改写为 443），
+# 包进 input 链时 dport 已是 443，本规则命中不到，属防御性纵深——
+# 仅当未来 hysteria 改用 DNAT/不自建表时才参与转发。不可据此认为它「修复了端口跳跃」。
+_firewall_build_porthopping_udp() {
+    local start end
+    start=$(get_state "HYSTERIA2_PH_START" "")
+    end=$(get_state "HYSTERIA2_PH_END" "")
+    [[ -z "$start" || -z "$end" ]] && return 0
+    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || return 0
+    (( start >= 1 && end <= 65535 && start < end )) || return 0
+    echo "        udp dport ${start}-${end} accept"
+}

@@ input 链 @@
-        tcp dport 443 ct state new accept
+        tcp dport { 80, 443 } ct state new accept
         udp dport 443 accept
 $(_firewall_build_extra_tcp "$extra_tcp")
 $(_firewall_build_extra_udp "$extra_udp")
+$(_firewall_build_porthopping_udp)

@@ run_firewall_nftables，nft -f 之后 @@
+    # flush ruleset 会清掉 hysteria 启动时自建的端口跳跃 redirect 表，
+    # 端口跳跃启用时需重启 hysteria 让其重建（crowdsec 表靠 bouncer 每 10s 自愈，无需干预）
+    if [[ -n "$(get_state "HYSTERIA2_PH_START" "")" ]] \
+        && systemctl is-active --quiet hysteria-server 2>/dev/null; then
+        log_step "重启 hysteria-server 以重建端口跳跃 redirect 表..."
+        systemctl restart hysteria-server
+    fi
```

### 残留待办（本次未处理，供后续）
- 线上旧 `/etc/sysconfig/nftables.conf` 的冗余 nat 表（32000-38000）仍在运行中的 ruleset 内，仅在「下次重跑 firewall 菜单」时才会被 flush 清除；如需立即清理需手工操作（本次只改脚本，不碰线上）。
- C2（cockpit 9090）、C4（冗余 reload-nginx.sh hook）、🟢-1（http2_push_preload 废弃指令）均未处理。

---

# 附录 B — 配置对比 + 同步执行记录（2026-06-10 追加）

## B.1 方法
- 备份线上 7 份配置至 `/root/config-backup-20260610/`（nginx 3 份、xray、singbox、hysteria、nftables）。
- 搭建只读沙箱：源用仓库 `install.sh` 的辅助函数 + 各 module 生成函数，输出路径重定向至 `/tmp/config-new/`，`save_state` 重定向至沙箱状态副本；以 `/etc/xray-deploy/config.env` 为只读状态来源。**不写任何线上文件。**
- 逐文件 `diff -u`，JSON 用 `jq -S` 做语义比对。

## B.2 对比结论（仓库脚本预期 vs 线上现状）
| 文件 | 结论 | 处置 |
|------|------|------|
| `xray-config.json` | 语义完全相同（jq -S 通过） | 无需动作 |
| `singbox-config.json` | 语义相同，仅 JSON 排版（缩进/数组换行）不同 | 无需动作 |
| `hysteria-config.yaml` | 仅 `trafficStats.listen` 随机端口不同，余全同 | 无需动作 |
| `fallback.conf` / `servers.conf` | 仅 `proxy_pass` 空格对齐 + 注释措辞 | 无功能差异，可选 |
| `00-upstreams.conf` | xhttp `keepalive_timeout` 15s→300s（功能性） | ✅ 已同步（见 Y1 / B.3） |
| `nftables.conf` | 结构性巨大差异（线上非本仓库生成） | 见 C1 验证确认，按用户决定不动线上 |

## B.3 已执行的线上变更
- **`/etc/nginx/conf.d/00-upstreams.conf`**：覆盖为仓库生成版（xhttp upstream `keepalive_timeout 15s → 300s`）。`nginx -t` ✓ → `systemctl reload nginx` ✓ → `nginx` active。备份：`/root/config-backup-20260610/00-upstreams.conf` + 同目录 `.bak.<ts>`。

## B.4 诚实标注 — 一处非预期副作用
- 沙箱生成 hysteria 配置时调用了仓库 `configure_hysteria2`，该函数为**写配置 + 落地一体**：写完 yaml（已重定向到沙箱，线上 `config.yaml` 经 diff 确认**未改**）后，继续对线上执行了 `sysctl -w`（rmem/wmem=412500000、ip_forward=1，均与既有 brutal/端口跳跃参数一致，幂等且未落盘）、重拷证书（内容相同）、覆盖 `hysteria-cert.sh` 部署钩子（写成当前仓库版）、并 **stop+start `hysteria-server`**（19:22:40 一次短暂重启）。
- 事后核验：`config.yaml` 与备份逐字节一致；`hysteria-server` active、:443 正常。实际后果仅为一次几秒服务重启。**教训：`configure_*` 类函数非纯生成，含落地动作，沙箱模拟前须先静态确认函数边界。**

---

# 附录 C — cert.sh 代码审查 + 线上现状对比（2026-06-10 追加）

> 审查范围：`modules/cert.sh`（2615行）+ `/etc/cloudflare/` 所有文件 + `/etc/letsencrypt/renewal/*.conf`
> 目标：确认已发现的代码 Bug 是否在线上已触发，以及修复前后是否需要手动干预线上状态。

---

## C.1 域名证书现状表

| 协议变量 | 完整域名 | 根域 | 证书有效期 | renewal 使用的 ini | ini token（前8位） |
|---|---|---|---|---|---|
| XHTTP_DOMAIN | lit.roadtrip.gq | roadtrip.gq | ✅ 2026-07-27（46天） | cf_account_1.ini | cfut_Fv1… |
| GRPC_DOMAIN | lt.roadtrip.gq | roadtrip.gq | ✅ 2026-07-27（同上） | cf_account_1.ini | cfut_Fv1… |
| REALITY_DOMAIN | lu.usa-al.cf | usa-al.cf | ✅ 2026-07-27（46天） | cf_account_2.ini | cfat_1lI… |
| ANYTLS_DOMAIN | lt.usa-al.cf | usa-al.cf | ✅ 2026-07-27（同上） | cf_account_2.ini | cfat_1lI… |
| NAIVE_DOMAIN | lt.roadfog.tk | roadfog.tk | ✅ 2026-08-27（77天） | domain_roadfog_tk.ini | cfat_5mj… |
| HYSTERIA2_DOMAIN | lt.roadfog.tk | roadfog.tk | ✅ 同上 | domain_roadfog_tk.ini | cfat_5mj… |

**三套根域证书全部有效，续期凭证路径与实际文件一致，无断链。**

### ini 文件归属关系

| ini 文件 | token（前8位） | renewal conf 引用 | 对应同内容新格式文件 | 状态 |
|---|---|---|---|---|
| cf_account_1.ini | cfut_Fv1… | roadtrip.gq.conf ✅ | roadtrip_gq.ini（同token）| 旧格式命名，续期正常 |
| cf_account_2.ini | cfat_1lI… | usa-al.cf.conf ✅ | usa-al_cf.ini（同token）| 旧格式命名，续期正常 |
| domain_roadfog_tk.ini | cfat_5mj… | roadfog.tk.conf ✅ | roadfog.ini（同token）| 新格式命名，续期正常 |
| roadtrip_gq.ini | cfut_Fv1… | 无 | — | 废文件（内容同cf_account_1，renewal未引用）|
| usa-al_cf.ini | cfat_1lI… | 无 | — | 废文件（内容同cf_account_2，renewal未引用）|
| roadfog.ini | cfat_5mj… | 无 | — | 废文件（内容同domain_roadfog_tk，renewal未引用）|
| zhongning_cf.ini | cfut_HF2… | 无 | — | **孤立文件**，见 C.3 |

---

## C.2 Bug 线上影响分析

### Bug 1 — load_cert_request_status 永远加载空数组

**代码位置**：`cert.sh:1535`

问题根因：解析循环先把所有 `#` 开头的行 `continue` 跳过，导致同样以 `#` 开头的
section 标记（`# --- CERT_SUCCESS_ROOTS ---` 等）永远无法被下方的 `case` 匹配到，
四个状态数组每次 load 都是空的。对比 `load_domain_config`（第 781 行）写法正确：
`case` 检查在 `#` 跳过之前。

**线上实证**：`/etc/cloudflare/cert_request_status.conf` 当前仍是旧格式
（`declare -a CERT_SUCCESS_ROOTS=([0]="roadtrip.gq" [1]="usa-al.cf")`），
说明新版 `save_cert_request_status` 从未在本机成功写出新格式文件；
而 `load_cert_request_status` 对旧格式同样解析失败（旧格式无 section 标记，
变量行也因 `declare -a` 不符合简单 `KEY=VALUE` 格式而被跳过）。
实际结果：`FAILED_CF_ACCOUNTS` 永远为空，`setup_cf_accounts` 里
「只重配失败账号」的提示从未出现。

**实际影响**：纯交互体验退化，不影响证书申请、续期、服务运行。

**线上状态是否需要修正**：不需要。旧格式文件内容与实际证书状态吻合（两个域名
申请成功），无错误状态需纠正。修复代码后，下次执行任意证书操作时
`save_cert_request_status` 自然写出新格式，之后 `load` 即可正常读取。

---

### Bug 2 — get_domain_ini 静默回退到可能不存在的文件

**代码位置**：`cert.sh:684-687`

```
log_warn "未找到 ${f}，回退到 cf_account_1.ini"
echo "${CF_CONFIG_DIR}/cf_account_1.ini"   # 不检查该文件是否实际存在
```

**线上实证**：三个根域均有正确的 `domain_<root>.ini` 映射文件，
`get_domain_ini` 的主路径全部命中，回退分支从未被触发。

**潜在风险**：若未来迁移完成后删除旧 `cf_account_N.ini`，再对一个缺少
`domain_*.ini` 映射的域名调用 `get_domain_ini`，将静默传递不存在的路径给
certbot，报错定位困难。

**线上状态是否需要修正**：不需要，当前所有路径正常命中。

---

### Bug 3 — add_domain_and_cert 的 certbot 调用是残缺副本

**代码位置**：`cert.sh:2137-2158`

`add_domain_and_cert`（选项3"新增域名"）末尾的 certbot 调用是
`request_certificates`（第 1694-1754 行）的简化抄写版，缺少：
- 3 次重试逻辑
- 限流检测（`rate_limit_hint`）
- `CERT_*_ROOTS` / `FAILED_CF_ACCOUNTS` 状态跟踪

**实际影响**：通过选项3新增域名时，若证书申请失败，失败状态不被记录，
下次执行 `setup_cf_accounts` 不会提示重配该账号。当前未有通过选项3添加
失败的未跟踪域名，线上状态无遗留错误。

---

## C.3 孤立文件 zhongning_cf.ini

| 属性 | 值 |
|---|---|
| 路径 | /etc/cloudflare/zhongning_cf.ini |
| token 前缀 | cfut_HF2… |
| 与其他 ini token 重复 | 否（唯一 token）|
| 对应 renewal conf | 无 |
| 对应 domain_*.ini | 无 |
| 对应 DOMAIN_REGISTRY 中的域名 | 无 |
| 对应线上证书 | 无 |

结论：该文件持有一个独立的 Cloudflare API Token，在当前部署中没有任何证书、
续期配置或域名与之关联。极可能是早期测试或已废弃域名（zhongning.cf 系列）
遗留的账号凭证。建议确认该域名/账号是否废弃后手动删除，本次审查不自动删除。

---

## C.4 修复方案建议

### 优先级

| 优先级 | 问题 | 线上影响 | 修复复杂度 |
|---|---|---|---|
| P1 | Bug 1：load_cert_request_status section 解析失效 | 低（仅丢失失败账号提示）| 低（3行调整）|
| P2 | Bug 2：get_domain_ini 静默回退 | 无（当前未触发）| 低（加文件存在检查）|
| P3 | Bug 3：add_domain_and_cert certbot 调用是残缺副本 | 中（无重试/无限流检测/不记录状态）| 中（提取公共函数）|
| P4 | 废文件清理（roadtrip_gq / usa-al_cf / roadfog .ini）| 无 | 低（手动 rm）|
| P5 | 孤立凭证 zhongning_cf.ini | 无 | 需用户确认后删除 |

### P1 修复内容

将 `#` 注释跳过移到 `case` 语句之后，与 `load_domain_config` 写法对齐：

```diff
 while IFS= read -r _line || [[ -n "$_line" ]]; do
     [[ -z "$_line" ]] && continue
-    [[ "$_line" == "#"* ]] && continue

     case "$_line" in
         "# --- CERT_SUCCESS_ROOTS ---")  _section="SUCCESS"; continue ;;
         "# --- END CERT_SUCCESS_ROOTS ---")  _section=""; continue ;;
         "# --- CERT_EXISTING_ROOTS ---")  _section="EXISTING"; continue ;;
         "# --- END CERT_EXISTING_ROOTS ---")  _section=""; continue ;;
         "# --- CERT_FAILED_ROOTS ---")  _section="FAILED"; continue ;;
         "# --- END CERT_FAILED_ROOTS ---")  _section=""; continue ;;
         "# --- FAILED_CF_ACCOUNTS ---")  _section="CF"; continue ;;
         "# --- END FAILED_CF_ACCOUNTS ---")  _section=""; continue ;;
     esac

+    [[ "$_line" == "#"* ]] && continue
```

修复后无需手动修改线上状态文件，下次执行证书操作时自然覆写为新格式。

### P2 修复内容

```diff
     log_warn "未找到 ${f}，回退到 cf_account_1.ini"
-    echo "${CF_CONFIG_DIR}/cf_account_1.ini"
+    local fallback="${CF_CONFIG_DIR}/cf_account_1.ini"
+    if [[ ! -f "$fallback" ]]; then
+        log_error "回退文件也不存在: ${fallback}，请先配置 CF 账号"
+        return 1
+    fi
+    echo "$fallback"
```

### P3 修复内容

`add_domain_and_cert` 末尾的 certbot 循环（第 2122-2159 行）替换为复用
`request_certificates`，只需临时将 `ALL_DOMAINS` 设为新增根域列表后调用：

```bash
local _saved_all=("${ALL_DOMAINS[@]}")
ALL_DOMAINS=()
local _seen_roots=()
for domain in "${new_domains[@]}"; do
    local root_domain
    root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    [[ " ${_seen_roots[*]} " != *" ${root_domain} "* ]] && ALL_DOMAINS+=("$root_domain") && _seen_roots+=("$root_domain")
done
request_certificates
ALL_DOMAINS=("${_saved_all[@]}")
```

### P4/P5 线上手动清理（用户确认后执行）

```bash
# P4：废文件（token 与 cf_account_N 完全相同，renewal conf 未引用）
rm /etc/cloudflare/roadtrip_gq.ini
rm /etc/cloudflare/usa-al_cf.ini
rm /etc/cloudflare/roadfog.ini

# P5：孤立凭证（需先确认 zhongning.cf 相关域名已废弃）
rm /etc/cloudflare/zhongning_cf.ini
```

### 线上不需要手动干预的理由

1. 三张证书全部有效，renewal conf 引用的 ini 文件全部存在且 token 正确
2. Bug 1 状态文件内容与实际证书状态吻合，修复代码后自然覆写，无错误状态需纠正
3. Bug 2 回退路径从未触发，当前所有根域均有正确的 ini 映射
4. Bug 3 残缺 certbot 调用仅在「选项3新增域名」场景触发，当前未有未跟踪的失败域名
