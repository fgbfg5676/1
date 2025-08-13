#!/bin/bash
# 完整整合版：含AdGuardHome、sirpdboy插件及核心配置

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"

ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
ADGUARD_CONF_DIR="package/base-files/files/etc/AdGuardHome"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
CUSTOM_PLUGINS_DIR="package/custom"

# 创建必要目录
mkdir -p "$ADGUARD_DIR" "$ADGUARD_CONF_DIR" "$DTS_DIR" "$CUSTOM_PLUGINS_DIR" || log_error "创建目录失败"

# -------------------- 内核模块与工具配置 --------------------
log_info "配置内核模块..."
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config
echo "CONFIG_PACKAGE_kmod-ath10k-ct=y" >> .config
echo "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y" >> .config
echo "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" >> .config
echo "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y" >> .config
log_success "内核模块配置完成"

# -------------------- AdGuardHome集成 --------------------
log_info "集成AdGuardHome..."
./scripts/feeds install -p luci luci-app-adguardhome >/dev/null || log_error "安装luci-app-adguardhome失败"

ADGUARD_URLS=(
  "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${ARCH}.tar.gz"
  "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${ARCH}.tar.gz"
)
ADGUARD_TMP="/tmp/adguard.tar.gz"

for url in "${ADGUARD_URLS[@]}"; do
  if wget $WGET_OPTS -O "$ADGUARD_TMP" "$url"; then
    log_success "AdGuardHome核心下载成功"
    break
  fi
done

if [ -f "$ADGUARD_TMP" ]; then
  tar -zxf "$ADGUARD_TMP" -C /tmp >/dev/null
  cp /tmp/AdGuardHome/AdGuardHome "$ADGUARD_DIR/"
  chmod +x "$ADGUARD_DIR/AdGuardHome"
  rm -rf /tmp/AdGuardHome "$ADGUARD_TMP"
else
  log_error "AdGuardHome核心下载失败"
fi

cat > "$ADGUARD_CONF_DIR/AdGuardHome.yaml" <<EOF
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: "\$2y\$10\$gIAKp1l.BME2k5p6mMYlj..4l5mhc8YBGZzI8J/6z8s8nJlQ6oP4y"
dns:
  bind_host: 0.0.0.0
  port: 53
  upstream_dns:
    - 223.5.5.5
    - 119.29.29.29
  cache_size: 10485760
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
log:
  file: /var/log/AdGuardHome.log
EOF

cat > "package/base-files/files/etc/init.d/adguardhome" <<EOF
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
chmod +x "package/base-files/files/etc/init.d/adguardhome"
echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> .config
log_success "AdGuardHome集成完成"

# -------------------- 整合sirpdboy插件（luci-app-partexp） --------------------
log_info "Integrating sirpdboy plugins..."
rm -rf "$CUSTOM_PLUGINS_DIR/luci-app-partexp"  # 清除旧版本
if git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git "$CUSTOM_PLUGINS_DIR/luci-app-partexp"; then
  # 更新feeds并安装
  ./scripts/feeds update -a >/dev/null
  ./scripts/feeds install -a >/dev/null
  # 确保配置文件包含该插件
  grep -q "^CONFIG_PACKAGE_luci-app-partexp=y" .config || echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
  log_success "sirpdboy插件集成完成"
else
  log_error "sirpdboy插件克隆失败"
fi

# -------------------- DTS补丁处理 --------------------
log_info "处理DTS补丁..."
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"

if ! wget $WGET_OPTS -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL"; then
    log_error "DTS补丁下载失败"
fi

if [ ! -f "$TARGET_DTS" ]; then
    log_info "应用DTS补丁..."
    sed -i 's/^root\///' "$DTS_PATCH_FILE"
    if patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"; then
        sed -i '1i /dts-v1/;' "$TARGET_DTS"
        if ! grep -q "#include \"qcom-ipq4019.dtsi\"" "$TARGET_DTS"; then
            sed -i '2i #include "qcom-ipq4019.dtsi"' "$TARGET_DTS"
        fi
        log_success "DTS补丁应用并修复完成"
    else
        log_error "DTS补丁应用失败"
    fi
else
    log_info "目标DTS已存在，跳过补丁应用"
fi

# -------------------- 设备规则配置 --------------------
log_info "配置设备规则..."
if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    cat <<EOF >> "$GENERIC_MK"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to \$(KERNEL_SIZE) | append-rootfs | trx -o \$@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_success "设备规则添加完成"
else
    log_info "设备规则已存在，跳过"
fi

# -------------------- 最终配置 --------------------
log_info "更新软件包索引..."
./scripts/feeds update -a >/dev/null && ./scripts/feeds install -a >/dev/null || log_error "feeds更新失败"

log_success "所有配置完成（含AdGuardHome和sirpdboy插件）"
    
