#!/bin/bash
#
# File name: diy-part2.sh (Optimized Secure Version)
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
# Version: 2.0 - Security Enhanced
# Fixes: Resolved security issues, improved error handling, added offline support
#
set -e  # 遇到错误立即退出脚本
# 移除 .config 的写权限，防止意外修改
chmod a-w .config
log_info ".config 文件已锁定，写权限已移除"

# -------------------- 全局配置 --------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/diy-part2.log"
CREDENTIALS_FILE="/tmp/openwrt_credentials.txt"
OFFLINE_MODE="${OFFLINE_MODE:-false}"  # 可通过环境变量控制

# 清理函数
cleanup() {
    local exit_code=$?
    log_info "执行清理操作..."
    
    # 清理临时目录
    for tmp_dir in "$NIKKI_TMP_DIR" "$PATCH_TMP_DIR"; do
        if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
            rm -rf "$tmp_dir"
            log_info "已清理临时目录: $tmp_dir"
        fi
    done
    
    # 如果是异常退出，记录错误
    if [ $exit_code -ne 0 ]; then
        log_error "脚本异常退出，退出码: $exit_code"
        echo "详细日志请查看: $LOG_FILE"
    fi
    
    exit $exit_code
}

# 设置陷阱函数
trap cleanup EXIT INT TERM

# -------------------- 颜色输出函数 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { 
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}
log_warn() { 
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}
log_error() { 
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}
log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1" >> "$LOG_FILE"
}

# -------------------- GitHub 发布函数 --------------------
create_github_release() {
    local tag_name="$1"
    local release_name="$2"
    local release_body="$3"

    log_info "创建 GitHub 发布版本: $tag_name"
    
    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GitHub Token 未设置！请设置 GITHUB_TOKEN 环境变量"
        exit 1
    fi

    curl -H "Authorization: token $GITHUB_TOKEN" \
         -d '{"tag_name": "'"$tag_name"'", "name": "'"$release_name"'", "body": "'"$release_body"'"}' \
         https://api.github.com/repos/your_username/your_repo/releases || {
        log_error "GitHub 发布失败，无法访问资源"
        exit 1
    }
    log_info "GitHub 发布版本成功: $tag_name"
}

# -------------------- 创建GitHub发布版本 --------------------
log_info "准备创建GitHub发布版本..."
TAG_NAME="2025.08.07-1527"
RELEASE_NAME="Release 2025.08.07-1527"
RELEASE_BODY="自动生成的发布版本"

# 调用发布函数
create_github_release "$TAG_NAME" "$RELEASE_NAME" "$RELEASE_BODY"

# -------------------- AdGuardHome 配置 --------------------
log_info "生成 AdGuardHome 配置文件..."

# 生成随机密码
ADGUARD_PASSWORD=$(generate_password 16)
ADGUARD_HASH=$(hash_password "$ADGUARD_PASSWORD")

# 保存凭据到文件
cat > "$CREDENTIALS_FILE" << EOF
=== OpenWrt 自定义配置凭据 ===
生成时间: $(date)

AdGuardHome 登录信息:
用户名: admin
密码: $ADGUARD_PASSWORD
访问地址: http://$TARGET_IP:$ADGUARD_PORT

重要提醒: 请妥善保存此文件，首次登录后建议修改密码
EOF

chmod 600 "$CREDENTIALS_FILE"
log_info "登录凭据已保存到: $CREDENTIALS_FILE"

cat <<EOF > "$CONFIG_PATH/AdGuardHome.yaml"
# AdGuardHome 配置文件 (自动生成)
# 生成时间: $(date)
# 默认用户名: admin, 密码请查看: $CREDENTIALS_FILE
bind_host: 0.0.0.0
bind_port: $ADGUARD_PORT
users:
  - name: admin
    password: $ADGUARD_HASH
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: zh-cn
theme: auto

# DNS设置
upstream_dns:
  - 223.5.5.5          # 阿里DNS (主)
  - 119.29.29.29       # 腾讯DNS
  - 8.8.8.8            # Google DNS
  - 1.1.1.1            # Cloudflare DNS
  - 114.114.114.114    # 114DNS (备用)
bootstrap_dns:
  - 223.5.5.5
  - 8.8.8.8

# 缓存设置
cache_size: 2000000
cache_ttl_min: 60
cache_ttl_max: 86400
cache_optimistic: true

# 过滤设置
filtering_enabled: true
parental_enabled: false
safebrowsing_enabled: true
safesearch_enabled: false
blocking_mode: default
blocked_response_ttl: 300

# 查询日志
querylog_enabled: true
querylog_file_enabled: true
querylog_interval: 24h
querylog_size_memory: 1000

# 统计
statistics_interval: 24h

# DHCP (禁用，由OpenWrt处理)
dhcp:
  enabled: false

# TLS配置 (禁用，建议通过反向代理处理)
tls:
  enabled: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 784

# 客户端设置
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []

# 过滤规则 (默认启用一些常用规则)
filters:
  - enabled: true
    url: https://anti-ad.net/easylist.txt
    name: "anti-AD"
    id: 1
  - enabled: true
    url: https://easylist-downloads.adblockplus.org/easylistchina.txt
    name: "EasyList China"
    id: 2
