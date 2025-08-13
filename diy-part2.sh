#!/bin/bash
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 for CM520-79F (IPQ40xx, ARMv7)
# Enhanced: 适配 Opboot 的 UBI 格式, 支持 Lean 源码, 可选 AdGuardHome, 增强日志
# Modifications:
# - 使用参考脚本的 DTS 和设备规则逻辑（a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch）
# - 移除 dnsmasq DNS 禁用、iptables 和防火墙配置
# - 适配 Opboot 的 ubi 格式（生成 openwrt-ipq40xx-generic-mobipromo_cm520-79f-squashfs-nand-factory.ubi）
# - 添加 WiFi 固件支持 (kmod-ath10k-ct, ipq-wifi-mobipromo_cm520-79f)
# - 检查 Lean 源码的 DTS，优先使用
# - 可选 AdGuardHome，通过环境变量控制
# - 添加固件大小检查和日志持久化

# -------------------- 日志记录函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_warn() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_step() {
  echo -e "[$(date +'%H:%M:%S')] \033[36m🔄 $*\033[0m"
  echo "----------------------------------------"
}

# -------------------- 智能重试函数 --------------------
retry_command() {
  local max_attempts=3
  local delay=5
  local attempt=1
  local cmd="$*"
  while [ $attempt -le $max_attempts ]; do
    log_info "执行命令 (尝试 $attempt/$max_attempts): $cmd"
    if eval "$cmd"; then
      [ $attempt -gt 1 ] && log_success "命令在第 $attempt 次尝试后成功执行"
      return 0
    else
      local exit_code=$?
      if [ $attempt -lt $max_attempts ]; then
        log_warn "命令执行失败 (退出码: $exit_code)，${delay}秒后重试..."
        sleep $delay
      else
        log_error "命令执行失败，已达到最大重试次数 ($max_attempts)"
      fi
    fi
    attempt=$((attempt + 1))
  done
}

retry_download() {
  local url="$1"
  local output="$2"
  local max_attempts=3
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    log_info "下载文件 (尝试 $attempt/$max_attempts): $url"
    if wget $WGET_OPTS -O "$output" "$url"; then
      local size=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output" 2>/dev/null || echo "未知")
      log_success "文件下载成功 (大小: ${size} 字节): $(basename "$output")"
      return 0
    else
      log_warn "下载失败，URL: $url"
      if [ $attempt -lt $max_attempts ]; then
        log_info "5秒后重试..."
        sleep 5
      fi
    fi
    attempt=$((attempt + 1))
  done
  log_error "文件下载失败，已达到最大重试次数: $url"
}

# -------------------- 文件检查函数 --------------------
check_critical_files() {
  local errors=0
  log_step "执行关键文件检查"
  if [ -f "$TARGET_DTS" ]; then
    local size=$(stat -f%z "$TARGET_DTS" 2>/dev/null || stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
    if [ "$size" -lt 1000 ]; then
      log_error "DTS文件太小 ($size 字节，预期至少 1000 字节): $TARGET_DTS"
    fi
    log_success "DTS文件存在: $TARGET_DTS (大小: ${size} 字节)"
  else
    log_error "DTS文件缺失: $TARGET_DTS"
  fi
  if [ "$ENABLE_ADGUARD" = "y" ]; then
    if [ -f "$ADGUARD_DIR/AdGuardHome" ]; then
      local size=$(stat -f%z "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || stat -c%s "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || echo "0")
      log_success "AdGuardHome核心存在 (大小: ${size} 字节)"
    else
      log_error "AdGuardHome核心缺失: $ADGUARD_DIR/AdGuardHome"
    fi
    if [ -f "package/base-files/files/etc/config/adguardhome" ]; then
      log_success "AdGuardHome配置文件已创建"
    else
      log_error "AdGuardHome配置文件未找到"
    fi
  fi
  log_step "检查固件大小"
  FIRMWARE_FILE="bin/targets/ipq40xx/generic/openwrt-ipq40xx-generic-mobipromo_cm520-79f-squashfs-nand-factory.ubi"
  if [ -f "$FIRMWARE_FILE" ]; then
    FIRMWARE_SIZE=$(stat -f%z "$FIRMWARE_FILE" 2>/dev/null || stat -c%s "$FIRMWARE_FILE" 2>/dev/null || echo "0")
    if [ "$FIRMWARE_SIZE" -gt 32768000 ]; then
      log_warn "固件大小 ($FIRMWARE_SIZE 字节) 可能超过 IMAGE_SIZE (32768k)"
    else
      log_success "固件大小检查通过: $FIRMWARE_SIZE 字节"
    fi
  else
    log_info "固件文件尚未生成: $FIRMWARE_FILE"
  fi
  return $errors
}

# -------------------- 执行摘要函数 --------------------
print_summary() {
  local start_time="$1"
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  local minutes=$((duration / 60))
  local seconds=$((duration % 60))
  echo ""
  echo "========================================"
  log_success "DIY脚本执行完成！"
  echo "========================================"
  log_info "总耗时: ${minutes}分${seconds}秒"
  log_info "日志已保存到: $LOG_FILE"
  echo ""
  echo "已完成配置："
  echo "1. ✅ 配置内核模块和WiFi固件"
  echo "2. ✅ 应用DTS补丁或使用Lean DTS"
  echo "3. ✅ 配置Opboot兼容的UBI设备规则"
  if [ "$ENABLE_ADGUARD" = "y" ]; then
    echo "4. ✅ 下载并配置AdGuardHome核心"
    echo "5. ✅ 配置AdGuardHome LuCI识别"
  else
    echo "4. ⏭️ AdGuardHome已禁用"
  fi
  echo "========================================"
  if check_critical_files; then
    log_success "所有关键文件检查通过"
  else
    log_error "部分关键文件检查未通过"
  fi
}

# -------------------- 脚本开始执行 --------------------
SCRIPT_START_TIME=$(date +%s)
LOG_FILE="diy-part2-$(date +%Y%m%d_%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE")
log_step "OpenWrt DIY脚本启动 - CM520-79F"
log_info "目标设备: CM520-79F (IPQ40xx, ARMv7)"
log_info "脚本版本: Enhanced v2.10 (适配Opboot UBI, 支持Lean源码, 可选AdGuardHome)"
log_info "日志保存到: $LOG_FILE"

