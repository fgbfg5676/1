#!/bin/bash
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 for CM520-79F (IPQ40xx, ARMv7) - 云编译优化版
# Enhanced: 适配 Opboot 的 UBI 格式, 支持 Lean 源码, 可选 AdGuardHome, 云编译环境优化
# Cloud Optimizations:
# - 修复云编译环境检查逻辑
# - 增强网络下载稳定性
# - 优化文件权限处理
# - 添加云编译特有的错误处理

# -------------------- 云编译环境检测 --------------------
detect_cloud_env() {
  if [ -n "$GITHUB_WORKSPACE" ]; then
    echo "GitHub Actions"
  elif [ -n "$CI" ]; then
    echo "Generic CI"
  elif [ -n "$GITLAB_CI" ]; then
    echo "GitLab CI"
  else
    echo "Local"
  fi
}

# -------------------- 日志记录函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_warn() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_step() {
  echo -e "[$(date +'%H:%M:%S')] \033[36m🔄 $*\033[0m"
  echo "----------------------------------------"
}

# -------------------- 云编译专用重试函数 --------------------
retry_command() {
  local max_attempts=5  # 云编译增加重试次数
  local delay=10        # 增加延迟时间
  local attempt=1
  local cmd="$*"
  while [ $attempt -le $max_attempts ]; do
    log_info "执行命令 (尝试 $attempt/$max_attempts): $cmd"
    if timeout 300 eval "$cmd"; then  # 添加超时控制
      [ $attempt -gt 1 ] && log_success "命令在第 $attempt 次尝试后成功执行"
      return 0
    else
      local exit_code=$?
      if [ $attempt -lt $max_attempts ]; then
        log_warn "命令执行失败 (退出码: $exit_code)，${delay}秒后重试..."
        sleep $delay
        delay=$((delay + 5))  # 递增延迟
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
  local max_attempts=5
  local attempt=1
  
  # 创建输出目录
  mkdir -p "$(dirname "$output")"
  
  while [ $attempt -le $max_attempts ]; do
    log_info "下载文件 (尝试 $attempt/$max_attempts): $url"
    
    # 使用多种下载工具
    local download_success=0
    if command -v wget >/dev/null 2>&1; then
      if timeout 120 wget $WGET_OPTS -O "$output" "$url"; then
        download_success=1
      fi
    elif command -v curl >/dev/null 2>&1; then
      if timeout 120 curl -fSL --retry 3 --retry-delay 5 -o "$output" "$url"; then
        download_success=1
      fi
    fi
    
    if [ $download_success -eq 1 ] && [ -f "$output" ]; then
      local size=$(stat -c%s "$output" 2>/dev/null || echo "0")
      if [ "$size" -gt 0 ]; then
        log_success "文件下载成功 (大小: ${size} 字节): $(basename "$output")"
        return 0
      else
        log_warn "下载的文件为空，重试..."
        rm -f "$output"
      fi
    fi
    
    if [ $attempt -lt $max_attempts ]; then
      local delay=$((attempt * 10))
      log_info "${delay}秒后重试..."
      sleep $delay
    fi
    attempt=$((attempt + 1))
  done
  log_error "文件下载失败，已达到最大重试次数: $url"
}

# -------------------- 云编译环境检查 --------------------
check_cloud_build_env() {
  log_step "检查云编译环境"
  
  local cloud_env=$(detect_cloud_env)
  log_info "检测到环境类型: $cloud_env"
  
  # 检查必要文件和目录
  local critical_files=("scripts/feeds" "Config.in" "Makefile")
  local critical_dirs=("package" "target" "scripts")
  
  for file in "${critical_files[@]}"; do
    if [ ! -f "$file" ]; then
      log_error "关键文件缺失: $file (请确保脚本在 OpenWrt 源码根目录运行)"
    fi
  done
  
  for dir in "${critical_dirs[@]}"; do
    if [ ! -d "$dir" ]; then
      log_error "关键目录缺失: $dir"
    fi
  done
  
  # 检查磁盘空间
  local available_space=$(df . | tail -1 | awk '{print $4}')
  if [ "$available_space" -lt 1048576 ]; then  # 1GB in KB
    log_warn "可用磁盘空间不足 1GB，可能影响编译"
  fi
  
  log_success "云编译环境检查通过"
}

