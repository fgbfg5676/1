#!/bin/bash
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
# Enhanced: 轻量级日志记录 + 智能重试 + 出错立即停止
# Modifications:
# - RESTORED iptables-based firewall and AdGuardHome rules.
# - REPLACED DTS patch and device rule sections with code from successful script.
# - ADDED immediate exit on critical failures.
# - MODIFIED DTS patch logic to apply patch on existing DTS file without deletion.
# - FIXED 'local' variable error in AdGuardHome core copy step.
# - FIXED syntax error in dnsmasq configuration (unexpected EOF).
# - ADDED validation for configuration file creation.

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

# 网络下载专用重试函数
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
  # 检查DTS文件
  if [ -f "$TARGET_DTS" ]; then
    local size=$(stat -f%z "$TARGET_DTS" 2>/dev/null || stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
    log_success "DTS文件存在: $TARGET_DTS (大小: ${size} 字节)"
  else
    log_error "DTS文件缺失: $TARGET_DTS"
  fi
  # 检查AdGuardHome核心
  if [ -f "$ADGUARD_DIR/AdGuardHome" ]; then
    local size=$(stat -f%z "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || stat -c%s "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || echo "0")
    log_success "AdGuardHome核心存在 (大小: ${size} 字节)"
  else
    log_error "AdGuardHome核心缺失: $ADGUARD_DIR/AdGuardHome"
  fi
  # 检查关键配置文件
  if [ -f "package/base-files/files/etc/config/adguardhome" ]; then
    log_success "AdGuardHome配置文件已创建"
  else
    log_error "AdGuardHome配置文件未找到"
  fi
  # 检查dnsmasq配置文件
  if [ -f "package/base-files/files/etc/config/dhcp" ]; then
    log_success "dnsmasq配置文件已创建"
  else
    log_error "dnsmasq配置文件未找到"
  fi
  # 检查iptables规则文件
  if [ -f "package/base-files/files/etc/firewall.user" ]; then
    log_success "iptables规则文件已创建"
  else
    log_error "iptables规则文件未找到"
  fi
  # 检查系统优化脚本
  if [ -f "package/base-files/files/etc/init.d/adguard-optimize" ]; then
    log_success "系统优化脚本已创建"
  else
    log_error "系统优化脚本未找到"
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
  echo ""
  echo "已完成配置："
  echo "1. ✅ 下载并配置AdGuardHome核心"
  echo "2. ✅ 配置LuCI识别和初始化YAML"
  echo "3. ✅ 禁用dnsmasq DNS，保留DHCP"
  echo "4. ✅ 配置iptables适配"
  echo "5. ✅ 设置开机自启和权限"
  echo "6. ✅ 防止包冲突"
  echo "7. ✅ 应用DTS补丁到现有文件"
  echo "8. ✅ 集成luci-app-partexp插件"
  echo "========================================"
  # 执行最终检查
  if check_critical_files; then
    log_success "所有关键文件检查通过"
  else
    log_error "部分关键文件检查未通过"
  fi
}

# -------------------- 脚本开始执行 --------------------
SCRIPT_START_TIME=$(date +%s)
log_step "OpenWrt DIY脚本启动 - CM520-79F"
log_info "目标设备: CM520-79F (IPQ40xx, ARMv7)"
log_info "脚本版本: Enhanced v2.6 (修复语法错误，应用DTS补丁到现有文件，增强文件检查)"

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

log_info "创建必要的目录结构"
mkdir -p "$ADGUARD_DIR" "$DTS_DIR" || log_error "创建目录结构失败"
# 确保DTS目录有写权限
chmod -R u+w "$DTS_DIR" || log_error "设置DTS目录权限失败"

# -------------------- 内核模块与工具配置 --------------------
log_step "配置内核模块与工具"
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config || log_error "配置 kmod-ubi 失败"
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config || log_error "配置 kmod-ubifs 失败"
echo "CONFIG_PACKAGE_trx=y" >> .config || log_error "配置 trx 失败"
log_success "已配置 kmod-ubi, kmod-ubifs, trx"

