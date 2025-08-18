#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
#echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default
#echo 'src-git kenzo https://github.com/kenzok8/openwrt-packages' >> feeds.conf.default  # 常用插件集合

# ========================================================
# 在 diy-part1.sh 的末尾，或在 ./scripts/feeds update -a 之前添加

log_info "正在清理可能衝突的舊版軟體包..."

# 強制刪除所有 feeds 中可能存在的 snmpd 和 libnetsnmp，確保使用官方版本
rm -rf feeds/packages/net/snmpd
rm -rf feeds/kenzo/net/snmpd
rm -rf feeds/kenzo/libnetsnmp

# 如果您還引入了其他 feed，也可能需要從中刪除
# 例如： rm -rf feeds/other_feed_name/net/snmpd

log_success "衝突軟體包清理完成。"
# ========================================================

