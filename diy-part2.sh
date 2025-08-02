#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# -------------------- 基础配置与变量定义（关键补充） --------------------
# 配置wget超时和重试参数，避免网络波动导致失败
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"

# 定义架构（适配mobipromo_cm520-79f）
ARCH="armv7"

# 定义核心目录路径（避免变量未定义错误）
OPENCLASH_CORE_DIR="package/luci-app-openclash/root/etc/openclash/core"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"

# 确保核心目录存在（避免后续下载失败）
mkdir -p "$OPENCLASH_CORE_DIR" "$ADGUARD_DIR"


# -------------------- 内核模块与工具配置 --------------------
# 添加所需内核模块和trx工具（生成固件必要）
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config


# -------------------- DTS补丁处理（核心修复） --------------------
# 下载并应用mobipromo_cm520-79f的DTS补丁
DTS_DIR="target/linux/ipq40xx/dts"
DTS_PATCH="mobipromo_cm520-79f.dts.patch"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"

# 创建DTS目录（确保存在）
mkdir -p "$DTS_DIR"

# 下载补丁文件（带错误处理）
echo "Downloading DTS patch for mobipromo_cm520-79f..."
if wget $WGET_OPTS -O "$DTS_DIR/$DTS_PATCH" "$DTS_PATCH_URL"; then
    echo "DTS patch downloaded successfully: $DTS_DIR/$DTS_PATCH"
else
    echo "Error: Failed to download DTS patch from $DTS_PATCH_URL"
    exit 1
fi

# 应用补丁到目标DTS文件（需与补丁实际目标匹配，此处假设为通用DTSI）
# 注意：若补丁目标文件不同，需修改TARGET_DTS（例如qcom-ipq40xx-mobipromo_cm520-79f.dts）
TARGET_DTS="qcom-ipq40xx-generic.dtsi"
if [ -f "$DTS_DIR/$TARGET_DTS" ]; then
    echo "Applying DTS patch to $TARGET_DTS..."
    # 补丁路径调整：-p1表示忽略补丁中的第一层目录（根据补丁内容调整）
    if patch -d "$DTS_DIR" -p1 < "$DTS_DIR/$DTS_PATCH"; then
        echo "DTS patch applied successfully"
    else
        echo "Error: Failed to apply DTS patch (可能目标文件不匹配，请检查TARGET_DTS)"
        exit 1
    fi
else
    echo "Error: Target DTS file $DTS_DIR/$TARGET_DTS not found (请确认源码中存在该文件)"
    exit 1
fi


# -------------------- 设备规则配置 --------------------
# 为mobipromo_cm520-79f添加trx生成规则
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
if grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    # 插入分区大小（根据设备实际Flash大小调整）
    sed -i '/define Device\/mobipromo_cm520-79f/ a\  KERNEL_SIZE := 4096k\n  ROOTFS_SIZE := 16384k' "$GENERIC_MK"
    # 插入trx固件生成逻辑
    sed -i '/define Device\/mobipromo_cm520-79f/,/endef/ {
        /IMAGE\// a\  IMAGE/trx := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | trx -o $@
    }' "$GENERIC_MK"
    echo "Successfully added trx rules for mobipromo_cm520-79f"
else
    echo "Error: Device mobipromo_cm520-79f not found in $GENERIC_MK（源码可能不支持该设备）"
    exit 1
fi


# -------------------- 集成OpenClash内核 --------------------
echo "开始集成OpenClash内核..."

# 清理历史内核文件（避免版本冲突）
rm -rf "$OPENCLASH_CORE_DIR"/*

# 下载mihomo（原Clash Meta）
echo "尝试获取最新mihomo内核地址..."
META_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | 
           grep "browser_download_url.*linux-$ARCH" | 
           grep -v -E "deb|rpm|pkg|gz" |  # 排除包格式和压缩包
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
        # 解压并忽略未知关键字警告（兼容不同tar版本）
        if tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$ADGUARD_DIR" --strip-components=1 --warning=no-unknown-keyword; then
            chmod +x "$ADGUARD_DIR/AdGuardHome"
            rm -f "$ADGUARD_DIR/AdGuardHome.tar.gz"  # 清理压缩包
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

# 清理旧插件目录（避免缓存冲突）
rm -rf package/custom/luci-app-watchdog
rm -rf package/custom/luci-app-partexp

# 克隆插件源码（带错误处理）
if ! git clone --depth 1 https://github.com/sirpdboy/luci-app-watchdog package/custom/luci-app-watchdog; then
    echo "错误：克隆luci-app-watchdog失败"
    exit 1
fi

if ! git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp package/custom/luci-app-partexp; then
    echo "错误：克隆luci-app-partexp失败"
    exit 1
fi

# 更新feeds并安装插件（确保新插件被识别）
./scripts/feeds update -a
./scripts/feeds install -a

# 强制启用插件（确保编译时包含）
echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> .config
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config


# -------------------- 修改默认配置 --------------------
# 修改默认IP（避免与其他设备冲突）
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate

# 修改主机名（标识设备）
sed -i 's/OpenWrt/CM520-79F/g' package/base-files/files/bin/config_generate


echo "DIY脚本执行完成"