# -------------------- 防止AdGuardHome包冲突 --------------------
log_step "配置AdGuardHome相关包，防止冲突"
sed -i '/^CONFIG_PACKAGE_adguardhome=y/d' .config || log_error "清理 adguardhome 配置失败"
echo "CONFIG_PACKAGE_adguardhome=n" >> .config || log_error "禁用 adguardhome 失败"
sed -i '/^CONFIG_PACKAGE_adguardhome-go=y/d' .config || log_error "清理 adguardhome-go 配置失败"
echo "CONFIG_PACKAGE_adguardhome-go=n" >> .config || log_error "禁用 adguardhome-go 失败"
log_success "已禁用可能冲突的AdGuardHome包"
if grep -q "^CONFIG_PACKAGE_luci-app-adguardhome=y" .config; then
  log_info "luci-app-adguardhome 已启用"
else
  echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> .config || log_error "启用 luci-app-adguardhome 失败"
  log_success "已启用 luci-app-adguardhome"
fi

# -------------------- DTS补丁处理 --------------------
log_step "处理DTS补丁"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
BASE_DTS_URL="https://raw.githubusercontent.com/openwrt/openwrt/main/target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019.dts"
BASE_DTS_FILE="$DTS_DIR/qcom-ipq4019.dts"

log_info "下载DTS补丁..."
if retry_download "$DTS_PATCH_URL" "$DTS_PATCH_FILE"; then
  log_success "DTS补丁下载完成"
  # 验证补丁文件
  log_info "验证补丁文件: $DTS_PATCH_FILE"
  if [ -s "$DTS_PATCH_FILE" ]; then
    log_info "补丁文件有效 (大小: $(stat -f%z "$DTS_PATCH_FILE" 2>/dev/null || stat -c%s "$DTS_PATCH_FILE" 2>/dev/null) 字节)"
    # 检查补丁是否针对qcom-ipq4019-cm520-79f.dts
    if grep -q "qcom-ipq4019-cm520-79f.dts" "$DTS_PATCH_FILE"; then
      log_info "补丁文件针对 qcom-ipq4019-cm520-79f.dts"
    else
      log_warn "补丁文件可能不针对 qcom-ipq4019-cm520-79f.dts，尝试应用"
    fi
  else
    log_error "补丁文件为空或无效: $DTS_PATCH_FILE"
  fi
  # 如果目标DTS文件不存在，下载基础DTS文件
  if ! [ -f "$TARGET_DTS" ]; then
    log_info "目标DTS文件不存在，下载基础DTS文件: $BASE_DTS_URL"
    if retry_download "$BASE_DTS_URL" "$BASE_DTS_FILE"; then
      log_success "基础DTS文件下载完成"
      # 复制为基础DTS文件作为初始文件
      cp "$BASE_DTS_FILE" "$TARGET_DTS" || log_error "复制基础DTS文件到 $TARGET_DTS 失败"
      log_info "已创建初始DTS文件: $TARGET_DTS"
    else
      log_error "基础DTS文件下载失败"
    fi
  else
    log_info "目标DTS文件已存在: $TARGET_DTS，保留并应用补丁"
  fi
  log_info "应用DTS补丁到现有DTS文件..."
  log_info "执行补丁命令: patch -d $DTS_DIR -p2 < $DTS_PATCH_FILE"
  # 备份现有DTS文件
  if [ -f "$TARGET_DTS" ]; then
    cp "$TARGET_DTS" "$TARGET_DTS.bak" || log_error "备份DTS文件失败"
    log_info "已备份DTS文件: $TARGET_DTS.bak"
  fi
  if patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" --verbose 2>&1 | tee /tmp/patch.log; then
    log_success "DTS补丁应用成功"
    # 验证DTS文件是否存在
    if [ -f "$TARGET_DTS" ]; then
      DTS_SIZE=$(stat -f%z "$TARGET_DTS" 2>/dev/null || stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
      log_success "DTS文件更新成功: $TARGET_DTS (大小: ${DTS_SIZE} 字节)"
    else
      log_error "DTS补丁应用后未生成文件: $TARGET_DTS"
    fi
  else
    log_warn "补丁应用失败 (p2)，查看 /tmp/patch.log 获取详细信息"
    cat /tmp/patch.log
    # 尝试使用 -p1
    log_info "尝试使用 -p1 应用补丁: patch -d $DTS_DIR -p1 < $DTS_PATCH_FILE"
    if patch -d "$DTS_DIR" -p1 < "$DTS_PATCH_FILE" --verbose 2>&1 | tee /tmp/patch.log; then
      log_success "DTS补丁应用成功 (使用 -p1)"
      if [ -f "$TARGET_DTS" ]; then
        DTS_SIZE=$(stat -f%z "$TARGET_DTS" 2>/dev/null || stat -c%s "$TARGET_DTS" 2>/dev/null || echo "0")
        log_success "DTS文件更新成功: $TARGET_DTS (大小: ${DTS_SIZE} 字节)"
      else
        log_error "DTS补丁应用后未生成文件: $TARGET_DTS"
      fi
    else
      log_error "DTS补丁应用失败 (p1 和 p2 均失败)，查看 /tmp/patch.log 获取详细信息"
      cat /tmp/patch.log
    fi
  fi
else
  log_error "DTS补丁下载失败"
fi

# -------------------- 设备规则配置 --------------------
log_step "配置设备规则"
if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
  log_info "添加CM520-79F设备规则..."
  cat <<EOF >> "$GENERIC_MK" || log_error "添加设备规则失败"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to \$(KERNEL_SIZE) | append-rootfs | trx -o \$@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
  log_success "CM520-79F设备规则添加成功"
else
  log_info "CM520-79F设备规则已存在"
fi

# -------------------- 集成AdGuardHome核心 --------------------
log_step "集成AdGuardHome核心"
rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz" || log_error "清理历史文件失败"
log_info "获取AdGuardHome最新版本下载地址..."
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep "browser_download_url.*linux_armv7" | cut -d '"' -f 4) || log_error "获取AdGuardHome下载地址失败"
if [ -n "$ADGUARD_URL" ]; then
  log_info "找到下载地址: $ADGUARD_URL"
  if retry_download "$ADGUARD_URL" "$ADGUARD_DIR/AdGuardHome.tar.gz"; then
    log_success "AdGuardHome核心下载完成"
    TMP_DIR=$(mktemp -d) || log_error "创建临时目录失败"
    log_info "解压AdGuardHome核心到临时目录: $TMP_DIR"
    if tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword; then
      log_success "AdGuardHome核心解压完成"
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
    log_info "清理临时文件完成"
  else
    log_error "AdGuardHome核心下载失败"
  fi
