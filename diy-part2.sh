#!/bin/bash
#
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
#
set -e  # 遇到错误立即退出脚本

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"
HOSTNAME="CM520-79F"  # 自定义主机名
TARGET_IP="192.168.5.1"  # 自定义IP地址
ADGUARD_PORT="5353"  # 修改监听端口为 5353
CONFIG_PATH="/etc/AdGuardHome"  # AdGuardHome 配置文件路径

# 确保所有路径变量都有明确值，避免为空
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# -------------------- 创建必要目录 --------------------
echo "创建必要目录..."
if ! mkdir -p "$DTS_DIR"; then
    echo "错误：无法创建目录 $DTS_DIR"
    exit 1
fi

# -------------------- AdGuardHome 配置 --------------------
echo "生成 AdGuardHome 配置文件..."
# 确保配置目录存在
mkdir -p "$CONFIG_PATH" || { echo "错误：无法创建AdGuardHome配置目录 $CONFIG_PATH"; exit 1; }
# 生成配置文件
cat <<EOF > "$CONFIG_PATH/AdGuardHome.yaml"
# AdGuardHome 配置文件
bind_port: $ADGUARD_PORT
upstream_dns:
  - 8.8.8.8
  - 8.8.4.4
  - 114.114.114.114
cache_size: 1000000  # DNS缓存大小
filtering_enabled: true
blocking_mode: default
EOF
# 设置配置文件权限
chmod 644 "$CONFIG_PATH/AdGuardHome.yaml"
echo "AdGuardHome 配置文件已创建，路径：$CONFIG_PATH/AdGuardHome.yaml，监听端口：$ADGUARD_PORT"

# -------------------- 内核模块与工具配置 --------------------
echo "配置内核模块..."
# 先删除旧配置，确保唯一性
sed -i "/CONFIG_PACKAGE_kmod-ubi/d" .config && echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
sed -i "/CONFIG_PACKAGE_kmod-ubifs/d" .config && echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
sed -i "/CONFIG_PACKAGE_trx/d" .config && echo "CONFIG_PACKAGE_trx=y" >> .config

# -------------------- 集成Nikki（采用官方feeds方式） --------------------
echo "开始通过官方源集成Nikki..."

# 1. 添加Nikki官方源（确保在feeds中生效）
if ! grep -q "nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" feeds.conf.default; then
    echo "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" >> feeds.conf.default
    echo "已成功添加 Nikki 源"
else
    echo "Nikki 源已存在"
fi

# 2. 更新并安装Nikki相关包
echo "更新 Nikki 源..."
./scripts/feeds update nikki || { echo "错误：更新Nikki源失败"; exit 1; }

echo "安装 Nikki 包..."
./scripts/feeds install -a -p nikki || { echo "错误：安装Nikki包失败"; exit 1; }

# 3. 在.config中启用Nikki核心组件及依赖
echo "启用 Nikki 相关配置..."
echo "CONFIG_PACKAGE_nikki=y" >> .config                  # 核心程序
echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config        # Web管理界面
echo "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y" >> .config # 中文语言包

echo "Nikki通过官方源集成完成"

# -------------------- DTS补丁处理 --------------------
echo "处理DTS补丁..."
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"

if ! wget $WGET_OPTS -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL"; then
    echo "警告：DTS补丁下载失败，使用默认DTS文件"
else
    # 无论TARGET_DTS是否存在，尝试应用补丁
    echo "应用DTS补丁..."
    if ! patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"; then
        echo "警告：DTS补丁应用失败，使用默认DTS文件"
    fi
fi

# -------------------- 设备规则配置 --------------------
echo "配置设备规则..."
if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    echo "添加CM520-79F设备规则..."
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
echo "集成sirpdboy插件..."
mkdir -p package/custom
rm -rf package/custom/luci-app-partexp

if ! git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git package/custom/luci-app-partexp; then
    echo "警告：luci-app-partexp克隆失败，跳过该插件"
else
    # -d y：自动安装所有依赖，确保完整性
    ./scripts/feeds install -d y -p custom luci-app-partexp
    echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
    echo "luci-app-partexp及其依赖已安装"
fi

# -------------------- 修改默认配置（修复IP和主机名） --------------------
echo "修改默认系统配置..."

# 修正IP地址修改逻辑
echo "修改默认IP地址为 $TARGET_IP..."
# 优先尝试设备专属网络配置（IPQ40xx平台）
NETWORK_FILE="target/linux/ipq40xx/base-files/etc/config/network"
if [ ! -f "$NETWORK_FILE" ]; then
  # 若设备专属文件不存在，使用通用路径
  NETWORK_FILE="package/base-files/files/etc/config/network"
fi

if [ -f "$NETWORK_FILE" ]; then
  # 兼容单引号、双引号或无引号的情况
  sed -i 's/option ipaddr[[:space:]]*[\"\']192.168.1.1[\"\']/option ipaddr '"'$TARGET_IP'"'/g' "$NETWORK_FILE"
  echo "已修改 $NETWORK_FILE 中的默认IP"
  # 调试输出
  echo "调试：修改后的IP配置内容："
  grep "ipaddr" "$NETWORK_FILE"
else
  echo "警告：未找到网络配置文件，IP修改可能失败"
fi

# 辅助修改config_generate（防止fallback配置）
if [ -f "package/base-files/files/bin/config_generate" ]; then
  sed -i "s/192.168.1.1/$TARGET_IP/g" package/base-files/files/bin/config_generate
  echo "已修改 config_generate 中的默认IP"
fi

# 修正主机名修改逻辑
echo "修改默认主机名为 $HOSTNAME..."

# 1. 修改hostname文件
if [ -f "package/base-files/files/etc/hostname" ]; then
  echo "$HOSTNAME" > package/base-files/files/etc/hostname
  echo "已修改 /etc/hostname 文件"
  # 调试输出
  echo "调试：hostname文件内容："
  cat package/base-files/files/etc/hostname
fi

# 2. 修改system配置（兼容引号差异）
SYSTEM_FILE="package/base-files/files/etc/config/system"
if [ -f "$SYSTEM_FILE" ]; then
  sed -i "s/option hostname[[:space:]]*[\"\']OpenWrt[\"\']/option hostname '$HOSTNAME'/g" "$SYSTEM_FILE"
  echo "已修改 $SYSTEM_FILE 中的主机名"
  # 调试输出
  echo "调试：修改后的主机名配置内容："
  grep "hostname" "$SYSTEM_FILE"
fi

# -------------------- 创建uci初始化脚本，确保配置生效 --------------------
echo "创建uci初始化脚本，确保配置生效..."

UCI_DEFAULTS_DIR="package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEFAULTS_DIR"
cat <<EOF > "$UCI_DEFAULTS_DIR/99-custom-settings"
#!/bin/sh
# 强制设置主机名
uci set system.@system[0].hostname='$HOSTNAME'
# 强制设置IP地址
uci set network.lan.ipaddr='$TARGET_IP'
uci commit system
uci commit network
exit 0
EOF
chmod +x "$UCI_DEFAULTS_DIR/99-custom-settings"
echo "已创建uci初始化脚本，确保配置生效"

echo "DIY脚本执行完成"
