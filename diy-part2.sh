#!/bin/bash
#
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
#

set -e  # 遇到错误立即退出

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"

DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

mkdir -p "$DTS_DIR"


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

# -------------------- 集成 AdGuardHome --------------------
echo "📦 集成 AdGuardHome 组件（使用本地文件或远程下载）..."

ADHOME_BASE="upload/main/AdGuardHome/adhome"

# 1. 创建目标目录（相对于脚本根目录）
mkdir -p files/usr/bin
mkdir -p files/etc/AdGuardHome
mkdir -p files/usr/lib/lua/luci/controller
mkdir -p files/usr/lib/lua/luci/model/cbi
mkdir -p files/usr/lib/lua/luci/view
mkdir -p files/etc/config
mkdir -p files/etc/init.d
mkdir -p files/usr/lib/lua/luci/i18n

# 2. 创建临时工作目录并进入
mkdir -p tmp_adguard
cd tmp_adguard

#########################
# 处理二进制文件
BIN_TAR="AdGuardHome_linux_armv7.tar.gz"
BIN_PATH="../../$ADHOME_BASE/depends/$BIN_TAR"
BIN_URL="https://github.com/fgbfg5676/1/raw/main/$ADHOME_BASE/depends/$BIN_TAR"

echo "🔹 处理 AdGuardHome 二进制文件..."

if [ -f "$BIN_PATH" ]; then
    echo "找到本地二进制压缩包，开始复制..."
    cp "$BIN_PATH" .
else
    echo "本地二进制压缩包不存在，尝试远程下载..."
    curl -L -o "$BIN_TAR" "$BIN_URL" || { echo "二进制下载失败"; exit 1; }
fi

echo "解压二进制压缩包..."
tar -xzf "$BIN_TAR"

if [ ! -f "AdGuardHome/AdGuardHome" ]; then
    echo "Error: 解压后找不到二进制文件 AdGuardHome/AdGuardHome"
    exit 1
fi

# 确保目标目录存在（这里相对 tmp_adguard，回退一级是根目录）
mkdir -p ../files/usr/bin

echo "移动二进制文件到目标目录..."
mv AdGuardHome/AdGuardHome ../files/usr/bin/
chmod +x ../files/usr/bin/AdGuardHome

rm -rf AdGuardHome "$BIN_TAR"

#########################
# LuCI IPK 下载与检测
LUCI_IPK="luci-app-adguardhome_1.8-20221120_all.ipk"
LUCI_IPK_URL="https://raw.githubusercontent.com/fgbfg5676/1/main/upload/main/AdGuardHome/adhome/$LUCI_IPK"

if [ -f "$LUCI_IPK_PATH" ]; then
    cp "$LUCI_IPK_PATH" .
else
    curl -L -o "$LUCI_IPK" "$LUCI_IPK_URL"
    if head -n 1 "$LUCI_IPK" | grep -q -i "<!DOCTYPE html>"; then
        echo "Error: 下载的不是 IPK 文件"
        exit 1
    fi
fi

ar x "$LUCI_IPK"
tar -xzf data.tar.gz

# 确保 LuCI 目标目录存在
mkdir -p ../files/usr/lib/lua/luci/controller
mkdir -p ../files/usr/lib/lua/luci/model/cbi
mkdir -p ../files/usr/lib/lua/luci/view
mkdir -p ../files/etc/config
mkdir -p ../files/etc/init.d

cp usr/lib/lua/luci/controller/adguardhome.lua ../files/usr/lib/lua/luci/controller/
cp -r usr/lib/lua/luci/model/cbi/adguardhome ../files/usr/lib/lua/luci/model/cbi/
cp -r usr/lib/lua/luci/view/adguardhome ../files/usr/lib/lua/luci/view/
cp etc/config/adguardhome ../files/etc/config/
cp etc/init.d/adguardhome ../files/etc/init.d/
chmod +x ../files/etc/init.d/adguardhome

rm -rf usr etc data.tar.gz control.tar.gz debian-binary "$LUCI_IPK"

