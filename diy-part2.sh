#!/bin/bash
#
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
#

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"

ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# Nikki 源配置
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"

mkdir -p "$ADGUARD_DIR" "$DTS_DIR"

# -------------------- 内核模块与工具配置 --------------------
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# -------------------- 集成 Nikki 源 --------------------
echo "集成 Nikki 源..."

# 检查是否已经添加了Nikki源
if ! grep -q "nikki.*$NIKKI_FEED" feeds.conf.default 2>/dev/null; then
    echo "添加 Nikki 源到 feeds.conf.default"
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default
else
    echo "Nikki 源已存在，跳过添加"
fi

# 更新和安装Nikki源
echo "更新 Nikki 源..."
if ./scripts/feeds update nikki; then
    echo "Nikki 源更新成功"
else
    echo "警告：Nikki 源更新失败，但继续执行"
fi

echo "安装 Nikki 包..."
if ./scripts/feeds install -a -p nikki; then
    echo "Nikki 包安装成功"
else
    echo "警告：Nikki 包安装失败，但继续执行"
fi

# 启用Nikki包
echo "启用 Nikki 配置..."
if ! grep -q "^CONFIG_PACKAGE_nikki=y" .config; then
    echo "CONFIG_PACKAGE_nikki=y" >> .config
fi
if ! grep -q "^CONFIG_PACKAGE_luci-app-nikki=y" .config; then
    echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
fi

echo "Nikki 集成完成"

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
rm -rf package/custom/luci-app-watchdog package/custom/luci-app-partexp

git clone --depth 1 https://github.com/sirpdboy/luci-app-watchdog.git package/custom/luci-app-watchdog
git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git package/custom/luci-app-partexp

./scripts/feeds update -a
./scripts/feeds install -a

echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> .config
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config

echo "DIY脚本执行完成（已集成Nikki）"
