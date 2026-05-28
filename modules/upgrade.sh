#!/usr/bin/env bash
# ============================================================
# modules/upgrade.sh
# 组件升级模块
# 当前升级入口由 install.sh 调度，本文件用于纳入模块缓存与同步列表。
# ============================================================

run_upgrade() {
    if declare -F do_upgrade_menu >/dev/null; then
        do_upgrade_menu
    else
        echo "升级菜单需要通过 install.sh 主脚本运行"
        return 1
    fi
}
