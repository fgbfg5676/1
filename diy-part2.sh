#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# 配置wget超时和重试参数，增强网络兼容性
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"

# 定义必要目录变量（关键修复：补充缺失变量）
OPENCLASH_CORE_DIR="package/luci-app-openclash/root/etc/openclash/core"
ARCH="armv7"  # 根据设备架构调整（当前适配mobipromo_cm520-79f）
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"

# 确保核心目录存在
mkdir -p "$OPENCLASH_CORE_DIR" "$ADGUARD_DIR"

# 添加所需内核模块和 trx 工具
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

# -------------------- 集成 OpenClash 内核 --------------------
echo "开始集成 OpenClash 内核..."

# 清理历史内核文件（避免残留冲突）
rm -rf "$OPENCLASH_CORE_DIR"/*

# 下载 mihomo (原 Clash Meta)
echo "尝试获取最新 mihomo 内核地址..."
# 注：若频繁失败，可添加 -H "Authorization: token YOUR_GITHUB_TOKEN" 提升API限额
META_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | 
           grep "browser_download_url.*linux-$ARCH" | 
           grep -v -E "deb|rpm|pkg|gz" |  # 排除包格式和压缩包（优先二进制）
           cut -d '"' -f 4)

if [ -n "$META_URL" ]; then
    echo "下载 mihomo (原 Clash Meta): $META_URL"
    if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta" "$META_URL"; then
        chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
        echo "mihomo 内核下载成功"
    else
        echo "警告：主链接下载失败，尝试备选链接"
        META_BACKUP="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-armv7-v1.19.12.gz"
        if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta.gz" "$META_BACKUP"; then
            gunzip -f "$OPENCLASH_CORE_DIR/clash_meta.gz"  # 强制覆盖现有文件
            chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
            echo "备选链接 mihomo 内核下载成功"
        else
            echo "错误：mihomo 内核下载失败，将影响 OpenClash 功能"
        fi
    fi
else
    echo "警告：未获取到最新 mihomo 地址，直接使用备选链接"
    META_BACKUP="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-armv7-v1.19.12.gz"
    if wget $WGET_OPTS -O "$OPENCLASH_CORE_DIR/clash_meta.gz" "$META_BACKUP"; then
        gunzip -f "$OPENCLASH_CORE_DIR/clash_meta.gz"
        chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
    else
        echo "错误：mihomo 内核下载失败，将影响 OpenClash 功能"
    fi
fi

echo "OpenClash 内核集成步骤完成"

# -------------------- 集成 AdGuardHome 核心 --------------------
echo "开始集成 AdGuardHome 核心..."

# 清理历史文件
rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz"

# 下载 AdGuardHome 核心
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest |
              grep "browser_download_url.*linux_armv7" |
              cut -d '"' -f 4)

if [ -n "$ADGUARD_URL" ]; then
    echo "下载 AdGuardHome: $ADGUARD_URL"
    if wget $WGET_OPTS -O "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_URL"; then
        # 兼容不同tar版本，忽略未知关键字警告
        if tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$ADGUARD_DIR" --strip-components=1 --warning=no-unknown-keyword; then
            chmod +x "$ADGUARD_DIR/AdGuardHome"
            rm -f "$ADGUARD_DIR/AdGuardHome.tar.gz"  # 清理压缩包
            echo "AdGuardHome 核心下载并解压成功"
        else
            echo "警告：AdGuardHome 解压失败，清理无效文件"
            rm -f "$ADGUARD_DIR/AdGuardHome.tar.gz"
        fi
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

echo "DIY 脚本执行完成"
