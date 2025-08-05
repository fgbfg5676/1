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

ADHOME_BASE="package/base-files/files/etc/adguardhome"
BIN_URL="https://raw.githubusercontent.com/fgbfg5676/1/main/upload/main/AdGuardHome/adhome/AdGuardHome_linux_armv7.tar.gz"
LUA_URL="https://raw.githubusercontent.com/fgbfg5676/1/main/upload/main/AdGuardHome/adhome/luci-app-adguardhome_1.8-20221120_all.ipk"
LANG_URL="https://raw.githubusercontent.com/fgbfg5676/1/main/upload/main/AdGuardHome/adhome/luci-i18n-adguardhome-zh-cn_git-22.323.68542-450e04a_all.ipk"
YAML_URL="https://raw.githubusercontent.com/fgbfg5676/1/main/upload/main/AdGuardHome/adhome/AdGuardHome.yaml"

# 创建目录
mkdir -p files/usr/bin
mkdir -p files/etc/init.d
mkdir -p files/etc
mkdir -p "$ADHOME_BASE"

# 下载 AdGuardHome 主程序
echo "🔹 下载 AdGuardHome 二进制文件..."
curl -L "$BIN_URL" -o "$ADHOME_BASE/AdGuardHome_linux_armv7.tar.gz"
tar -xzf "$ADHOME_BASE/AdGuardHome_linux_armv7.tar.gz" -C "$ADHOME_BASE"
mv "$ADHOME_BASE/AdGuardHome/AdGuardHome" files/usr/bin/
chmod +x files/usr/bin/AdGuardHome

# 下载配置文件
echo "🔹 下载默认配置 AdGuardHome.yaml..."
curl -L "$YAML_URL" -o files/etc/AdGuardHome.yaml

# 创建 init 启动脚本
echo "🔹 创建启动脚本..."
cat > files/etc/init.d/AdGuardHome <<'EOF'
#!/bin/sh /etc/rc.common
START=90
STOP=10

start() {
    /usr/bin/AdGuardHome -c /etc/AdGuardHome.yaml -w /etc/adguardhome --no-check-update &
}

stop() {
    killall AdGuardHome
}
EOF
chmod +x files/etc/init.d/AdGuardHome

# 下载 luci app 和语言包
echo "🔹 下载 LuCI 界面及中文语言包..."
curl -L "$LUA_URL" -o luci-app-adguardhome.ipk
curl -L "$LANG_URL" -o luci-i18n-adguardhome-zh-cn.ipk

# 安装到 feeds（用这种方式保证打包进固件）
mkdir -p package/adgh/luci
cd package/adgh/luci
ln -s ../../../../luci-app-adguardhome.ipk .
ln -s ../../../../luci-i18n-adguardhome-zh-cn.ipk .
cd ../../../..

echo "✅ AdGuardHome 集成完成。"


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
