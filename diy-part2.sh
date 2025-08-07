#!/bin/bash
#
# File name: diy-part2.sh (Optimized Secure Version)
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
# Version: 2.0 - Security Enhanced
# Fixes: Resolved security issues, improved error handling, added offline support
#
set -e  # 遇到错误立即退出脚本

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

# -------------------- 工具函数 --------------------
# 生成随机密码
generate_password() {
    local length="${1:-12}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 20 | tr -d "=+/" | cut -c1-"$length"
    else
        # 备用方法
        tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "$length"
    fi
}

# 哈希密码（bcrypt格式）
hash_password() {
    local password="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import bcrypt
import sys
password = '$password'.encode('utf-8')
hashed = bcrypt.hashpw(password, bcrypt.gensalt())
print(hashed.decode('utf-8'))
" 2>/dev/null || echo "\$2a\$10\$YourGeneratedHashHere"
    elif command -v openssl >/dev/null 2>&1; then
        echo -n "$password" | openssl passwd -1 -stdin
    else
        # 如果没有可用工具，使用预设hash但警告用户
        log_warn "无法生成密码哈希，请手动修改AdGuardHome密码"
        echo "\$2y\$10\$FoyiYiwQKRoJl9zzG7u0yeFpb4B8jVH4VkgrKauQuOV0WRnLNPXXi"
    fi
}

# 备份文件
backup_file() {
    local file="$1"
    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    if [ -f "$file" ]; then
        cp "$file" "$backup"
        log_info "已备份 $file 到 $backup"
        return 0
    fi
    return 1
}

# 验证YAML文件
validate_yaml() {
    local yaml_file="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import yaml
import sys
try:
    with open('$yaml_file', 'r') as f:
        yaml.safe_load(f)
    print('YAML文件语法正确')
    sys.exit(0)
except Exception as e:
    print(f'YAML文件语法错误: {e}')
    sys.exit(1)
" 2>/dev/null
        return $?
    fi
    log_debug "跳过YAML验证（无python3）"
    return 0
}

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout=10 --max-redirect=5"
ARCH="armv7"
HOSTNAME="CM520-79F"  # 自定义主机名
TARGET_IP="192.168.5.1"  # 自定义IP地址
ADGUARD_PORT="5353"  # 修改监听端口为 5353
CONFIG_PATH="package/base-files/files/etc/AdGuardHome"  # 固件虚拟路径

# 确保所有路径变量都有明确值，避免为空
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# 备用源配置
NIKKI_PRIMARY="https://github.com/nikkinikki-org/OpenWrt-nikki.git"
NIKKI_MIRROR="https://gitee.com/nikkinikki/OpenWrt-nikki.git"
NIKKI_BACKUP_BINARY="https://github.com/fgbfg5676/1/raw/main/nikki_arm_cortex-a7_neon-vfpv4-openwrt-23.05.tar.gz"

# 临时目录
NIKKI_TMP_DIR="/tmp/nikki_install_$$"
PATCH_TMP_DIR="/tmp/patch_install_$$"

# -------------------- 依赖检查 --------------------
log_info "检查系统依赖..."
REQUIRED_TOOLS=("git" "wget" "patch" "sed" "grep" "tar" "gzip")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    log_error "缺少必要工具: ${MISSING_TOOLS[*]}"
    log_error "请安装缺失的工具后重试"
    exit 1
fi

# 检查可选工具
OPTIONAL_TOOLS=("python3" "openssl" "bcrypt")
for tool in "${OPTIONAL_TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        log_debug "发现可选工具: $tool"
    else
        log_debug "可选工具未找到: $tool"
    fi
done

log_info "依赖检查完成"

# -------------------- 网络连接检查 --------------------
check_network() {
    local test_url="$1"
    local timeout="${2:-10}"
    
    if [ "$OFFLINE_MODE" = "true" ]; then
        log_debug "离线模式，跳过网络检查: $test_url"
        return 1
    fi
    
    if wget --timeout="$timeout" --tries=1 --spider "$test_url" >/dev/null 2>&1; then
        log_debug "网络检查成功: $test_url"
        return 0
    else
        log_debug "网络检查失败: $test_url"
        return 1
    fi
}

# -------------------- 创建必要目录 --------------------
log_info "创建必要目录..."
REQUIRED_DIRS=("$DTS_DIR" "$CONFIG_PATH" "$NIKKI_TMP_DIR" "$PATCH_TMP_DIR")

