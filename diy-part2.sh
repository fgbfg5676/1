#!/bin/bash
# 完整CM520-79F云编译脚本（确保无功能遗漏）
# 包含：DTS处理、AdGuardHome完整集成、内核配置、设备规则等

# -------------------- 核心配置参数 --------------------
WORK_DIR="${GITHUB_WORKSPACE}"  # 云编译工作目录
# DTS相关
DTS_DIR="$WORK_DIR/target/linux/ipq40xx/files/arch/arm/boot/dts"
CM520_DTS="qcom-ipq4019-cm520-79f.dts"
BASE_DTS="qcom-ipq4019.dtsi"
PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
BASE_DTS_URLS=(
  "https://raw.githubusercontent.com/coolsnowwolf/lede/master/target/linux/ipq40xx/files/arch/arm/boot/dts/$BASE_DTS"
  "https://mirror.ghproxy.com/https://raw.githubusercontent.com/coolsnowwolf/lede/master/target/linux/ipq40xx/files/arch/arm/boot/dts/$BASE_DTS"
  "https://gitee.com/coolsnowwolf/lede/raw/master/target/linux/ipq40xx/files/arch/arm/boot/dts/$BASE_DTS"
)
# AdGuardHome相关
ADGUARD_APP_DIR="$WORK_DIR/feeds/luci/applications/luci-app-adguardhome"
ADGUARD_BIN_DIR="$WORK_DIR/package/luci-app-adguardhome/root/usr/bin"
ADGUARD_CONF_DIR="$WORK_DIR/package/base-files/files/etc/AdGuardHome"
ADGUARD_URLS=(
  "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz"
  "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_armv7.tar.gz"
  "https://mirror.ghproxy.com/https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz"
)
# 设备规则文件
GENERIC_MK="$WORK_DIR/target/linux/ipq40xx/image/generic.mk"

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_warn() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }

# -------------------- 多源下载（增强网络兼容性） --------------------
download_with_retry() {
  local output="$1"
  shift
  local urls=("$@")
  local max_tries=5  # 增加重试次数，适配云环境网络波动

  mkdir -p "$(dirname "$output")"
  rm -f "$output"

  for url in "${urls[@]}"; do
    for ((try=1; try<=max_tries; try++)); do
      log_info "下载尝试 $try/$max_tries: $(basename "$url")"
      if curl -fsSL --retry 2 --connect-timeout 15 -o "$output" "$url" || \
         wget -q --tries=2 --timeout=15 -O "$output" "$url"; then
        if [ -s "$output" ]; then
          log_success "下载成功: $(basename "$output")"
          return 0
        fi
      fi
      sleep $((try * 3))  # 指数退避重试
    done
  done
  log_error "所有源下载失败: $(basename "$output")"
}

# -------------------- 1. 处理DTS文件（核心） --------------------
process_dts() {
  log_info "===== 开始处理DTS文件 ====="
  mkdir -p "$DTS_DIR"

  # 下载基础DTSI（必须文件）
  download_with_retry "$DTS_DIR/$BASE_DTS" "${BASE_DTS_URLS[@]}"

  # 从补丁提取完整DTS
  download_with_retry "/tmp/cm520-patch.patch" "$PATCH_URL"
  log_info "提取补丁中的DTS内容..."
  sed -n '/^+++ b\//,/^--$/p' /tmp/cm520-patch.patch | sed '1d;$d' > "$DTS_DIR/$CM520_DTS"
  
  # 修复补丁可能带的路径前缀（如root/）
  sed -i 's/^root\///' "$DTS_DIR/$CM520_DTS"

  # 强制添加基础DTSI引用（防止遗漏）
  if ! grep -q "#include \"$BASE_DTS\"" "$DTS_DIR/$CM520_DTS"; then
    sed -i "1a #include \"$BASE_DTS\"" "$DTS_DIR/$CM520_DTS"
    log_info "已添加基础DTSI引用"
  fi

  # 验证DTS语法
  if ! dtc -I dts -O dtb -o /dev/null "$DTS_DIR/$CM520_DTS" 2>/tmp/dtc-error.log; then
    log_error "DTS语法错误！详情: \n$(cat /tmp/dtc-error.log)"
  fi
  log_success "DTS文件处理完成（语法验证通过）"
}

