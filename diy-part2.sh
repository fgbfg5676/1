#!/bin/bash
#
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
#

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"

OPENCLASH_CORE_DIR="package/luci-app-openclash/root/etc/openclash/core"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

mkdir -p "$OPENCLASH_CORE_DIR" "$ADGUARD_DIR" "$DTS_DIR"

# -------------------- 内核模块与工具配置 --------------------
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# -------------------- DTS补丁处理 --------------------
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"

echo "Downloading DTS patch..."
wget $WGET_OPTS -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL"
if [ ! -f "$TARGET_DTS" ]; then
    echo "Applying DTS patch..."
    patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"
fi

# -------------------- 设备规则配置 --------------------
if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    echo "Adding CM520-79F device rule..."
    cat <<EOF >> "$GENERIC_MK"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to \$$(KERNEL_SIZE) | append-rootfs | trx -o \$\@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
fi

# -------------------- OpenClash 核心集成 --------------------
echo "Integrating OpenClash mihomo core..."
rm -rf "$OPENCLASH_CORE_DIR"/*
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-armv7-v1.19.12.gz"
wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta.gz" "$MIHOMO_URL"
gunzip -f "$OPENCLASH_CORE_DIR/clash_meta.gz"
chmod +x "$OPENCLASH_CORE_DIR/clash_meta"

# -------------------- AdGuardHome 核心集成 --------------------
echo "Integrating AdGuardHome core..."
rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz"
ADGUARD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.59/AdGuardHome_linux_armv7.tar.gz"
wget $WGET_OPTS -O "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_URL"
tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$ADGUARD_DIR"
mv "$ADGUARD_DIR/AdGuardHome_linux_armv7/AdGuardHome" "$ADGUARD_DIR/"
chmod +x "$ADGUARD_DIR/AdGuardHome"
rm -rf "$ADGUARD_DIR/AdGuardHome_linux_armv7" "$ADGUARD_DIR/AdGuardHome.tar.gz"

# -------------------- 插件集成 --------------------
echo "Integrating sirpdboy plugins..."
mkdir -p package/custom
rm -rf package/custom/luci-app-watchdog package/custom/luci-app-partexp

git clone --depth 1 https://github.com/sirpdboy/luci-app-watchdog.git package/custom/luci-app-watchdog
git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git package/custom/luci-app-partexp

./scripts/feeds update -a
./scripts/feeds install -a

echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> .config
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config

# -------------------- 修改默认配置 --------------------
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate
sed -i 's/OpenWrt/CM520-79F/g' package/base-files/files/bin/config_generate

echo "DIY脚本执行完成"