else
  log_error "未找到AdGuardHome核心下载地址"
fi

# -------------------- AdGuardHome LuCI 识别与配置 --------------------
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
if [ -f "package/base-files/files/etc/config/adguardhome" ]; then
  log_success "AdGuardHome UCI配置文件创建完成"
else
  log_error "AdGuardHome UCI配置文件创建失败"
fi

mkdir -p "package/base-files/files/etc/AdGuardHome" || log_error "创建AdGuardHome工作目录失败"
cat >"package/base-files/files/etc/AdGuardHome/AdGuardHome.yaml" <<EOF || log_error "创建AdGuardHome YAML配置失败"
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: \$2y\$10\$gIAKp1l.BME2k5p6mMYlj..4l5mhc8YBGZzI8J/6z8s8nJlQ6oP4y
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: zh-cn
theme: auto
debug_pprof: false
web_session_ttl: 720
dns:
  bind_hosts:
    - 0.0.0.0
  port: 5353
  statistics_interval: 90
  querylog_enabled: true
  querylog_file_enabled: true
  querylog_interval: 2160h
  querylog_size_memory: 1000
  anonymize_client_ip: false
  protection_enabled: true
  blocking_mode: default
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_response_ttl: 10
  parental_block_host: family-block.dns.adguard.com
  safebrowse_block_host: standard-block.dns.adguard.com
  ratelimit: 20
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - 223.5.5.5
    - 119.29.29.29
    - tls://dns.alidns.com
    - tls://doh.pub
  upstream_dns_file: ""
  bootstrap_dns:
    - 223.5.5.5:53
    - 119.29.29.29:53
  all_servers: false
  fastest_addr: false
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
filtering:
  protection_enabled: true
  filtering_enabled: true
  blocking_mode: default
  parental_enabled: false
  safebrowse_enabled: false
  safesearch_enabled: false
  safesearch_cache_size: 1048576
  safesearch_cache_ttl: 1800
  rewrites: []
  blocked_services: []
  upstream_timeout: 10s
