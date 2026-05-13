# server-audit 脚本分析报告

## 脚本间依赖关系
---

## 1. install.sh — Hi Hysteria 引导安装器

**用途**：交互式引导脚本，让用户选择 Hysteria 版本（v1 或 v2），然后从 GitHub 下载对应的 hihy 管理脚本并执行。

**参数**：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| HIHY_BIN_LINK | 环境变量（可选） | /usr/bin/hihy | hihy 脚本存放路径 |
| HIHY_HYSTERIA2_URL | 环境变量（可选） | GitHub raw URL | Hysteria2 下载 URL |
| HIHY_HYSTERIA1_URL | 环境变量（可选） | GitHub raw URL | Hysteria1 下载 URL |
| $1 | 交互输入（必填） | 无 | 版本选择：1=hysteria2，2=hysteria1 |

**主要逻辑流程**：
1. 交互提示用户选择 Hysteria 版本
2. resolveHysteriaVersion() 将用户输入映射为 hysteria2/hysteria1，空输入默认 hysteria2
3. downloadHihyScript() 下载脚本：优先 wget，其次 curl（原子写入：先写临时文件再 mv）
4. 赋予执行权限并运行下载的 hihy 脚本
5. BASH_SOURCE[0] 判断确保 source 时不执行 main

---

## 2. hy2.sh — Hi Hysteria 主管理脚本（~3871 行）

**用途**：Hysteria2 全生命周期管理工具，包括安装、配置、卸载、更新、服务管理、流量统计、客户端配置生成等完整功能。

**参数**：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| HIHY_ROOT_DIR | 环境变量（可选） | /etc/hihy | hihy 根目录 |
| HIHY_BIN_LINK | 环境变量（可选） | /usr/bin/hihy | hihy 命令路径 |
| HIHY_YQ_BIN | 环境变量（可选） | /usr/bin/yq | yq 二进制路径 |
| HIHY_PID_FILE | 环境变量（可选） | /var/run/hihy.pid | PID 文件 |
| HIHY_RC_LOCAL | 环境变量（可选） | /etc/rc.local | rc.local 路径 |
| HIHY_REMOTE_SCRIPT_URL | 环境变量（可选） | GitHub URL | 远程 hihy 脚本 URL |
| HIHY_REMOTE_SCRIPT_MIRROR_URL | 环境变量（可选） | jsDelivr CDN | 镜像下载 URL |
| HIHY_VERSION_CHECK_TTL | 环境变量（可选） | 21600（6小时） | 版本检查缓存 TTL（秒） |
| HIHY_REMOTE_CONNECT_TIMEOUT | 环境变量（可选） | 2 | 远程请求连接超时（秒） |
| HIHY_REMOTE_MAX_TIME | 环境变量（可选） | 5 | 远程请求最大时间（秒） |
| $1 | 命令行（可选） | 无 | install/uninstall/start/stop/restart/checkStatus/updateHysteriaCore/generate_client_config/changeServerConfig/changeIp64/hihyUpdate/aclControl/getHysteriaTrafic/checkLogs/addSocks5Outbound/cronTask |

**主要逻辑流程**：

- 核心工具函数层（1-400行）：downloadToFile、echoColor、getArchitecture、generate_uuid
- 版本检查层（87-273行）：TTL+锁保护的后台异步版本检查
- 安装状态管理层（680-780行）：not-installed / partially-installed / installed 三态管理
- 依赖安装层（423-565行）：检测包管理器，安装缺失依赖，下载 yq
- 安装流程 install()（2062-2268行）：下载核心二进制 → 13步交互式配置
- 交互式配置 setHysteriaConfig()（857-1897行）：证书/端口/拥塞控制/认证/混淆/伪装等
- 服务管理：Alpine 用 OpenRC，其他用传统 init 脚本
- 客户端配置生成：原生 YAML、分享链接（hy2://）、Clash Meta 配置
- 防火墙管理：支持 UFW/firewalld/iptables/nftables

---

## 3. test_bootstrap_install.sh — 引导安装器单元测试

**用途**：对 install.sh 中的核心函数进行单元测试，验证下载逻辑和版本映射的正确性。

**参数**：无（内部通过环境变量注入测试路径）

**测试用例**：
1. test_download_uses_curl_when_wget_is_missing — 模拟 mock curl 下载，验证 URL、文件内容、执行权限
2. test_download_fails_cleanly_without_download_client — 无下载工具时验证返回失败且不留残留文件
3. test_resolve_hysteria_version_mapping — 验证输入映射：1→hysteria2，空→hysteria2，2→hysteria1，3→失败

---

## 4. test_install_recovery.sh — 安装恢复逻辑单元测试

**用途**：对 hy2.sh 中的安装状态分类、部分安装恢复、版本检查、防火墙端口操作等关键函数进行单元测试。

**参数**：无（内部通过环境变量注入测试路径）

**测试用例**：
1. test_not_installed_state — 干净系统检测为 not-installed
2. test_partial_state_detection_and_recovery — 部分安装检测 + 清理验证
3. test_installed_state_detection — 完整安装检测为 installed
4. test_missing_launcher_is_partial_state — 缺少 hihy 链接检测为 partially-installed
5. test_install_validation_uses_iptables_backend — 强制使用 iptables 后端
6. test_cached_version_notifications_are_displayed — 缓存版本通知显示
7. test_version_check_ttl_and_lock_guard — TTL 未过期+锁存活时阻止重复检查
8. test_show_menu_starts_background_check_after_render — 菜单渲染后触发后台版本检查
9. test_failure_marker_round_trip — 失败标记写入→检测→清除→恢复
10. test_firewall_port_range_cleanup — 验证端口范围添加/删除（UFW）
11. test_yq_download_uses_curl_when_wget_is_missing — 无 wget 时 curl 下载 yq 验证