# -------------------- 2. 完整集成AdGuardHome --------------------
integrate_adguard() {
  log_info "===== 开始集成AdGuardHome ====="

  # 确保luci-app-adguardhome存在
  if [ ! -d "$ADGUARD_APP_DIR" ]; then
    log_info "安装luci-app-adguardhome包..."
    cd "$WORK_DIR" || log_error "进入源码目录失败"
    ./scripts/feeds install -p luci luci-app-adguardhome >/dev/null || \
      log_error "安装luci-app-adguardhome失败"
  fi

  # 创建必要目录
  mkdir -p "$ADGUARD_BIN_DIR" "$ADGUARD_CONF_DIR" "$WORK_DIR/package/base-files/files/etc/init.d"

  # 下载并部署AdGuardHome核心
  download_with_retry "/tmp/adguard.tar.gz" "${ADGUARD_URLS[@]}"
  log_info "解压AdGuardHome核心..."
  tar -zxf /tmp/adguard.tar.gz -C /tmp >/dev/null
  cp /tmp/AdGuardHome/AdGuardHome "$ADGUARD_BIN_DIR/"
  chmod +x "$ADGUARD_BIN_DIR/AdGuardHome"

  # 配置文件：主配置
  cat > "$WORK_DIR/package/base-files/files/etc/config/adguardhome" <<EOF
config adguardhome 'main'
  option enabled '1'
  option binpath '/usr/bin/AdGuardHome'
  option configpath '/etc/AdGuardHome/AdGuardHome.yaml'
  option logfile '/var/log/AdGuardHome.log'
  option workdir '/etc/AdGuardHome'
EOF

  # 配置文件：默认规则（避免首次启动无配置）
  cat > "$ADGUARD_CONF_DIR/AdGuardHome.yaml" <<EOF
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: "\$2y\$10\$gIAKp1l.BME2k5p6mMYlj..4l5mhc8YBGZzI8J/6z8s8nJlQ6oP4y"  # 默认密码admin
dns:
  bind_host: 0.0.0.0
  port: 53
  upstream_dns:
    - 223.5.5.5
    - 119.29.29.29
    - https://dns.alidns.com/dns-query
  cache_size: 10485760
  cache_ttl_min: 0
  cache_ttl_max: 3600
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
log:
  file: /var/log/AdGuardHome.log
  max_size: 10
  max_backups: 3
  verbose: false
EOF

  # 启动脚本（确保开机自启）
  cat > "$WORK_DIR/package/base-files/files/etc/init.d/adguardhome" <<EOF
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
  chmod +x "$WORK_DIR/package/base-files/files/etc/init.d/adguardhome"

  log_success "AdGuardHome集成完成（含配置文件和启动脚本）"
}

# -------------------- 3. 配置设备规则 --------------------
configure_device() {
  log_info "===== 配置CM520-79F设备规则 ====="
  if ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
    cat <<EOF >> "$GENERIC_MK"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := $CM520_DTS
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 65536k  # 适配80MB flash
  IMAGE_SIZE := 78643200
  SUPPORTED_DEVICES := mobipromo,cm520-79f
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128KiB
  PAGESIZE := 2048
  IMAGE/factory.ubi := append-ubi
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_success "设备规则添加完成"
  else
    log_info "设备规则已存在，跳过"
  fi
}

# -------------------- 4. 配置内核与软件包 --------------------
configure_kernel_packages() {
  log_info "===== 配置内核模块与软件包 ====="
  cd "$WORK_DIR" || log_error "进入源码目录失败"

  # 更新feeds（确保所有包可用）
  ./scripts/feeds update -a >/dev/null || log_error "feeds更新失败"
  ./scripts/feeds install -a >/dev/null || log_error "feeds安装失败"

  # 生成默认配置
  make defconfig >/dev/null || log_error "生成默认配置失败"

  # 强制添加必要模块和软件包
  cat >> .config <<EOF
# 基础功能
CONFIG_PACKAGE_kmod-ubi=y
CONFIG_PACKAGE_kmod-ubifs=y
CONFIG_PACKAGE_trx=y
CONFIG_PACKAGE_fstools=y
CONFIG_PACKAGE_mtd-utils=y

# 无线支持
CONFIG_PACKAGE_kmod-ath10k-ct=y
CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y
CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y

# 文件系统
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_TARGET_ROOTFS_UBIFS=y
CONFIG_UBIFS_COMPRESSION_ZSTD=y

# AdGuardHome相关
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y  # 避免DNS冲突

# 系统工具
CONFIG_PACKAGE_opkg=y
CONFIG_PACKAGE_sshd=y
CONFIG_PACKAGE_wget=y
CONFIG_PACKAGE_curl=y
EOF

  # 应用配置
  make defconfig >/dev/null || log_error "应用配置失败"
  log_success "内核与软件包配置完成"
}

# -------------------- 5. 执行编译 --------------------
run_compile() {
  log_info "===== 开始编译固件 ====="
  cd "$WORK_DIR" || log_error "进入源码目录失败"

  # 清理之前的编译缓存（避免冲突）
  make clean >/dev/null || log_info "无缓存可清理"

  # 执行编译（根据CPU核心数自动分配线程）
  log_info "编译线程数: $(nproc)"
  if ! make -j$(nproc) V=s; then
    log_error "编译过程失败"
  fi

  # 检查并输出固件路径
  local firmware=$(find "$WORK_DIR/bin/targets/ipq40xx/generic/" -name "openwrt-ipq40xx-generic-mobipromo_cm520-79f-*.ubi" | head -1)
  if [ -f "$firmware" ]; then
    log_success "编译成功！固件路径: $firmware"
    log_success "固件大小: $(du -h "$firmware" | awk '{print $1}')"
  else
    log_error "未找到生成的固件文件"
  fi
}

# -------------------- 主流程 --------------------
main() {
  log_info "===== CM520-79F 完整编译脚本启动 ====="
  process_dts           # 处理DTS（核心）
  integrate_adguard     # 集成AdGuardHome（含所有配置）
  configure_device      # 配置设备规则
  configure_kernel_packages  # 配置内核与软件包
  run_compile           # 执行编译
  log_info "===== 所有流程完成 ====="
}

# 启动主流程
main "$@"
    
