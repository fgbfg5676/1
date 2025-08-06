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
# 添加nikki安装目录
NIKKI_INSTALL_DIR="usr/bin"

mkdir -p "$OPENCLASH_CORE_DIR" "$ADGUARD_DIR" "$DTS_DIR"

# -------------------- 内核模块与工具配置 --------------------
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# -------------------- 集成nikki工具 --------------------
echo "开始集成nikki工具..."
# 创建临时目录
TMP_NIKKI=$(mktemp -d)
# 下载nikki压缩包
NIKKI_URL="https://github.com/fgbfg5676/1/blob/main/nikki_arm_cortex-a7_neon-vfpv4-openwrt-23.05.tar.gz?raw=true"
if wget $WGET_OPTS -O "$TMP_NIKKI/nikki.tar.gz" "$NIKKI_URL"; then
    # 解压到临时目录
    tar -zxf "$TMP_NIKKI/nikki.tar.gz" -C "$TMP_NIKKI"
    # 查找可执行文件并复制到目标目录
    NIKKI_EXE=$(find "$TMP_NIKKI" -name "nikki" -type f -executable | head -n 1)
    if [ -n "$NIKKI_EXE" ]; then
        # 创建安装目录
        mkdir -p "package/base-files/files/$NIKKI_INSTALL_DIR"
        # 复制可执行文件
        cp "$NIKKI_EXE" "package/base-files/files/$NIKKI_INSTALL_DIR/"
        # 添加执行权限
        chmod +x "package/base-files/files/$NIKKI_INSTALL_DIR/nikki"
        echo "nikki工具集成成功"
    else
        echo "警告：未找到nikki可执行文件"
    fi
else
    echo "警告：nikki压缩包下载失败"
fi
# 清理临时文件
rm -rf "$TMP_NIKKI"
echo "nikki工具集成完成"

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

# -------------------- 集成AdGuardHome核心 --------------------
echo "开始集成AdGuardHome核心..."

# 清理历史文件
rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz"

# 下载AdGuardHome核心
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest |
              grep "browser_download_url.*linux_armv7" |
              cut -d '"' -f 4)

if [ -n "$ADGUARD_URL" ]; then
    echo "下载AdGuardHome: $ADGUARD_URL"
    if wget $WGET_OPTS -O "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_URL"; then
        # 解压到临时目录，查看实际目录结构
        TMP_DIR=$(mktemp -d)
        tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword
        
        # 查找解压后的AdGuardHome可执行文件路径（兼容不同目录结构）
        ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -n 1)
        if [ -n "$ADG_EXE" ]; then
            # 复制可执行文件到目标目录
            cp "$ADG_EXE" "$ADGUARD_DIR/"
            chmod +x "$ADGUARD_DIR/AdGuardHome"
            echo "AdGuardHome核心复制成功"
        else
            echo "警告：未找到AdGuardHome可执行文件"
        fi
        
        # 清理临时文件
        rm -rf "$TMP_DIR" "$ADGUARD_DIR/AdGuardHome.tar.gz"
    else
        echo "警告：AdGuardHome下载失败"
    fi
else
    echo "警告：未找到AdGuardHome核心地址"
fi

echo "AdGuardHome核心集成完成"

# -------------------- 插件集成 --------------------
echo "Integrating sirpdboy plugins..."
mkdir -p package/custom
rm -rf package/custom/luci-app-partexp

git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git package/custom/luci-app-partexp

./scripts/feeds update -a
./scripts/feeds install -a

echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config

# -------------------- 修改默认配置 --------------------
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate
sed -i 's/OpenWrt/CM520-79F/g' package/base-files/files/bin/config_generate

echo "DIY脚本执行完成"