# 检查是否在OpenWrt构建环境中
if [ ! -d "openwrt" ] || [ ! -f "scripts/feeds" ]; then
  log_error "此脚本必须在OpenWrt构建环境中运行"
fi

# 检查依赖
check_dependencies() {
  local deps=("wget" "curl" "git" "patch" "tar")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      log_error "缺少依赖: $dep"
    fi
  done
  log_success "所有依赖检查通过"
}
check_dependencies

# 验证脚本语法
log_info "验证脚本语法..."
if bash -n "$0"; then
  log_success "脚本语法检查通过"
else
  log_error "脚本语法检查失败，请检查脚本内容"
fi

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
ENABLE_ADGUARD=${ENABLE_ADGUARD:-"y"}  # 默认启用AdGuardHome，可通过环境变量禁用

log_info "创建必要的目录结构"
mkdir -p "$ADGUARD_DIR" "$DTS_DIR" || log_error "创建目录结构失败"
chmod -R u+w "$DTS_DIR" || log_error "设置DTS目录权限失败"

# -------------------- 内核模块与工具配置 --------------------
log_step "配置内核模块与工具"
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config || log_error "配置 kmod-ubi 失败"
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config || log_error "配置 kmod-ubifs 失败"
echo "CONFIG_PACKAGE_trx=y" >> .config || log_error "配置 trx 失败"
echo "CONFIG_PACKAGE_kmod-ath10k-ct=y" >> .config || log_error "配置 kmod-ath10k-ct 失败"
echo "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" >> .config || log_error "配置 ipq-wifi-mobipromo_cm520-79f 失败"
log_success "已配置 kmod-ubi, kmod-ubifs, trx, kmod-ath10k-ct, ipq-wifi-mobipromo_cm520-79f"

# -------------------- DTS补丁处理 --------------------
log_step "下载并部署 mobipromo_cm520-79f 的 DTS 文件"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
BASE_DTS_URL="https://raw.githubusercontent.com/openwrt/openwrt/main/target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019.dts"
BASE_DTS_FILE="$DTS_DIR/qcom-ipq4019.dts"

log_info "检查Lean源码是否包含CM520-79F DTS"
if [ -f "feeds/lede/target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019-cm520-79f.dts" ]; then
  log_info "Lean源码已包含CM520-79F DTS，跳过补丁"
  cp "feeds/lede/target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019-cm520-79f.dts" "$TARGET_DTS" || log_error "复制Lean DTS失败"
