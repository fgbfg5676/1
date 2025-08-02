#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# 配置wget超时和重试参数，增强网络兼容性
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"

# 定义必要必要目录变量
OPENCLASH_CORE_DIR="package/luci-app-openclash/root/etc/openclash/core"
ARCH="armv7"  # 适配mobipromo_cm520-79f架构
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"

# 确保核心目录存在
mkdir -p "$OPENCLASH_CORE_DIR" "$ADGUARD_DIR"

# 添加所需内核模块和trx工具
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# 使用仓库根目录的本地DTS文件
DTS_DIR="target/linux/ipq40xx/dts"
LOCAL_DTS="qcom-ipq4019-cm520-79f.dts"  # 仓库根目录中的DTS文件
TARGET_DTS="qcom-ipq40xx-mobipromo_cm520-79f.dts"  # 目标文件名（与设备定义匹配）

# 创建DTS目录（若不存在）
mkdir -p "$DTS_DIR"

# 检查并复制本地DTS文件（使用绝对路径确保定位正确）
LOCAL_DTS_PATH="$GITHUB_WORKSPACE/$LOCAL_DTS"
if [ -f "$LOCAL_DTS_PATH" ]; then
    cp "$LOCAL_DTS_PATH" "$DTS_DIR/$TARGET_DTS"
    echo "已将本地DTS文件复制到：$DTS_DIR/$TARGET_DTS"
else
    echo "错误：未找到DTS文件 $LOCAL_DTS_PATH，请检查仓库根目录"
    exit 1
fi

# 为mobipromo_cm520-79f设备添加trx生成规则
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
if grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    # 替换现有规则（避免重复添加）
    sed -i '/define Device\/mobipromo_cm520-79f/ {
        N;N;N;  # 跳过现有行
        s/define Device\/mobipromo_cm520-79f.*/define Device\/mobipromo_cm520-79f\n  KERNEL_SIZE := 4096k\n  ROOTFS_SIZE := 16384k/
    }' "$GENERIC_MK"
    # 添加TRX生成规则
    sed -i '/define Device\/mobipromo_cm520-79f/,/endef/ {
        /IMAGE\// a\  IMAGE/trx := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | trx -o $@
    }' "$GENERIC_MK"
    echo "Successfully added trx rules for mobipromo_cm520-79f"
else
    echo "Error: Device mobipromo_cm520-79f not found in $GENERIC_MK"
    exit 1
fi

# -------------------- 集成OpenClash内核 --------------------
echo "开始集成OpenClash内核..."

# 清理历史内核文件
rm -rf "$OPENCLASH_CORE_DIR"/*

# 下载mihomo（原Clash Meta）
echo "尝试获取最新mihomo内核地址..."
META_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | 
           grep "browser_download_url.*linux-$ARCH" | 
           grep -v -E "deb|rpm|pkg|gz" | 
           cut -d '"' -f 4)

if [ -n "$META_URL" ]; then
    echo "下载mihomo: $META_URL"
    if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta" "$META_URL"; then
        chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
        echo "mihomo内核下载成功"
    else
        echo "警告：主链接下载失败，尝试备选链接"
        META_BACKUP="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-armv7-v1.19.12.gz"
        if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta.gz" "$META_BACKUP"; then
            gunzip -f "$OPENCLASH_CORE_DIR/clash_meta.gz"
            chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
            echo "备选链接mihomo内核下载成功"
        else
            echo "错误：mihomo内核下载失败，将影响OpenClash功能"
        fi
    fi
else
    echo "警告：未获取到最新mihomo地址，使用备选链接"
    META_BACKUP="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-armv7-v1.19.12.gz"
    if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta.gz" "$META_BACKUP"; then
        gunzip -f "$OPENCLASH_CORE_DIR/clash_meta.gz"
        chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
    else
        echo "错误：mihomo内核下载失败，将影响OpenClash功能"
    fi
fi

echo "OpenClash内核集成完成"

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
        # 解压并忽略未知关键字警告
        if tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$ADGUARD_DIR" --strip-components=1 --warning=no-unknown-keyword; then
            chmod +x "$ADGUARD_DIR/AdGuardHome"
            rm -f "$ADGUARD_DIR/AdGuardHome.tar.gz"
            echo "AdGuardHome核心下载并解压成功"
        else
            echo "警告：AdGuardHome解压失败，清理无效文件"
            rm -f "$ADGUARD_DIR/AdGuardHome.tar.gz"
        fi
    else
        echo "警告：AdGuardHome下载失败"
    fi
else
    echo "警告：未找到AdGuardHome核心地址"
fi

echo "AdGuardHome核心集成完成"

# -------------------- 集成sirpdboy的插件 --------------------
echo "开始集成sirpdboy插件..."

# 创建自定义插件目录
mkdir -p package/custom

# 清理旧插件目录
rm -rf package/custom/luci-app-watchdog
rm -rf package/custom/luci-app-partexp

# 克隆插件源码
git clone --depth 1 https://github.com/sirpdboy/luci-app-watchdog package/custom/luci-app-watchdog
git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp package/custom/luci-app-partexp

# 更新feeds并安装插件
./scripts/feeds update -a
./scripts/feeds install -a

# 强制启用插件
echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> .config
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config

# 修改默认配置
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate  # 默认IP
sed -i 's/OpenWrt/CM520-79F/g' package/base-files/files/bin/config_generate        # 主机名

echo "DIY脚本执行完成"
