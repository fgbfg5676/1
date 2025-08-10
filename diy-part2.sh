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

# AdGuardHome 下载地址（armv7架构最新稳定版）
ADGUARD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz"


# -------------------- 日志函数 --------------------

log_info() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
log_error() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$ERROR_LOG"
    exit 1
}

# -------------------- 初始化错误日志 --------------------

echo "===== DIY 脚本错误日志 =====" > "$ERROR_LOG"
echo "开始时间: $(date)" >> "$ERROR_LOG"

# -------------------- 1. 创建必要目录 --------------------

log_info "创建必要目录..."
mkdir -p \
    "target/linux/ipq40xx/dts" \
    "package/custom" \
    "package/base-files/files$ADGUARD_CONF_DIR" \
    "package/base-files/files/usr/bin" \
    "package/base-files/files/etc/uci-defaults" \
    "package/base-files/files/etc/config"
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

# -------------------- 3. 集成 Nikki --------------------

log_info "开始通过官方源集成 Nikki..."
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
if ! grep -q "nikki.*$NIKKI_FEED" feeds.conf.default; then
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default || log_error "添加 Nikki 源失败"
fi
./scripts/feeds update nikki || log_error "Nikki 源更新失败"
./scripts/feeds install -a -p nikki || log_error "Nikki 包安装失败"
grep -q "^CONFIG_PACKAGE_nikki=y" .config || echo "CONFIG_PACKAGE_nikki=y" >> .config
grep -q "^CONFIG_PACKAGE_luci-app-nikki=y" .config || echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
log_info "Nikki 通过官方源集成完成"

# -------------------- 4. 处理 DTS 文件（替代补丁应用） --------------------

log_info "处理 DTS 文件（直接下载完整 DTS 替代补丁方式）..."

DTS_DIR="target/linux/ipq40xx/dts"
DTS_FILE="qcom-ipq40xx-mobipromo_cm520-79f.dts"
DTS_URL="https://raw.githubusercontent.com/mptcp/openmptcprouter/master/target/linux/ipq40xx/dts/qcom-ipq40xx-mobipromo_cm520-79f.dts"

mkdir -p "$DTS_DIR"

log_info "下载 DTS 文件..."
if wget -q -O "$DTS_DIR/$DTS_FILE" "$DTS_URL"; then
    log_info "DTS 文件下载完成: $DTS_DIR/$DTS_FILE"
else
    log_error "DTS 文件下载失败"
fi

# -------------------- 5. 配置设备规则 --------------------

log_info "配置设备规则..."

GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

if ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
    cat <<EOF >> "$GENERIC_MK"
define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq40xx-mobipromo_cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to \$\$(KERNEL_SIZE) | append-rootfs | trx -o \$\@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_info "设备规则添加完成"
else
    log_info "设备规则已存在，跳过"
fi

# -------------------- 6. 强制修改主机名 --------------------

log_info "强制修改主机名为：$FORCE_HOSTNAME"

HOSTNAME_FILE="package/base-files/files/etc/hostname"
echo "$FORCE_HOSTNAME" > "$HOSTNAME_FILE" || log_error "写入 hostname 文件失败"

SYSTEM_CONF="package/base-files/files/etc/config/system"
if [ ! -f "$SYSTEM_CONF" ]; then
    log_info "系统配置文件不存在，创建新文件：$SYSTEM_CONF"
    cat <<EOF > "$SYSTEM_CONF"
config system
    option hostname 'OpenWrt'
    option timezone 'UTC'
EOF
fi
if grep -q "option hostname" "$SYSTEM_CONF"; then
    sed -i "s/option hostname.*/option hostname '$FORCE_HOSTNAME'/" "$SYSTEM_CONF" || log_error "修改 system 配置失败"
else
    sed -i "/config system/a \    option hostname '$FORCE_HOSTNAME'" "$SYSTEM_CONF" || log_error "添加 hostname 失败"
fi
log_info "主机名修改完成"

# -------------------- 7. 强制修改默认 IP --------------------

log_info "强制修改默认IP为：$FORCE_IP"

NETWORK_CONF="package/base-files/files/etc/config/network"
if [ ! -f "$NETWORK_CONF" ]; then
    log_info "网络配置文件不存在，创建新文件：$NETWORK_CONF"
    cat <<EOF > "$NETWORK_CONF"
config interface 'lan'
    option type 'bridge'
    option ifname 'eth0'
    option ipaddr '192.168.1.1'
    option netmask '255.255.255.0'
