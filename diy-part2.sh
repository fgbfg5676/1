#!/bin/bash
#
# File name: diy-part2.sh (Improved Version)
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
# Improvements: Enhanced error handling, validation, and robustness
#
set -e  # 遇到错误立即退出脚本

# -------------------- 颜色输出函数 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"
HOSTNAME="CM520-79F"  # 自定义主机名
TARGET_IP="192.168.5.1"  # 自定义IP地址
ADGUARD_PORT="5353"  # 修改监听端口为 5353
CONFIG_PATH="package/base-files/files/etc/AdGuardHome"  # AdGuardHome 配置文件路径（编译时路径）

# 确保所有路径变量都有明确值，避免为空
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# 备用源配置
NIKKI_PRIMARY="https://github.com/nikkinikki-org/OpenWrt-nikki.git"
NIKKI_MIRROR="https://gitee.com/nikkinikki/OpenWrt-nikki.git"  # 假设的镜像源
NIKKI_BACKUP_BINARY="https://github.com/fgbfg5676/1/raw/main/nikki_arm_cortex-a7_neon-vfpv4-openwrt-23.05.tar.gz"

# -------------------- 依赖检查 --------------------
log_info "检查系统依赖..."
REQUIRED_TOOLS=("git" "wget" "patch" "sed" "grep")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "缺少必要工具: $tool"
        exit 1
    fi
done
log_info "依赖检查完成"

