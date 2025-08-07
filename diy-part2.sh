#!/bin/bash
#
# File name: diy-part2.sh (Final Version with Dependency Fix)
# Description: OpenWrt DIY script with auto-fix for firewall4 dependency
# Target: CM520-79F (IPQ40xx, ARMv7)
#
set -e  # 遇到错误立即退出脚本

# -------------------- 颜色输出函数 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"
HOSTNAME="CM520-79F"
TARGET_IP="192.168.5.1"
ADGUARD_PORT="5353"
CONFIG_PATH="package/base-files/files/etc/AdGuardHome"

DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# Nikki源配置
NIKKI_PRIMARY="https://github.com/nikkinikki-org/OpenWrt-nikki.git"
NIKKI_MIRROR="https://gitee.com/nikkinikki/OpenWrt-nikki.git"
NIKKI_BACKUP_BINARY="https://github.com/fgbfg5676/1/raw/main/nikki_arm_cortex-a7_neon-vfpv4-openwrt-23.05.tar.gz"

# -------------------- 依赖检查 --------------------
log_info "检查系统依赖..."
REQUIRED_TOOLS=("git" "wget" "patch" "sed" "grep" "find")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "缺少必要工具: $tool"
        exit 1
    fi
done
log_info "依赖检查完成"

# -------------------- 网络连接检查 --------------------
check_network() {
    local test_url="$1"
    if wget $WGET_OPTS --spider "$test_url" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# -------------------- 创建必要目录 --------------------
log_info "创建必要目录..."
mkdir -p "$DTS_DIR" || { log_error "无法创建目录 $DTS_DIR"; exit 1; }

# -------------------- AdGuardHome 配置 --------------------
log_info "生成 AdGuardHome 配置文件..."
mkdir -p "$CONFIG_PATH" || { log_error "无法创建AdGuardHome配置目录"; exit 1; }

cat <<EOF > "$CONFIG_PATH/AdGuardHome.yaml"
bind_host: 0.0.0.0
bind_port: $ADGUARD_PORT
users:
  - name: admin
    password: \$2y\$10\$FoyiYiwQKRoJl9zzG7u0yeFpb4B8jVH4VkgrKauQuOV0WRnLNPXXi
language: zh-cn
upstream_dns:
  - 8.8.8.8
  - 114.114.114.114
  - 1.1.1.1
EOF
chmod 644 "$CONFIG_PATH/AdGuardHome.yaml"
log_info "AdGuardHome配置完成"

# -------------------- 内核模块配置 --------------------
log_info "配置内核模块..."
REQUIRED_CONFIGS=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
    # 防火墙配置：禁用firewall4，启用firewall3
    "CONFIG_PACKAGE_firewall3=y"
    "CONFIG_PACKAGE_firewall4=n"
    "CONFIG_PACKAGE_luci-firewall=y"
)

for config in "${REQUIRED_CONFIGS[@]}"; do
    config_name=$(echo "$config" | cut -d'_' -f3- | cut -d'=' -f1)
    sed -i "/^#*CONFIG_PACKAGE_${config_name}/d" .config
    echo "$config" >> .config
done

# -------------------- 集成Nikki --------------------
log_info "集成Nikki代理..."
NIKKI_SOURCE=""
NIKKI_METHOD=""
if check_network "$NIKKI_PRIMARY"; then
    NIKKI_SOURCE="$NIKKI_PRIMARY"
    NIKKI_METHOD="feeds"
elif check_network "$NIKKI_MIRROR"; then
    NIKKI_SOURCE="$NIKKI_MIRROR"
    NIKKI_METHOD="feeds"
elif check_network "$NIKKI_BACKUP_BINARY"; then
    NIKKI_SOURCE="$NIKKI_BACKUP_BINARY"
    NIKKI_METHOD="binary"
else
    log_error "所有Nikki源不可用，跳过集成"
    NIKKI_SOURCE=""
fi

if [ -n "$NIKKI_SOURCE" ] && [ "$NIKKI_METHOD" = "feeds" ]; then
    if ! grep -q "nikki.*OpenWrt-nikki.git" feeds.conf.default; then
        echo "src-git nikki $NIKKI_SOURCE;main" >> feeds.conf.default
    fi
    ./scripts/feeds update nikki
    ./scripts/feeds install -a -p nikki
    echo "CONFIG_PACKAGE_nikki=y" >> .config
    echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
    echo "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y" >> .config
fi

# -------------------- 核心：自动修复依赖冲突 --------------------
log_info "开始修复依赖冲突..."

