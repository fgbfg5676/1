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
CUSTOM_DTS="../qcom-ipq4019-cm520-79f.dts"
DTS_URL="https://raw.githubusercontent.com/fgbfg5676/1/main/qcom-ipq4019-cm520-79f.dts"

# 创建必要目录
mkdir -p "$ADGUARD_DIR" "$ADGUARD_CONF_DIR" "$DTS_DIR" "$CUSTOM_PLUGINS_DIR" || log_error "创建目录失败"

# -------------------- 调试信息 --------------------
log_info "调试信息：当前工作目录：$(pwd)"
log_info "调试信息：仓库根目录文件列表："
ls -la .. || log_info "无法列出仓库根目录文件"
log_info "调试信息：当前目录文件列表："
ls -la . || log_info "无法列出当前目录文件"
log_info "调试信息：检查DTS文件：$CUSTOM_DTS"
log_info "调试信息：检查GitHub URL：$DTS_URL"

# -------------------- 替换自定义DTS文件 --------------------
log_info "替换自定义DTS文件..."
DTS_FOUND=0
# 检查大小写变体
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

# 尝试从GitHub下载
if [ "$DTS_FOUND" -eq 0 ]; then
  log_info "尝试从GitHub下载DTS文件..."
  if wget $WGET_OPTS -O "/tmp/qcom-ipq4019-cm520-79f.dts" "$DTS_URL"; then
    cp "/tmp/qcom-ipq4019-cm520-79f.dts" "$DTS_DIR/qcom-ipq4019-cm520-79f.dts" || log_error "复制下载的DTS文件失败"
    DTS_FOUND=1
    log_success "从GitHub下载并替换DTS文件"
  else
    log_info "尝试下载大写文件名版本..."
    if wget $WGET_OPTS -O "/tmp/qcom-ipq4019-cm520-79f.dts" "${DTS_URL/qcom/Qcom}"; then
      cp "/tmp/qcom-ipq4019-cm520-79f.dts" "$DTS_DIR/qcom-ipq4019-cm520-79f.dts" || log_error "复制下载的DTS文件失败"
      DTS_FOUND=1
      log_success "从GitHub下载大写文件名并替换DTS文件"
    fi
  fi
fi

if [ "$DTS_FOUND" -eq 0 ]; then
  log_error "未找到DTS文件：${DTS_PATTERNS[*]} 或 $DTS_URL"
fi

# 验证DTS文件语法
if command
