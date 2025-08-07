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
ADGUARD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz"

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
log_error() { 
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$ERROR_LOG"
    exit 1
}

# -------------------- 1. 初始化错误日志 --------------------
echo "===== DIY脚本错误日志 =====" > "$ERROR_LOG"
echo "开始时间: $(date)" >> "$ERROR_LOG"

# -------------------- 2. 创建必要目录 --------------------
log_info "创建必要目录..."
mkdir -p \
    "target/linux/ipq40xx/files/arch/arm/boot/dts" \
    "package/custom" \
    "package/base-files/files$ADGUARD_CONF_DIR" \
    "package/base-files/files/usr/bin" \
    "package/base-files/files/etc/uci-defaults" \
    "package/base-files/files/etc/config"
log_info "必要目录创建完成"

# -------------------- 3. 配置内核模块 --------------------
log_info "配置内核模块..."
REQUIRED_MODULES=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
    "CONFIG_PACKAGE_firewall3=y"  # 提前启用firewall3
)
for mod in "${REQUIRED_MODULES[@]}"; do
    mod_key=$(echo "$mod" | cut -d'=' -f1)
    sed -i "/^#*${mod_key}/d" .config || log_error "修改.config失败（内核模块）"
    echo "$mod" >> .config || log_error "写入.config失败（$mod）"
done
log_info "内核模块配置完成"

# -------------------- 4. 集成Nikki --------------------
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

# -------------------- 5. 【新增位置】防火墙兼容处理（解决递归依赖） --------------------
# 复制以下代码到这里
log_info "处理设备不支持firewall4的问题..."

# 1. 全局禁用firewall4（优先级最高）
echo "CONFIG_PACKAGE_firewall4=n" >> .config
echo "CONFIG_PACKAGE_luci-firewall4=n" >> .config  # 禁用对应LuCI界面

# 2. 强制启用firewall3及配套组件
echo "CONFIG_PACKAGE_firewall3=y" >> .config
echo "CONFIG_PACKAGE_luci-firewall=y" >> .config  # firewall3的LuCI界面
echo "CONFIG_PACKAGE_ip6tables=y" >> .config  # 兼容IPv6防火墙规则
echo "CONFIG_PACKAGE_iptables=y" >> .config   # firewall3依赖的iptables工具

# 3. 批量修改所有包的依赖（解决管道损坏问题）
log_info "全局替换firewall4依赖为firewall3..."

# 步骤1：将find结果保存到临时文件，避免管道损坏
TMP_FILE=$(mktemp)
find ./feeds ./package \( -name "Makefile" -o -name "Config.in" \) > "$TMP_FILE" 2>/dev/null

# 步骤2：检查是否找到文件（基于临时文件内容）
if [ ! -s "$TMP_FILE" ]; then
    log_error "未找到任何Makefile或Config.in文件，请检查路径是否正确"
fi

# 步骤3：从临时文件读取路径，逐个处理（避免管道问题）
while read -r file; do
    [ -z "$file" ] && continue  # 跳过空行
    log_info "正在处理文件: $file"
    # 单个文件处理失败不影响整体
    sed -i "s/+firewall4/+firewall3/g" "$file" || log_warn "替换依赖失败: $file"
    sed -i "/select.*firewall4/d" "$file" || log_warn "删除select失败: $file"
    sed -i "/depends on.*firewall4/d" "$file" || log_warn "删除depends失败: $file"
done < "$TMP_FILE"

# 清理临时文件
rm -f "$TMP_FILE"
log_info "全局依赖替换完成"

# -------------------- 4. 单独处理nikki的依赖（修正路径） --------------------
log_info "单独处理nikki的依赖..."
# 优先搜索feeds目录（通过feeds安装的包默认存放在这里）
NIKKI_MAKEFILE=$(find ./feeds/nikki -name "Makefile" | grep -E "/nikki(/|$)" | head -n 1)

# 若feeds中未找到，尝试全局搜索（排除无关路径）
if [ -z "$NIKKI_MAKEFILE" ]; then
    log_info "未在feeds中找到，尝试全局搜索..."
    NIKKI_MAKEFILE=$(find ./ -path ./feeds -prune -o -name "Makefile" | grep -E "/nikki(/|$)" | head -n 1)
fi