safe_search:
  enabled: false
  bing: true
  duckduckgo: true
  google: true
  pixabay: true
  yandex: true
  youtube: true
blocked_response_ttl: 10
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  localtime: false
verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 17
EOF
if [ -f "package/base-files/files/etc/AdGuardHome/AdGuardHome.yaml" ]; then
  log_success "AdGuardHome初始化YAML配置创建完成"
else
  log_error "AdGuardHome初始化YAML配置创建失败"
fi

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
  local binpath workdir configpath logfile verbose
  config_get binpath 'main' 'binpath' '/usr/bin/AdGuardHome'
  config_get workdir 'main' 'workdir' '/etc/AdGuardHome'
  config_get configpath 'main' 'configpath' '/etc/AdGuardHome/AdGuardHome.yaml'
  config_get logfile 'main' 'logfile' '/var/log/AdGuardHome.log'
  config_get_bool verbose 'main' 'verbose' '0'
  mkdir -p "$workdir"
  if [ ! -f "$configpath" ]; then
    echo "AdGuardHome config file not found: $configpath"
    return 1
  fi
  procd_open_instance AdGuardHome
  procd_set_param command "$binpath" --config "$configpath" --work-dir "$workdir"
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
if [ -f "package/base-files/files/etc/init.d/adguardhome" ]; then
  chmod +x "package/base-files/files/etc/init.d/adguardhome" || log_error "设置AdGuardHome服务脚本权限失败"
  log_success "AdGuardHome UCI识别配置完成"
else
  log_error "AdGuardHome服务脚本创建失败"
fi

# -------------------- dnsmasq 配置 (禁用 DNS 功能，保留 DHCP) --------------------
log_step "配置dnsmasq (禁用DNS，保留DHCP)"
mkdir -p "package/base-files/files/etc/config" || log_error "创建dhcp配置目录失败"
cat >"package/base-files/files/etc/config/dhcp" <<'EOF' || log_error "创建dnsmasq配置文件失败"
config dnsmasq 'main'
  option domainneeded '1'
  option boguspriv '1'
  option filterwin2k '0'
  option localise_queries '1'
  option rebind_protection '1'
  option rebind_localhost '1'
  option local '/lan/'
  option domain 'lan'
  option expandhosts '1'
  option authoritative '1'
  option readethers '1'
  option leasefile '/tmp/dhcp.leases'
  option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
  option nonwildcard '1'
  option localservice '1'
  option noresolv '1'
  option port '0'
  list server '127.0.0.1#5353'

config dhcp 'lan'
  option interface 'lan'
  option start '100'
  option limit '150'
  option leasetime '12h'
  option dhcpv4 'server'
  option dhcpv6 'server'
  option ra 'server'
  option ra_management '1'
  list dns '192.168.1.1'

config dhcp 'wan'
  option interface 'wan'
  option ignore '1'

config odhcpd 'main'
  option maindhcp '0'
  option leasefile '/tmp/hosts/odhcpd'
  option leasetrigger '/usr/sbin/odhcpd-update'
  option loglevel '4'
EOF
if [ -f "package/base-files/files/etc/config/dhcp" ]; then
  log_success "dnsmasq配置完成 (DNS功能已禁用，DHCP功能保留)"
else
  log_error "dnsmasq配置文件创建失败"
fi

