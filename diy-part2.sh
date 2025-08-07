#!/bin/bash
#
# File name: diy-part2.sh (Fixed Version)
# Description: 修复nikki依赖处理失败的问题
#
set -euo pipefail  # 更严格的错误检查，但增加容错处理

# -------------------- 颜色输出函数 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -------------------- 基础配置 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
HOSTNAME="CM520-79F"
TARGET_IP="192.168.5.1"
ADGUARD_PORT="5353"
CONFIG_PATH="package/base-files/files/etc/AdGuardHome"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# Nikki源
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

# -------------------- 网络检查 --------------------
check_network() {
    local test_url="$1"
    wget $WGET_OPTS --spider "$test_url" 2>/dev/null
}

# -------------------- 目录与配置文件创建 --------------------
mkdir -p "$DTS_DIR" "$CONFIG_PATH"
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

# -------------------- 内核与防火墙配置 --------------------
log_info "配置内核模块与防火墙..."
REQUIRED_CONFIGS=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
    "CONFIG_PACKAGE_firewall3=y"
    "CONFIG_PACKAGE_firewall4=n"
    "CONFIG_PACKAGE_luci-firewall=y"
)
for config in "${REQUIRED_CONFIGS[@]}"; do
    config_name=$(echo "$config" | cut -d'_' -f3- | cut -d'=' -f1)
    sed -i "/^#*CONFIG_PACKAGE_${config_name}/d" .config
    echo "$config" >> .config
done

# -------------------- 集成Nikki（增强容错） --------------------
log_info "集成Nikki代理..."
NIKKI_SOURCE=""
if check_network "$NIKKI_PRIMARY"; then
    NIKKI_SOURCE="$NIKKI_PRIMARY"
elif check_network "$NIKKI_MIRROR"; then
    NIKKI_SOURCE="$NIKKI_MIRROR"
elif check_network "$NIKKI_BACKUP_BINARY"; then
    NIKKI_SOURCE="$NIKKI_BACKUP_BINARY"
else
    log_error "所有Nikki源不可用，跳过集成"
    NIKKI_SOURCE=""
fi

# 仅当源有效时才尝试集成
if [ -n "$NIKKI_SOURCE" ]; then
    # 添加feeds（避免重复添加）
    if ! grep -q "nikki.*OpenWrt-nikki.git" feeds.conf.default; then
        echo "src-git nikki $NIKKI_SOURCE;main" >> feeds.conf.default
    fi
    # 更新并安装（允许失败后继续，避免脚本退出）
    if ! ./scripts/feeds update nikki; then
        log_warn "Nikki源更新失败，尝试强制安装"
    fi
    if ! ./scripts/feeds install -a -p nikki; then
        log_warn "Nikki包安装失败，手动添加配置"
    fi
    # 强制添加配置项
    echo "CONFIG_PACKAGE_nikki=y" >> .config
    echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
    echo "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y" >> .config
fi

# -------------------- 核心修复：依赖冲突处理（容错版） --------------------
log_info "开始修复依赖冲突..."

# 1. 修复nikki依赖（关键优化：允许找不到文件时继续）
log_info "调整nikki依赖为firewall3..."
# 明确指定可能的路径，避免find命令失效
POSSIBLE_NIKKI_PATHS=(
    "feeds/nikki/nikki/Makefile"
    "package/nikki/Makefile"
    "package/custom/nikki/Makefile"
)
NIKKI_MAKEFILE=""
for path in "${POSSIBLE_NIKKI_PATHS[@]}"; do
    if [ -f "$path" ]; then
        NIKKI_MAKEFILE="$path"
        break
    fi
done

# 仅当找到文件时才修改，否则警告但不退出
if [ -n "$NIKKI_MAKEFILE" ]; then
    sed -i "s/+firewall4/+firewall3/g" "$NIKKI_MAKEFILE"
    sed -i "/+firewall4/d" "$NIKKI_MAKEFILE"
    log_info "已修改nikki的Makefile: $NIKKI_MAKEFILE"
else
    log_warn "未找到nikki的Makefile，手动添加防火墙3依赖到.config"
    echo "CONFIG_PACKAGE_firewall3=y" >> .config  # 强制确保依赖
fi

# 2. 修复luci-app-fchomo依赖（同上，容错处理）
log_info "解除luci-app-fchomo的循环依赖..."
POSSIBLE_FCHOMO_PATHS=(
    "feeds/luci/applications/luci-app-fchomo/Makefile"
    "package/luci-app-fchomo/Makefile"
    "package/custom/luci-app-fchomo/Makefile"
)
FCHOMO_MAKEFILE=""
for path in "${POSSIBLE_FCHOMO_PATHS[@]}"; do
    if [ -f "$path" ]; then
        FCHOMO_MAKEFILE="$path"
        break
    fi
done

if [ -n "$FCHOMO_MAKEFILE" ]; then
    sed -i "/+firewall4/d" "$FCHOMO_MAKEFILE"
    sed -i "s/+nikki//g" "$FCHOMO_MAKEFILE"
    log_info "已修改luci-app-fchomo的Makefile: $FCHOMO_MAKEFILE"
else
    log_warn "未找到luci-app-fchomo的Makefile，跳过修改（可能已移除）"
fi

# 3. 修复geoview自依赖
log_info "修复geoview自依赖..."
GEOVIEW_CONFIG=$(find ./ -name "Config.in" | grep "geoview" | head -n 1)
if [ -n "$GEOVIEW_CONFIG" ]; then
    sed -i "/depends on.*geoview/d" "$GEOVIEW_CONFIG"
else
    log_warn "未找到geoview的配置文件，跳过修复"
fi

# -------------------- 其他配置（保持不变） --------------------
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

# 集成插件与系统配置
mkdir -p package/custom
rm -rf package/custom/luci-app-partexp
git clone --depth 1 "https://github.com/sirpdboy/luci-app-partexp.git" package/custom/luci-app-partexp && \
./scripts/feeds install -d y -p custom luci-app-partexp && \
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config || log_warn "luci-app-partexp集成失败"

# 修改IP和主机名
NETWORK_FILE="target/linux/ipq40xx/base-files/etc/config/network"
[ ! -f "$NETWORK_FILE" ] && NETWORK_FILE="package/base-files/files/etc/config/network"
[ -f "$NETWORK_FILE" ] && sed -i "s/192\.168\.1\.1/$TARGET_IP/g" "$NETWORK_FILE"

echo "$HOSTNAME" > "package/base-files/files/etc/hostname"

# UCI初始化脚本
UCI_DEFAULTS_DIR="package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEFAULTS_DIR"
cat <<EOF > "$UCI_DEFAULTS_DIR/99-custom-settings"
uci set system.@system[0].hostname='$HOSTNAME'
uci set network.lan.ipaddr='$TARGET_IP'
uci commit system
uci commit network
EOF
chmod +x "$UCI_DEFAULTS_DIR/99-custom-settings"

# 最终配置
rm -f tmp/.config-package.in
make defconfig || log_warn "配置生成有警告，但继续执行"

log_info "====================="
log_info "DIY脚本执行完成！"
log_info "已尽可能修复依赖冲突"
log_info "====================="