# -------------------- 权限安全处理 --------------------
safe_chmod() {
  local target="$1"
  local permissions="$2"
  if [ -e "$target" ]; then
    if chmod "$permissions" "$target" 2>/dev/null; then
      log_info "权限设置成功: $target ($permissions)"
    else
      log_warn "权限设置失败，但继续执行: $target"
    fi
  else
    log_warn "目标不存在，跳过权限设置: $target"
  fi
}

safe_mkdir() {
  local dir="$1"
  if mkdir -p "$dir" 2>/dev/null; then
    log_info "目录创建成功: $dir"
  else
    log_warn "目录创建失败，但继续执行: $dir"
  fi
}

# -------------------- 文件检查函数 --------------------
check_critical_files() {
  local errors=0
  log_step "执行关键文件检查"
  
  if [ -f "$TARGET_DTS" ]; then
    local size=$(stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
    if [ "$size" -lt 1000 ]; then
      log_error "DTS文件太小 ($size 字节，预期至少 1000 字节): $TARGET_DTS"
    fi
    log_success "DTS文件存在: $TARGET_DTS (大小: ${size} 字节)"
  else
    log_error "DTS文件缺失: $TARGET_DTS"
  fi
  
  if [ "$ENABLE_ADGUARD" = "y" ]; then
    if [ -f "$ADGUARD_DIR/AdGuardHome" ]; then
      local size=$(stat -c%s "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || echo "0")
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
  
  # 检查固件大小
  log_step "检查固件大小"
  FIRMWARE_FILE="bin/targets/ipq40xx/generic/openwrt-ipq40xx-generic-mobipromo_cm520-79f-squashfs-nand-factory.ubi"
  if [ -f "$FIRMWARE_FILE" ]; then
    FIRMWARE_SIZE=$(stat -c%s "$FIRMWARE_FILE" 2>/dev/null || echo "0")
    if [ "$FIRMWARE_SIZE" -gt 33554432 ]; then  # 32MB
      log_warn "固件大小 ($FIRMWARE_SIZE 字节) 可能超过 32MB 限制"
    else
      log_success "固件大小检查通过: $FIRMWARE_SIZE 字节"
    fi
    
    # 检查 UBI 格式
    if command -v file >/dev/null 2>&1; then
      if file "$FIRMWARE_FILE" | grep -q -i "ubi\|ubifs"; then
        log_success "固件格式符合 Opboot UBI 要求"
      else
        log_warn "固件可能不是 UBI 格式，请检查"
      fi
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
  local cloud_env=$(detect_cloud_env)
  
  echo ""
  echo "========================================"
  log_success "DIY脚本执行完成！"
  echo "========================================"
  log_info "环境类型: $cloud_env"
  log_info "总耗时: ${minutes}分${seconds}秒"
  log_info "日志已保存到: $LOG_FILE"
  echo ""
  echo "已完成配置："
  echo "1. ✅ 配置内核模块和WiFi固件"
  echo "2. ✅ 应用DTS补丁（Opboot兼容）"
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

log_step "OpenWrt DIY脚本启动 - CM520-79F (云编译优化版)"
log_info "目标设备: CM520-79F (IPQ40xx, ARMv7)"
log_info "脚本版本: Cloud Enhanced v2.12 (适配云编译环境)"
log_info "日志保存到: $LOG_FILE"

# 检查云编译环境
check_cloud_build_env

# 检查依赖
check_dependencies() {
  local deps=("git" "patch" "tar")
  local optional_deps=("wget" "curl")
  
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      log_error "缺少必需依赖: $dep"
    fi
  done
  
  # 检查下载工具
  local has_downloader=0
  for dep in "${optional_deps[@]}"; do
    if command -v "$dep" >/dev/null 2>&1; then
      has_downloader=1
      log_info "发现下载工具: $dep"
    fi
  done
  
  if [ $has_downloader -eq 0 ]; then
    log_error "缺少下载工具 (需要 wget 或 curl)"
  fi
  
  log_success "依赖检查通过"
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
WGET_OPTS="-q --timeout=60 --tries=5 --retry-connrefused --connect-timeout=30"
ARCH="armv7"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
ENABLE_ADGUARD=${ENABLE_ADGUARD:-"y"}  # 默认启用AdGuardHome

log_info "创建必要的目录结构"
safe_mkdir "$ADGUARD_DIR"
safe_mkdir "$DTS_DIR"
safe_chmod "$DTS_DIR" "u+w"

# -------------------- 内核模块与工具配置 --------------------
log_step "配置内核模块与工具"
{
  echo "CONFIG_PACKAGE_kmod-ubi=y"
  echo "CONFIG_PACKAGE_kmod-ubifs=y"
  echo "CONFIG_PACKAGE_trx=y"
  echo "CONFIG_PACKAGE_kmod-ath10k-ct=y"
  echo "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y"
} >> .config || log_error "配置内核模块失败"
log_success "已配置 UBI/WiFi 相关模块"

# -------------------- DTS补丁处理（智能应用） --------------------
log_step "下载并部署 mobipromo_cm520-79f 的 DTS 补丁"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"

log_info "下载DTS补丁..."
if retry_download "$DTS_PATCH_URL" "$DTS_PATCH_FILE"; then
  log_success "DTS补丁下载完成"
  
  # 智能应用补丁
  log_info "智能应用DTS补丁..."
  patch_applied=0
  
  for patch_level in 0 1 2 3; do
    if patch -d "$DTS_DIR" -p$patch_level --dry-run < "$DTS_PATCH_FILE" >/dev/null 2>&1; then
      log_info "使用 -p$patch_level 应用补丁"
      if patch -d "$DTS_DIR" -p$patch_level < "$DTS_PATCH_FILE" --verbose 2>&1 | tee /tmp/patch.log; then
        log_success "DTS补丁应用成功 (p$patch_level)"
        DTS_SIZE=$(stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
        log_success "DTS文件更新成功: $TARGET_DTS (大小: ${DTS_SIZE} 字节)"
        patch_applied=1
        break
      else
        log_warn "DTS补丁应用失败 (p$patch_level)"
      fi
    fi
  done
  
  if [ $patch_applied -eq 0 ]; then
    log_error "DTS补丁应用失败，所有patch level均无效"
  fi
else
  log_error "DTS补丁下载失败"
fi

# -------------------- 设备规则配置（防重复添加） --------------------
log_step "配置设备规则"
if ! grep -A 20 "define Device/mobipromo_cm520-79f" "$GENERIC_MK" | grep -q "TARGET_DEVICES.*mobipromo_cm520-79f"; then
  log_info "添加CM520-79F设备规则（适配Opboot UBI）..."
  cat <<'EOF' >> "$GENERIC_MK" || log_error "添加设备规则失败"

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
  IMAGE/factory.ubi := append-ubi | check-size $(IMAGE_SIZE)
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
  log_success "CM520-79F设备规则添加成功"
else
  log_info "CM520-79F设备规则已存在，跳过添加"
fi

# -------------------- 集成AdGuardHome核心（云编译优化） --------------------
if [ "$ENABLE_ADGUARD" = "y" ]; then
  log_step "集成AdGuardHome核心"
  
  # 清理旧文件
  rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz"
  
  log_info "获取AdGuardHome最新版本下载地址..."
  ADGUARD_URL=""
  
  # 使用多种方式获取下载地址
  if command -v curl >/dev/null 2>&1; then
    ADGUARD_URL=$(timeout 60 curl -s --retry 3 --connect-timeout 15 \
      "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | \
      grep '"browser_download_url":.*linux_armv7' | \
      cut -d '"' -f 4 | head -1)
  elif command -v wget >/dev/null 2>&1; then
    ADGUARD_URL=$(timeout 60 wget -qO- --tries=3 --connect-timeout=15 \
      "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | \
      grep '"browser_download_url":.*linux_armv7' | \
      cut -d '"' -f 4 | head -1)
  fi
  
  if [ -n "$ADGUARD_URL" ]; then
    log_info "下载地址: $ADGUARD_URL"
    
    if retry_download "$ADGUARD_URL" "$ADGUARD_DIR/AdGuardHome.tar.gz"; then
      TMP_DIR=$(mktemp -d) || log_error "创建临时目录失败"
      trap "rm -rf '$TMP_DIR'" EXIT
      
      log_info "解压AdGuardHome核心..."
      if tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword 2>/dev/null; then
        ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -n 1)
        if [ -n "$ADG_EXE" ] && [ -f "$ADG_EXE" ]; then
          cp "$ADG_EXE" "$ADGUARD_DIR/" || log_error "复制AdGuardHome核心失败"
          safe_chmod "$ADGUARD_DIR/AdGuardHome" "+x"
          ADG_SIZE=$(stat -c%s "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || echo "0")
          log_success "AdGuardHome核心部署成功 (大小: ${ADG_SIZE} 字节)"
        else
          log_error "未找到AdGuardHome可执行文件"
        fi
      else
        log_error "AdGuardHome核心解压失败"
      fi
      
      rm -rf "$TMP_DIR" "$ADGUARD_DIR/AdGuardHome.tar.gz"
    else
      log_error "AdGuardHome核心下载失败"
    fi
  else
    log_error "未找到AdGuardHome核心下载地址"
  fi

  # 配置AdGuardHome（简化版，避免冲突）
  log_step "配置AdGuardHome"
  safe_mkdir "package/base-files/files/etc/config"
  cat >"package/base-files/files/etc/config/adguardhome" <<'EOF' || log_error "创建AdGuardHome UCI配置失败"
config adguardhome 'main'
	option enabled '0'
	option binpath '/usr/bin/AdGuardHome'
	option configpath '/etc/AdGuardHome/AdGuardHome.yaml'
	option workdir '/etc/AdGuardHome'
	option logfile '/var/log/AdGuardHome.log'
	option verbose '0'
	option update '1'
EOF

  safe_mkdir "package/base-files/files/etc/AdGuardHome"
  cat >"package/base-files/files/etc/AdGuardHome/AdGuardHome.yaml" <<'EOF' || log_error "创建AdGuardHome配置失败"
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: $2y$10$gIAKp1l.BME2k5p6mMYlj..4l5mhc8YBGZzI8J/6z8s8nJlQ6oP4y
language: zh-cn
dns:
  bind_hosts:
    - 127.0.0.1
  port: 5353
  cache_size: 1048576
  upstream_dns:
    - 223.5.5.5
    - 119.29.29.29
  bootstrap_dns:
    - 223.5.5.5:53
    - 119.29.29.29:53
filters:
  - enabled: true
    url: https://anti-ad.net/easylist.txt
    name: anti-AD
    id: 1
EOF

  safe_mkdir "package/base-files/files/etc/init.d"
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
	killall AdGuardHome 2>/dev/null || true
}

reload_service() {
	stop
	start
}
EOF
  
  safe_chmod "package/base-files/files/etc/init.d/adguardhome" "+x"
  log_success "AdGuardHome配置完成"
else
  log_info "AdGuardHome已被禁用（ENABLE_ADGUARD=$ENABLE_ADGUARD）"
fi

# -------------------- 最终检查和配置更新 --------------------
log_step "执行最终配置检查"
retry_command "./scripts/feeds update -a"
retry_command "./scripts/feeds install -a"
log_success "配置检查和更新完成"

# -------------------- 执行摘要 --------------------
print_summary "$SCRIPT_START_TIME"
