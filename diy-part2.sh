#!/bin/bash

set -euo pipefail
shopt -s extglob

# -------------------- 变量定义 --------------------

FORCE_HOSTNAME="CM520-79F"
FORCE_IP="192.168.5.1"
ADGUARD_PORT="5353"
ADGUARD_BIN="/usr/bin/AdGuardHome"
ADGUARD_CONF_DIR="/etc/AdGuardHome"
ADGUARD_CONF="$ADGUARD_CONF_DIR/AdGuardHome.yaml"
ERROR_LOG="/tmp/diy_error.log"

# AdGuardHome 最新发布API
ADGUARD_API="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"

# DTS路径及补丁
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/cm520-79f.patch"

GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# Nikki feed 地址
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"

# sirpdboy 插件仓库
SIRPDBOY_WATCHDOG="https://github.com/sirpdboy/luci-app-watchdog.git"
SIRPDBOY_PARTEXP="https://github.com/sirpdboy/luci-app-partexp.git"

# -------------------- 日志函数 --------------------

log_info() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
log_error() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$ERROR_LOG"
    exit 1
}

# -------------------- 初始化 --------------------

echo "===== DIY 脚本错误日志 =====" > "$ERROR_LOG"
echo "开始时间: $(date)" >> "$ERROR_LOG"
log_info "开始执行DIY脚本"

# -------------------- 1. 准备目录 --------------------

log_info "准备目录结构..."
mkdir -p \
    "$DTS_DIR" \
    "package/custom" \
    "package/base-files/files$ADGUARD_CONF_DIR" \
    "package/base-files/files/usr/bin" \
    "package/base-files/files/etc/uci-defaults" \
    "package/base-files/files/etc/config"
log_info "目录准备完成"

# -------------------- 2. 内核模块配置 --------------------

log_info "配置内核模块..."
for mod in CONFIG_PACKAGE_kmod-ubi CONFIG_PACKAGE_kmod-ubifs CONFIG_PACKAGE_trx CONFIG_PACKAGE_firewall3; do
    sed -i "/^#*${mod}/d" .config 2>/dev/null || true
    echo "$mod=y" >> .config
done
log_info "内核模块配置完成"

# -------------------- 3. 集成 Nikki --------------------

log_info "集成 Nikki 源..."
if ! grep -q "nikki.*$NIKKI_FEED" feeds.conf.default 2>/dev/null; then
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default || log_error "添加 Nikki 源失败"
fi
./scripts/feeds update nikki || log_error "Nikki 源更新失败"
./scripts/feeds install -a -p nikki || log_error "Nikki 包安装失败"
grep -q "^CONFIG_PACKAGE_nikki=y" .config || echo "CONFIG_PACKAGE_nikki=y" >> .config
grep -q "^CONFIG_PACKAGE_luci-app-nikki=y" .config || echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
log_info "Nikki 集成完成"

# -------------------- 4. 设备树补丁处理 --------------------

log_info "处理 DTS 补丁..."
[ -f "$TARGET_DTS" ] || log_error "目标 DTS 文件不存在：$TARGET_DTS"

if [ ! -f "$TARGET_DTS.backup" ]; then
    cp "$TARGET_DTS" "$TARGET_DTS.backup" || log_error "备份 DTS 文件失败"
    log_info "备份 DTS 到 $TARGET_DTS.backup"
else
    log_info "DTS 备份已存在，跳过备份"
fi

log_info "下载 DTS 补丁..."
wget -q --timeout=30 --tries=3 --retry-connrefused --connect-timeout=10 -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL" || log_error "下载 DTS 补丁失败"
[ -s "$DTS_PATCH_FILE" ] || log_error "DTS 补丁文件为空或损坏"

log_info "检查补丁兼容性..."
patch --dry-run -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" || log_error "补丁不兼容"

log_info "应用 DTS 补丁..."
patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" || log_error "应用 DTS 补丁失败"
rm -f "$DTS_PATCH_FILE"
log_info "DTS 补丁应用完成"

# -------------------- 5. 写入设备规则 --------------------

log_info "写入设备规则..."
if ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
    cat <<EOF >> "$GENERIC_MK"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to \$\$(KERNEL_SIZE) | append-rootfs | trx -o \$\@
endef

TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_info "设备规则添加成功"
else
    log_info "设备规则已存在，跳过添加"
fi

# -------------------- 6. 强制主机名和默认IP --------------------

log_info "配置主机名和默认 IP..."

HOSTNAME_FILE="package/base-files/files/etc/hostname"
echo "$FORCE_HOSTNAME" > "$HOSTNAME_FILE" || log_error "写入 hostname 失败"

SYSTEM_CONF="package/base-files/files/etc/config/system"
if [ ! -f "$SYSTEM_CONF" ]; then
    cat <<EOF > "$SYSTEM_CONF"
config system
    option hostname 'OpenWrt'
    option timezone 'UTC'
EOF
    log_info "系统配置文件新建完成"
fi
sed -i "s/option hostname.*/option hostname '$FORCE_HOSTNAME'/" "$SYSTEM_CONF" || sed -i "/config system/a \    option hostname '$FORCE_HOSTNAME'" "$SYSTEM_CONF"

NETWORK_CONF="package/base-files/files/etc/config/network"
if [ ! -f "$NETWORK_CONF" ]; then
    cat <<EOF > "$NETWORK_CONF"
