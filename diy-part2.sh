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

ADGUARD_API="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"

DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/cm520-79f.patch"

GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"

SIRPDBOY_WATCHDOG="https://github.com/sirpdboy/luci-app-watchdog.git"
SIRPDBOY_PARTEXP="https://github.com/sirpdboy/luci-app-partexp.git"

BASE_FILES="package/base-files/files"

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

# ========== 1. 准备目录（成功脚本方式） ==========

log_info "准备目录结构..."
mkdir -p \
    "$DTS_DIR" \
    "package/custom" \
    "$BASE_FILES$ADGUARD_CONF_DIR" \
    "$BASE_FILES/usr/bin" \
    "$BASE_FILES/etc/uci-defaults" \
    "$BASE_FILES/etc/config" \
    "$BASE_FILES/etc/init.d"
log_info "目录准备完成"

# ========== 2. 内核模块配置（成功脚本简化追加） ==========

log_info "配置内核模块..."
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config
echo "CONFIG_PACKAGE_firewall3=y" >> .config
log_info "内核模块配置完成"

# ========== 3. 集成 Nikki ==========

log_info "集成 Nikki 源..."
if ! grep -q "nikki.*$NIKKI_FEED" feeds.conf.default 2>/dev/null; then
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default || log_error "添加 Nikki 源失败"
fi

./scripts/feeds update nikki || log_error "Nikki 源更新失败"
./scripts/feeds install -a -p nikki || log_error "Nikki 包安装失败"

grep -q "^CONFIG_PACKAGE_nikki=y" .config || echo "CONFIG_PACKAGE_nikki=y" >> .config
grep -q "^CONFIG_PACKAGE_luci-app-nikki=y" .config || echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
log_info "Nikki 集成完成"

# ========== 4. DTS补丁处理（失败脚本方式） ==========

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

# ========== 5. 写入设备规则（成功脚本方式简洁追加） ==========

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

# ========== 6. 默认主机名和IP配置（保持失败脚本方式） ==========

log_info "配置主机名和默认 IP..."

HOSTNAME_FILE="$BASE_FILES/etc/hostname"
echo "$FORCE_HOSTNAME" > "$HOSTNAME_FILE" || log_error "写入 hostname 失败"

SYSTEM_CONF="$BASE_FILES/etc/config/system"
if [ ! -f "$SYSTEM_CONF" ]; then
    cat <<EOF > "$SYSTEM_CONF"
config system
    option hostname 'OpenWrt'
    option timezone 'UTC'
EOF
    log_info "系统配置文件新建完成"
fi
sed -i "s/option hostname.*/option hostname '$FORCE_HOSTNAME'/" "$SYSTEM_CONF" || sed -i "/config system/a \    option hostname '$FORCE_HOSTNAME'" "$SYSTEM_CONF"

NETWORK_CONF="$BASE_FILES/etc/config/network"
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

UCI_SCRIPT="$BASE_FILES/etc/uci-defaults/99-force-ip-hostname"
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

# ========== 7. 集成 AdGuardHome 二进制（保持失败脚本方式） ==========

log_info "集成 AdGuardHome 二进制（防冲突模式）..."

# 移除 .config 中启用的 adguardhome 包选项避免冲突
if grep -q "^CONFIG_PACKAGE_adguardhome=y" .config 2>/dev/null; then
    log_info "检测到 .config 启用了 adguardhome 包，正在移除"
    sed -i '/^CONFIG_PACKAGE_adguardhome=y/d' .config
else
    log_info ".config 没有启用 adguardhome 包"
fi

# 清理旧编译残留，避免文件冲突
log_info "清理旧编译残留，避免文件冲突"
make clean || true
rm -rf build_dir/target-*/* root-* || true

# 创建 AdGuardHome 相关目录
mkdir -p "$BASE_FILES/usr/bin" "$BASE_FILES$ADGUARD_CONF_DIR" "$BASE_FILES/etc/init.d" "$BASE_FILES/etc/config"

# 获取最新 AdGuardHome armv7 版本下载地址
log_info "获取 AdGuardHome 最新 armv7 版本下载地址..."
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 "$ADGUARD_API" | grep '"browser_download_url":' | grep 'linux_armv7' | cut -d '"' -f 4)
[ -n "$ADGUARD_URL" ] || log_error "未找到有效的 AdGuardHome 下载链接"

TMP_DIR=$(mktemp -d)
TMP_ARCHIVE="$TMP_DIR/adguard.tar.gz"

log_info "下载 AdGuardHome..."
wget -q -O "$TMP_ARCHIVE" "$ADGUARD_URL" || { rm -rf "$TMP_DIR"; log_error "AdGuardHome 下载失败"; }

log_info "解压 AdGuardHome..."
tar -xzf "$TMP_ARCHIVE" -C "$TMP_DIR" || { rm -rf "$TMP_DIR"; log_error "解压失败"; }

ADGUARD_BIN_SRC=$(find "$TMP_DIR" -type f -name AdGuardHome -executable | head -n1)
if [ -z "$ADGUARD_BIN_SRC" ]; then
    ADGUARD_BIN_SRC=$(find "$TMP_DIR" -type f -name AdGuardHome | head -n1)
fi
[ -f "$ADGUARD_BIN_SRC" ] || { rm -rf "$TMP_DIR"; log_error "AdGuardHome 二进制文件未找到"; }

log_info "复制二进制文件到 $BASE_FILES/usr/bin/AdGuardHome"
cp "$ADGUARD_BIN_SRC" "$BASE_FILES/usr/bin/AdGuardHome" || { rm -rf "$TMP_DIR"; log_error "复制失败"; }
chmod +x "$BASE_FILES/usr/bin/AdGuardHome"

# 生成配置文件
log_info "生成 AdGuardHome 配置文件"
cat <<EOF > "$BASE_FILES$ADGUARD_CONF_DIR/AdGuardHome.yaml"
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

# 生成启动脚本
log_info "生成 AdGuardHome 启动脚本"
cat <<EOF > "$BASE_FILES/etc/init.d/adguardhome"
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
chmod +x "$BASE_FILES/etc/init.d/adguardhome"

# LuCI 配置支持
LUCI_CONF="$BASE_FILES/etc/config/luci"
touch "$LUCI_CONF"
if ! grep -q "adguardhome" "$LUCI_CONF"; then
    cat <<EOF >> "$LUCI_CONF"

config adguardhome 'main'
    option bin_path '$ADGUARD_BIN'
    option conf_path '$ADGUARD_CONF'
    option enabled '1'
EOF
fi

rm -rf "$TMP_DIR"
log_info "AdGuardHome 集成完成"

# ========== 8. 集成 sirpdboy 插件（保持失败脚本方式） ==========

log_info "集成 sirpdboy 插件..."
rm -rf package/custom/luci-app-watchdog package/custom/luci-app-partexp

git clone --depth 1 "$SIRPDBOY_WATCHDOG" package/custom/luci-app-watchdog || log_error "拉取 luci-app-watchdog 失败"
git clone --depth 1 "$SIRPDBOY_PARTEXP" package/custom/luci-app-partexp || log_error "拉取 luci-app-partexp 失败"

./scripts/feeds update -a
./scripts/feeds install -a

echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> .config
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
log_info "sirpdboy 插件集成完成"

# ========== 9. 脚本执行完成 ==========

log_info "DIY脚本执行完成（所有功能均已集成且启用）"
