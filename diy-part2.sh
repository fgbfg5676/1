#!/bin/bash
# 最終解決方案腳本：包含所有修復和必要的網絡配置

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
CUSTOM_DTS="../qcom-ipq4019-cm520-79f.dts"
DTS_URL="https://raw.githubusercontent.com/fgbfg5676/1/main/qcom-ipq4019-cm520-79f.dts"

# 创建必要目录
mkdir -p "$ADGUARD_DIR" "$ADGUARD_CONF_DIR" "$DTS_DIR" "$CUSTOM_PLUGINS_DIR" || log_error "创建目录失败"

# -------------------- 调试信息 --------------------
log_info "调试信息：当前工作目录：$(pwd )"
log_info "调试信息：检查DTS文件：$CUSTOM_DTS"
log_info "调试信息：检查GitHub URL：$DTS_URL"

# -------------------- 替换自定义DTS文件 --------------------
log_info "替换自定义DTS文件..."
DTS_FOUND=0
DTS_PATTERNS=(
  "$CUSTOM_DTS"
  "../Qcom-ipq4019-cm520-79f.dts"
  "qcom-ipq4019-cm520-79f.dts"
  "Qcom-ipq4019-cm520-79f.dts"
  "/home/runner/work/1/1/qcom-ipq4019-cm520-79f.dts"
  "/home/runner/work/1/1/Qcom-ipq4019-cm520-79f.dts"
)
for path in "${DTS_PATTERNS[@]}"; do
  if [ -f "$path" ]; then
    cp "$path" "$DTS_DIR/qcom-ipq4019-cm520-79f.dts" || log_error "复制DTS文件失败：$path"
    DTS_FOUND=1
    log_success "找到并替换DTS文件：$path"
    break
  fi
done

if [ "$DTS_FOUND" -eq 0 ]; then
  log_info "尝试从GitHub下载DTS文件..."
  if wget $WGET_OPTS -O "$DTS_DIR/qcom-ipq4019-cm520-79f.dts" "$DTS_URL"; then
      DTS_FOUND=1
      log_success "从GitHub下载并替换DTS文件：$DTS_URL"
  fi
fi

if [ "$DTS_FOUND" -eq 0 ]; then
  log_error "未找到或下载DTS文件"
fi

# -------------------- 關鍵步驟：創建網絡配置文件 --------------------
log_info "創建針對 CM520-79F 的網絡配置文件..."
BOARD_DIR="target/linux/ipq40xx/base-files/etc/board.d"
mkdir -p "$BOARD_DIR"
cat > "$BOARD_DIR/02_network" <<EOF
#!/bin/sh

. /lib/functions/system.sh

ipq40xx_board_detect() {
	local machine
	machine=\$(board_name)

	case "\$machine" in
	"mobipromo,cm520-79f")
		ucidef_set_interfaces_lan_wan "eth1" "eth0"
		;;
	esac
}

boot_hook_add preinit_main ipq40xx_board_detect
EOF
log_success "網絡配置文件創建完成"

# -------------------- 内核模块与工具配置 --------------------
log_info "配置内核模块..."
# (您的内核配置保持不变)
grep -q "CONFIG_PACKAGE_kmod-ubi=y" .config || echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
grep -q "CONFIG_PACKAGE_kmod-ubifs=y" .config || echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
grep -q "CONFIG_PACKAGE_trx=y" .config || echo "CONFIG_PACKAGE_trx=y" >> .config
grep -q "CONFIG_PACKAGE_kmod-ath10k-ct=y" .config || echo "CONFIG_PACKAGE_kmod-ath10k-ct=y" >> .config
grep -q "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y" .config || echo "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y" >> .config
grep -q "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" .config || echo "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" >> .config
grep -q "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y" .config || echo "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y" >> .config
grep -q "CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y" .config || echo "CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y" >> .config
log_success "内核模块配置完成"

# -------------------- AdGuardHome集成 (已增強健壯性) --------------------
log_info "集成AdGuardHome..."
./scripts/feeds install -p luci luci-app-adguardhome >/dev/null || log_error "安装luci-app-adguardhome失败"

ADGUARD_URLS=(
  "https://ghproxy.com/https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${ARCH}.tar.gz"
  "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${ARCH}.tar.gz"
 )
ADGUARD_TMP="/tmp/adguard.tar.gz"
ADGUARD_DOWNLOADED=false

for url in "${ADGUARD_URLS[@]}"; do
  log_info "正在尝试从 $url 下载 AdGuardHome..."
  if wget $WGET_OPTS -O "$ADGUARD_TMP" "$url"; then
    if file "$ADGUARD_TMP" | grep -q 'gzip compressed data'; then
      log_success "AdGuardHome核心下载成功，且文件格式正确。"
      ADGUARD_DOWNLOADED=true
      break
    else
      log_info "下载的文件不是有效的gzip格式，尝试下一个URL..."
      rm -f "$ADGUARD_TMP"
    fi
  else
    log_info "从 $url 下载失败。尝试下一个URL..."
  fi
done

if [ "$ADGUARD_DOWNLOADED" = true ]; then
  tar -zxf "$ADGUARD_TMP" -C /tmp >/dev/null || log_error "解压缩AdGuardHome失败"
  cp /tmp/AdGuardHome/AdGuardHome "$ADGUARD_DIR/" || log_error "AdGuardHome复制失败"
  chmod +x "$ADGUARD_DIR/AdGuardHome"
  rm -rf /tmp/AdGuardHome "$ADGUARD_TMP"
else
  log_error "AdGuardHome核心下载失败，所有URL都已尝试。"
fi

# (AdGuardHome的配置文件部分保持不变)
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
  cache_size: 4194304
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
log:
  file: /var/log/AdGuardHome.log
EOF
log_success "AdGuardHome集成完成"

# -------------------- 整合sirpdboy插件 --------------------
log_info "集成sirpdboy插件..."
if git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git "$CUSTOM_PLUGINS_DIR/luci-app-partexp"; then
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
  IMAGE_SIZE := 81920k
  IMAGE/trx := append-kernel | pad-to \$(KERNEL_SIZE ) | append-rootfs | trx -o \$@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_success "设备规则添加完成"
else
    sed -i 's/IMAGE_SIZE := 32768k/IMAGE_SIZE := 81920k/' "$GENERIC_MK"
    log_info "设备规则已存在，更新IMAGE_SIZE"
fi

# -------------------- 最终配置 --------------------
log_info "更新和安装所有feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

log_success "所有配置完成，準備開始編譯..."
