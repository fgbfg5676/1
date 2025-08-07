#!/bin/bash
set -euo pipefail

# -------------------- 基础配置 --------------------
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
BACKUP_DTS="$TARGET_DTS.backup"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/cm520-79f.patch"
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"

# -------------------- 日志函数 --------------------
log_info() { echo -e "[INFO] $1"; }
log_error() { echo -e "[ERROR] $1"; exit 1; }
log_fatal() {
    echo -e "[FATAL] $1"
    if [ -f "$BACKUP_DTS" ]; then
        cp "$BACKUP_DTS" "$TARGET_DTS"
        echo "[FATAL] 已恢复原始DTS文件，系统可启动"
    fi
    exit 1
}

# -------------------- 1. 创建必要目录 --------------------
log_info "创建必要目录..."
mkdir -p "$DTS_DIR" "package/custom" || log_error "目录创建失败"
log_info "必要目录创建完成"

# -------------------- 2. 配置内核模块 --------------------
log_info "配置内核模块..."
REQUIRED_MODULES=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
)
for mod in "${REQUIRED_MODULES[@]}"; do
    sed -i "/$(echo "$mod" | cut -d'=' -f1)/d" .config
    echo "$mod" >> .config
done
log_info "内核模块配置完成"

# -------------------- 3. 集成Nikki --------------------
log_info "开始通过官方源集成Nikki..."
if ! grep -q "nikki.*$NIKKI_FEED" feeds.conf.default; then
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default
    log_info "已添加Nikki源到feeds"
fi
./scripts/feeds update nikki || log_error "Nikki源更新失败"
./scripts/feeds install -a -p nikki || log_error "Nikki包安装失败"
echo "CONFIG_PACKAGE_nikki=y" >> .config
echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
log_info "Nikki通过官方源集成完成"

# -------------------- 4. DTS补丁处理（核心修复） --------------------
log_info "检查目标设备树文件..."
[ -f "$TARGET_DTS" ] || log_fatal "目标DTS文件 $TARGET_DTS 不存在，系统无法启动"

log_info "将原始DTS文件备份到 $BACKUP_DTS..."
cp "$TARGET_DTS" "$BACKUP_DTS" || log_fatal "DTS备份失败"

log_info "下载DTS补丁并校验完整性..."
if ! wget -q -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL"; then
    log_fatal "补丁下载失败，请检查URL: $DTS_PATCH_URL"
fi

# 验证补丁文件是否完整（避免空文件或损坏）
if [ ! -s "$DTS_PATCH_FILE" ]; then
    log_fatal "下载的补丁文件为空或损坏"
fi

log_info "测试DTS补丁兼容性..."
if ! patch --dry-run -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" >/dev/null 2>&1; then
    log_fatal "补丁与目标DTS不兼容，可能导致系统无法启动"
fi

log_info "应用DTS补丁..."
if ! patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"; then
    log_fatal "补丁应用失败，已恢复原始DTS文件"
fi
rm -f "$DTS_PATCH_FILE"  # 清理补丁文件
log_info "DTS补丁处理完成（验证通过）"

# -------------------- 5. 配置设备规则 --------------------
log_info "配置设备规则..."
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
if ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
    cat <<EOF >> "$GENERIC_MK"
define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to \$$(KERNEL_SIZE) | append-rootfs | trx -o \$\@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_info "设备规则添加完成"
else
    log_info "设备规则已存在，跳过"
fi

# -------------------- 完成 --------------------
log_info "DIY脚本执行完成（无语法错误）"
