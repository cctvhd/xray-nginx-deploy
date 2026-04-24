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
