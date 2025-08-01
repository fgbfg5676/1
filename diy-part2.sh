#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# 添加所需内核模块和 trx 工具
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# 下载并部署 mobipromo_cm520-79f 的 DTS 文件
DTS_DIR="target/linux/ipq40xx/dts"
DTS_FILE="qcom-ipq40xx-mobipromo_cm520-79f.dts"
DTS_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"  # 直接使用提供的 DTS 源链接

# 创建 DTS 目录（若不存在）
mkdir -p "$DTS_DIR"

# 下载 DTS 文件（注：若链接为补丁文件，需调整下载逻辑；此处假设为完整 DTS）
echo "Downloading DTS file for mobipromo_cm520-79f..."
if wget -q -O "$DTS_DIR/$DTS_FILE" "$DTS_URL"; then
    echo "DTS file downloaded successfully: $DTS_DIR/$DTS_FILE"
else
    echo "Error: Failed to download DTS file from $DTS_URL"
    exit 1
fi

# 为 mobipromo_cm520-79f 设备添加 trx 生成规则
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
if grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    # 插入分区大小（根据 DTS 中的分区定义调整，示例值需匹配实际）
    sed -i '/define Device\/mobipromo_cm520-79f/ a\  KERNEL_SIZE := 4096k\n  ROOTFS_SIZE := 16384k' "$GENERIC_MK"
    # 插入 trx 固件生成逻辑
    sed -i '/define Device\/mobipromo_cm520-79f/,/endef/ {
        /IMAGE\// a\  IMAGE/trx := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | trx -o $@
    }' "$GENERIC_MK"
    echo "Successfully added trx rules for mobipromo_cm520-79f"
else
    echo "Error: Device mobipromo_cm520-79f not found in $GENERIC_MK"
    exit 1
fi

# 可选：修改默认IP、主机名等
# sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate
# sed -i 's/OpenWrt/CM520-79F/g' package/base-files/files/bin/config_generate
