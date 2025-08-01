#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate
#!/bin/bash

# 添加 kmod-ubi 和 kmod-ubifs 模块
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config

# 确保 trx 工具被启用（用于生成带头部的固件）
echo "CONFIG_PACKAGE_trx=y" >> .config
# 定位 generic.mk 文件（OpenWrt 源码中的路径）
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# 为 mobipromo_cm520-79f 设备添加 trx 固件生成规则
# 先检查设备定义是否已存在，避免重复添加
if ! grep -q "DEVICE_mobipromo_cm520-79f" "$GENERIC_MK"; then
    # 若设备定义不存在（通常不会，此处为兜底），可忽略或手动补充
    echo "Warning: Device mobipromo_cm520-79f not found in $GENERIC_MK"
else
    # 在设备定义中插入 trx 生成规则
    # 使用 sed 命令在设备定义块内添加 IMAGE/trx 逻辑
    sed -i '/define Device\/mobipromo_cm520-79f/,/endef/ {
        /IMAGE\//!b
        a\  IMAGE/trx := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | trx -o $@
    }' "$GENERIC_MK"
fi
