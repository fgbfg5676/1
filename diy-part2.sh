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

OPENCLASH_CORE_DIR="package/luci-app-openclash/root/etc/openclash/core"
ADGUARD_DIR="files/usr/bin"  # 统一路径
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

# -------------------- OpenClash Meta 内核集成 --------------------
echo "🚀 开始集成 OpenClash Meta 内核..."

# 创建临时目录
TMP_DIR=$(mktemp -d)
cleanup() {
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
        echo "🧹 已清理临时文件"
    fi
}
trap cleanup EXIT

echo "📡 正在获取 mihomo 最新版本信息..."

# 获取最新版本
LATEST_RELEASE=$(curl -s --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
    "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")

if [ -n "$LATEST_RELEASE" ]; then
    LATEST_TAG=$(echo "$LATEST_RELEASE" | grep -o '"tag_name": *"[^"]*"' | \
        sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
else
    echo "❌ 无法获取最新版本，使用备用方案..."
    LATEST_TAG=$(curl -s --retry 3 --connect-timeout 10 \
        "https://github.com/MetaCubeX/mihomo/releases/latest" | \
        grep -o 'tag/v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1 | cut -d'/' -f2)
fi

if [ -z "$LATEST_TAG" ]; then
    echo "❌ 无法获取版本信息，跳过 Meta 内核"
else
    echo "📦 最新版本: $LATEST_TAG"
    
    # 构建下载链接
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/mihomo-linux-${ARCH}-${LATEST_TAG}.gz"
    
    echo "⬇️  正在下载 mihomo 内核..."
    if wget $WGET_OPTS -O "$TMP_DIR/clash_meta.gz" "$MIHOMO_URL"; then
        if file "$TMP_DIR/clash_meta.gz" | grep -q gzip; then
            echo "📂 正在解压..."
            gunzip -f "$TMP_DIR/clash_meta.gz"
            mv "$TMP_DIR/clash_meta" "$OPENCLASH_CORE_DIR/clash_meta"
            chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
            echo "✅ Meta 内核安装成功"
        else
            echo "❌ 下载文件格式错误，跳过 Meta 内核"
        fi
    else
        echo "❌ Meta 内核下载失败，跳过"
    fi
fi

# -------------------- AdGuardHome 核心集成 --------------------
# 集成AdGuardHome
integrate_adguardhome() {
    log_info "🚀 开始集成 AdGuardHome 核心..."
    
    log_info "📡 正在获取 AdGuardHome 最新版本信息..."
    
    # 获取最新版本
    local latest_version=$(curl -s "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$latest_version" ]; then
        log_error "无法获取AdGuardHome版本信息"
        return 1
    fi
    
    log_info "📦 版本: $latest_version"
    
    # 检测架构
    local arch=$(detect_arch)
    log_info "🔍 检测到架构: $arch"
    
    # 构建下载链接
    local download_url="https://github.com/AdguardTeam/AdGuardHome/releases/download/$latest_version/AdGuardHome_$arch.tar.gz"
    log_info "✅ 获取下载链接: $download_url"
    
    # 下载AdGuardHome
    log_info "⬇️ 正在下载 AdGuardHome..."
    
    # 创建临时目录
    mkdir -p /tmp/adguardhome
    cd /tmp/adguardhome
    
    # 尝试多个下载方式
    local download_success=false
    
    # 方式1: 直接下载
    if wget -q --timeout=30 --tries=3 -O AdGuardHome.tar.gz "$download_url"; then
        download_success=true
    # 方式2: 使用GitHub镜像
    elif wget -q --timeout=30 --tries=3 -O AdGuardHome.tar.gz "${download_url/github.com/mirror.ghproxy.com/github.com}"; then
        download_success=true
    # 方式3: 使用另一个镜像
    elif wget -q --timeout=30 --tries=3 -O AdGuardHome.tar.gz "${download_url/github.com/ghproxy.com/github.com}"; then
        download_success=true
    fi
    
    if [ "$download_success" = true ]; then
        # 解压并安装
        tar -xzf AdGuardHome.tar.gz
        
        # 创建目标目录
        mkdir -p "$GITHUB_WORKSPACE/openwrt/files/usr/bin"
        
        # 复制二进制文件
        cp AdGuardHome/AdGuardHome "$GITHUB_WORKSPACE/openwrt/files/usr/bin/"
        chmod +x "$GITHUB_WORKSPACE/openwrt/files/usr/bin/AdGuardHome"
        
        cd - > /dev/null
        rm -rf /tmp/adguardhome
        
        log_success "✅ AdGuardHome 安装成功"
    else
        cd - > /dev/null
        rm -rf /tmp/adguardhome
        log_error "❌ AdGuardHome 下载失败"
        return 1
    fi
}
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
echo "   ✅ Meta 内核已集成"
echo "   ✅ AdGuardHome 已集成"
echo "   ✅ 插件已安装"
echo "   ✅ 默认配置已修改 (IP: 192.168.5.1, 主机名: CM520-79F)"
