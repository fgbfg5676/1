#!/bin/bash
# 适用于现有GitHub Actions工作流的CM520-79F编译脚本
# 功能：处理DTS、配置编译参数、执行编译

# -------------------- 配置参数（根据你的工作流调整） --------------------
# 源码根目录（GitHub Actions中通常为${GITHUB_WORKSPACE}）
WORK_DIR="${GITHUB_WORKSPACE}"
# DTS相关路径
DTS_DIR="$WORK_DIR/target/linux/ipq40xx/files/arch/arm/boot/dts"
CM520_DTS="qcom-ipq4019-cm520-79f.dts"
BASE_DTS="qcom-ipq4019.dtsi"
# 补丁与基础DTS源
PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
BASE_DTS_URLS=(
  "https://raw.githubusercontent.com/coolsnowwolf/lede/master/target/linux/ipq40xx/files/arch/arm/boot/dts/$BASE_DTS"
  "https://mirror.ghproxy.com/https://raw.githubusercontent.com/coolsnowwolf/lede/master/target/linux/ipq40xx/files/arch/arm/boot/dts/$BASE_DTS"
)

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_warn() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }

# -------------------- 多源下载（适配云环境网络） --------------------
download_with_retry() {
  local output="$1"
  shift
  local urls=("$@")
  local max_tries=3

  for url in "${urls[@]}"; do
    for ((try=1; try<=max_tries; try++)); do
      if curl -fsSL --retry 2 -o "$output" "$url" || \
         wget -q --tries=2 -O "$output" "$url"; then
        if [ -s "$output" ]; then
          log_success "下载成功: $(basename "$output")"
          return 0
        fi
      fi
      sleep $((try * 5))
    done
  done
  log_error "下载失败: $(basename "$output")"
}

# -------------------- 核心：处理DTS（直接用补丁中的完整DTS） --------------------
process_dts() {
  log_info "处理CM520-79F设备树..."
  mkdir -p "$DTS_DIR"

  # 下载基础DTSI（必须）
  download_with_retry "$DTS_DIR/$BASE_DTS" "${BASE_DTS_URLS[@]}"

  # 从补丁提取完整DTS
  log_info "从补丁提取DTS内容..."
  download_with_retry "/tmp/cm520-patch.patch" "$PATCH_URL"
  
  # 提取补丁中的DTS主体（去除补丁前后缀）
  sed -n '/^+++ b\//,/^--$/p' /tmp/cm520-patch.patch | sed '1d;$d' > "$DTS_DIR/$CM520_DTS"
  
  # 修复路径前缀（如补丁中可能带的"root/"）
  sed -i 's/^root\///' "$DTS_DIR/$CM520_DTS"

  # 验证DTS语法（提前拦截错误）
  if ! dtc -I dts -O dtb -o /dev/null "$DTS_DIR/$CM520_DTS" 2>/tmp/dtc-err.log; then
    log_error "DTS语法错误！详情: $(cat /tmp/dtc-err.log)"
  fi
  log_success "DTS处理完成（语法验证通过）"
}

# -------------------- 配置编译参数 --------------------
configure_build() {
  log_info "配置编译参数..."
  cd "$WORK_DIR" || log_error "无法进入源码目录"

  # 更新feeds
  ./scripts/feeds update -a >/dev/null || log_error "feeds更新失败"
  ./scripts/feeds install -a >/dev/null || log_error "feeds安装失败"

  # 生成默认配置
  make defconfig >/dev/null || log_error "生成默认配置失败"

  # 添加必要模块（UBI/无线等）
  cat >> .config <<EOF
CONFIG_PACKAGE_kmod-ubi=y
CONFIG_PACKAGE_kmod-ubifs=y
CONFIG_PACKAGE_trx=y
CONFIG_PACKAGE_kmod-ath10k-ct=y
CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_UBIFS_COMPRESSION_ZSTD=y
EOF

  # 应用配置
  make defconfig >/dev/null || log_error "应用配置失败"
  log_success "编译参数配置完成"
}

# -------------------- 执行编译 --------------------
run_compile() {
  log_info "开始编译（线程数: $(nproc)）..."
  cd "$WORK_DIR" || log_error "无法进入源码目录"
  
  # 执行编译（-j参数自动适配CPU核心数）
  if ! make -j$(nproc) V=s; then
    log_error "编译失败"
  fi

  # 输出固件路径
  local firmware=$(find "$WORK_DIR/bin/targets/ipq40xx/generic/" -name "openwrt-ipq40xx-generic-mobipromo_cm520-79f-*.ubi" | head -1)
  if [ -f "$firmware" ]; then
    log_success "编译成功！固件路径: $firmware"
    log_success "固件大小: $(du -h "$firmware" | awk '{print $1}')"
  else
    log_error "未找到生成的固件"
  fi
}

# -------------------- 主流程 --------------------
main() {
  log_info "===== CM520-79F编译脚本启动 ====="
  process_dts      # 处理DTS（核心步骤）
  configure_build  # 配置编译参数
  run_compile      # 执行编译
  log_info "===== 流程结束 ====="
}

main "$@"
