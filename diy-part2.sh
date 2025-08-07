#!/bin/bash
set -e  # 错误立即退出

# -------------------- 日志输出函数 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -------------------- 基础变量定义 --------------------
# 目录与路径
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
ADGUARD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.64/AdGuardHome_linux_armv7.tar.gz"
ADGUARD_PORT="5553"  # 自定义DNS端口
TARGET_IP="192.168.5.1"  # 示例默认IP
HOSTNAME="CM520-79F"

# 第三方源配置
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
SIRPDBOY_PARTEXP="https://github.com/sirpdboy/luci-app-partexp.git"

# -------------------- 1. 创建必要目录 --------------------
log_info "创建必要目录..."
mkdir -p \
    "$DTS_DIR" \
    "package/custom" \
    "package/base-files/files/etc/AdGuardHome" \
    "package/base-files/files/etc/uci-defaults"
log_info "必要目录创建完成"

# -------------------- 2. 配置内核模块 --------------------
log_info "配置内核模块..."
# 添加必要的内核模块配置到.config
REQUIRED_MODULES=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
    "CONFIG_PACKAGE_firewall3=y"  # 假设使用firewall3
)
for mod in "${REQUIRED_MODULES[@]}"; do
    # 先删除旧配置，添加新配置
    sed -i "/$(echo "$mod" | cut -d'=' -f1)/d" .config
    echo "$mod" >> .config
done
log_info "内核模块配置完成"

# -------------------- 3. 集成Nikki（官方源方式） --------------------
log_info "开始通过官方源集成Nikki..."
# 添加Nikki源到feeds.conf.default
if ! grep -q "nikki.*$NIKKI_FEED" feeds.conf.default; then
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default
    log_info "已添加Nikki源到feeds"
fi

# 更新并安装Nikki相关包
./scripts/feeds update nikki
./scripts/feeds install -a -p nikki  # 安装源中所有包
# 强制启用Nikki组件
echo "CONFIG_PACKAGE_nikki=y" >> .config
echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
echo "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y" >> .config
log_info "Nikki通过官方源集成完成"

# -------------------- 4. 处理DTS补丁 --------------------
log_info "处理DTS补丁..."
# 假设DTS补丁URL（日志未显示具体链接，此处为示例）
DTS_PATCH_URL="https://example.com/dts-patch.patch"
wget -q -O "$DTS_DIR/cm520-79f.patch" "$DTS_PATCH_URL"
# 应用补丁（忽略失败，继续执行）
if ! patch -d "$DTS_DIR" -p1 < "$DTS_DIR/cm520-79f.patch"; then
    log_warn "DTS补丁应用失败，使用默认DTS"
fi

# -------------------- 5. 配置设备规则 --------------------
log_info "配置设备规则..."
# 检查并添加CM520-79F设备规则到generic.mk
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
    log_info "CM520-79F设备规则添加完成"
else
    log_info "设备规则已存在，跳过"
fi

# -------------------- 6. 集成AdGuardHome（自定义端口） --------------------
log_info "开始集成AdGuardHome核心并修改DNS端口为$ADGUARD_PORT..."
# 下载并解压AdGuardHome
wget -q -O /tmp/AdGuardHome.tar.gz "$ADGUARD_URL"
mkdir -p /tmp/adguard
tar -xzf /tmp/AdGuardHome.tar.gz -C /tmp/adguard --strip-components=1

# 复制可执行文件到固件目录
cp /tmp/adguard/AdGuardHome "package/base-files/files/usr/bin/"
chmod +x "package/base-files/files/usr/bin/AdGuardHome"

# 创建配置文件（设置端口5553）
ADGUARD_CONF="package/base-files/files/etc/AdGuardHome/AdGuardHome.yaml"
if [ ! -f "$ADGUARD_CONF" ]; then
    log_info "未找到默认配置文件，创建新配置并设置端口"
    cat <<EOF > "$ADGUARD_CONF"
bind_host: 0.0.0.0
bind_port: $ADGUARD_PORT
users:
  - name: admin
    password: \$2y\$10\$defaulthash  # 默认密码哈希
upstream_dns:
  - 223.5.5.5
  - 114.114.114.114
EOF
else
    # 若配置文件存在，修改端口
    sed -i "s/bind_port: [0-9]*/bind_port: $ADGUARD_PORT/" "$ADGUARD_CONF"
fi
log_info "AdGuardHome核心集成完成"

# -------------------- 7. 集成sirpdboy插件（luci-app-partexp） --------------------
log_info "集成sirpdboy插件..."
# 克隆插件到自定义目录
rm -rf "package/custom/luci-app-partexp"
git clone --depth 1 "$SIRPDBOY_PARTEXP" "package/custom/luci-app-partexp"
# 安装插件及依赖
./scripts/feeds install -d y -p custom luci-app-partexp
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
log_info "luci-app-partexp集成完成"

# -------------------- 8. 更新所有feeds并安装包 --------------------
log_info "更新所有feeds并安装包..."
# 更新其他feeds（日志中提到的packages、luci、helloworld等）
./scripts/feeds update -a  # 更新所有源
./scripts/feeds install -a  # 安装所有包
log_info "所有feeds更新并安装完成"

# -------------------- 9. 修改默认系统配置 --------------------
log_info "修改默认系统配置..."
# 修改默认IP（示例路径，根据实际调整）
NETWORK_CONF="package/base-files/files/etc/config/network"
sed -i "s/192\.168\.1\.1/$TARGET_IP/" "$NETWORK_CONF"

# 修改主机名
echo "$HOSTNAME" > "package/base-files/files/etc/hostname"

# 创建uci初始化脚本（确保配置生效）
cat <<EOF > "package/base-files/files/etc/uci-defaults/99-custom"
uci set system.@system[0].hostname='$HOSTNAME'
uci set network.lan.ipaddr='$TARGET_IP'
uci commit
EOF
chmod +x "package/base-files/files/etc/uci-defaults/99-custom"

# -------------------- 10. 脚本完成 --------------------
log_info "DIY脚本执行完成"