else
  log_info "下载DTS补丁..."
  if retry_download "$DTS_PATCH_URL" "$DTS_PATCH_FILE"; then
    log_success "DTS补丁下载完成"
    if [ -s "$DTS_PATCH_FILE" ]; then
      log_info "验证补丁文件: $DTS_PATCH_FILE"
      if grep -q "qcom-ipq4019-cm520-79f.dts" "$DTS_PATCH_FILE"; then
        log_info "补丁文件针对 qcom-ipq4019-cm520-79f.dts"
      else
        log_warn "补丁文件可能不针对 qcom-ipq4019-cm520-79f.dts，尝试应用"
      fi
    else
      log_error "补丁文件为空或无效: $DTS_PATCH_FILE"
    fi
    if ! [ -f "$TARGET_DTS" ]; then
      log_info "目标DTS文件不存在，下载基础DTS文件: $BASE_DTS_URL"
      if retry_download "$BASE_DTS_URL" "$BASE_DTS_FILE"; then
        cp "$BASE_DTS_FILE" "$TARGET_DTS" || log_error "复制基础DTS文件到 $TARGET_DTS 失败"
        log_info "已创建初始DTS文件: $TARGET_DTS"
      else
        log_error "基础DTS文件下载失败"
      fi
    else
      log_info "目标DTS文件已存在: $TARGET_DTS，保留并应用补丁"
    fi
    if [ -f "$TARGET_DTS" ]; then
      cp "$TARGET_DTS" "$TARGET_DTS.bak-$(date +%Y%m%d_%H%M%S)" || log_error "备份DTS文件失败"
      log_info "已备份DTS文件: $TARGET_DTS.bak"
    fi
    if patch -d "$DTS_DIR" -p2 --dry-run < "$DTS_PATCH_FILE" >/dev/null 2>&1; then
      if patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" --verbose 2>&1 | tee /tmp/patch.log; then
        log_success "DTS补丁应用成功 (p2)"
        DTS_SIZE=$(stat -f%z "$TARGET_DTS" 2>/dev/null || stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
        log_success "DTS文件更新成功: $TARGET_DTS (大小: ${DTS_SIZE} 字节)"
      else
        log_error "DTS补丁应用失败 (p2)，查看 /tmp/patch.log"
      fi
    else
      log_info "尝试使用 -p1 应用补丁"
      if patch -d "$DTS_DIR" -p1 < "$DTS_PATCH_FILE" --verbose 2>&1 | tee /tmp/patch.log; then
        log_success "DTS补丁应用成功 (p1)"
        DTS_SIZE=$(stat -f%z "$TARGET_DTS" 2>/dev/null || stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
        log_success "DTS文件更新成功: $TARGET_DTS (大小: ${DTS_SIZE} 字节)"
      else
        log_error "DTS补丁应用失败 (p1 和 p2 均失败)，查看 /tmp/patch.log"
      fi
    fi
  else
    log_error "DTS补丁下载失败"
  fi
fi

# -------------------- 设备规则配置（参考脚本，适配 UBI） --------------------
log_step "配置设备规则"
if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
  log_info "添加CM520-79F设备规则（适配Opboot UBI）..."
  cat <<EOF >> "$GENERIC_MK" || log_error "添加设备规则失败"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  SUPPORTED_DEVICES := mobipromo,cm520-79f
  DEVICE_DTS_CONFIG := config@1
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128KiB
  PAGESIZE := 2048
  IMAGE/ubi := append-ubi | check-size \$(IMAGE_SIZE)
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
  log_success "CM520-79F设备规则添加成功"
else
  log_info "CM520-79F设备规则已存在，检查Opboot UBI兼容性"
  sed -i '/define Device\/mobipromo_cm520-79f/,/endef/ s/IMAGE\/trx :=.*/IMAGE\/ubi := append-ubi | check-size \$(IMAGE_SIZE)/' "$GENERIC_MK" || log_error "更新Opboot UBI映像格式失败"
  sed -i '/define Device\/mobipromo_cm520-79f/ a\  KERNEL_SIZE := 4096k\n  ROOTFS_SIZE := 16384k\n  UBINIZE_OPTS := -E 5\n  BLOCKSIZE := 128KiB\n  PAGESIZE := 2048' "$GENERIC_MK" || log_error "更新分区大小和UBI参数失败"
  log_success "已更新CM520-79F设备规则为UBI格式"
fi

# -------------------- 集成AdGuardHome核心（可选） --------------------
if [ "$ENABLE_ADGUARD" = "y" ]; then
  log_step "集成AdGuardHome核心"
  rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz" || log_error "清理历史文件失败"
  log_info "获取AdGuardHome最新版本下载地址..."
  ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep "browser_download_url.*linux_armv7" | cut -d '"' -f 4) || log_error "获取AdGuardHome下载地址失败"
  if [ -n "$ADGUARD_URL" ]; then
    if retry_download "$ADGUARD_URL" "$ADGUARD_DIR/AdGuardHome.tar.gz"; then
      TMP_DIR=$(mktemp -d) || log_error "创建临时目录失败"
      trap "rm -rf '$TMP_DIR'; log_info '清理临时目录: $TMP_DIR'" EXIT
      log_info "解压AdGuardHome核心到临时目录: $TMP_DIR"
      if tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword; then
        ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -n 1)
        if [ -n "$ADG_EXE" ]; then
          cp "$ADG_EXE" "$ADGUARD_DIR/" || log_error "复制AdGuardHome核心失败"
          chmod +x "$ADGUARD_DIR/AdGuardHome" || log_error "设置AdGuardHome执行权限失败"
          ADG_SIZE=$(stat -f%z "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || stat -c%s "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || echo "0")
          log_success "AdGuardHome核心复制成功 (大小: ${ADG_SIZE} 字节)"
        else
          log_error "未找到AdGuardHome可执行文件"
        fi
      else
        log_error "AdGuardHome核心解压失败"
      fi
      rm -rf "$TMP_DIR" "$ADGUARD_DIR/AdGuardHome.tar.gz" || log_info "清理临时文件失败（非致命）"
    else
      log_error "AdGuardHome核心下载失败"
    fi
  else
    log_error "未找到AdGuardHome核心下载地址"
  fi

  log_step "配置AdGuardHome LuCI识别"
  mkdir -p "package/base-files/files/etc/config" || log_error "创建配置目录失败"
  cat >"package/base-files/files/etc/config/adguardhome" <<EOF || log_error "创建AdGuardHome UCI配置文件失败"
