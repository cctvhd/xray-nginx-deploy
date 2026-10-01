# xray-nginx-deploy

一键部署 Xray + Nginx + Sing-Box 的自动化脚本

## 支持系统
- Ubuntu 20.04 / 22.04 / 24.04
- Debian 10 / 11 / 12
- CentOS / RHEL / Rocky / AlmaLinux 8 / 9

## 支持协议
- VLESS + Reality 直连
- VLESS + gRPC + CDN (Cloudflare)
- VLESS + XHTTP + CDN (Cloudflare)
- Sing-Box AnyTLS
- Cloudflare WARP 本地代理 (127.0.0.1:40000)

## 使用方法
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cctvhd/xray-nginx-deploy/main/install.sh)
```

## 功能模块
- 自动识别系统和内核版本
- 自动优化系统参数 (BBR/BBRv3)
- 自动申请 Cloudflare SSL 证书
- 自动生成 Nginx 配置
- 自动生成 Xray 配置
- 自动生成 Sing-Box AnyTLS 配置
- 自动安装/配置 Cloudflare WARP (Proxy 模式)
- 自动生成客户端连接链接

## WARP 说明
- 脚本支持在 Linux 上安装 Cloudflare WARP，并切换到 Proxy 模式。
- 当前默认代理地址为 `127.0.0.1:40000`，与你的 Xray / Sing-Box 出站配置保持一致。
- 若使用 Cloudflare One，本地代理模式依赖设备配置文件开启 `Local proxy mode`，并要求 `MASQUE` 隧道协议。

## 已知问题（未修）

以下两条是**已知、未修**的缺陷。遇到对应现象时不必再排查——都定性了，且都不影响生成的配置本身。

### 1. 借公共 SNI 的 Reality 槽：每轮重配都要重选一次「借用站点」

- **现象**：进「配置 Xray」时，即便上一次已经选过借用站点，仍会再问一遍地区和目标，
  日志里带一句「原公共参数已被自建模式的客户端链接同步覆盖，无法复用」。
- **根因**：state 里的 `REALITY_DEST` 被 `modules/sync.sh` 的
  `sync_hydrate_client_state()` 按活机 `config.json` 的 `realitySettings.dest`
  回填（`emit("REALITY_DEST", rs.get("dest"))`），而那个字段**两种模式下都是回环
  地址**——借公共模式下是 dokodemo 自己的监听地址 `127.0.0.1:4431`（vless）/
  `127.0.0.1:4432`（xhttp），自建模式下是本地伪装站 `127.0.0.1:8321`。它从来就不
  表示「借用的站点」，所以复用时永远判为不可用。
- **影响**：只影响交互（多问一次）。**产物正确性不受影响**：生成端自 `adf77f2`
  起不再信任该键的回环值，会回落到 `serverNames[0]:443`（客户端真正会发的 SNI）。
- **修法（未做）**：`sync_hydrate_client_state` 里跳过 `127.0.0.1:*` 的 dest 再 emit。

### 2. 改完 Sing-Box 配置后，服务仍在跑旧配置

- **现象**：`/etc/sing-box/config.json` 的 mtime 已更新，但
  `systemctl show sing-box -p ActiveEnterTimestamp` 停在上一次启动的时间点。
- **根因**：`modules/singbox.sh` 的 `start_singbox()` 用的是
  `systemctl enable --now sing-box`——对**已经运行**的 unit，`--now` 是空操作
  （只做 enable，不重启）。
- **影响**：「配置 Sing-Box」后新配置不生效，必须手工 `systemctl restart sing-box`。
  xray（`enable` + `restart`）与 hysteria2（`restart`）不受影响。
- **修法（未做）**：与 xray / hysteria2 一致，改成 `systemctl enable sing-box` +
  `systemctl restart sing-box`。

### 3. 其他（仅日志/外观，无功能影响）

- `reality_untag_self_domain()` 收尾恒定打「`<tag>` 节点已切换为公共 SNI 模式（自建
  域名已摘除）」，但该函数在「换自有域自建」路径上同样会被调用，此时真实结果仍是
  自建——紧随其后由 `apply_reality_sni_switch` 打的模式感知文案才是准的。
- 历史实验域会留下无主的 `DOMAIN_PROTO_<域>` / `DOMAIN_MODE_<域>` 空态键（域本身已
  不在 `DOMAIN_REGISTRY`）。它们不产生任何 nginx 路由或 server 块，只是 state 里的
  陈旧键。
