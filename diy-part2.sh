#!/bin/bash
set -euo pipefail
shopt -s extglob

# -------------------- 核心配置 --------------------
FORCE_HOSTNAME="CM520-79F"
FORCE_IP="192.168.5.1"
ADGUARD_PORT="5353"
ADGUARD_BIN="/usr/bin/AdGuardHome"
ADGUARD_CONF_DIR="/etc/AdGuardHome"
ADGUARD_CONF="$ADGUARD_CONF_DIR/AdGuardHome.yaml"
ERROR_LOG="/tmp/diy_error.log"

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
log_error() { 
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$ERROR_LOG"
    exit 1
}

# -------------------- 初始化错误日志 --------------------
echo "===== DIY脚本错误日志 =====" > "$ERROR_LOG"
echo "开始时间: $(date)" >> "$ERROR_LOG"

# -------------------- 1. 创建必要目录（含系统配置文件目录） --------------------
log_info "创建必要目录..."
# 确保系统配置文件目录存在（关键修复）
mkdir -p \
    "target/linux/ipq40xx/files/arch/arm/boot/dts" \
    "package/custom" \
    "package/base-files/files$ADGUARD_CONF_DIR" \
    "package/base-files/files/usr/bin" \
    "package/base-files/files/etc/uci-defaults" \
    "package/base-files/files/etc/config"  # 确保/etc/config目录存在
log_info "必要目录创建完成"

# -------------------- 2. 配置内核模块 --------------------
log_info "配置内核模块..."
REQUIRED_MODULES=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
    "CONFIG_PACKAGE_firewall3=y"
)
for mod in "${REQUIRED_MODULES[@]}"; do
    mod_key=$(echo "$mod" | cut -d'=' -f1)
    sed -i "/^#*${mod_key}/d" .config || log_error "修改.config失败（内核模块）"
    echo "$mod" >> .config || log_error "写入.config失败（$mod）"
done
log_info "内核模块配置完成"

# -------------------- 3. 集成Nikki --------------------
log_info "开始通过官方源集成Nikki..."
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
if ! grep -q "nikki.*$NIKKI_FEED" feeds.conf.default; then
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default || log_error "添加Nikki源失败"
fi
./scripts/feeds update nikki || log_error "Nikki源更新失败"
./scripts/feeds install -a -p nikki || log_error "Nikki包安装失败"
echo "CONFIG_PACKAGE_nikki=y" >> .config || log_error "启用nikki失败"
echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config || log_error "启用luci-app-nikki失败"
log_info "Nikki通过官方源集成完成"

# -------------------- 4. DTS补丁处理 --------------------
log_info "处理DTS补丁..."
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
BACKUP_DTS="$TARGET_DTS.backup"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/cm520-79f.patch"

[ -f "$TARGET_DTS" ] || log_error "目标DTS文件不存在：$TARGET_DTS"
cp "$TARGET_DTS" "$BACKUP_DTS" || log_error "DTS备份失败"
wget -q -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL" || log_error "DTS补丁下载失败"
[ -s "$DTS_PATCH_FILE" ] || log_error "DTS补丁为空或损坏"
if ! patch --dry-run -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" >/dev/null 2>&1; then
    log_error "DTS补丁不兼容"
fi
patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" || log_error "DTS补丁应用失败"
rm -f "$DTS_PATCH_FILE"
log_info "DTS补丁处理完成（验证通过）"

# -------------------- 5. 配置设备规则 --------------------
log_info "配置设备规则..."
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
if ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
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
    log_info "设备规则添加完成"
else
    log_info "设备规则已存在，跳过"
fi

# -------------------- 6. 强制修改主机名（核心修复：确保system文件存在） --------------------
log_info "强制修改主机名为：$FORCE_HOSTNAME..."
# 1. 修改hostname文件
HOSTNAME_FILE="package/base-files/files/etc/hostname"
echo "$FORCE_HOSTNAME" > "$HOSTNAME_FILE" || log_error "写入hostname文件失败"