# -------------------- 网络连接检查 --------------------
check_network() {
    local test_url="$1"
    if wget $WGET_OPTS --spider "$test_url" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# -------------------- 创建必要目录 --------------------
log_info "创建必要目录..."
if ! mkdir -p "$DTS_DIR"; then
    log_error "无法创建目录 $DTS_DIR"
    exit 1
fi

# -------------------- AdGuardHome 配置 --------------------
log_info "生成 AdGuardHome 配置文件..."
# 确保配置目录存在
mkdir -p "$CONFIG_PATH" || { log_error "无法创建AdGuardHome配置目录 $CONFIG_PATH"; exit 1; }

# 生成更完整的配置文件
cat <<EOF > "$CONFIG_PATH/AdGuardHome.yaml"
# AdGuardHome 配置文件 (自动生成)
bind_host: 0.0.0.0
bind_port: $ADGUARD_PORT
users:
  - name: admin
    password: \$2y\$10\$FoyiYiwQKRoJl9zzG7u0yeFpb4B8jVH4VkgrKauQuOV0WRnLNPXXi  # 默认密码: admin
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: zh-cn
theme: auto

# DNS设置
upstream_dns:
  - 8.8.8.8
  - 8.8.4.4
  - 114.114.114.114
  - 1.1.1.1
  - 223.5.5.5
bootstrap_dns:
  - 8.8.8.8
  - 1.1.1.1

# 缓存设置
cache_size: 1000000
cache_ttl_min: 10
cache_ttl_max: 86400

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

# TLS配置 (可选)
tls:
  enabled: false
  port_https: 443
  port_dns_over_tls: 853
EOF

# 设置配置文件权限
chmod 644 "$CONFIG_PATH/AdGuardHome.yaml"
log_info "AdGuardHome 配置文件已创建，路径：$CONFIG_PATH/AdGuardHome.yaml，监听端口：$ADGUARD_PORT"

# -------------------- 内核模块与工具配置（增强版） --------------------
log_info "配置内核模块..."
# 严格添加配置项，先删除所有相关行（包括注释和变体），再写入干净配置
REQUIRED_CONFIGS=(
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
    "CONFIG_PACKAGE_trx=y"
)

for config in "${REQUIRED_CONFIGS[@]}"; do
    # 提取配置项名称（如从CONFIG_PACKAGE_kmod-ubi=y中提取kmod-ubi）
    config_name=$(echo "$config" | cut -d'_' -f3- | cut -d'=' -f1)
    # 删除所有包含该配置项的行（包括注释和不同格式）
    sed -i "/^#*CONFIG_PACKAGE_${config_name}/d" .config
    # 在.config末尾添加干净的配置项
    echo "$config" >> .config
    log_info "已添加配置项: $config"
done

# -------------------- 集成Nikki（采用官方feeds方式，增强错误处理） --------------------
log_info "开始通过官方源集成Nikki..."

# 1. 检查网络连接并选择源
NIKKI_SOURCE=""
NIKKI_METHOD=""
if check_network "$NIKKI_PRIMARY"; then
    NIKKI_SOURCE="$NIKKI_PRIMARY"
    NIKKI_METHOD="feeds"
    log_info "使用主要源: $NIKKI_PRIMARY"
elif check_network "$NIKKI_MIRROR"; then
    NIKKI_SOURCE="$NIKKI_MIRROR"
    NIKKI_METHOD="feeds"
    log_warn "主要源不可用，使用镜像源: $NIKKI_MIRROR"
elif check_network "$NIKKI_BACKUP_BINARY"; then
    NIKKI_SOURCE="$NIKKI_BACKUP_BINARY"
    NIKKI_METHOD="binary"
    log_warn "源码源均不可用，使用备用二进制包"
else
    log_error "所有Nikki源均不可用，跳过Nikki集成"
    NIKKI_SOURCE=""
fi

if [ -n "$NIKKI_SOURCE" ]; then
    if [ "$NIKKI_METHOD" = "feeds" ]; then
        # 方式1：通过feeds集成源码包
        # 2. 添加Nikki官方源（确保在feeds中生效）
        if ! grep -q "nikki.*OpenWrt-nikki.git" feeds.conf.default; then
            echo "src-git nikki $NIKKI_SOURCE;main" >> feeds.conf.default
            log_info "已成功添加 Nikki 源"
        else
            log_info "Nikki 源已存在，跳过添加"
        fi

        # 3. 更新并安装Nikki相关包
        log_info "更新 Nikki 源..."
        if ./scripts/feeds update nikki; then
            log_info "Nikki 源更新成功"
            
            log_info "安装 Nikki 包..."
            if ./scripts/feeds install -a -p nikki; then
                # 4. 在.config中启用Nikki核心组件及依赖
                log_info "启用 Nikki 相关配置..."
                echo "CONFIG_PACKAGE_nikki=y" >> .config                  # 核心程序
                echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config        # Web管理界面
                echo "CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y" >> .config # 中文语言包
                
                log_info "Nikki通过官方源集成完成"
            else
                log_warn "Nikki包安装失败，尝试备用二进制包"
                NIKKI_METHOD="binary"
                NIKKI_SOURCE="$NIKKI_BACKUP_BINARY"
            fi
        else
            log_warn "Nikki源更新失败，尝试备用二进制包"
            NIKKI_METHOD="binary"
            NIKKI_SOURCE="$NIKKI_BACKUP_BINARY"
        fi
    fi
    
    if [ "$NIKKI_METHOD" = "binary" ]; then
        # 方式2：使用预编译二进制包
        log_info "开始集成Nikki二进制包..."
        
        # 创建临时目录
        NIKKI_TMP_DIR="/tmp/nikki_install"
        mkdir -p "$NIKKI_TMP_DIR"
        
        # 下载并解压二进制包
        if wget $WGET_OPTS -O "$NIKKI_TMP_DIR/nikki.tar.gz" "$NIKKI_SOURCE"; then
            log_info "Nikki二进制包下载成功"
            
            # 解压到临时目录
            if tar -xzf "$NIKKI_TMP_DIR/nikki.tar.gz" -C "$NIKKI_TMP_DIR"; then
                log_info "Nikki二进制包解压成功"
                
                # 创建自定义包目录
                mkdir -p package/custom/nikki-binary
                
                # 创建Makefile来集成二进制文件
                cat <<'NIKKI_MAKEFILE' > package/custom/nikki-binary/Makefile
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
  DEPENDS:=+libc +libpthread +ca-certificates
  URL:=https://github.com/nikkinikki-org/OpenWrt-nikki
endef

define Package/nikki-binary/description
  Nikki is a transparent proxy tool based on Mihomo.
  This is a pre-compiled binary package.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	# 复制预编译文件将在Package/nikki-binary/install中处理
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/nikki-binary/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/nikki
	$(INSTALL_DIR) $(1)/etc/init.d
	
	# 复制主程序（需要根据实际解压后的文件结构调整）
	if [ -f /tmp/nikki_install/nikki ]; then \
		$(INSTALL_BIN) /tmp/nikki_install/nikki $(1)/usr/bin/; \
	elif [ -f /tmp/nikki_install/bin/nikki ]; then \
		$(INSTALL_BIN) /tmp/nikki_install/bin/nikki $(1)/usr/bin/; \
	fi
	
	# 复制配置文件（如果存在）
	if [ -f /tmp/nikki_install/config.yaml ]; then \
		$(INSTALL_CONF) /tmp/nikki_install/config.yaml $(1)/etc/nikki/; \
	fi
	
	# 创建基本的init脚本
	echo '#!/bin/sh /etc/rc.common' > $(1)/etc/init.d/nikki
	echo 'START=99' >> $(1)/etc/init.d/nikki
	echo 'USE_PROCD=1' >> $(1)/etc/init.d/nikki
	echo 'start_service() {' >> $(1)/etc/init.d/nikki
	echo '    procd_open_instance' >> $(1)/etc/init.d/nikki
	echo '    procd_set_param command /usr/bin/nikki' >> $(1)/etc/init.d/nikki
	echo '    procd_set_param respawn' >> $(1)/etc/init.d/nikki
	echo '    procd_close_instance' >> $(1)/etc/init.d/nikki
	echo '}' >> $(1)/etc/init.d/nikki
	chmod +x $(1)/etc/init.d/nikki
endef

$(eval $(call BuildPackage,nikki-binary))
NIKKI_MAKEFILE
                
                # 启用二进制包
                echo "CONFIG_PACKAGE_nikki-binary=y" >> .config
                
                log_info "Nikki二进制包集成完成"
            else
                log_warn "Nikki二进制包解压失败"
            fi
        else
            log_warn "Nikki二进制包下载失败"
        fi
        
        # 清理临时文件
        rm -rf "$NIKKI_TMP_DIR"
    fi
else
    log_warn "跳过Nikki集成，继续执行其他配置"
fi

# -------------------- DTS补丁处理 --------------------
log_info "处理DTS补丁..."
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"

if ! wget $WGET_OPTS -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL"; then
    log_warn "DTS补丁下载失败，使用默认DTS文件"
else
    # 无论TARGET_DTS是否存在，尝试应用补丁
    log_info "应用DTS补丁..."
    if ! patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"; then
        log_warn "DTS补丁应用失败，使用默认DTS文件"
    fi
fi

# -------------------- 设备规则配置（添加验证） --------------------
log_info "配置设备规则..."
if [ ! -f "$GENERIC_MK" ]; then
    log_error "找不到设备配置文件: $GENERIC_MK"
    exit 1
fi

if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    log_info "添加CM520-79F设备规则..."
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
    log_info "CM520-79F设备规则添加成功"
else
    log_info "CM520-79F设备规则已存在，跳过添加"
fi

# -------------------- 插件集成（增强错误处理） --------------------
log_info "集成sirpdboy插件..."
mkdir -p package/custom
rm -rf package/custom/luci-app-partexp

PARTEXP_URL="https://github.com/sirpdboy/luci-app-partexp.git"
if check_network "$PARTEXP_URL"; then
    if git clone --depth 1 "$PARTEXP_URL" package/custom/luci-app-partexp; then
        # -d y：自动安装所有依赖，确保完整性
        if ./scripts/feeds install -d y -p custom luci-app-partexp; then
            echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
            log_info "luci-app-partexp及其依赖已安装"
        else
            log_warn "luci-app-partexp依赖安装失败"
        fi
    else
        log_warn "luci-app-partexp克隆失败，跳过该插件"
    fi
else
    log_warn "luci-app-partexp源不可用，跳过该插件"
fi

# -------------------- 修改默认配置（增强验证） --------------------
log_info "修改默认系统配置..."

# 修正IP地址修改逻辑
log_info "修改默认IP地址为 $TARGET_IP..."
# 优先尝试设备专属网络配置（IPQ40xx平台）
NETWORK_FILE="target/linux/ipq40xx/base-files/etc/config/network"
if [ ! -f "$NETWORK_FILE" ]; then
  # 若设备专属文件不存在，使用通用路径
  NETWORK_FILE="package/base-files/files/etc/config/network"
fi

if [ -f "$NETWORK_FILE" ]; then
  # 兼容单引号、双引号或无引号的情况
  sed -i 's/option ipaddr[[:space:]]*[\"\x27]*192\.168\.1\.1[\"\x27]*/option ipaddr '"'$TARGET_IP'"'/g' "$NETWORK_FILE"
  
  # 验证修改是否成功
  if grep -q "$TARGET_IP" "$NETWORK_FILE"; then
      log_info "已成功修改 $NETWORK_FILE 中的默认IP"
  else
      log_warn "IP修改可能未生效，请手动检查"
  fi
  
  # 调试输出
  log_info "当前IP配置内容："
  grep "ipaddr" "$NETWORK_FILE" | head -3
else
  log_warn "未找到网络配置文件，IP修改可能失败"
fi

# 辅助修改config_generate（防止fallback配置）
if [ -f "package/base-files/files/bin/config_generate" ]; then
  sed -i "s/192\.168\.1\.1/$TARGET_IP/g" package/base-files/files/bin/config_generate
  log_info "已修改 config_generate 中的默认IP"
fi

# 修正主机名修改逻辑
log_info "修改默认主机名为 $HOSTNAME..."

# 1. 修改hostname文件
HOSTNAME_FILE="package/base-files/files/etc/hostname"
mkdir -p "$(dirname "$HOSTNAME_FILE")"
echo "$HOSTNAME" > "$HOSTNAME_FILE"
log_info "已修改 hostname 文件"

# 2. 修改system配置（兼容引号差异）
SYSTEM_FILE="package/base-files/files/etc/config/system"
if [ -f "$SYSTEM_FILE" ]; then
  sed -i "s/option hostname[[:space:]]*[\"\x27]*OpenWrt[\"\x27]*/option hostname '$HOSTNAME'/g" "$SYSTEM_FILE"
  
  # 验证修改是否成功
  if grep -q "$HOSTNAME" "$SYSTEM_FILE"; then
      log_info "已成功修改 $SYSTEM_FILE 中的主机名"
  else
      log_warn "主机名修改可能未生效，请手动检查"
  fi
  
  # 调试输出
  log_info "当前主机名配置内容："
  grep "hostname" "$SYSTEM_FILE" | head -3
else
    log_warn "未找到系统配置文件，将通过uci-defaults设置"
fi

# -------------------- 创建uci初始化脚本，确保配置生效 --------------------
log_info "创建uci初始化脚本，确保配置生效..."

UCI_DEFAULTS_DIR="package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEFAULTS_DIR"
cat <<EOF > "$UCI_DEFAULTS_DIR/99-custom-settings"
#!/bin/sh
# 自定义设置初始化脚本 (自动生成)
# 强制设置主机名
uci set system.@system[0].hostname='$HOSTNAME'
# 强制设置IP地址
uci set network.lan.ipaddr='$TARGET_IP'
# 提交更改
uci commit system
uci commit network

# 重启网络服务
/etc/init.d/network reload >/dev/null 2>&1 &

# 记录日志
logger -t custom-init "Applied custom settings: hostname=$HOSTNAME, ip=$TARGET_IP"

exit 0
EOF
chmod +x "$UCI_DEFAULTS_DIR/99-custom-settings"
log_info "已创建uci初始化脚本，确保配置生效"

# -------------------- 最终验证（增强版） --------------------
log_info "执行最终验证..."

# 验证关键文件是否存在
CRITICAL_FILES=(
    "$CONFIG_PATH/AdGuardHome.yaml"
    "$UCI_DEFAULTS_DIR/99-custom-settings"
    ".config"
)

for file in "${CRITICAL_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        log_error "关键文件缺失: $file"
        exit 1
    fi
done

# 验证.config中的关键配置（严格匹配非注释行）
for config in "${REQUIRED_CONFIGS[@]}"; do
    # 仅匹配非注释、无多余空格的有效配置项
    if ! grep -q "^[[:space:]]*$config[[:space:]]*$" .config; then
        # 二次添加配置项，防止被其他步骤覆盖
        echo "$config" >> .config
        log_warn "配置项已二次添加（可能被覆盖）: $config"
    fi
done

log_info "====================="
log_info "DIY脚本执行完成！"
log_info "====================="
log_info "请执行以下步骤确认配置："
log_info "1. 运行 'make menuconfig'"
log_info "2. 在菜单中搜索并确认勾选："
log_info "   - Kernel modules -> Filesystems -> kmod-ubi"
log_info "   - Kernel modules -> Filesystems -> kmod-ubifs"
log_info "   - Utilities -> trx"
log_info "3. 保存配置并退出，然后执行 'make -j$(nproc)' 编译"
log_info "====================="
log_info "配置摘要："
log_info "- 目标设备: CM520-79F (IPQ40xx)"
log_info "- 主机名: $HOSTNAME"
log_info "- IP地址: $TARGET_IP"
log_info "- AdGuardHome端口: $ADGUARD_PORT"
log_info "- Nikki代理: $([ -n "$NIKKI_SOURCE" ] && echo "已集成($NIKKI_METHOD)" || echo '未集成')"
log_info "====================="