# 1. 修复nikki依赖：将firewall4改为firewall3
log_info "调整nikki依赖为firewall3..."
NIKKI_MAKEFILE=$(find ./ -name "nikki.mk" -o -name "Makefile" | grep "nikki$")
if [ -n "$NIKKI_MAKEFILE" ]; then
    # 替换依赖项
    sed -i "s/+firewall4/+firewall3/g" "$NIKKI_MAKEFILE"
    # 确保不依赖firewall4
    sed -i "/+firewall4/d" "$NIKKI_MAKEFILE"
    log_info "已修改nikki的Makefile: $NIKKI_MAKEFILE"
else
    log_warn "未找到nikki的Makefile，跳过依赖修改"
fi

# 2. 修复luci-app-fchomo依赖：移除firewall4和nikki的循环依赖
log_info "解除luci-app-fchomo的循环依赖..."
FCHOMO_MAKEFILE=$(find ./ -name "luci-app-fchomo.mk" -o -name "Makefile" | grep "luci-app-fchomo")
if [ -n "$FCHOMO_MAKEFILE" ]; then
    # 移除对firewall4的依赖
    sed -i "/+firewall4/d" "$FCHOMO_MAKEFILE"
    # 移除对nikki的直接依赖（打破循环）
    sed -i "s/+nikki//g" "$FCHOMO_MAKEFILE"
    log_info "已修改luci-app-fchomo的Makefile: $FCHOMO_MAKEFILE"
else
    log_warn "未找到luci-app-fchomo的Makefile，可能已移除"
fi

# 3. 修复geoview自依赖问题
log_info "修复geoview自依赖..."
GEOVIEW_CONFIG=$(find ./ -name "Config.in" | grep "geoview")
if [ -n "$GEOVIEW_CONFIG" ]; then
    # 移除自依赖配置
    sed -i "/depends on.*geoview/d" "$GEOVIEW_CONFIG"
    log_info "已修改geoview的配置文件: $GEOVIEW_CONFIG"
else
    log_warn "未找到geoview的配置文件，跳过修复"
fi

# -------------------- DTS补丁与设备规则 --------------------
log_info "处理DTS补丁与设备规则..."
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
wget $WGET_OPTS -O "$DTS_DIR/dts.patch" "$DTS_PATCH_URL" && patch -d "$DTS_DIR" -p2 < "$DTS_DIR/dts.patch" || log_warn "DTS补丁应用失败"

if ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
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

# -------------------- 集成插件与系统配置 --------------------
log_info "集成插件与系统配置..."
# 集成luci-app-partexp
mkdir -p package/custom
rm -rf package/custom/luci-app-partexp
git clone --depth 1 "https://github.com/sirpdboy/luci-app-partexp.git" package/custom/luci-app-partexp && \
./scripts/feeds install -d y -p custom luci-app-partexp && \
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config || log_warn "luci-app-partexp集成失败"

# 修改默认IP和主机名
NETWORK_FILE="target/linux/ipq40xx/base-files/etc/config/network"
[ ! -f "$NETWORK_FILE" ] && NETWORK_FILE="package/base-files/files/etc/config/network"
[ -f "$NETWORK_FILE" ] && sed -i "s/192\.168\.1\.1/$TARGET_IP/g" "$NETWORK_FILE"

echo "$HOSTNAME" > "package/base-files/files/etc/hostname"

# 创建uci初始化脚本
UCI_DEFAULTS_DIR="package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEFAULTS_DIR"
cat <<EOF > "$UCI_DEFAULTS_DIR/99-custom-settings"
uci set system.@system[0].hostname='$HOSTNAME'
uci set network.lan.ipaddr='$TARGET_IP'
uci commit system
uci commit network
EOF
chmod +x "$UCI_DEFAULTS_DIR/99-custom-settings"

# -------------------- 最终配置处理 --------------------
log_info "最终配置处理..."
# 清理依赖缓存
rm -f tmp/.config-package.in
# 重新生成配置
make defconfig

log_info "====================="
log_info "DIY脚本执行完成！"
log_info "已自动修复firewall4依赖冲突，保留nikki"
log_info "配置摘要："
log_info "- 防火墙: 已启用firewall3，禁用firewall4"
log_info "- 目标设备: CM520-79F (IPQ40xx)"
log_info "- IP地址: $TARGET_IP"
log_info "- Nikki代理: $([ -n "$NIKKI_SOURCE" ] && echo "已集成" || echo "未集成")"
log_info "====================="