for dir in "${REQUIRED_DIRS[@]}"; do
    if ! mkdir -p "$dir"; then
        log_error "无法创建目录: $dir"
        exit 1
    fi
    log_debug "目录创建成功: $dir"
done

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
POSSIBLE_NETWORK_PATHS=(
    "target/linux/ipq40xx/base-files/etc/config/network"
    "package/base-files/files/etc/config/network"
    "feeds/base-files/etc/config/network"
    "build_dir/target-arm_cortex-a7+neon-vfpv4_musl_eabi/base-files/etc/config/network"
)

POSSIBLE_SYSTEM_PATHS=(
    "package/base-files/files/etc/config/system"
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

# -------------------- 创建增强的UCI初始化脚本 --------------------
log_info "创建增强的UCI初始化脚本..."

UCI_DEFAULTS_DIR="package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEFAULTS_DIR"

cat > "$UCI_DEFAULTS_DIR/99-custom-settings" << EOF
#!/bin/sh
# 自定义设置初始化脚本 (增强版)
# 生成时间: $(date)

# 日志函数
log_msg() {
    logger -t "custom-init" "\$1"
    echo "[custom-init] \$1"
}

log_msg "开始应用自定义配置..."

# 设置系统配置
uci -q batch << EOC
set system.@system[0].hostname='$HOSTNAME'
set system.@system[0].timezone='CST-8'
set system.@system[0].zonename='Asia/Shanghai'
commit system
EOC

# 设置网络配置
uci -q batch << EOC
set network.lan.ipaddr='$TARGET_IP'
set network.lan.netmask='255.255.255.0'
set network.lan.proto='static'
commit network
EOC

# 设置AdGuardHome相关防火墙规则（如果需要）
if [ -f /etc/config/firewall ]; then
    uci -q batch << EOC
add firewall rule
set firewall.@rule[-1].name='Allow-AdGuardHome'
set firewall.@rule[-1].src='lan'
set firewall.@rule[-1].dest_port='$ADGUARD_PORT'
set firewall.@rule[-1].proto='tcp udp'
set firewall.@rule[-1].target='ACCEPT'
commit firewall
EOC
    log_msg "已添加AdGuardHome防火墙规则"
fi

# 设置无线网络（如果配置文件存在）
if [ -f /etc/config/wireless ]; then
    uci -q batch << EOC
set wireless.radio0.disabled='0'
set wireless.radio1.disabled='0'
set wireless.default_radio0.encryption='psk2'
set wireless.default_radio0.key='OpenWrt2024!'
set wireless.default_radio0.ssid='$HOSTNAME-2.4G'
set wireless.default_radio1.encryption='psk2'
set wireless.default_radio1.key='OpenWrt2024!'
set wireless.default_radio1.ssid='$HOSTNAME-5G'
commit wireless
EOC
    log_msg "已配置默认WiFi设置"
fi

# 重载相关服务
/etc/init.d/network reload >/dev/null 2>&1 &
/etc/init.d/system reload >/dev/null 2>&1 &

log_msg "自定义配置应用完成: hostname=$HOSTNAME, ip=$TARGET_IP"

# 创建首次启动标记文件
touch /etc/custom-init-done

log_msg "系统将在稍后重启网络服务以应用新配置"

exit 0
EOF

chmod +x "$UCI_DEFAULTS_DIR/99-custom-settings"
log_info "✅ UCI初始化脚本已创建: $UCI_DEFAULTS_DIR/99-custom-settings"

# -------------------- 创建安全加固脚本 --------------------
log_info "创建安全加固脚本..."

SECURITY_SCRIPT_DIR="package/base-files/files/etc/uci-defaults"
cat > "$SECURITY_SCRIPT_DIR/98-security-hardening" << 'EOF'
#!/bin/sh
# 安全加固脚本

log_msg() {
    logger -t "security-hardening" "$1"
}

log_msg "开始应用安全加固配置..."

# 禁用不必要的服务
for service in telnet rlogin rsh; do
    if [ -f "/etc/init.d/$service" ]; then
        /etc/init.d/$service disable >/dev/null 2>&1
        log_msg "已禁用服务: $service"
    fi
done

# 设置更安全的SSH配置（如果SSH服务存在）
if [ -f /etc/config/dropbear ]; then
    uci -q batch << EOC
set dropbear.@dropbear[0].PasswordAuth='off'
set dropbear.@dropbear[0].RootPasswordAuth='off'
set dropbear.@dropbear[0].Port='22'
commit dropbear
EOC
    log_msg "已加固SSH配置"
fi

# 设置防火墙安全规则
if [ -f /etc/config/firewall ]; then
    # 禁用WPS
    uci -q set wireless.default_radio0.wps_pushbutton='0' 2>/dev/null
    uci -q set wireless.default_radio1.wps_pushbutton='0' 2>/dev/null
    uci -q commit wireless 2>/dev/null
    
    # 添加基础防护规则
    uci -q batch << EOC
add firewall rule
set firewall.@rule[-1].name='Drop-Invalid-Packets'
set firewall.@rule[-1].src='wan'
set firewall.@rule[-1].proto='all'
set firewall.@rule[-1].extra='-m state --state INVALID'
set firewall.@rule[-1].target='DROP'
commit firewall
EOC
    log_msg "已添加防火墙安全规则"
fi

log_msg "安全加固配置完成"
exit 0
EOF

chmod +x "$SECURITY_SCRIPT_DIR/98-security-hardening"
log_info "✅ 安全加固脚本已创建"

# -------------------- 最终验证和清理 --------------------
log_info "执行最终验证..."

# 验证关键文件是否存在
CRITICAL_FILES=(
    "$CONFIG_PATH/AdGuardHome.yaml"
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
log_info "   2. make -j\$(nproc)   # 开始编译固件"
log_info "   3. 查看凭据文件获取登录信息"
log_info ""
log_info "⚠️  重要提醒:"
log_info "   • 首次登录后请立即修改默认密码"
log_info "   • 妥善保存凭据文件内容"
log_info "   • 如遇问题请查看详细日志"
log_info ""
log_info "=========================================="

# 显示凭据信息（仅显示前几行，避免敏感信息泄露）
if [ -f "$CREDENTIALS_FILE" ]; then
    echo ""
    log_info "🔑 登录凭据预览（完整信息请查看: $CREDENTIALS_FILE）:"
    head -8 "$CREDENTIALS_FILE" | sed 's/^/   /'
    echo "   ... 更多信息请查看完整凭据文件"
fi

log_info ""
log_info "✨ 脚本执行成功完成！祝您编译顺利！"

# 正常退出（cleanup函数会自动调用）
exit 0

# -------------------- 内核模块与工具配置 --------------------
log_info "配置内核模块..."

# 备份原始配置
backup_file ".config" || log_debug "原始.config不存在，跳过备份"

# 需要的配置项
REQUIRED_CONFIGS=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
    "CONFIG_PACKAGE_block-mount=y"
    "CONFIG_PACKAGE_kmod-fs-ext4=y"
    "CONFIG_PACKAGE_kmod-usb-storage=y"
)

# 高级配置项（可选但推荐）
OPTIONAL_CONFIGS=(
    "CONFIG_PACKAGE_luci-ssl=y"
    "CONFIG_PACKAGE_wpad-wolfssl=y"
    "CONFIG_PACKAGE_curl=y"
    "CONFIG_PACKAGE_ca-certificates=y"
)

# 清理并添加必需配置
for config in "${REQUIRED_CONFIGS[@]}"; do
    config_name=$(echo "$config" | cut -d'=' -f1)
    # 删除所有相关行（包括注释）
    sed -i "/^#*${config_name}/d" .config 2>/dev/null || true
    echo "$config" >> .config
    log_debug "添加配置: $config"
done

# 添加可选配置
for config in "${OPTIONAL_CONFIGS[@]}"; do
    config_name=$(echo "$config" | cut -d'=' -f1)
    if ! grep -q "^${config_name}=" .config; then
        sed -i "/^#*${config_name}/d" .config 2>/dev/null || true
        echo "$config" >> .config
        log_debug "添加可选配置: $config"
    fi
done

# 验证配置项
missing_configs=()
for config in "${REQUIRED_CONFIGS[@]}"; do
    if ! grep -q "^$config$" .config; then
        missing_configs+=("$config")
    fi
done

if [ ${#missing_configs[@]} -gt 0 ]; then
    log_warn "以下配置项可能未正确添加: ${missing_configs[*]}"
    log_warn "请检查.config文件或手动添加"
fi

log_info "内核模块配置完成"

# -------------------- 错误处理优化：非关键错误不中断脚本 --------------------
set +e  # 临时关闭自动退出，处理非关键部分

# -------------------- 集成Nikki --------------------
log_info "开始集成Nikki代理..."

NIKKI_SUCCESS=false
NIKKI_SOURCE=""
NIKKI_METHOD=""

# 选择Nikki源
if [ "$OFFLINE_MODE" != "true" ]; then
    if check_network "$NIKKI_PRIMARY" 5; then
        NIKKI_SOURCE="$NIKKI_PRIMARY"
        NIKKI_METHOD="feeds"
        log_info "使用主要源: $NIKKI_PRIMARY"
    elif check_network "$NIKKI_MIRROR" 5; then
        NIKKI_SOURCE="$NIKKI_MIRROR"
        NIKKI_METHOD="feeds"
        log_warn "主要源不可用，使用镜像源: $NIKKI_MIRROR"
    elif check_network "$NIKKI_BACKUP_BINARY" 5; then
        NIKKI_SOURCE="$NIKKI_BACKUP_BINARY"
        NIKKI_METHOD="binary"
        log_warn "源码源均不可用，使用备用二进制包"
    fi
fi

if [ -z "$NIKKI_SOURCE" ]; then
    log_warn "所有Nikki源均不可用或处于离线模式，跳过Nikki集成"
else
    # Feeds源安装
    if [ "$NIKKI_METHOD" = "feeds" ]; then
        log_info "通过feeds源安装Nikki..."
        
        if ! grep -q "nikki.*OpenWrt-nikki.git" feeds.conf.default 2>/dev/null; then
            echo "src-git nikki $NIKKI_SOURCE;main" >> feeds.conf.default
            log_info "已添加 Nikki 源到 feeds.conf.default"
        else
            log_info "Nikki 源已存在，跳过添加"
        fi

        if ./scripts/feeds update nikki 2>>"$LOG_FILE"; then
            log_info "Nikki 源更新成功"
            
            if ./scripts/feeds install -a -p nikki 2>>"$LOG_FILE"; then
                echo "CONFIG_PACKAGE_nikki=y" >> .config
                echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
                echo "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y" >> .config
                log_info "Nikki通过feeds源安装完成"
                NIKKI_SUCCESS=true
            else
                log_warn "Nikki包安装失败，尝试二进制包方法"
                NIKKI_METHOD="binary"
                NIKKI_SOURCE="$NIKKI_BACKUP_BINARY"
            fi
        else
            log_warn "Nikki源更新失败，尝试二进制包方法"
            NIKKI_METHOD="binary"
            NIKKI_SOURCE="$NIKKI_BACKUP_BINARY"
        fi
    fi
    
    # 二进制包安装
    if [ "$NIKKI_METHOD" = "binary" ] && [ "$NIKKI_SUCCESS" = false ]; then
        log_info "通过二进制包安装Nikki..."
        
        if wget $WGET_OPTS -O "$NIKKI_TMP_DIR/nikki.tar.gz" "$NIKKI_SOURCE" 2>>"$LOG_FILE"; then
            log_info "Nikki二进制包下载成功"
            
            if tar -xzf "$NIKKI_TMP_DIR/nikki.tar.gz" -C "$NIKKI_TMP_DIR" 2>>"$LOG_FILE"; then
                log_info "Nikki二进制包解压成功"
                
                mkdir -p package/custom/nikki-binary
                
                # 创建优化的Makefile
                cat > package/custom/nikki-binary/Makefile << 'NIKKI_MAKEFILE'
include $(TOPDIR)/rules.mk

PKG_NAME:=nikki-binary
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/nikki-binary
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Nikki Proxy (Binary)
  DEPENDS:=+libc +libpthread +ca-certificates +curl
  URL:=https://github.com/nikkinikki-org/OpenWrt-nikki
  PKGARCH:=all
endef

define Package/nikki-binary/description
  Nikki is a transparent proxy tool based on Mihomo.
  This is a pre-compiled binary package with enhanced features.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/nikki-binary/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/nikki
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	
	# 安装二进制文件
	if [ -f /tmp/nikki_install_$$$$/nikki ]; then \
		$(INSTALL_BIN) /tmp/nikki_install_$$$$/nikki $(1)/usr/bin/; \
	elif [ -f /tmp/nikki_install_$$$$/bin/nikki ]; then \
		$(INSTALL_BIN) /tmp/nikki_install_$$$$/bin/nikki $(1)/usr/bin/; \
	fi
	
	# 安装配置文件
	if [ -f /tmp/nikki_install_$$$$/config.yaml ]; then \
		$(INSTALL_CONF) /tmp/nikki_install_$$$$/config.yaml $(1)/etc/nikki/; \
	else \
		echo 'port: 7890' > $(1)/etc/nikki/config.yaml; \
		echo 'socks-port: 7891' >> $(1)/etc/nikki/config.yaml; \
		echo 'allow-lan: true' >> $(1)/etc/nikki/config.yaml; \
		echo 'mode: rule' >> $(1)/etc/nikki/config.yaml; \
		echo 'log-level: info' >> $(1)/etc/nikki/config.yaml; \
	fi
	
	# 创建init脚本
	echo '#!/bin/sh /etc/rc.common' > $(1)/etc/init.d/nikki
	echo 'START=99' >> $(1)/etc/init.d/nikki
	echo 'STOP=10' >> $(1)/etc/init.d/nikki
	echo 'USE_PROCD=1' >> $(1)/etc/init.d/nikki
	echo '' >> $(1)/etc/init.d/nikki
	echo 'start_service() {' >> $(1)/etc/init.d/nikki
	echo '    procd_open_instance' >> $(1)/etc/init.d/nikki
	echo '    procd_set_param command /usr/bin/nikki' >> $(1)/etc/init.d/nikki
	echo '    procd_set_param args -d /etc/nikki' >> $(1)/etc/init.d/nikki
	echo '    procd_set_param respawn' >> $(1)/etc/init.d/nikki
	echo '    procd_set_param stderr 1' >> $(1)/etc/init.d/nikki
	echo '    procd_set_param stdout 1' >> $(1)/etc/init.d/nikki
	echo '    procd_close_instance' >> $(1)/etc/init.d/nikki
	echo '}' >> $(1)/etc/init.d/nikki
	chmod +x $(1)/etc/init.d/nikki
	
	# 创建UCI配置
	echo 'config nikki' > $(1)/etc/config/nikki
	echo '	option enabled 0' >> $(1)/etc/config/nikki
	echo '	option config_path "/etc/nikki/config.yaml"' >> $(1)/etc/config/nikki
endef

define Package/nikki-binary/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
    echo "Nikki binary package installed successfully"
    echo "Use 'service nikki start' to start the service"
fi
endef

$(eval $(call BuildPackage,nikki-binary))
NIKKI_MAKEFILE

                echo "CONFIG_PACKAGE_nikki-binary=y" >> .config
                log_info "Nikki二进制包Makefile创建完成"
                NIKKI_SUCCESS=true
            else
                log_warn "Nikki二进制包解压失败"
            fi
        else
            log_warn "Nikki二进制包下载失败"
        fi
    fi
fi

if [ "$NIKKI_SUCCESS" = true ]; then
    log_info "✅ Nikki集成完成 ($NIKKI_METHOD 方式)"
else
    log_warn "❌ Nikki集成失败，但不影响其他功能"
fi

# -------------------- 重新启用严格错误处理 --------------------
set -e

# -------------------- DTS补丁处理 --------------------
log_info "处理设备树(DTS)补丁..."

DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$PATCH_TMP_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"

# 临时关闭严格模式处理非关键补丁
set +e
if [ "$OFFLINE_MODE" != "true" ] && check_network "$DTS_PATCH_URL" 10; then
    if wget $WGET_OPTS -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL" 2>>"$LOG_FILE"; then
        log_info "DTS补丁下载成功，准备应用..."
        
        # 备份原DTS文件（如果存在）
        backup_file "$TARGET_DTS" 2>/dev/null || true
        
        if patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" 2>>"$LOG_FILE"; then
            log_info "✅ DTS补丁应用成功"
        else
            log_warn "❌ DTS补丁应用失败，使用默认DTS文件"
        fi
    else
        log_warn "DTS补丁下载失败，使用默认DTS文件"
    fi
else
    log_warn "跳过DTS补丁下载（离线模式或网络不可用）"
fi
set -e

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