config interface 'lan'
    option type 'bridge'
    option ifname 'eth0'
    option ipaddr '192.168.1.1'
    option netmask '255.255.255.0'
EOF
    log_info "网络配置文件新建完成"
fi
sed -i "s/option ipaddr[[:space:]]*['\"]*[0-9.]\+['\"]*/option ipaddr '$FORCE_IP'/" "$NETWORK_CONF" || log_error "修改默认IP失败"

# uci默认脚本
UCI_SCRIPT="package/base-files/files/etc/uci-defaults/99-force-ip-hostname"
cat <<EOF > "$UCI_SCRIPT"
#!/bin/sh
uci set network.lan.ipaddr='$FORCE_IP'
uci set system.@system[0].hostname='$FORCE_HOSTNAME'
uci commit network
uci commit system
/etc/init.d/network reload
exit 0
EOF
chmod +x "$UCI_SCRIPT"
log_info "默认主机名和IP配置完成"

# -------------------- 7. 集成 AdGuardHome --------------------

log_info "集成 AdGuardHome，端口：$ADGUARD_PORT"
ADGUARD_DIR="package/base-files/files$ADGUARD_BIN"
ADGUARD_TMP_DIR="/tmp/adguard"
ADGUARD_ARCHIVE="/tmp/adguard.tar.gz"

rm -rf "$ADGUARD_TMP_DIR" "$ADGUARD_ARCHIVE"

log_info "获取 AdGuardHome 最新armv7版本下载地址..."
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 "$ADGUARD_API" | grep '"browser_download_url":' | grep 'linux_armv7' | cut -d '"' -f 4)
[ -n "$ADGUARD_URL" ] || log_error "未找到有效的 AdGuardHome 下载链接"

log_info "下载 AdGuardHome..."
wget -q -O "$ADGUARD_ARCHIVE" "$ADGUARD_URL" || log_error "AdGuardHome 下载失败"
[ "$(stat -c%s "$ADGUARD_ARCHIVE")" -ge 102400 ] || log_error "AdGuardHome 包大小异常"

log_info "解压 AdGuardHome..."
mkdir -p "$ADGUARD_TMP_DIR"
tar -xzf "$ADGUARD_ARCHIVE" -C "$ADGUARD_TMP_DIR" || log_error "AdGuardHome 解压失败"

log_info "查找 AdGuardHome 二进制文件..."
ADGUARD_BIN_SRC=$(find "$ADGUARD_TMP_DIR" -type f -name AdGuardHome -executable | head -n1)
if [ -z "$ADGUARD_BIN_SRC" ]; then
    ADGUARD_BIN_SRC=$(find "$ADGUARD_TMP_DIR" -type f -name AdGuardHome | head -n1)
fi
[ -f "$ADGUARD_BIN_SRC" ] || log_error "AdGuardHome 二进制文件未找到"

log_info "复制二进制文件到 $ADGUARD_DIR"
mkdir -p "$(dirname "$ADGUARD_DIR")"
cp "$ADGUARD_BIN_SRC" "$ADGUARD_DIR" || log_error "复制二进制文件失败"
chmod +x "$ADGUARD_DIR" || log_error "设置执行权限失败"

log_info "生成 AdGuardHome 配置文件"
cat <<EOF > "package/base-files/files$ADGUARD_CONF"
bind_host: 0.0.0.0
bind_port: $ADGUARD_PORT
users:
  - name: admin
    password: \$2y\$10\$FoyiYiwQKRoJl9zzG7u0yeFpb4B8jVH4VkgrKauQuOV0WRnLNPXXi
language: zh-cn
upstream_dns:
  - 223.5.5.5
  - 114.114.114.114
EOF

log_info "创建 AdGuardHome 启动脚本"
SERVICE_SCRIPT="package/base-files/files/etc/init.d/adguardhome"
cat <<EOF > "$SERVICE_SCRIPT"
#!/bin/sh /etc/rc.common
START=95
STOP=15
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command $ADGUARD_BIN -c $ADGUARD_CONF
    procd_set_param respawn
    procd_close_instance
}
EOF
chmod +x "$SERVICE_SCRIPT" || log_error "设置 AdGuardHome 启动脚本权限失败"

log_info "修正 LuCI 配置，启动时识别 AdGuardHome"
LUCI_CONF="package/base-files/files/etc/config/luci"
touch "$LUCI_CONF"
if ! grep -q "adguardhome" "$LUCI_CONF"; then
    cat <<EOF >> "$LUCI_CONF"
config adguardhome 'main'
    option bin_path '$ADGUARD_BIN'
    option conf_path '$ADGUARD_CONF'
    option enabled '1'
EOF
fi

log_info "AdGuardHome 集成完成"

# -------------------- 8. 集成 sirpdboy 插件 --------------------

log_info "集成 sirpdboy 插件..."
rm -rf package/custom/luci-app-watchdog package/custom/luci-app-partexp

git clone --depth 1 "$SIRPDBOY_WATCHDOG" package/custom/luci-app-watchdog || log_error "拉取 luci-app-watchdog 失败"
git clone --depth 1 "$SIRPDBOY_PARTEXP" package/custom/luci-app-partexp || log_error "拉取 luci-app-partexp 失败"

./scripts/feeds update -a
./scripts/feeds install -a

echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> .config
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
log_info "sirpdboy 插件集成完成"

# -------------------- 9. 完成提示 --------------------

log_info "DIY脚本执行完成（所有功能均已集成且启用）"
