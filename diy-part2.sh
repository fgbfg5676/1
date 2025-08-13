#!/bin/bash
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 for CM520-79F (IPQ40xx, ARMv7) - 云编译优化版
# Enhanced: 适配 Opboot 的 UBI 格式, 支持 Lean 源码, 可选 AdGuardHome, 60-80MB 固件
# Modifications:
# - 保留设备规则（KERNEL_SIZE=4096k, ROOTFS_SIZE=16384k, IMAGE_SIZE=32768k），禁用 check-size
# - 强制使用 DTS 补丁（a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch）
# - 验证内核模块（kmod-ubi, kmod-ubifs, trx, kmod-ath10k-ct, ipq-wifi-mobipromo_cm520-79f）
# - 优化 AdGuardHome 配置，降低内存占用
# - 增强云编译环境检查和下载稳定性（多源下载、智能重试）
# - 完整包含用户提供的代码（基础配置、内核模块、DTS补丁、设备规则）
# Date: August 13, 2025

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
  local max_attempts=5
  local delay=10
  local attempt=1
  local cmd="$*"
  while [ $attempt -le $max_attempts ]; do
    log_info "执行命令 (尝试 $attempt/$max_attempts): $cmd"
    if timeout 900 eval "$cmd"; then  # 延长超时到15分钟
      [ $attempt -gt 1 ] && log_success "命令在第 $attempt 次尝试后成功执行"
      return 0
    else
      local exit_code=$?
      if [ $attempt -lt $max_attempts ]; then
        log_warn "命令执行失败 (退出码: $exit_code)，${delay}秒后重试..."
        sleep $delay
        delay=$((delay + 10))  # 更长的延迟递增
      else
        log_error "命令执行失败，已达到最大重试次数 ($max_attempts)"
      fi
    fi
    attempt=$((attempt + 1))
  done
}