# -------------------- iptables 适配 --------------------
log_step "配置iptables适配"
cat >"package/base-files/files/etc/firewall.user" <<'EOF' || log_error "创建iptables规则文件失败"
#!/bin/sh
# AdGuardHome firewall rules using iptables
iptables -t nat -F PREROUTING
iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j DNAT --to 127.0.0.1:5353
iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j DNAT --to 127.0.0.1:5353
iptables -I INPUT -p tcp --dport 3000 -j ACCEPT
iptables -I INPUT -p tcp --dport 5353 -j ACCEPT
iptables -I INPUT -p udp --dport 5353 -j ACCEPT
EOF
if [ -f "package/base-files/files/etc/firewall.user" ]; then
  chmod +x "package/base-files/files/etc/firewall.user" || log_error "设置iptables规则文件权限失败"
  log_success "iptables规则文件创建完成"
else
  log_error "iptables规则文件创建失败"
fi

# -------------------- 系统配置优化 --------------------
log_step "配置系统优化"
mkdir -p "package/base-files/files/etc/init.d" || log_error "创建系统优化init.d目录失败"
cat >"package/base-files/files/etc/init.d/adguard-optimize" <<'EOF' || log_error "创建系统优化脚本失败"
#!/bin/sh /etc/rc.common
START=99
start() {
  echo 'nameserver 127.0.0.1' > /tmp/resolv.conf
  echo 'nameserver 223.5.5.5' > /tmp/resolv.conf
  chmod +x /usr/bin/AdGuardHome 2>/dev/null || true
  mkdir -p /etc/AdGuardHome
  chmod 755 /etc/AdGuardHome
  [ -x /etc/firewall.user ] && /etc/firewall.user
}
EOF
if [ -f "package/base-files/files/etc/init.d/adguard-optimize" ]; then
  chmod +x "package/base-files/files/etc/init.d/adguard-optimize" || log_error "设置系统优化脚本权限失败"
  log_success "系统优化脚本创建完成"
  log_success "系统优化配置完成"
else
  log_error "系统优化脚本创建失败"
fi

# -------------------- 插件集成 --------------------
log_step "集成sirpdboy插件"
mkdir -p package/custom || log_error "创建插件目录失败"
rm -rf package/custom/luci-app-partexp || log_info "清理旧插件失败（非致命）"
log_info "克隆luci-app-partexp插件..."
if retry_command "git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git package/custom/luci-app-partexp"; then
  log_success "luci-app-partexp插件克隆成功"
else
  log_error "luci-app-partexp插件克隆失败"
fi
log_info "更新所有feeds..."
if retry_command "./scripts/feeds update -a"; then
  log_success "feeds更新成功"
else
  log_error "feeds更新失败"
fi
log_info "安装所有feeds..."
if retry_command "./scripts/feeds install -a"; then
  log_success "feeds安装成功"
else
  log_error "feeds安装失败"
fi
if grep -q "^CONFIG_PACKAGE_luci-app-partexp=y" .config; then
  log_info "luci-app-partexp 已启用"
else
  echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config || log_error "启用 luci-app-partexp 失败"
  log_success "已启用 luci-app-partexp"
fi
log_success "sirpdboy插件集成完成"

# -------------------- 最终检查和配置清理 --------------------
log_step "执行最终配置检查和清理"
log_info "配置iptables和firewall相关包..."
packages_to_enable=(
  "CONFIG_PACKAGE_firewall=y"
  "CONFIG_PACKAGE_iptables=y"
)
for package in "${packages_to_enable[@]}"; do
  package_name=$(echo "$package" | cut -d'=' -f1)
  if grep -q "^${package}" .config; then
    log_info "${package_name} 已启用"
  else
    echo "$package" >> .config || log_error "启用 ${package_name} 失败"
    log_success "已启用 ${package_name}"
  fi
done
log_info "禁用可能冲突的防火墙包..."
packages_to_disable=(
  "CONFIG_PACKAGE_firewall4=n"
)
for package in "${packages_to_disable[@]}"; do
  package_name=$(echo "$package" | cut -d'=' -f1)
  sed -i "/^${package_name}=y/d" .config || log_error "清理 ${package_name} 配置失败"
  echo "$package" >> .config || log_error "禁用 ${package_name} 失败"
  log_success "已禁用 ${package_name}"
done
log_success "配置检查和清理完成"

# -------------------- 最终检查和脚本摘要 --------------------
print_summary "$SCRIPT_START_TIME"