EOF
fi
sed -i "s/option ipaddr[[:space:]]*['\"]*[0-9.]\+['\"]*/option ipaddr '$FORCE_IP'/" "$NETWORK_CONF" || log_error "修改 LAN IP 失败"

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
chmod +x "$UCI_SCRIPT" || log_error "设置 UCI 脚本权限失败"
log_info "默认IP修改完成"

# -------------------- 8. 集成 AdGuardHome --------------------

log_info "集成 AdGuardHome，端口：$ADGUARD_PORT"

ADGUARD_TMP_DIR="/tmp/adguard"
ADGUARD_ARCHIVE="/tmp/adguard.tar.gz"

rm -rf "$ADGUARD_TMP_DIR" "$ADGUARD_ARCHIVE"

log_info "下载 AdGuardHome (armv7)..."
wget -q -O "$ADGUARD_ARCHIVE" "$ADGUARD_URL" || log_error "AdGuardHome 下载失败"

if [ $(stat -c "%s" "$ADGUARD_ARCHIVE") -lt 102400 ]; then
    log_error "AdGuardHome 压缩包过小，可能损坏"
fi

log_info "解压 AdGuardHome..."
mkdir -p "$ADGUARD_TMP_DIR" || log_error "创建临时目录失败"
tar -xzf "$ADGUARD_ARCHIVE" -C "$ADGUARD_TMP_DIR" || log_error "解压失败"

log_info "查找 AdGuardHome 二进制文件..."
ADGUARD_BIN_SRC=$(find "$ADGUARD_TMP_DIR" -type f -name "AdGuardHome" -executable | head -n 1)
if [ -z "$ADGUARD_BIN_SRC" ]; then
    ADGUARD_BIN_SRC=$(find "$ADGUARD_TMP_DIR" -type f -name "AdGuardHome" | head -n 1)
fi
[ -f "$ADGUARD_BIN_SRC" ] || log_error "未找到 AdGuardHome 二进制文件"

log_info "复制二进制文件到 $ADGUARD_BIN"
cp "$ADGUARD_BIN_SRC" "package/base-files/files$ADGUARD_BIN" || log_error "复制二进制失败"
chmod +x "package/base-files/files$ADGUARD_BIN" || log_error "设置执行权限失败"

log_info "生成配置文件"
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

log_info "创建启动脚本"
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
chmod +x "$SERVICE_SCRIPT" || log_error "设置服务脚本权限失败"

log_info "修正 LuCI 识别配置"
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
log_info "AdGuardHome 集成完成"

# -------------------- 9. 修补 feeds 版 firewall3 依赖问题 --------------------

log_info "替换 luci-app-fchomo 和 luci-app-homeproxy 的 firewall3 依赖为 firewall"
patch_firewall_dep() {
    local files=(
        "feeds/small/luci-app-fchomo/Makefile"
        "feeds/small/luci-app-homeproxy/Makefile"
    )
    for f in "${files[@]}"; do
        if [ -f "$f" ]; then
            log_info "修改 $f 依赖 firewall3 -> firewall"
            sed -i 's/\(Depends:.*\)firewall3/\1firewall/g' "$f" || log_error "修改 $f 失败"
            sed -i 's/DEPENDS:=firewall3/DEPENDS:=firewall/g' "$f" || log_error "修改 $f 失败"
        else
            log_info "文件不存在，跳过：$f"
        fi
    done
}
patch_firewall_dep

# -------------------- 10. 移除 feeds 版 AdGuardHome 配置 --------------------

log_info "移除 feeds 版 AdGuardHome 配置"
if grep -q "CONFIG_PACKAGE_adguardhome=y" .config; then
    sed -i '/CONFIG_PACKAGE_adguardhome/d' .config
    sed -i '/CONFIG_PACKAGE_luci-app-adguardhome/d' .config
    sed -i '/CONFIG_PACKAGE_luci-app-adguardhome_INCLUDE_binary/d' .config
    log_info "移除完成"
else
    log_info "无 feeds 版 AdGuardHome 配置，跳过"
fi

# -------------------- 11. 执行最终验证 --------------------

log_info "执行最终验证..."
grep -q "$FORCE_HOSTNAME" "$HOSTNAME_FILE" || log_error "主机名文件验证失败"
grep -q "$FORCE_IP" "$NETWORK_CONF" || log_error "IP配置文件验证失败"
[ -f "package/base-files/files$ADGUARD_BIN" ] || log_error "AdGuardHome 二进制缺失"

log_info "DIY 脚本执行完成（所有功能已生效）"
