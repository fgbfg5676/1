#!/bin/bash
set -euo pipefail
shopt -s extglob

log_info() { echo "[$(date +'%F %T')] [INFO] $*"; }
log_error() { echo "[$(date +'%F %T')] [ERROR] $*" >&2; exit 1; }

# -------------------- 全局变量 --------------------
FORCE_HOSTNAME="CM520-79F"
FORCE_IP="192.168.5.1"
ADGUARD_PORT="5353"
ADGUARD_BIN="/usr/bin/AdGuardHome"
ADGUARD_CONF_DIR="/etc/AdGuardHome"
ADGUARD_CONF="$ADGUARD_CONF_DIR/AdGuardHome.yaml"
ERROR_LOG="/tmp/diy_error.log"

ADGUARD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz"

# 使用你原来的 DTS 路径 + 文件名/URL（保持不改）
DTS_DIR="target/linux/ipq40xx/dts"
DTS_FILE="qcom-ipq40xx-mobipromo_cm520-79f.dts"
DTS_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"

GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

echo "===== DIY脚本错误日志 =====" > "$ERROR_LOG"
echo "开始时间: $(date)" >> "$ERROR_LOG"

# -------------------- 可选的预检查（只检查通用文件，不会修改 DTS） --------------------
check_preconditions() {
    # 仅检查 generic.mk 存在性以避免对你原脚本做不必要的干预
    if [ ! -f "$GENERIC_MK" ]; then
        echo "[WARNING] $GENERIC_MK 不存在 — 可能还未生成。继续执行将按你的原逻辑尝试添加设备规则。"
    fi
}
check_preconditions

# -------------------- 1. 添加所需内核模块和 trx 工具 --------------------
log_info "添加所需内核模块和 trx 工具到 .config"
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# -------------------- 2. 添加 Nikki feed 并启用包（保持原有行为） --------------------
log_info "添加 Nikki feed..."
FEED_LINE="src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
if ! grep -q "^$FEED_LINE" feeds.conf.default; then
  echo "$FEED_LINE" >> feeds.conf.default
  log_info "Nikki feed 添加成功"
else
  log_info "Nikki feed 已存在，跳过"
fi

log_info "更新并安装 Nikki 包..."
./scripts/feeds update nikki || log_error "Nikki feed 更新失败"
./scripts/feeds install -a -p nikki || log_error "Nikki feed 安装失败"

log_info "启用 Nikki 相关包..."
grep -q "^CONFIG_PACKAGE_nikki=y" .config || echo "CONFIG_PACKAGE_nikki=y" >> .config
grep -q "^CONFIG_PACKAGE_luci-app-nikki=y" .config || echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config

# -------------------- 3. 你的原始 DTS：按你要求原样加入（不改动） --------------------
# 创建 DTS 目录（若不存在）
mkdir -p "$DTS_DIR"

echo "Downloading DTS file for mobipromo_cm520-79f..."
# 直接把你提供的 URL 下载为指定 DTS 文件（和你的一模一样）
if wget -q -O "$DTS_DIR/$DTS_FILE" "$DTS_URL"; then
    echo "DTS file downloaded successfully: $DTS_DIR/$DTS_FILE"
else
    echo "Error: Failed to download DTS file from $DTS_URL"
    exit 1
fi

# 为 mobipromo_cm520-79f 设备添加 trx 生成规则（保持你原来的 sed 操作）
if grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    # 插入分区大小（根据 DTS 中的分区定义调整，示例值需匹配实际）
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

# -------------------- 4. 配置设备规则（如果设备规则不存在则添加） --------------------
log_info "配置设备规则（若缺失则写入）"
if ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
    cat <<'EOF' >> "$GENERIC_MK"
define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | trx -o $@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_info "设备规则添加完成"
else
    log_info "设备规则已存在，跳过"
fi

# -------------------- 5. 强制主机名与默认 IP --------------------
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

# -------------------- 6. 集成 AdGuardHome（你的实现） --------------------
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
cat <<'EOF' > "$SERVICE_SCRIPT"
#!/bin/sh /etc/rc.common
START=95
STOP=15
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/AdGuardHome -c /etc/AdGuardHome/AdGuardHome.yaml
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

# -------------------- 7. 将 feeds 中可能存在的 adguardhome 从 .config 移除（避免冲突） --------------------
log_info "移除 feeds 版 AdGuardHome 配置（若存在）"
if grep -q "CONFIG_PACKAGE_adguardhome=y" .config; then
    sed -i '/CONFIG_PACKAGE_adguardhome/d' .config
    sed -i '/CONFIG_PACKAGE_luci-app-adguardhome/d' .config
    sed -i '/CONFIG_PACKAGE_luci-app-adguardhome_INCLUDE_binary/d' .config
    log_info "移除完成"
else
    log_info "无 feeds 版 AdGuardHome 配置，跳过"
fi

# -------------------- 8. 将 luci-app-fchomo 和 luci-app-homeproxy 的 firewall3 -> firewall（若有） --------------------
log_info "替换 luci-app-fchomo 和 luci-app-homeproxy 的 firewall3 依赖为 firewall（如果对应 Makefile 存在）"
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

# -------------------- 9. 最终验证 --------------------
log_info "执行最终验证..."
HOSTNAME_FILE="package/base-files/files/etc/hostname"
NETWORK_CONF="package/base-files/files/etc/config/network"
grep -q "$FORCE_HOSTNAME" "$HOSTNAME_FILE" || log_error "主机名文件验证失败"
grep -q "$FORCE_IP" "$NETWORK_CONF" || log_error "IP配置文件验证失败"
[ -f "package/base-files/files$ADGUARD_BIN" ] || log_error "AdGuardHome 二进制缺失"

log_info "DIY脚本执行完成（所有功能已生效）"