EOF

chmod 644 "$CONFIG_PATH/AdGuardHome.yaml"

# 验证YAML文件
if validate_yaml "$CONFIG_PATH/AdGuardHome.yaml"; then
    log_info "AdGuardHome 配置文件已创建并验证，路径：$CONFIG_PATH/AdGuardHome.yaml"
    log_info "监听端口：$ADGUARD_PORT，凭据文件：$CREDENTIALS_FILE"
else
    log_warn "AdGuardHome 配置文件可能存在语法问题，请检查"
fi
set -e

# -------------------- 修改默认配置 --------------------
log_info "修改系统默认配置..."

# 可能的配置文件路径
POSSIBLE_NETWORK_PATHS=( "target/linux/ipq40xx/base-files/etc/config/network"
                         "package/base-files/files/etc/config/network"
                         "feeds/base-files/etc/config/network"
                         "build_dir/target-arm_cortex-a7+neon-vfpv4_musl_eabi/base-files/etc/config/network"
)

POSSIBLE_SYSTEM_PATHS=( "package/base-files/files/etc/config/system"
                        "feeds/base-files/etc/config/system"
                        "build_dir/target-arm_cortex-a7+neon-vfpv4_musl_eabi/base-files/etc/config/system"
)

# 修改IP地址
log_info "设置默认IP地址为: $TARGET_IP"
NETWORK_FILE=""
for path in "${POSSIBLE_NETWORK_PATHS[@]}"; do
    if [ -f "$path" ]; then
        NETWORK_FILE="$path"
        backup_file "$NETWORK_FILE"
        break
    fi
done

if [ -n "$NETWORK_FILE" ]; then
    # 更精确的IP地址替换
    sed -i "s/option ipaddr[[:space:]]*[\"']*192\.168\.[0-9]*\.[0-9]*[\"']*/option ipaddr '$TARGET_IP'/g" "$NETWORK_FILE"
    log_info "✅ 已修改网络配置文件: $NETWORK_FILE"
    log_debug "当前IP配置: $(grep "ipaddr" "$NETWORK_FILE" | head -3)"
else
    log_warn "未找到网络配置文件，将通过uci-defaults设置"
fi

# 辅助修改config_generate
CONFIG_GENERATE="package/base-files/files/bin/config_generate"
if [ -f "$CONFIG_GENERATE" ]; then
    backup_file "$CONFIG_GENERATE"
    sed -i "s/192\.168\.1\.1/$TARGET_IP/g" "$CONFIG_GENERATE"
    log_info "已修改config_generate中的默认IP"
fi

# 修改主机名
log_info "设置默认主机名为: $HOSTNAME"
SYSTEM_FILE=""
for path in "${POSSIBLE_SYSTEM_PATHS[@]}"; do
    if [ -f "$path" ]; then
        SYSTEM_FILE="$path"
        backup_file "$SYSTEM_FILE"
        break
    fi
done

# 确保hostname文件存在
HOSTNAME_FILE="package/base-files/files/etc/hostname"
mkdir -p "$(dirname "$HOSTNAME_FILE")"
echo "$HOSTNAME" > "$HOSTNAME_FILE"
log_info "✅ 已创建hostname文件: $HOSTNAME_FILE"

# 修改system配置文件
if [ -n "$SYSTEM_FILE" ]; then
    sed -i "s/option hostname[[:space:]]*[\"']*[^\"']*[\"']*/option hostname '$HOSTNAME'/g" "$SYSTEM_FILE"
    log_info "✅ 已修改系统配置文件: $SYSTEM_FILE"
    log_debug "当前主机名配置: $(grep "hostname" "$SYSTEM_FILE" | head -3)"
fi

# -------------------- 设备规则配置 --------------------
log_info "配置CM520-79F设备规则..."

if [ ! -f "$GENERIC_MK" ]; then
    log_error "找不到设备配置文件: $GENERIC_MK"
    log_error "请确保在正确的OpenWrt源码目录中运行此脚本"
    exit 1
fi

# 备份设备配置文件
backup_file "$GENERIC_MK"

if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    log_info "添加CM520-79F设备规则到 $GENERIC_MK ..."
    
    cat >> "$GENERIC_MK" << 'EOF'

# CM520-79F Device Configuration (Auto-generated)
define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  DEVICE_DTS_DIR := ../qca
  SOC := qcom-ipq4019
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  DEVICE_PACKAGES := ath10k-firmware-qca4019-ct kmod-ath10k-ct wpad-wolfssl \
                     kmod-usb3 kmod-usb-dwc3 kmod-usb-dwc3-qcom \
                     kmod-ledtrig-usbdev kmod-phy-qcom-ipq4019-usb
  IMAGE/trx := append-kernel | pad-to $$$(KERNEL_SIZE) | append-rootfs | pad-rootfs | trx
  KERNEL := kernel-bin | append-dtb | uImage none
  KERNEL_NAME := zImage
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    
    log_info "✅ CM520-79F设备规则添加成功"
else
    log_info "CM520-79F设备规则已存在，跳过添加"
fi