config adguardhome 'main'
  option enabled '0'
  option binpath '/usr/bin/AdGuardHome'
  option configpath '/etc/AdGuardHome/AdGuardHome.yaml'
  option workdir '/etc/AdGuardHome'
  option logfile '/var/log/AdGuardHome.log'
  option verbose '0'
  option update '1'
EOF
  mkdir -p "package/base-files/files/etc/AdGuardHome" || log_error "创建AdGuardHome工作目录失败"
  cat >"package/base-files/files/etc/AdGuardHome/AdGuardHome.yaml" <<EOF || log_error "创建AdGuardHome YAML配置失败"
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: \$2y\$10\$gIAKp1l.BME2k5p6mMYlj..4l5mhc8YBGZzI8J/6z8s8nJlQ6oP4y
language: zh-cn
dns:
  bind_hosts:
    - 0.0.0.0
  port: 5353
  cache_size: 2097152
  max_goroutines: 100
  upstream_dns:
    - 223.5.5.5
    - 119.29.29.29
  bootstrap_dns:
    - 223.5.5.5:53
    - 119.29.29.29:53
  # ... 其他配置省略 ...
EOF
  mkdir -p "package/base-files/files/etc/init.d" || log_error "创建init.d目录失败"
  cat >"package/base-files/files/etc/init.d/adguardhome" <<'EOF' || log_error "创建AdGuardHome服务脚本失败"
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
PROG=/usr/bin/AdGuardHome
CONF=/etc/AdGuardHome/AdGuardHome.yaml
start_service() {
  config_load 'adguardhome'
  local enabled
  config_get_bool enabled 'main' 'enabled' '0'
  [ "$enabled" = '1' ] || return 1
  procd_open_instance AdGuardHome
  procd_set_param command "$PROG" --config "$CONF" --work-dir "/etc/AdGuardHome"
  procd_set_param pidfile /var/run/AdGuardHome.pid
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param respawn
  procd_close_instance
}
stop_service() {
  killall AdGuardHome 2>/dev/null
}
reload_service() {
  stop
  start
}
EOF
  chmod +x "package/base-files/files/etc/init.d/adguardhome" || log_error "设置AdGuardHome服务脚本权限失败"
  log_success "AdGuardHome配置完成"
else
  log_info "AdGuardHome已被禁用（ENABLE_ADGUARD=$ENABLE_ADGUARD）"
fi

# -------------------- 最终检查和配置清理 --------------------
log_step "执行最终配置检查和清理"
./scripts/feeds update -a || log_error "更新feeds失败"
./scripts/feeds install -a || log_error "安装feeds失败"
log_success "配置检查和清理完成"

# -------------------- 执行摘要 --------------------
print_summary "$SCRIPT_START_TIME"