# 检查是否找到
if [ -n "$NIKKI_MAKEFILE" ] && [ -f "$NIKKI_MAKEFILE" ]; then
    log_info "找到nikki的Makefile: $NIKKI_MAKEFILE"
    # 替换依赖
    sed -i "s/firewall4/firewall3/g" "$NIKKI_MAKEFILE" || log_error "替换nikki依赖失败: $NIKKI_MAKEFILE"
    sed -i "/firewall4/d" "$NIKKI_MAKEFILE" || log_error "删除nikki中firewall4失败: $NIKKI_MAKEFILE"
else
    # 增强错误提示，指导用户检查Nikki集成
    log_error "未找到nikki的Makefile！可能原因：
1. Nikki源未正确同步（尝试重新执行./scripts/feeds update nikki）
2. 包名不匹配（检查feeds/nikki目录下是否有nikki相关包）
当前搜索路径：./feeds/nikki及全局（排除feeds子目录）"
fi
# -------------------- 5. 禁用luci-app-fchomo（更可靠的检查） --------------------
log_info "检查并禁用luci-app-fchomo..."
if grep -q "CONFIG_PACKAGE_luci-app-fchomo=y" .config 2>/dev/null; then
    log_info "禁用luci-app-fchomo以打破循环依赖"
    sed -i "s/CONFIG_PACKAGE_luci-app-fchomo=y/CONFIG_PACKAGE_luci-app-fchomo=n/" .config || log_error "禁用fchomo失败"
else
    log_info "luci-app-fchomo未启用，无需处理"
fi

# -------------------- 6. 清理缓存并重新生成配置（输出详细日志） --------------------
log_info "清理依赖缓存并重新生成配置..."
rm -rf tmp/.config-package.in  # 彻底删除旧缓存
log_info "执行make defconfig（可能需要几分钟）..."
# 执行make defconfig并捕获输出，便于定位错误
if ! make defconfig > make_defconfig.log 2>&1; then
    log_error "make defconfig失败！详细日志如下："
    cat make_defconfig.log | tee -a "$ERROR_LOG"  # 输出错误日志
    exit 1
fi
log_info "配置生成成功"

# -------------------- 【新增结束】 --------------------

# -------------------- 6. DTS补丁处理 --------------------
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

# -------------------- 7. 配置设备规则 --------------------
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

# -------------------- 8. 强制修改主机名 --------------------
log_info "强制修改主机名为：$FORCE_HOSTNAME..."
HOSTNAME_FILE="package/base-files/files/etc/hostname"
echo "$FORCE_HOSTNAME" > "$HOSTNAME_FILE" || log_error "写入hostname文件失败"

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
    sed -i "s/option hostname.*/option hostname '$FORCE_HOSTNAME'/" "$SYSTEM_CONF" || log_error "修改system配置失败"
else
    sed -i "/config system/a \    option hostname '$FORCE_HOSTNAME'" "$SYSTEM_CONF" || log_error "添加hostname失败"
fi
log_info "主机名修改完成（强制生效）"

# -------------------- 9. 强制修改IP地址 --------------------
log_info "强制修改默认IP为：$FORCE_IP..."
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

sed -i "s/option ipaddr[[:space:]]*['\"]*[0-9.]\+['\"]*/option ipaddr '$FORCE_IP'/" "$NETWORK_CONF" || log_error "修改LAN IP失败"

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

# -------------------- 10. 集成AdGuardHome --------------------
log_info "集成AdGuardHome（端口：$ADGUARD_PORT）..."
ADGUARD_TMP_DIR="/tmp/adguard"
ADGUARD_ARCHIVE="/tmp/adguard.tar.gz"

rm -rf "$ADGUARD_TMP_DIR" "$ADGUARD_ARCHIVE"

log_info "下载AdGuardHome（armv7架构）..."
if ! wget -q -O "$ADGUARD_ARCHIVE" "$ADGUARD_URL"; then
    log_error "AdGuardHome下载失败，请检查URL：$ADGUARD_URL"
fi

if [ $(stat -c "%s" "$ADGUARD_ARCHIVE") -lt 102400 ]; then
    log_error "AdGuardHome压缩包过小，可能损坏"
fi

log_info "解压AdGuardHome..."
mkdir -p "$ADGUARD_TMP_DIR" || log_error "创建临时目录失败"
if ! tar -xzf "$ADGUARD_ARCHIVE" -C "$ADGUARD_TMP_DIR"; then
    log_error "AdGuardHome解压失败（压缩包损坏或格式错误）"
