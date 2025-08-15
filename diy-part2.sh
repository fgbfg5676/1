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
CUSTOM_DTS="../qcom-ipq4019-cm520-79f.dts"  # 适配GitHub Actions工作目录

# 创建必要目录
mkdir -p "$ADGUARD_DIR" "$ADGUARD_CONF_DIR" "$DTS_DIR" "$CUSTOM_PLUGINS_DIR" || log_error "创建目录失败"

# -------------------- 调试信息 --------------------
log_info "调试信息：当前工作目录：$(pwd)"
log_info "调试信息：仓库根目录文件列表："
ls -la .. || log_info "无法列出仓库根目录文件"
log_info "调试信息：检查DTS文件：$CUSTOM_DTS"

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
  # 备用路径检查
  log_info "尝试在当前目录查找DTS文件..."
  if [ -f "qcom-ipq4019-cm520-79f.dts" ]; then
    cp "qcom-ipq4019-cm520-79f.dts" "$DTS_DIR/qcom-ipq4019-cm520-79f.dts" || log_error "复制备用DTS文件失败"
    log_success "从当前目录找到并替换DTS文件"
  else
    log_error "未找到DTS文件：$CUSTOM_DTS 或 qcom-ipq4019-cm520-79f.dts"
  fi
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
    password: "\$2y\$10\$gIAKp1l.BME2k5p6mMYlj..4l5mhc8YBGZzI8J
