#!/bin/bash
# File name: diy-part2.sh
# Description: 完整适配Lean源码的CM520-79F编译脚本（优化网络与DTS）
# 功能：Lean源码DTS整合、多源下载、补丁应用、语法验证、完整功能配置

# -------------------- 日志与基础函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_warn() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_step() { 
  echo -e "[$(date +'%H:%M:%S')] \033[36m🔄 $*\033[0m"
  echo "----------------------------------------"
}

# 带重试的多源下载（解决网络不好问题）
download_with_retry() {
  local output="$1"
  shift
  local urls=("$@")
  local max_tries=5
  local try=1
  local url_index=0

  rm -f "$output"
  mkdir -p "$(dirname "$output")"

  while [ $url_index -lt ${#urls[@]} ]; do
    local url="${urls[$url_index]}"
    while [ $try -le $max_tries ]; do
      log_info "下载尝试 $try/$max_tries（源 $((url_index+1))）: $(basename "$url")"
      if command -v wget >/dev/null; then
        if wget -q --timeout=30 --tries=2 --retry-connrefused -O "$output" "$url"; then
          if [ -s "$output" ]; then
            log_success "下载成功: $(basename "$output")"
            return 0
          fi
        fi
      elif command -v curl >/dev/null; then
        if curl -fsSL --retry 2 --connect-timeout 10 -o "$output" "$url"; then
          if [ -s "$output" ]; then
            log_success "下载成功: $(basename "$output")"
            return 0
          fi
        fi
      fi
      try=$((try + 1))
      sleep $((try * 5))
    done
    try=1
    url_index=$((url_index + 1))
    log_warn "当前源失败，切换到第 $((url_index+1)) 个源"
  done
  log_error "所有源下载失败: $(basename "$output")"
}

# -------------------- 环境检查 --------------------
check_environment() {
  log_step "检查编译环境"
  local required_tools=("git" "patch" "make" "gcc" "g++" "dtc" "wget" "curl")
  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null; then
      log_info "安装缺失工具: $tool"
      sudo apt-get update >/dev/null
      sudo apt-get install -y "$tool" >/dev/null || log_error "安装 $tool 失败"
    fi
  done
  log_success "环境检查通过"
}

# -------------------- 核心配置变量 --------------------
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
CM520_DTS="qcom-ipq4019-cm520-79f.dts"
BASE_DTS="qcom-ipq4019.dtsi"
ENABLE_ADGUARD="y"

# Lean源码DTS镜像源（解决网络问题）
LEAN_DTS_BASE_URLS=(
  "https://raw.githubusercontent.com/coolsnowwolf/lede/master/target/linux/ipq40xx/files/arch/arm/boot/dts"
  "https://mirror.ghproxy.com/https://raw.githubusercontent.com/coolsnowwolf/lede/master/target/linux/ipq40xx/files/arch/arm/boot/dts"
  "https://raw.fastgit.org/coolsnowwolf/lede/master/target/linux/ipq40xx/files/arch/arm/boot/dts"
  "https://gitee.com/coolsnowwolf/lede/raw/master/target/linux/ipq40xx/files/arch/arm/boot/dts"
)

# 补丁与AdGuardHome源
DTS_PATCH_URLS=(
  "https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
  "https://mirror.ghproxy.com/https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
)
ADGUARD_URLS=(
  "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz"
  "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_armv7.tar.gz"
)

# -------------------- DTS处理（核心优化） --------------------
handle_dts() {
  log_step "配置Lean源码DTS文件"
  
  # 下载基础DTS（Lean源码核心依赖）
  download_with_retry \
    "$DTS_DIR/$BASE_DTS" \
    "${LEAN_DTS_BASE_URLS[@]/%//$BASE_DTS}"

  # 下载或创建CM520-79F专用DTS
  if ! download_with_retry \
    "$DTS_DIR/$CM520_DTS" \
    "${LEAN_DTS_BASE_URLS[@]/%//$CM520_DTS}"; then
    log_info "Lean源码无专用DTS，基于基础模板创建"
    cat > "$DTS_DIR/$CM520_DTS" <<EOF
/dts-v1/;
#include "$BASE_DTS"

/ {
    model = "MobiPromo CM520-79F";
    compatible = "mobipromo,cm520-79f", "qcom,ipq4019";
};

&nand {
    status = "okay";
    nand-ecc-strength = <4>;
    nand-ecc-step-size = <512>;
    partitions {
        compatible = "fixed-partitions";
        #address-cells = <1>;
        #size-cells = <1>;

        partition@0 { label = "SBL1"; reg = <0x0 0x100000>; read-only; };
        partition@100000 { label = "MIBIB"; reg = <0x100000 0x100000>; read-only; };
        partition@200000 { label = "QSEE"; reg = <0x200000 0x100000>; read-only; };
        partition@300000 { label = "CDT"; reg = <0x300000 0x80000>; read-only; };
        partition@380000 { label = "DDRPARAMS"; reg = <0x380000 0x80000>; read-only; };
        partition@400000 { label = "APPSBLENV"; reg = <0x400000 0x80000>; };
        partition@480000 { label = "APPSBL"; reg = <0x480000 0x100000>; read-only; };
        partition@580000 { label = "ART"; reg = <0x580000 0x80000>; read-only; };
        partition@600000 { label = "rootfs"; reg = <0x600000 0x7a00000>; };
    };
};

&wifi0 {
    status = "okay";
    qcom,ath10k-calibration-variant = "mobipromo-cm520-79f";
};

&wifi1 {
    status = "okay";
    qcom,ath10k-calibration-variant = "mobipromo-cm520-79f";
};

&gmac0 { status = "okay"; };
&gmac1 { status = "okay"; };
&uart0 { status = "okay"; };
EOF
    log_success "CM520-79F DTS模板创建完成"
  fi

  # 应用Opboot兼容补丁
  log_info "应用DTS补丁"
  download_with_retry \
    "/tmp/cm520-patch.patch" \
    "${DTS_PATCH_URLS[@]}"
  
  # 尝试自动适配补丁（支持不同补丁格式）
  if patch -d "$DTS_DIR" -p1 < /tmp/cm520-patch.patch 2>/dev/null; then
    log_success "DTS补丁应用成功"
  elif patch -d "$DTS_DIR" -p2 < /tmp/cm520-patch.patch 2>/dev/null; then
    log_success "DTS补丁应用成功（使用-p2）"
  else
    log_warn "补丁可能已集成或不兼容，跳过但继续执行"
  fi

  # DTS语法验证（提前发现错误）
  log_info "验证DTS语法"
  if dtc -I dts -O dtb -o /dev/null "$DTS_DIR/$CM520_DTS" 2>/tmp/dtc-error.log; then
    log_success "DTS语法验证通过"
  else
    log_error "DTS语法错误！详情: /tmp/dtc-error.log"
  fi
}

# -------------------- 设备规则配置 --------------------
configure_device_rules() {
  log_step "配置设备编译规则"
  if ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
    cat <<EOF >> "$GENERIC_MK"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := $CM520_DTS
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  SUPPORTED_DEVICES := mobipromo,cm520-79f
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128KiB
  PAGESIZE := 2048
  IMAGE/factory.ubi := append-ubi
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_success "CM520-79F设备规则添加成功"
  else
    log_info "设备规则已存在，更新UBI配置"
    sed -i '/define Device\/mobipromo_cm520-79f/,/endef/ s/IMAGE\/.*/IMAGE\/factory.ubi := append-ubi/' "$GENERIC_MK"
    log_success "设备规则更新完成"
  fi
}

# -------------------- 内核模块配置 --------------------
configure_kernel_modules() {
  log_step "配置内核模块"
  local config=".config"
  local modules=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
    "CONFIG_PACKAGE_kmod-ath10k-ct=y"
    "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y"
    "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
    "CONFIG_UBIFS_COMPRESSION_ZSTD=y"
  )
  for mod in "${modules[@]}"; do
    if ! grep -qxF "$mod" "$config"; then
      echo "$mod" >> "$config"
      log_info "添加内核模块: $mod"
    fi
  done
  log_success "内核模块配置完成"
}

# -------------------- AdGuardHome配置 --------------------
configure_adguard() {
  if [ "$ENABLE_ADGUARD" != "y" ]; then
    log_info "AdGuardHome已禁用"
    return 0
  fi
  log_step "配置AdGuardHome"
  
  mkdir -p "$ADGUARD_DIR"
  download_with_retry \
    "/tmp/AdGuardHome.tar.gz" \
    "${ADGUARD_URLS[@]}"
  
  # 解压并部署
  tar -zxf /tmp/AdGuardHome.tar.gz -C /tmp
  cp /tmp/AdGuardHome/AdGuardHome "$ADGUARD_DIR/"
  chmod +x "$ADGUARD_DIR/AdGuardHome"
  
  # 配置文件
  mkdir -p "package/base-files/files/etc/config"
  cat > "package/base-files/files/etc/config/adguardhome" <<EOF
config adguardhome 'main'
  option enabled '1'
  option binpath '/usr/bin/AdGuardHome'
  option configpath '/etc/AdGuardHome/AdGuardHome.yaml'
EOF
  
  log_success "AdGuardHome配置完成"
}

# -------------------- 最终配置 --------------------
finalize_config() {
  log_step "更新软件包索引"
  ./scripts/feeds update -a >/dev/null && ./scripts/feeds install -a >/dev/null
  log_success "软件包索引更新完成"
  
  log_success "所有配置步骤完成！可执行以下命令编译："
  echo "make -j$(nproc) V=s"
}

# -------------------- 主流程执行 --------------------
main() {
  log_step "CM520-79F 编译配置脚本启动（基于Lean源码）"
  check_environment
  handle_dts          # 核心：处理DTS文件（解决之前的语法错误）
  configure_device_rules
  configure_kernel_modules
  configure_adguard
  finalize_config
}

main "$@"