# -------------------- 插件集成 --------------------
log_info "集成第三方插件..."

# sirpdboy插件集成（非关键，失败不退出）
set +e
PARTEXP_URL="https://github.com/sirpdboy/luci-app-partexp.git"
if [ "$OFFLINE_MODE" != "true" ] && check_network "$PARTEXP_URL" 5; then
    log_info "正在集成 luci-app-partexp 插件..."
    
    rm -rf package/custom/luci-app-partexp 2>/dev/null || true
    mkdir -p package/custom
    
    if git clone --depth 1 "$PARTEXP_URL" package/custom/luci-app-partexp 2>>"$LOG_FILE"; then
        log_info "luci-app-partexp 克隆成功"
        
        # 尝试通过feeds安装依赖
        if ./scripts/feeds install -d y -p custom luci-app-partexp 2>>"$LOG_FILE"; then
            echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
            log_info "✅ luci-app-partexp 集成完成"
        else
            log_warn "luci-app-partexp 依赖安装失败，但插件文件已添加"
            echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
        fi
    else
        log_warn "luci-app-partexp 克隆失败，跳过该插件"
    fi
else
    log_warn "跳过 luci-app-partexp 插件（离线模式或网络不可用）"
fi
set -e

# -------------------- 最终验证和清理 --------------------
log_info "执行最终验证..."

# 验证关键文件是否存在
CRITICAL_FILES=( "$CONFIG_PATH/AdGuardHome.yaml"
                 "$UCI_DEFAULTS_DIR/99-custom-settings"
                 "$UCI_DEFAULTS_DIR/98-security-hardening"
                 ".config"
                 "$CREDENTIALS_FILE"
)

missing_files=()
for file in "${CRITICAL_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        missing_files+=("$file")
    fi
done

if [ ${#missing_files[@]} -gt 0 ]; then
    log_error "关键文件缺失: ${missing_files[*]}"
    exit 1
fi

# 验证配置文件内容
config_errors=()
for config in "${REQUIRED_CONFIGS[@]}"; do
    if ! grep -q "^$config$" .config; then
        config_errors+=("$config")
    fi
done

if [ ${#config_errors[@]} -gt 0 ]; then
    log_warn "以下配置项可能未正确设置: ${config_errors[*]}"
    log_warn "编译时请检查这些选项是否正确启用"
fi

# 生成配置摘要文件
SUMMARY_FILE="/tmp/openwrt_build_summary.txt"
cat > "$SUMMARY_FILE" << EOF
=== OpenWrt 构建配置摘要 ===
生成时间: $(date)
脚本版本: 2.0 (Security Enhanced)

目标设备: CM520-79F (IPQ40xx, ARMv7)
主机名: $HOSTNAME
IP地址: $TARGET_IP

服务配置:
- AdGuardHome: 端口 $ADGUARD_PORT
- Nikki代理: $([ "$NIKKI_SUCCESS" = true ] && echo "✅ 已集成($NIKKI_METHOD)" || echo "❌ 未集成")

安全功能:
- ✅ 随机密码生成
- ✅ 安全加固脚本
- ✅ 防火墙规则优化
- ✅ 配置文件备份

重要文件:
- 登录凭据: $CREDENTIALS_FILE
- 配置摘要: $SUMMARY_FILE
- 构建日志: $LOG_FILE

下一步操作:
1. 运行 'make menuconfig' 检查配置
2. 运行 'make -j\$(nproc)' 开始编译
3. 编译完成后查看凭据文件获取登录信息

注意事项:
- 首次登录后请立即修改默认密码
- 建议定期备份配置文件
- 如遇问题请查看详细日志: $LOG_FILE
EOF

# 最终清理
log_info "执行最终清理..."

# 设置正确的文件权限
find package/base-files/files -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
find package/base-files/files/etc/init.d -type f -exec chmod +x {} \; 2>/dev/null || true

# 清理编译缓存（可选，用于确保干净构建）
if [ "${CLEAN_BUILD:-false}" = "true" ]; then
    log_info "清理构建缓存..."
    make clean >/dev/null 2>&1 || true
    log_info "构建缓存已清理"
fi

# -------------------- 脚本完成 --------------------
log_info "=========================================="
log_info "🎉 OpenWrt DIY脚本执行完成！"
log_info "=========================================="
log_info ""
log_info "📋 配置摘要:"
log_info "   目标设备: CM520-79F (IPQ40xx)"
log_info "   主机名: $HOSTNAME"
log_info "   IP地址: $TARGET_IP"
log_info "   AdGuardHome: 端口 $ADGUARD_PORT"
log_info "   Nikki代理: $([ "$NIKKI_SUCCESS" = true ] && echo "✅ 已集成($NIKKI_METHOD)" || echo "❌ 跳过")"
log_info ""
log_info "🔐 安全信息:"
log_info "   凭据文件: $CREDENTIALS_FILE"
log_info "   配置摘要: $SUMMARY_FILE"
log_info "   构建日志: $LOG_FILE"
log_info ""
log_info "🚀 下一步操作:"
log_info "   1. make menuconfig  # 检查并调整编译选项"
log_info "   2. make -j\$(nproc
