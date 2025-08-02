#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# 配置wget超时和重试参数，增强网络兼容性（统统一定义一次）
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"

# 添加加所需内核模块和 trx 工具
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# 下载并部署 mobipromo_cm520-79f 的 DTS 文件
DTS_DIR="target/linux/ipq40xx/dts"
DTS_FILE="qcom-ipq40xx-mobipromo_cm520-79f.dts"
DTS_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"

mkdir -p "$DTS_DIR"
echo "Downloading DTS file for mobipromo_cm520-79f..."
if wget $WGET_OPTS -O "$DTS_DIR/$DTS_FILE" "$DTS_URL"; then
    echo "DTS file downloaded successfully: $DTS_DIR/$DTS_FILE"
else
    echo "Error: Failed to download DTS file from $DTS_URL"
    exit 1
fi

# 为 mobipromo_cm520-79f 设备添加 trx 生成规则
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
if grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    sed -i '/define Device\/mobipromo_cm520-79f/ a\  KERNEL_SIZE := 4096k\n  ROOTFS_SIZE := 16384k' "$GENERIC_MK"
    sed -i '/define Device\/mobipromo_cm520-79f/,/endef/ {
        /IMAGE\// a\  IMAGE/trx := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | trx -o $@
    }' "$GENERIC_MK"
    echo "Successfully added trx rules for mobipromo_cm520-79f"
else
    echo "Error: Device mobipromo_cm520-79f not found in $GENERIC_MK"
    exit 1
fi

# -------------------- 集成 OpenClash 内核 --------------------
echo "开始集成 OpenClash 内核..."
OPENCLASH_CORE_DIR="package/luci-app-openclash/root/etc/openclash/core"
mkdir -p "$OPENCLASH_CORE_DIR"
ARCH="armv7"

# 下载 Clash Premium
PREMIUM_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/Dreamacro/clash/releases/tags/premium | 
              grep "browser_download_url.*linux-$ARCH" | 
              cut -d '"' -f 4)
if [ -n "$PREMIUM_URL" ]; then
    echo "下载 Clash Premium: $PREMIUM_URL"
    if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash" "$PREMIUM_URL"; then
        chmod +x "$OPENCLASH_CORE_DIR/clash"
    else
        echo "警告：Clash Premium 下载失败，尝试备选链接"
        PREMIUM_BACKUP="https://github.com/Dreamacro/clash/releases/download/premium/clash-linux-armv7-v1.18.0.gz"
        if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash.gz" "$PREMIUM_BACKUP"; then
            gunzip "$OPENCLASH_CORE_DIR/clash.gz"
            chmod +x "$OPENCLASH_CORE_DIR/clash"
        else
            echo "警告：备选链接失败，Clash Premium 未集成"
        fi
    fi
else
    echo "警告：未找到 Clash Premium 内核地址"
fi

# 下载 mihomo (原 Clash Meta)
META_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | 
           grep "browser_download_url.*linux-$ARCH" | 
           cut -d '"' -f 4)
if [ -n "$META_URL" ]; then
    echo "下载 mihomo (原 Clash Meta): $META_URL"
    if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta" "$META_URL"; then
        chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
    else
        echo "警告：mihomo 下载失败，尝试备选链接"
        META_BACKUP="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-armv7-v1.19.12.gz"
        if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta.gz" "$META_BACKUP"; then
            gunzip "$OPENCLASH_CORE_DIR/clash_meta.gz"
            chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
        else
            echo "警告：备选链接失败，mihomo 未集成"
        fi
    fi
else
    echo "警告：未找到 mihomo 内核地址"
fi
echo "OpenClash 内核集成步骤完成"

# -------------------- 集成 AdGuardHome 核心 --------------------
echo "开始集成 AdGuardHome 核心..."
# 修复：调整匹配规则（linux_armv7）并处理压缩包
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest |
              grep "browser_download_url.*linux_armv7" |  # 修正匹配规则（下划线+小写）
              cut -d '"' -f 4)
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
mkdir -p "$ADGUARD_DIR"

if [ -n "$ADGUARD_URL" ]; then
    echo "下载 AdGuardHome: $ADGUARD_URL"
    # 修复：下载压缩包并解压
    if wget $WGET_OPTS -O "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_URL"; then
        # 解压并提取可执行文件（--strip-components=1 移除顶层目录）
        tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$ADGUARD_DIR" --strip-components=1
        chmod +x "$ADGUARD_DIR/AdGuardHome"
        rm "$ADGUARD_DIR/AdGuardHome.tar.gz"  # 清理压缩包
    else
        echo "警告：AdGuardHome 下载失败"
    fi
else
    echo "警告：未找到 AdGuardHome 核心地址"
fi
echo "AdGuardHome 核心集成步骤完成"


# 修改默认IP、主机名等
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate
sed -i 's/OpenWrt/CM520-79F/g' package/base-files/files/bin/config_generate