# 2. 修改或创建system配置文件（关键修复）
SYSTEM_CONF="package/base-files/files/etc/config/system"
# 确保文件存在（即使为空）
if [ ! -f "$SYSTEM_CONF" ]; then
    log_info "系统配置文件不存在，创建新文件：$SYSTEM_CONF"
    touch "$SYSTEM_CONF" || log_error "创建system配置文件失败（权限问题）"
    # 写入基础配置结构
    cat <<EOF > "$SYSTEM_CONF"
config system
    option hostname 'OpenWrt'  # 临时值，后续会被替换
    option timezone 'UTC'
EOF
fi

# 替换hostname配置
if grep -q "option hostname" "$SYSTEM_CONF"; then
    sed -i "s/option hostname.*/option hostname '$FORCE_HOSTNAME'/" "$SYSTEM_CONF" || log_error "修改system配置失败"
else
    # 向config system块中添加hostname
    sed -i "/config system/a \    option hostname '$FORCE_HOSTNAME'" "$SYSTEM_CONF" || log_error "添加hostname到system配置失败"
fi
log_info "主机名修改完成（强制生效）"

# -------------------- 7. 强制修改IP地址 --------------------
log_info "强制修改默认IP为：$FORCE_IP..."
NETWORK_CONF="package/base-files/files/etc/config/network"
# 确保网络配置文件存在
if [ ! -f "$NETWORK_CONF" ]; then
    log_info "网络配置文件不存在，创建新文件：$NETWORK_CONF"
    touch "$NETWORK_CONF" || log_error "创建network配置文件失败"
    cat <<EOF > "$NETWORK_CONF"
config interface 'lan'
    option type 'bridge'
    option ifname 'eth0'
    option ipaddr '192.168.1.1'  # 临时值
    option netmask '255.255.255.0'
EOF
fi

# 替换LAN口IP
sed -i "s/option ipaddr[[:space:]]*['\"]*[0-9.]\+['\"]*/option ipaddr '$FORCE_IP'/" "$NETWORK_CONF" || log_error "修改LAN IP失败"

# 添加uci-defaults脚本确保生效
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
chmod +x "$UCI_SCRIPT" || log_error "设置uci脚本权限失败"
log_info "默认IP修改完成（强制生效）"

# -------------------- 8. 集成AdGuardHome --------------------
log_info "集成AdGuardHome（端口：$ADGUARD_PORT）..."
ADGUARD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.64/AdGuardHome_linux_armv7.tar.gz"
wget -q -O /tmp/adguard.tar.gz "$ADGUARD_URL" || log_error "AdGuardHome下载失败"
mkdir -p /tmp/adguard
tar -xzf /tmp/adguard.tar.gz -C /tmp/adguard --strip-components=1 || log_error "AdGuardHome解压失败"
cp /tmp/adguard/AdGuardHome "package/base-files/files$ADGUARD_BIN" || log_error "复制AdGuardHome二进制失败"
chmod +x "package/base-files/files$ADGUARD_BIN"

# 生成配置文件
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

# 添加启动服务
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
chmod +x "$SERVICE_SCRIPT"

# 解决LuCI识别问题
LUCI_CONF="package/base-files/files/etc/config/luci"
[ -f "$LUCI_CONF" ] || touch "$LUCI_CONF"
if ! grep -q "adguardhome" "$LUCI_CONF"; then
    cat <<EOF >> "$LUCI_CONF"
config adguardhome 'main'
    option bin_path '$ADGUARD_BIN'
    option conf_path '$ADGUARD_CONF'
    option enabled '1'
EOF
fi
log_info "AdGuardHome集成完成"

# -------------------- 9. 最终验证 --------------------
log_info "执行最终验证..."
grep -q "$FORCE_HOSTNAME" "$HOSTNAME_FILE" || log_error "主机名文件验证失败"
grep -q "$FORCE_IP" "$NETWORK_CONF" || log_error "IP配置文件验证失败"
[ -f "package/base-files/files$ADGUARD_BIN" ] || log_error "AdGuardHome二进制缺失"
log_info "DIY脚本执行完成（所有功能已生效）"