fi

log_info "搜索AdGuardHome二进制文件..."
ADGUARD_BIN_SRC=$(find "$ADGUARD_TMP_DIR" -type f -name "AdGuardHome" -executable | head -n 1)
if [ -z "$ADGUARD_BIN_SRC" ]; then
    ADGUARD_BIN_SRC=$(find "$ADGUARD_TMP_DIR" -type f -name "AdGuardHome" | head -n 1)
fi

if [ -z "$ADGUARD_BIN_SRC" ] || [ ! -f "$ADGUARD_BIN_SRC" ]; then
    log_error "未找到AdGuardHome二进制文件"
fi

log_info "找到二进制文件：$ADGUARD_BIN_SRC"
cp "$ADGUARD_BIN_SRC" "package/base-files/files$ADGUARD_BIN" || log_error "复制AdGuardHome二进制失败"
chmod +x "package/base-files/files$ADGUARD_BIN" || log_error "设置可执行权限失败"

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

# -------------------- 额外修复：依赖缺失与递归问题 --------------------
log_info "处理firewall3依赖缺失与递归依赖错误..."

# 1. 确保firewall3被强制启用（解决依赖缺失警告）
log_info "强制启用firewall3及其依赖..."
echo "CONFIG_PACKAGE_firewall3=y" >> .config
echo "CONFIG_PACKAGE_iptables=y" >> .config
echo "CONFIG_PACKAGE_ip6tables=y" >> .config
# 刷新配置，确保生效
sed -i "/CONFIG_PACKAGE_firewall3=n/d" .config
sed -i "/CONFIG_PACKAGE_iptables=n/d" .config

# 2. 修复luci-app-fchomo自递归依赖（简化逻辑，直接禁用）
log_info "修复luci-app-fchomo自依赖..."
# 不尝试复杂修复，直接强制禁用该包（非核心功能，不影响主流程）
if ! grep -q "CONFIG_PACKAGE_luci-app-fchomo=n" .config 2>/dev/null; then
    log_info "直接禁用luci-app-fchomo以避免递归依赖"
    # 确保写入.config成功
    if echo "CONFIG_PACKAGE_luci-app-fchomo=n" >> .config; then
        log_info "luci-app-fchomo已禁用"
    else
        log_warn "写入.config失败，尝试直接修改"
        sed -i "s/CONFIG_PACKAGE_luci-app-fchomo=.*/CONFIG_PACKAGE_luci-app-fchomo=n/" .config 2>/dev/null
    fi
else
    log_info "luci-app-fchomo已禁用，无需处理"
fi
# 3. 修复geoview自递归依赖
log_info "修复geoview自依赖..."
GEOVIEW_CONFIG=$(find ./feeds ./package -name "Config.in" | grep "geoview" | head -n 1)
GEOVIEW_MAKEFILE=$(find ./feeds ./package -name "Makefile" | grep "geoview" | head -n 1)
if [ -n "$GEOVIEW_CONFIG" ]; then
    # 移除自依赖（如 "depends on PACKAGE_geoview"）
    sed -i "/depends on.*geoview/d" "$GEOVIEW_CONFIG"
    log_info "已修复geoview的Config.in: $GEOVIEW_CONFIG"
elif [ -n "$GEOVIEW_MAKEFILE" ]; then
    sed -i "/DEPENDS.*=.*+geoview/d" "$GEOVIEW_MAKEFILE"
    log_info "已修复geoview的Makefile: $GEOVIEW_MAKEFILE"
else
    log_warn "未找到geoview的配置文件，尝试禁用该包"
    echo "CONFIG_PACKAGE_geoview=n" >> .config
fi

# 4. 清理缓存并重新生成配置
rm -rf tmp/.config-package.in
make defconfig || log_error "最终配置生成失败，依赖问题未解决"

log_info "依赖缺失与递归问题修复完成"
# -------------------- 11. 最终验证 --------------------
log_info "执行最终验证..."
grep -q "$FORCE_HOSTNAME" "$HOSTNAME_FILE" || log_error "主机名文件验证失败"
grep -q "$FORCE_IP" "$NETWORK_CONF" || log_error "IP配置文件验证失败"
[ -f "package/base-files/files$ADGUARD_BIN" ] || log_error "AdGuardHome二进制缺失"
log_info "DIY脚本执行完成（所有功能已生效）"