#########################
# 处理中文语言包
I18N_IPK="luci-i18n-adguardhome-zh-cn_git-22.323.68542-450e04a_all.ipk"
I18N_IPK_PATH="../../$ADHOME_BASE/$I18N_IPK"
I18N_IPK_URL="https://github.com/fgbfg5676/1/raw/main/$ADHOME_BASE/$I18N_IPK"

echo "🔹 处理中文语言包..."

if [ -f "$I18N_IPK_PATH" ]; then
    echo "找到本地语言包 IPK，开始复制..."
    cp "$I18N_IPK_PATH" .
else
    echo "本地语言包 IPK 不存在，尝试远程下载..."
    curl -L -o "$I18N_IPK" "$I18N_IPK_URL" || { echo "语言包下载失败"; exit 1; }
fi

ar x "$I18N_IPK"
tar -xzf data.tar.gz

mkdir -p ../files/usr/lib/lua/luci/i18n
cp usr/lib/lua/luci/i18n/adguardhome.zh-cn.lmo ../files/usr/lib/lua/luci/i18n/

rm -rf usr data.tar.gz control.tar.gz debian-binary "$I18N_IPK"

#########################
# 处理默认配置文件
echo "🔹 处理默认配置文件..."

if [ -f "../../$ADHOME_BASE/AdGuardHome.yaml" ]; then
    cp "../../$ADHOME_BASE/AdGuardHome.yaml" ../files/etc/AdGuardHome/
else
    echo "Warning: 默认配置文件不存在，使用内置默认配置"
    cat > ../files/etc/AdGuardHome/AdGuardHome.yaml <<EOF
bind_host: 0.0.0.0
bind_port: 3000
dns:
  bind_host: 0.0.0.0
  bind_port: 53
EOF
fi

#########################
# 清理临时目录
cd ..
rm -rf tmp_adguard

echo "✅ AdGuardHome 组件集成完成"

# -------------------- 修改默认配置 --------------------
echo "🔧 修改默认配置..."

# 强制修改所有可能的配置文件
CONFIG_FILES=(
    "package/base-files/files/bin/config_generate"
    "package/base-files/files/etc/board.d/02_network"
    "target/linux/ipq40xx/base-files/etc/board.d/02_network"
    "target/linux/ipq40xx/base-files/etc/uci-defaults/02_network"
)

for file in "${CONFIG_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "修改文件: $file"
        sed -i 's/192.168.1.1/192.168.5.1/g' "$file"
        sed -i 's/OpenWrt/CM520-79F/g' "$file"
    fi
done

# 创建强制配置文件
mkdir -p package/base-files/files/etc/uci-defaults
cat > package/base-files/files/etc/uci-defaults/99-custom-network << 'UCIEOF'
#!/bin/sh
# 强制设置网络配置
uci -q batch << UCI_EOF
set network.lan.ipaddr='192.168.5.1'
set network.lan.netmask='255.255.255.0'
set system.@system[0].hostname='CM520-79F'
commit network
commit system
UCI_EOF
exit 0
UCIEOF

chmod +x package/base-files/files/etc/uci-defaults/99-custom-network
echo "✅ 已创建强制配置文件"

# 批量查找并修改所有相关文件
find . -name "*.sh" -o -name "config_generate" -o -name "02_network" -o -name "network" 2>/dev/null | \
while read -r file; do
    if [ -f "$file" ] && grep -q "192.168.1.1" "$file" 2>/dev/null; then
        sed -i 's/192.168.1.1/192.168.5.1/g' "$file"
        echo "已修改: $file"
    fi
    if [ -f "$file" ] && grep -q "OpenWrt" "$file" 2>/dev/null; then
        sed -i 's/OpenWrt/CM520-79F/g' "$file"
    fi
done

echo "🎉 DIY脚本执行完成！"
echo "📋 执行摘要："
echo "   ✅ DTS 补丁已应用"
echo "   ✅ 设备规则已添加"
echo "   ✅ 插件已安装"
echo "   ✅ 默认配置已修改 (IP: 192.168.5.1, 主机名: CM520-79F)"
