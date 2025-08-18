# ========================================================
#!/bin/bash
#
# OpenWrt DIY script part 1 (Before Update feeds)
# 完整版，带日志函数，清理冲突包
# 作者: The Architect & Manus AI
#

# --- 开启严格模式，任何错误立即退出 ---
set -euxo pipefail
# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] ℹ️  $*"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] ❌ $*"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] ✅ $*"; }

# -------------------- 变量 --------------------
FEEDS_CONF="${FEEDS_CONF:-feeds.conf.default}"

# -------------------- 清理可能冲突的旧版软件包 --------------------
log_info "正在清理可能冲突的旧版软件包..."

# 强制删除所有 feeds 中可能存在的 snmpd 和 libnetsnmp，确保使用官方版本
rm -rf feeds/packages/net/snmpd
rm -rf feeds/kenzo/net/snmpd
rm -rf feeds/kenzo/libnetsnmp

# 如果你引入了其他 feed，也可能需要从中删除
# 例如： rm -rf feeds/other_feed_name/net/snmpd

log_success "冲突软件包清理完成。"

# -------------------- 可选：解注或添加 feed --------------------
# 如果需要解注或添加 feed，可以在这里执行
# sed -i 's/^#\(.*helloworld\)/\1/' "$FEEDS_CONF"
# echo 'src-git helloworld https://github.com/fw876/helloworld' >> "$FEEDS_CONF"
# echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >> "$FEEDS_CONF"
# echo 'src-git kenzo https://github.com/kenzok8/openwrt-packages' >> "$FEEDS_CONF"

log_info "diy-part1.sh 执行完毕，可继续执行 ./scripts/feeds update -a"

# ========================================================

