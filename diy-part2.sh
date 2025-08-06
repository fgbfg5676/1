#!/bin/bash
#
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
#
set -e  # 遇到错误立即退出脚本

# -------------------- 基础配置与变量定义 --------------------
# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"

# 确保所有路径变量都有明确值，避免为空
OPENCLASH_CORE_DIR="package/luci-app-openclash/root/etc/openclash/core"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
ADGUARD_CONFIG_DIR="package/luci-app-adguardhome/root/etc/adguardhome"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
NEW_DNS_PORT=5553

# 逐个创建目录，避免因某个变量为空导致整体失败
mkdir -p "$OPENCLASH_CORE_DIR"
mkdir -p "$ADGUARD_DIR"
mkdir -p "$ADGUARD_CONFIG_DIR"
mkdir -p "$DTS_DIR"
# -------------------- 内核模块与工具配置 --------------------
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# -------------------- 集成Nikki（采用官方feeds方式） --------------------
echo "开始通过官方源集成Nikki..."

# 1. 添加Nikki官方源（确保在feeds中生效）
echo "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" >> feeds.conf.default

# 2. 更新并安装Nikki相关包
./scripts/feeds update nikki
./scripts/feeds install -a -p nikki

# 3. 在.config中启用Nikki核心组件及依赖
echo "CONFIG_PACKAGE_nikki=y" >> .config                  # 核心程序
echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config        # Web管理界面
echo "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y" >> .config # 中文语言包

# 4. 强制启用Nikki依赖的内核模块和工具（根据官方README依赖列表）
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

# -------------------- 集成AdGuardHome核心并修改DNS端口 --------------------
echo "开始集成AdGuardHome核心并修改DNS端口为$NEW_DNS_PORT..."

# 清理历史文件
rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml"

# 下载AdGuardHome核心
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest |
              grep "browser_download_url.*linux_armv7" |
              cut -d '"' -f 4)

if [ -n "$ADGUARD_URL" ]; then
    echo "下载AdGuardHome: $ADGUARD_URL"
    if wget $WGET_OPTS -O "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_URL"; then
        # 解压到临时目录
        TMP_DIR=$(mktemp -d)
        tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword
        
        # 查找可执行文件并复制
        ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -n 1)
        if [ -n "$ADG_EXE" ]; then
            cp "$ADG_EXE" "$ADGUARD_DIR/"
            chmod +x "$ADGUARD_DIR/AdGuardHome"
            
            # 提取默认配置文件并修改DNS端口
            ADG_CONFIG=$(find "$TMP_DIR" -name "AdGuardHome.yaml" -type f | head -n 1)
            if [ -n "$ADG_CONFIG" ]; then
                # 复制配置文件到目标目录
                cp "$ADG_CONFIG" "$ADGUARD_CONFIG_DIR/"
                
                # 修改DNS端口（处理两种配置格式）
                # 格式1: 处理addresses中的端口（如0.0.0.0:53）
                sed -i "s/0.0.0.0:53/0.0.0.0:$NEW_DNS_PORT/g" "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml"
                # 格式2: 处理独立的port字段
                sed -i "/^  port: 53$/s/53/$NEW_DNS_PORT/" "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml"
                
                echo "AdGuardHome DNS端口已修改为$NEW_DNS_PORT"
            else
                echo "警告：未找到AdGuardHome配置文件，无法修改端口"
            fi
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