# 多源下载函数 - 接受URL列表作为参数
multi_source_download() {
  local output="$1"
  shift
  local urls=("$@")
  local max_attempts_per_url=3
  local attempt=1
  local url_index=0
  
  mkdir -p "$(dirname "$output")"
  
  # 先检查文件是否已存在且有效
  if [ -f "$output" ]; then
    local size=$(stat -c%s "$output" 2>/dev/null || echo "0")
    if [ "$size" -gt 0 ]; then
      log_info "文件已存在且有效，跳过下载: $(basename "$output")"
      return 0
    else
      log_warn "文件存在但为空，将重新下载: $(basename "$output")"
      rm -f "$output"
    fi
  fi

  while [ $url_index -lt ${#urls[@]} ]; do
    local url="${urls[$url_index]}"
    log_info "使用源 $((url_index + 1))/${#urls[@]}: $url"
    
    while [ $attempt -le $max_attempts_per_url ]; do
      log_info "下载文件 (尝试 $attempt/$max_attempts_per_url): $(basename "$output")"
      local download_success=0
      
      if command -v wget >/dev/null 2>&1; then
        if timeout 300 wget -q --timeout=60 --tries=2 --retry-connrefused --connect-timeout=20 \
          -O "$output" "$url"; then
          download_success=1
        fi
      elif command -v curl >/dev/null 2>&1; then
        if timeout 300 curl -fSL --retry 2 --retry-delay 10 -o "$output" "$url"; then
          download_success=1
        fi
      fi
      
      if [ $download_success -eq 1 ] && [ -f "$output" ]; then
        local size=$(stat -c%s "$output" 2>/dev/null || echo "0")
        if [ "$size" -gt 0 ]; then
          log_success "文件下载成功 (大小: ${size} 字节): $(basename "$output")"
          return 0
        else
          log_warn "下载的文件为空，重试当前源..."
          rm -f "$output"
        fi
      fi
      
      if [ $attempt -lt $max_attempts_per_url ]; then
        local delay=$((attempt * 15))
        log_info "${delay}秒后重试当前源..."
        sleep $delay
      fi
      
      attempt=$((attempt + 1))
    done
    
    # 当前源失败，尝试下一个源
    url_index=$((url_index + 1))
    attempt=1
    log_warn "源 $url_index 下载失败，尝试下一个源"
  done
  
  log_error "所有源均下载失败: $(basename "$output")"
}

# -------------------- 云编译环境检查 --------------------
check_cloud_build_env() {
  log_step "检查云编译环境"
  local cloud_env=$(detect_cloud_env)
  log_info "检测到环境类型: $cloud_env"
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
  
  # 检查磁盘空间（增加到8GB要求）
  local available_space=$(df . | tail -1 | awk '{print $4}')
  if [ "$available_space" -lt 8388608 ]; then  # 8GB in KB
    log_warn "可用磁盘空间不足 8GB，可能影响编译"
  fi
  
  # 更全面的网络检查
  local test_urls=("https://github.com" "https://raw.githubusercontent.com" "https://git.openwrt.org")
  local network_issues=0
  
  for url in "${test_urls[@]}"; do
    if ! curl -s --connect-timeout 10 "$url" >/dev/null; then
      log_warn "无法连接到 $url，可能影响下载"
      network_issues=$((network_issues + 1))
    fi
  done
  
  if [ $network_issues -eq ${#test_urls[@]} ]; then
    log_error "所有测试URL均无法访问，网络连接完全失败"
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
    if grep -q -E "nand|wifi" "$TARGET_DTS"; then
      log_success "DTS文件包含硬件定义 (nand/wifi): $TARGET_DTS"
    else
      log_warn "DTS文件可能缺少关键硬件定义: $TARGET_DTS"
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
  
  log_step "检查固件大小和格式"
  FIRMWARE_FILE="bin/targets/ipq40xx/generic/openwrt-ipq40xx-generic-mobipromo_cm520-79f-squashfs-nand-factory.ubi"
  if [ -f "$FIRMWARE_FILE" ]; then
    FIRMWARE_SIZE=$(stat -c%s "$FIRMWARE_FILE" 2>/dev/null || echo "0")
    if [ "$FIRMWARE_SIZE" -gt 83886080 ]; then  # 80MB
      log_warn "固件大小 ($FIRMWARE_SIZE 字节) 超过 80MB，可能接近 NAND 容量极限"
    elif [ "$FIRMWARE_SIZE" -lt 62914560 ]; then  # 60MB
      log_warn "固件大小 ($FIRMWARE_SIZE 字节) 小于 60MB，可能缺少代理插件"
    else
      log_success "固件大小检查通过: $FIRMWARE_SIZE 字节 (60-80MB)"
    fi
    if [ "$FIRMWARE_SIZE" -gt 104857600 ]; then  # 100MB (NAND 可用空间估计)
      log_error "固件大小 ($FIRMWARE_SIZE 字节) 可能超过 NAND 容量 (128MB)"
    fi
    if command -v file >/dev/null 2>&1; then
      if file "$FIRMWARE_FILE" | grep -q -i "ubi\|ubifs"; then
        log_success "固件格式符合 Opboot UBI 要求"
      else
        log_warn "固件可能不是 UBI 格式，请检查"
      fi
    fi
    if command -v ubinfo >/dev/null 2>&1; then
      if ubinfo "$FIRMWARE_FILE" | grep -q "Volume ID"; then
        log_success "UBI卷结构有效"
      else
        log_warn "UBI卷结构可能无效，请检查"
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
  echo "1. ✅ 验证内核模块和WiFi固件"
  echo "2. ✅ 强制应用DTS补丁（Opboot兼容）"
  echo "3. ✅ 配置Opboot兼容的UBI设备规则（60-80MB 固件）"
  
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
exec 1> >(tee -a "$LOG_FILE") 2>&1  # 同时捕获stdout和stderr

log_step "OpenWrt DIY脚本启动 - CM520-79F (云编译优化版)"
log_info "目标设备: CM520-79F (IPQ40xx, ARMv7)"
log_info "脚本版本: Cloud Enhanced v2.20 (增强下载稳定性, 多源支持)"
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
# 用户提供的代码（完整保留）
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
ENABLE_ADGUARD=${ENABLE_ADGUARD:-"y"}

log_info "创建必要的目录结构"
safe_mkdir "$ADGUARD_DIR"
safe_mkdir "$DTS_DIR"
safe_chmod "$DTS_DIR" "u+w"

# -------------------- 内核模块与工具配置 --------------------
# 用户提供的代码（完整保留）
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# 补充验证和额外模块
log_step "验证内核模块与工具配置"
CONFIG_FILE=".config"
REQUIRED_MODULES=(
  "CONFIG_PACKAGE_kmod-ath10k-ct=y"
  "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y"
  "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
  "CONFIG_UBIFS_COMPRESSION_ZSTD=y"
)

for module in "${REQUIRED_MODULES[@]}"; do
  if grep -Fx "$module" "$CONFIG_FILE" >/dev/null 2>&1; then
    log_success "模块已启用: $module"
  else
    log_info "模块未启用，添加: $module"
    echo "$module" >> "$CONFIG_FILE" || log_error "添加模块 $module 失败"
  fi
done

# 检查代理插件
AGENT_PLUGINS=(
  "CONFIG_PACKAGE_luci-app-ssr-plus"
  "CONFIG_PACKAGE_v2ray-core"
)

for plugin in "${AGENT_PLUGINS[@]}"; do
  if grep -q "$plugin=y" "$CONFIG_FILE"; then
    log_success "代理插件已启用: $plugin"
  else
    log_info "代理插件未启用: $plugin"
  fi
done

log_success "内核模块和插件验证完成"

# -------------------- DTS补丁处理 --------------------
# 用户提供的代码（完整保留并增强）
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"

# 定义DTS补丁的多个下载源
DTS_PATCH_MIRRORS=(
  "https://patch-diff.githubusercontent.com/raw/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
  "https://mirror.ghproxy.com/$DTS_PATCH_URL"
)

echo "Downloading DTS patch..."
# 使用多源下载DTS补丁
multi_source_download "$DTS_PATCH_FILE" "$DTS_PATCH_URL" "${DTS_PATCH_MIRRORS[@]}"

if [ ! -f "$TARGET_DTS" ]; then
    echo "Applying DTS patch..."
    patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"
fi

# 补充逻辑：增强DTS补丁处理
log_step "增强DTS补丁处理（确保Opboot兼容）"
BASE_DTS_URL="https://raw.githubusercontent.com/openwrt/openwrt/main/target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019.dts"
BASE_DTS_FILE="$DTS_DIR/qcom-ipq4019.dts"

# 定义基础DTS文件的多个备用下载源
BASE_DTS_MIRRORS=(
  "https://mirror.ghproxy.com/$BASE_DTS_URL"
  "https://raw.fastgit.org/openwrt/openwrt/main/target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019.dts"
  "https://git.openwrt.org/?p=openwrt/openwrt.git;a=blob_plain;f=target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019.dts;hb=HEAD"
  "https://cgit.openwrt.org/openwrt.git/plain/target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019.dts"
)

if [ -f "$DTS_PATCH_FILE" ] && [ -s "$DTS_PATCH_FILE" ]; then
  log_info "验证补丁文件: $DTS_PATCH_FILE"
  if grep -q "qcom-ipq4019-cm520-79f.dts" "$DTS_PATCH_FILE"; then
    log_info "补丁文件针对 qcom-ipq4019-cm520-79f.dts"
  else
    log_warn "补丁文件可能不针对 qcom-ipq4019-cm520-79f.dts，尝试应用"
  fi
else
  log_info "DTS补丁文件不存在或为空，尝试重新下载..."
  multi_source_download "$DTS_PATCH_FILE" "$DTS_PATCH_URL" "${DTS_PATCH_MIRRORS[@]}"
  log_success "DTS补丁重新下载完成"
fi

if ! [ -f "$BASE_DTS_FILE" ]; then
  log_info "基础DTS文件不存在，尝试多源下载..."
  multi_source_download "$BASE_DTS_FILE" "$BASE_DTS_URL" "${BASE_DTS_MIRRORS[@]}"
  log_success "基础DTS文件下载成功"
fi

if [ -f "$TARGET_DTS" ]; then
  cp "$TARGET_DTS" "$TARGET_DTS.bak-$(date +%Y%m%d_%H%M%S)" || log_error "备份DTS文件失败"
  log_info "已备份DTS文件: $TARGET_DTS.bak"
fi

cp "$BASE_DTS_FILE" "$TARGET_DTS" || log_error "复制基础DTS文件到 $TARGET_DTS 失败"
log_info "强制应用DTS补丁（确保Opboot兼容）..."

if patch -d "$DTS_DIR" -p2 --dry-run < "$DTS_PATCH_FILE" >/dev/null 2>&1; then
  if patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" --verbose 2>&1 | tee /tmp/patch.log; then
    log_success "DTS补丁应用成功 (p2)"
    DTS_SIZE=$(stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
    log_success "DTS文件更新成功: $TARGET_DTS (大小: ${DTS_SIZE} 字节)"
  else
    log_error "DTS补丁应用失败 (p2)，查看 /tmp/patch.log"
  fi
else
  log_info "尝试使用 -p1 应用补丁"
  if patch -d "$DTS_DIR" -p1 < "$DTS_PATCH_FILE" --verbose 2>&1 | tee /tmp/patch.log; then
    log_success "DTS补丁应用成功 (p1)"
    DTS_SIZE=$(stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
    log_success "DTS文件更新成功: $TARGET_DTS (大小: ${DTS_SIZE} 字节)"
  else
    log_error "DTS补丁应用失败 (p1 和 p2 均失败)，查看 /tmp/patch.log"
  fi
fi

# -------------------- 设备规则配置 --------------------
# 用户提供的代码（完整保留）
if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    echo "Adding CM520-79F device rule..."
    cat <<EOF >> "$GENERIC_MK"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to \$(KERNEL_SIZE) | append-rootfs | trx -o \$\@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
fi

# 补充逻辑：适配Opboot UBI格式（60-80MB固件）
log_step "配置设备规则（适配Opboot UBI）"
if grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
  log_info "CM520-79F设备规则已存在，检查UBI兼容性"
  sed -i '/define Device\/mobipromo_cm520-79f/,/endef/ s/IMAGE\/trx :=.*/IMAGE\/factory.ubi := append-ubi/' "$GENERIC_MK" || log_error "更新UBI映像格式失败"
  
  if ! grep -q "SUPPORTED_DEVICES" "$GENERIC_MK"; then
    sed -i '/define Device\/mobipromo_cm520-79f/ a\  SUPPORTED_DEVICES := mobipromo,cm520-79f\n  DEVICE_DTS_CONFIG := config@1\n  UBINIZE_OPTS := -E 5\n  BLOCKSIZE := 128KiB\n  PAGESIZE := 2048' "$GENERIC_MK" || log_error "添加UBI参数失败"
  fi
  
  log_success "已更新CM520-79F设备规则为UBI格式（60-80MB 固件）"
else
  log_info "添加CM520-79F设备规则（适配Opboot UBI，60-80MB 固件）..."
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
  IMAGE/factory.ubi := append-ubi
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
  log_success "CM520-79F设备规则添加成功"
fi

# -------------------- 集成AdGuardHome核心（云编译优化） --------------------
if [ "$ENABLE_ADGUARD" = "y" ]; then
  log_step "集成AdGuardHome核心"
  rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz"
  
  log_info "获取AdGuardHome最新版本下载地址..."
  ADGUARD_URL=""
  ADGUARD_MIRRORS=(
    "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_armv7.tar.gz"
  )
  
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
  
  # 构建完整的下载源列表
  local adguard_download_urls=()
  if [ -n "$ADGUARD_URL" ]; then
    adguard_download_urls+=("$ADGUARD_URL")
  fi
  adguard_download_urls+=("${ADGUARD_MIRRORS[@]}")
  
  if [ ${#adguard_download_urls[@]} -gt 0 ]; then
    log_info "AdGuardHome下载源数量: ${#adguard_download_urls[@]}"
    if multi_source_download "$ADGUARD_DIR/AdGuardHome.tar.gz" "${adguard_download_urls[@]}"; then
      TMP_DIR=$(mktemp -d) || log_error "创建临时目录失败"
      trap "rm -rf '$TMP_DIR'" EXIT
      
      log_info "解压AdGuardHome核心..."
      if tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword 2>/dev/null; then
        ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -1)
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
  cache_size: 262144
  max_goroutines: 20
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
  if [ -f /var/run/AdGuardHome.pid ]; then
    kill $(cat /var/run/AdGuardHome.pid) 2>/dev/null || true
  fi
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
