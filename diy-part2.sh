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

# 确保所有路径变量都有明确值，避免为空
OPENCLASH_CORE_DIR="package/luci-app-openclash/root/etc/openclash/core"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
ADGUARD_CONFIG_DIR="package/luci-app-adguardhome/root/etc/adguardhome"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
NEW_DNS_PORT=5553  # 自定义DNS端口，避免冲突

# 逐个创建目录，增加错误提示
echo "创建必要目录..."
for dir in "$OPENCLASH_CORE_DIR" "$ADGUARD_DIR" "$ADGUARD_CONFIG_DIR" "$DTS_DIR"; do
    if ! mkdir -p "$dir"; then
        echo "错误：无法创建目录 $dir"
        exit 1
    fi
done

# -------------------- 内核模块与工具配置 --------------------
echo "配置内核模块..."
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# -------------------- 集成Nikki（采用官方feeds方式） --------------------
echo "开始通过官方源集成Nikki..."

# 1. 添加Nikki官方源（确保在feeds中生效）
if ! grep -q "nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" feeds.conf.default; then
    echo "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" >> feeds.conf.default
fi

# 2. 更新并安装Nikki相关包
./scripts/feeds update nikki || { echo "错误：更新Nikki源失败"; exit 1; }
./scripts/feeds install -a -p nikki || { echo "错误：安装Nikki包失败"; exit 1; }

# 3. 在.config中启用Nikki核心组件及依赖
echo "CONFIG_PACKAGE_nikki=y" >> .config                  # 核心程序
echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config        # Web管理界面
echo "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y" >> .config # 中文语言包

# 4. 强制启用Nikki依赖的内核模块和工具
echo "CONFIG_PACKAGE_ca-bundle=y" >> .config
echo "CONFIG_PACKAGE_curl=y" >> .config
echo "CONFIG_PACKAGE_yq=y" >> .config
echo "CONFIG_PACKAGE_firewall4=y" >> .config
echo "CONFIG_PACKAGE_ip-full=y" >> .config
echo "CONFIG_PACKAGE_kmod-inet-diag=y" >> .config
echo "CONFIG_PACKAGE_kmod-nft-socket=y" >> .config
echo "CONFIG_PACKAGE_kmod-nft-tproxy=y" >> .config
echo "CONFIG_PACKAGE_kmod-tun=y" >> .config

echo "Nikki通过官方源集成完成"

# -------------------- DTS补丁处理 --------------------
echo "处理DTS补丁..."
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"

if ! wget $WGET_OPTS -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL"; then
    echo "警告：DTS补丁下载失败，使用默认DTS文件"
else
    if [ ! -f "$TARGET_DTS" ]; then
        echo "应用DTS补丁..."
        if ! patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"; then
            echo "警告：DTS补丁应用失败，使用默认DTS文件"
        fi
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

# -------------------- 集成AdGuardHome核心并修改DNS端口 --------------------
echo "开始集成AdGuardHome核心并修改DNS端口为$NEW_DNS_PORT..."

# 清理历史文件
rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml"

# 下载AdGuardHome核心
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest |
              grep "browser_download_url.*linux_armv7" |
              cut -d '"' -f 4)

if [ -z "$ADGUARD_URL" ]; then
    echo "警告：未找到AdGuardHome核心地址，使用默认版本"
    ADGUARD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.64/AdGuardHome_linux_armv7.tar.gz"
fi

echo "下载AdGuardHome: $ADGUARD_URL"
if wget $WGET_OPTS -O "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_URL"; then
    # 解压到临时目录
    TMP_DIR=$(mktemp -d)
    if ! tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword; then
        echo "错误：AdGuardHome解压失败"
        rm -rf "$TMP_DIR"
        exit 1
    fi
    
    # 查找可执行文件并复制
    ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -n 1)
    if [ -z "$ADG_EXE" ]; then
        echo "错误：未找到AdGuardHome可执行文件"
        rm -rf "$TMP_DIR"
        exit 1
    fi
    
    cp "$ADG_EXE" "$ADGUARD_DIR/"
    chmod +x "$ADGUARD_DIR/AdGuardHome"
    echo "AdGuardHome可执行文件已复制"
    
    # 处理配置文件和端口修改
    ADG_CONFIG=$(find "$TMP_DIR" -name "AdGuardHome.yaml" -type f | head -n 1)
    if [ -n "$ADG_CONFIG" ]; then
        cp "$ADG_CONFIG" "$ADGUARD_CONFIG_DIR/"
        # 修改DNS端口（处理多种配置格式）
        sed -i.bak "s/:53/:$NEW_DNS_PORT/g" "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml"
        sed -i.bak "/^port: 53$/s/53/$NEW_DNS_PORT/" "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml"
        rm -f "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml.bak"
        echo "AdGuardHome DNS端口已修改为$NEW_DNS_PORT"
    else
        echo "未找到默认配置文件，创建新配置并设置端口"
        cat <<EOF > "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml"
bind_host: 0.0.0.0
bind_port: 3000
dns:
  bind_host: 0.0.0.0
  port: $NEW_DNS_PORT
  addresses:
    - 0.0.0.0:$NEW_DNS_PORT
  bootstrap_dns:
    - 114.114.114.114:53
    - 8.8.8.8:53
EOF
        echo "已创建新配置文件，DNS端口设为$NEW_DNS_PORT"
    fi
    
    # 清理临时文件
    rm -rf "$TMP_DIR" "$ADGUARD_DIR/AdGuardHome.tar.gz"
else
    echo "错误：AdGuardHome下载失败"
    exit 1
fi

echo "AdGuardHome核心集成完成"

# -------------------- 插件集成 --------------------
echo "集成sirpdboy插件..."
mkdir -p package/custom
rm -rf package/custom/luci-app-partexp

if ! git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git package/custom/luci-app-partexp; then
    echo "警告：luci-app-partexp克隆失败，跳过该插件"
else
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
fi

# -------------------- 修改默认配置 --------------------
echo "修改默认系统配置..."
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate
sed -i 's/OpenWrt/CM520-79F/g' package/base-files/files/bin/config_generate

echo "DIY脚本执行完成"
