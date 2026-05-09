# 修改清单 — codex/proxy-kernel-service-tuning 分支

## 第一批：安全与正确性修复

### F1 — fallback.conf 移除 proxy_protocol（xver 对齐）
- **文件**: `modules/nginx.sh` 行 775
- **改动**: `listen 127.0.0.1:10080 proxy_protocol;` → `listen 127.0.0.1:10080;`
- **原因**: Xray Reality fallback 实际配置为 `xver: 0`，不发送 PROXY protocol header。Nginx 加了 proxy_protocol 会把首个 HTTP 请求当作 PROXY header 解析，导致所有 fallback 请求 400 Bad Request。

### F2 — fallback.conf 真实 IP 来源修正
- **文件**: `modules/nginx.sh` 行 794-795
- **改动**: `proxy_set_header X-Real-IP $remote_addr` → `$final_real_ip`；`X-Forwarded-For` 同理
- **原因**: xver=0 时无 proxy_protocol，`$remote_addr` 始终是 127.0.0.1。改用 `$final_real_ip`（经 cloudflare_real_ip.conf 的 geo+map 链推导）获取真实客户端 IP。

### F3 — common.conf 清理过时/危险全局头
- **文件**: `modules/nginx.sh` 行 427-433
- **改动**:
  - 删除 `add_header X-XSS-Protection "1; mode=block"`（已被浏览器弃用，非标准行为）
  - 删除全局 CSP（干扰代理流式传输，移至各伪装页 location 内单独添加）
  - 删除全局 CORS（`Access-Control-Allow-Origin *` 污染伪装页响应，移至 xhttp location 内单独添加）
- **原因**: CSP 全局设置会阻断 xhttp/gRPC 流式数据；CORS 全局设置会让伪装页也返回 `Allow-Origin: *`，暴露代理特征。

### F4 — xhttp location Cache-Control 方向修正
- **文件**: `modules/nginx.sh` 行 912
- **改动**: `proxy_set_header Cache-Control "no-cache, no-store, private"` → `add_header Cache-Control "no-store, no-cache, must-revalidate" always;`
- **原因**: `proxy_set_header` 是发给上游 Xray 的请求头，对 CDN 缓存控制无效。应使用 `add_header` 设置响应头，`no-store` 排最前确保 CDN 不缓存代理流量。

### F5 — trap 证书 RSA→ECDSA
- **文件**: `modules/nginx.sh` 行 125
- **改动**: `openssl req -x509 -newkey rsa:2048` → `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1`
- **原因**: RSA 2048 密钥体积大、握手慢，ECDSA P-256 更符合现代 TLS 实践，且与上游 acme 证书算法一致。

### F6 — xray.sh xver 值修正
- **文件**: `modules/xray.sh` 行 458
- **改动**: `"xver": 2` → `"xver": 0`
- **原因**: 服务器实际运行配置 (server-audit/xray/config.json) 使用 `xver: 0`。仓库生成的配置写了 `xver: 2`，与 nginx fallback 不加 proxy_protocol 矛盾，导致连接解析失败。

## 第二批：超时与补全

### D1 — 全局超时收紧 + 代理 location 显式覆盖
- **文件**: `modules/nginx.sh` 行 589, 595
- **改动**:
  - `client_body_timeout 7200s` → `60s`
  - `send_timeout 7200s` → `60s`
  - xhttp location (行 936-937)、gRPC location (行 1060-1061) 显式覆盖回 `7200s`
- **原因**: 全局 7200s 超时对非代理 location（伪装页、health）是慢速攻击向量。收紧到 60s 防御，代理 location 单独覆盖长超时保证隧道存活。

### A4 — fallback.conf gRPC location 补全缺失配置
- **文件**: `modules/nginx.sh` 行 821-824
- **改动**: 补加 `grpc_socket_keepalive on;`、`client_max_body_size 0;`、`client_body_timeout 7200s;`、`send_timeout 7200s;`
- **原因**: fallback 的 gRPC location 缺少这些参数，与 servers.conf 中的同名 location 不一致。缺少 `client_max_body_size 0` 会导致大 gRPC 帧被拒绝；缺少超时覆盖会继承全局 60s 导致 gRPC 流中断。

