#!/bin/bash
# 完整整合版：含AdGuardHome、sirpdboy插件、自定义DTS及核心配置

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout=10 -L"
ARCH="armv7"

ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
ADGUARD_CONF_DIR="package/base-files/files/etc/AdGuardHome"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
CUSTOM_PLUGINS_DIR="package/custom"
CUSTOM_DTS="qcom-ipq4019-cm520-79f.dts"

# 创建必要目录
mkdir -p "$ADGUARD_DIR" "$ADGUARD_CONF_DIR" "$DTS_DIR" "$CUSTOM_PLUGINS_DIR" || log_error "创建目录失败"

# -------------------- 替换自定义DTS文件 --------------------
log_info "替换自定义DTS文件..."
if [ -f "$CUSTOM_DTS" ]; then
  cp "$CUSTOM_DTS" "$DTS_DIR/qcom-ipq4019-cm520-79f.dts" || log_error "复制DTS文件失败"
  # 验证DTS文件语法
  if command -v dtc >/dev/null; then
    dtc -I dts -O dtb "$DTS_DIR/qcom-ipq4019-cm520-79f.dts" -o /tmp/test.dtb >/dev/null 2>&1 || log_error "DTS文件语法错误"
    rm -f /tmp/test.dtb
  else
    log_info "未找到dtc工具，跳过DTS语法验证"
  fi
  # 确保DTS包含必要头文件
  if ! grep -q "/dts-v1/;" "$DTS_DIR/qcom-ipq4019-cm520-79f.dts"; then
    sed -i '1i /dts-v1/;' "$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
  fi
  if ! grep -q "#include \"qcom-ipq4019.dtsi\"" "$DTS_DIR/qcom-ipq4019-cm520-79f.dts"; then
    sed -i '2i #include "qcom-ipq4019.dtsi"' "$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
  fi
  log_success "自定义DTS文件替换完成"
else
  log_error "未找到自定义DTS文件：$CUSTOM_DTS"
fi

# -------------------- 内核模块与工具配置 --------------------
log_info "配置内核模块..."
grep -q "CONFIG_PACKAGE_kmod-ubi=y" .config || echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
grep -q "CONFIG_PACKAGE_kmod-ubifs=y" .config || echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
grep -q "CONFIG_PACKAGE_trx=y" .config || echo "CONFIG_PACKAGE_trx=y" >> .config
grep -q "CONFIG_PACKAGE_kmod-ath10k-ct=y" .config || echo "CONFIG_PACKAGE_kmod-ath10k-ct=y" >> .config
grep -q "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y" .config || echo "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y" >> .config
grep -q "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" .config || echo "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" >> .config
grep -q "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y" .config || echo "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y" >> .config
grep -q "CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y" .config || echo "CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y" >> .config
log_success "内核模块配置完成"

# -------------------- 检查端口冲突 --------------------
log_info "检查DNS端口冲突..."
if command -v netstat >/dev/null && netstat -tuln | grep -q :53; then
  log_info "检测到端口53冲突，禁用dnsmasq..."
  echo "# Disable dnsmasq to avoid port conflict" >> package/base-files/files/etc/rc.local
  echo "/etc/init.d/dnsmasq stop" >> package/base-files/files/etc/rc.local
  echo "/etc/init.d/dnsmasq disable" >> package/base-files/files/etc/rc.local
fi

# -------------------- AdGuardHome集成 --------------------
log_info "集成AdGuardHome..."
./scripts/feeds install -p luci luci-app-adguardhome >/dev/null || log_error "安装luci-app-adguardhome失败"

ADGUARD_URLS=(
  "https://ghproxy.com/https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${ARCH}.tar.gz"
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
  cp /tmp/AdGuardHome/AdGuardHome "$ADGUARD_DIR/" || log_error "AdGuardHome复制失败"
  chmod +x "$ADGUARD_DIR/AdGuardHome"
  # 验证二进制架构
  if command -v file >/dev/null && ! file "$ADGUARD_DIR/AdGuardHome" | grep -q "ARM"; then
    log_error "AdGuardHome二进制架构不匹配"
  fi
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
  cache_size: 4194304  # 优化为4MB，适应设备内存
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
grep -q "CONFIG_PACKAGE_luci-app-adguardhome=y" .config || echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> .config
log_success "AdGuardHome集成完成"

# -------------------- 整合sirpdboy插件（luci-app-partexp） --------------------
log_info "集成sirpdboy插件..."
rm -rf "$CUSTOM_PLUGINS_DIR/luci-app-partexp"
if git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git "$CUSTOM_PLUGINS_DIR/luci-app-partexp" || \
   git clone --depth 1 https://gitee.com/sirpdboy/luci-app-partexp.git "$CUSTOM_PLUGINS_DIR/luci-app-partexp"; then
  ./scripts/feeds update -a >/dev/null
  ./scripts/feeds install -a >/dev/null || log_error "插件依赖安装失败"
  grep -q "CONFIG_PACKAGE_luci-app-partexp=y" .config || echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
  log_success "sirpdboy插件集成完成"
else
  log_error "sirpdboy插件克隆失败"
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
  IMAGE_SIZE := 81920k  # 优化为80MB
  IMAGE/trx := append-kernel | pad-to \$(KERNEL_SIZE) | append-rootfs | trx -o \$@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_success "设备规则添加完成"
else
    # 更新IMAGE_SIZE为80MB
    sed -i 's/IMAGE_SIZE := 32768k/IMAGE_SIZE := 81920k/' "$GENERIC_MK"
    log_info "设备规则已存在，更新IMAGE_SIZE为80MB"
fi

# -------------------- 最终配置 --------------------
log_info "更新软件包索引..."
if ! ./scripts/feeds update -a >/dev/null; then
  log_info "尝试使用国内镜像更新feeds..."
  sed -i 's|https://github.com|https://ghproxy.com/https://github.com|' feeds.conf.default
  ./scripts/feeds update -a >/dev/null || log_error "feeds更新失败"
fi
./scripts/feeds install -a >/dev/null || log_error "feeds安装失败"

log_success "所有配置完成（含AdGuardHome、sirpdboy插件和自定义DTS）"
