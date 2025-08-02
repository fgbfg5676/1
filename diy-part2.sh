#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# 添加所需内核模块和 trx 工具
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# 下载并应用 mobipromo_cm520-79f 的 DTS 补丁
DTS_DIR="target/linux/ipq40xx/dts"
DTS_PATCH="mobipromo_cm520-79f.dts.patch"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"  # 明确为补丁文件

# 创建 DTS 目录（若不存在）
mkdir -p "$DTS_DIR"

# 下载补丁文件
echo "Downloading DTS patch for mobipromo_cm520-79f..."
if wget -q -O "$DTS_DIR/$DTS_PATCH" "$DTS_PATCH_URL"; then
    echo "DTS patch downloaded successfully: $DTS_DIR/$DTS_PATCH"
else
    echo "Error: Failed to download DTS patch from $DTS_PATCH_URL"
    exit 1
fi

# 应用补丁到目标DTS文件（假设基于qcom-ipq40xx-generic.dtsi修改）
# 注意：需根据补丁实际目标文件调整下面的路径
TARGET_DTS="qcom-ipq40xx-generic.dtsi"
if [ -f "$DTS_DIR/$TARGET_DTS" ]; then
    echo "Applying DTS patch to $TARGET_DTS..."
    patch -d "$DTS_DIR" -p1 < "$DTS_DIR/$DTS_PATCH"
    if [ $? -eq 0 ]; then
        echo "DTS patch applied successfully"
    else
        echo "Error: Failed to apply DTS patch"
        exit 1
    fi
else
    echo "Error: Target DTS file $DTS_DIR/$TARGET_DTS not found"
    exit 1
fi

# 为 mobipromo_cm520-79f 设备添加 trx 生成规则
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
if grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    # 插入分区大小（根据DTS实际分区定义调整）
    sed -i '/define Device\/mobipromo_cm520-79f/ a\  KERNEL_SIZE := 4096k\n  ROOTFS_SIZE := 16384k' "$GENERIC_MK"
    # 插入 trx 固件生成逻辑
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