### E1 — sysctl 补加 tcp_fastopen
- **文件**: `modules/system.sh` 行 361
- **改动**: 补加 `net.ipv4.tcp_fastopen = 3`
- **原因**: 值 3 同时启用客户端和服务端 TFO，减少 TCP 握手延迟。Nginx stream 已配置 `fastopen=256`，内核侧也需开启。

### E2 — sysctl 补加 tcp_tw_reuse
- **文件**: `modules/system.sh` 行 362
- **改动**: 补加 `net.ipv4.tcp_tw_reuse = 2`
- **原因**: 值 2 仅在客户端角色复用 TIME_WAIT，服务端安全不受影响。代理出站连接受限于 ephemeral port 池，复用可缓解高并发时端口耗尽。

## 第三批：低优先级优化

### TLS 1.3 套件顺序调整
- **文件**: `modules/nginx.sh` 行 412
- **改动**: `TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256` → `TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256`
- **原因**: CHACHA20 提前到第二位，对不支持 AES-NI 的移动设备（ARM）更友好，减少 CPU 开销。

### ssl_ecdh_curve 写法统一
- **文件**: `modules/nginx.sh` 行 415
- **改动**: `ssl_ecdh_curve X25519:prime256v1;` → `ssl_conf_command Curves X25519:P-256:P-384;`
- **原因**: `ssl_conf_command Curves` 是 OpenSSL 1.1.1+ 推荐方式，优先级高于 `ssl_ecdh_curve`，且显式包含 P-384 提升兼容性。

### ssl_session_cache 缩小
- **文件**: `modules/nginx.sh` 行 416
- **改动**: `shared:SSL:50m` → `shared:SSL:10m`
- **原因**: 50m 可缓存约 20 万条 session，对代理节点远超需求。10m（约 4 万条）足够，节省共享内存。

### 20880 trap server 补短超时
- **文件**: `modules/nginx.sh` 行 1148-1150
- **改动**: 补加 `client_header_timeout 10s;`、`send_timeout 10s;`、`keepalive_timeout 10s;`
- **原因**: trap server 仅用于消耗扫描器流量，不需要长连接。短超时快速释放资源，防止被慢速连接耗尽。

### open_file_cache small 缩小
- **文件**: `modules/nginx.sh` 行 450
- **改动**: `NGINX_OPEN_FILE_CACHE_MAX=20000` → `2000`
- **原因**: small profile（1C/<2G）节点缓存 2 万条 file entry 占用过多内存，2000 条足够伪装页和静态资源使用。

### limit_req_zone 清理
- **文件**: `modules/nginx.sh` 行 629
- **改动**:
  - `zone=websocket:20m rate=2000r/s` → `rate=200r/s`
  - 删除 `zone=api:20m rate=3000r/s` 行
- **原因**: 2000r/s 对代理场景过高，几乎无防护效果；api zone 未被任何 location 引用，是无用配置。

### max_fails 语义统一
- **文件**: `modules/nginx.sh` 行 739, 748
- **改动**: `max_fails=3` → `max_fails=0`
- **原因**: upstream 后端均为本地回环（127.0.0.1），后端故障时尝试 failover 无意义。`max_fails=0` 禁用健康检查，避免本地临时抖动触发误判。

### gRPC 参数同步服务器实际值
- **文件**: `modules/nginx.sh` 行 816-819, 1051-1057
- **改动**:
  - `grpc_send_timeout / grpc_read_timeout 7200s` → `300s`（fallback.conf + servers.conf）
  - `grpc_buffer_size 4k` → `64k`（fallback.conf + servers.conf）
- **原因**: 7200s 超时对 gRPC unary call 过长，300s 足够覆盖长流；grpc_buffer_size 4k 偏小导致大 gRPC 帧被截断，64k 是推荐默认值。

### 全局安全头下移至 location 级别
- **文件**: `modules/nginx.sh` 行 827-843, 914-920, 946-951, 961-980, 1063-1106
- **改动**: 各 location 内显式添加 `Strict-Transport-Security`、`X-Content-Type-Options`、`X-Frame-Options`、`Referrer-Policy`、`Permissions-Policy`；伪装页 location 添加 CSP；xhttp location 添加 CORS
- **原因**: Nginx `add_header` 在 location 内会覆盖上层继承，全局设置后 location 级无法追加不同值。逐 location 显式设置确保每个响应头正确生效。
