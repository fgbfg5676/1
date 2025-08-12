#!/bin/bash
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
# Enhanced: 轻量级日志记录 + 智能重试
# -------------------- 日志记录函数 --------------------

-------------------- 日志记录函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $\033[0m"; }
log_warn() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $\033[0m"; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $\033[0m"; }
log_step() {
echo -e "[$(date +'%H:%M:%S')] \033[36m🔄 $*\033[0m"
echo "----------------------------------------"
}
-------------------- 智能重试函数 --------------------
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
return $exit_code
fi
fi
attempt=$((attempt + 1))
done
return 1
}
网络下载专用重试函数
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
return 1
}
-------------------- 文件检查函数 --------------------
check_critical_files() {
local errors=0
log_step "执行关键文件检查"
检查DTS文件
if [ -f "$TARGET_DTS" ]; then
log_success "DTS文件存在: $TARGET_DTS"
else
log_error "DTS文件缺失: $TARGET_DTS"
errors=$((errors + 1))
fi
检查AdGuardHome核心
if [ -f "$ADGUARD_DIR/AdGuardHome" ]; then
local size=$(stat -f%z "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || stat -c%s "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || echo "0")
log_success "AdGuardHome核心存在 (大小: ${size} 字节)"
else
log_error "AdGuardHome核心缺失: $ADGUARD_DIR/AdGuardHome"
errors=$((errors + 1))
fi
检查关键配置文件
if [ -f "package/base-files/files/etc/config/adguardhome" ]; then
log_success "AdGuardHome配置文件已创建"
else
log_warn "AdGuardHome配置文件未找到"
errors=$((errors + 1))
fi
return $errors
}
-------------------- 执行摘要函数 --------------------
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
echo "1. ✅ 集成Nikki源"
echo "2. ✅ 下载并配置AdGuardHome核心"

echo "3. ✅ 配置LuCI识别和初始化YAML"
echo "4. ✅ 禁用dnsmasq DNS，保留DHCP"
echo "5. ✅ 配置firewall4/nftables适配"
echo "6. ✅ 设置开机自启和权限"
echo "7. ✅ 防止包冲突"
echo "8. ✅ 保持DTS补丁原封不动"
echo "========================================"
执行最终检查
if check_critical_files; then
log_success "所有关键文件检查通过"
else
log_warn "部分关键文件检查未通过，请检查日志"
fi
}
-------------------- 脚本开始执行 --------------------
SCRIPT_START_TIME=$(date +%s)
log_step "OpenWrt DIY脚本启动 - CM520-79F"
log_info "目标设备: CM520-79F (IPQ40xx, ARMv7)"
log_info "脚本版本: Enhanced v1.0 (日志记录 + 智能重试)"
-------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=1 --retry-connrefused --connect-timeout 10"
ARCH="armv7"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"

GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
Nikki 源配置
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
log_info "创建必要的目录结构"
mkdir -p "$ADGUARD_DIR" "$DTS_DIR"
-------------------- 内核模块与工具配置 --------------------
log_step "配置内核模块与工具"
if grep -q "^CONFIG_PACKAGE_kmod-ubi=y" .config; then
log_info "kmod-ubi 已启用"
else
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
log_success "已启用 kmod-ubi"
fi
if grep -q "^CONFIG_PACKAGE_kmod-ubifs=y" .config; then
log_info "kmod-ubifs 已启用"

else
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
log_success "已启用 kmod-ubifs"
fi
if grep -q "^CONFIG_PACKAGE_trx=y" .config; then
log_info "trx 已启用"
else
echo "CONFIG_PACKAGE_trx=y" >> .config
log_success "已启用 trx"
fi
-------------------- 防止AdGuardHome包冲突 --------------------
log_step "配置AdGuardHome相关包，防止冲突"
禁用可能冲突的AdGuardHome包
sed -i '/^CONFIG_PACKAGE_adguardhome=y/d' .config
echo "CONFIG_PACKAGE_adguardhome=n" >> .config
sed -i '/^CONFIG_PACKAGE_adguardhome-go=y/d' .config
echo "CONFIG_PACKAGE_adguardhome-go=n" >> .config
log_success "已禁用可能冲突的AdGuardHome包"
确保luci-app-adguardhome启用
if grep -q "^CONFIG_PACKAGE_luci-app-adguardhome=y" .config; then
log_info "luci-app-adguardhome 已启用"
else
echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> .config
log_success "已启用 luci-app-adguardhome"
fi
-------------------- 集成 Nikki 源 --------------------
log_step "集成 Nikki 源"
检查是否已经添加了Nikki源
if grep -q "nikki.*$NIKKI_FEED" feeds.conf.default 2>/dev/null; then
log_info "Nikki 源已存在，跳过添加"
else
echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default
log_success "已添加 Nikki 源到 feeds.conf.default"
fi
更新Nikki源
log_info "更新 Nikki 源..."
if retry_command "./scripts/feeds update nikki"; then
log_success "Nikki 源更新成功"
else
log_warn "Nikki 源更新失败，但继续执行"
fi
安装Nikki包
log_info "安装 Nikki 包..."
if retry_command "./scripts/feeds install -a -p nikki"; then
log_success "Nikki 包安装成功"
else
log_warn "Nikki 包安装失败，但继续执行"
fi
启用Nikki包
if grep -q "^CONFIG_PACKAGE_nikki=y" .config; then
log_info "nikki 包已启用"
else
echo "CONFIG_PACKAGE_nikki=y" >> .config
log_success "已启用 nikki 包"
fi
if grep -q "^CONFIG_PACKAGE_luci-app-nikki=y" .config; then
log_info "luci-app-nikki 已启用"
else
echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
log_success "已启用 luci-app-nikki"
fi
log_success "Nikki 集成完成"
-------------------- DTS补丁处理 (保持原封不动) --------------------
log_step "处理DTS补丁 (保持原有逻辑)"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
log_info "下载DTS补丁..."
if retry_download "$DTS_PATCH_URL" "$DTS_PATCH_FILE"; then
log_success "DTS补丁下载完成"
if [ ! -f "$TARGET_DTS" ]; then
log_info "应用DTS补丁..."
if patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"; then
log_success "DTS补丁应用成功"
else
log_error "DTS补丁应用失败"
fi
else
log_info "DTS文件已存在，跳过补丁应用"
fi
else
log_error "DTS补丁下载失败"
fi
-------------------- 设备规则配置 --------------------
log_step "配置设备规则"
if grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
log_info "CM520-79F设备规则已存在"
else
log_info "添加CM520-79F设备规则..."
cat <<eof>> "$GENERIC_MK"</eof>
define Device/mobipromo_cm520-79f
DEVICE_VENDOR := MobiPromo
DEVICE_MODEL := CM520-79F
DEVICE_DTS := qcom-ipq4019-cm520-79f
KERNEL_SIZE := 4096k
ROOTFS_SIZE := 16384k
IMAGE_SIZE := 32768k
IMAGE/trx := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | trx -o $@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
log_success "CM520-79F设备规则添加成功"
fi
-------------------- 集成AdGuardHome核心 --------------------
log_step "集成AdGuardHome核心"
清理历史文件
log_info "清理历史文件..."
rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz"
获取下载地址
log_info "获取AdGuardHome最新版本下载地址..."
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep "browser_download_url.*linux_armv7" | cut -d '"' -f 4)
if [ -n "$ADGUARD_URL" ]; then
log_info "找到下载地址: $ADGUARD_URL"
下载AdGuardHome核心
if retry_download "$ADGUARD_URL" "$ADGUARD_DIR/AdGuardHome.tar.gz"; then
log_success "AdGuardHome核心下载完成"
解压到临时目录
TMP_DIR=$(mktemp -d)
log_info "解压AdGuardHome核心到临时目录: $TMP_DIR"
if tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword; then
log_success "AdGuardHome核心解压完成"
查找可执行文件
ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -n 1)
if [ -n "$ADG_EXE" ]; then
cp "$ADG_EXE" "$ADGUARD_DIR/"
chmod +x "$ADGUARD_DIR/AdGuardHome"
local size=$(stat -f%z "$ADGUARD_DIR/AdGuardHome" 2>/dev/null || stat -c%s "$ADGUARD_DIR/AdGuardHome" 2>/dev/null)
log_success "AdGuardHome核心复制成功 (大小: ${size} 字节)"
else
log_error "未找到AdGuardHome可执行文件"
fi
else
log_error "AdGuardHome核心解压失败"
fi
清理临时文件
rm -rf "$TMP_DIR" "$ADGUARD_DIR/AdGuardHome.tar.gz"
log_info "清理临时文件完成"
else
log_error "AdGuardHome核心下载失败"
fi
else
log_error "未找到AdGuardHome核心下载地址"
fi
-------------------- AdGuardHome LuCI 识别与配置 --------------------
log_step "配置AdGuardHome LuCI识别"
创建 /etc/config/adguardhome
mkdir -p "package/base-files/files/etc/config"
cat > "package/base-files/files/etc/config/adguardhome" <<EOF
config adguardhome 'main'
option enabled '0'
option binpath '/usr/bin/AdGuardHome'
option configpath '/etc/AdGuardHome/AdGuardHome.yaml'
option workdir '/etc/AdGuardHome'
option logfile '/var/log/AdGuardHome.log'
option verbose '0'
option update '1'
EOF
log_success "AdGuardHome UCI配置文件创建完成"
创建初始化YAML配置
mkdir -p "package/base-files/files/etc/AdGuardHome"
cat > "package/base-files/files/etc/AdGuardHome/AdGuardHome.yaml" <<EOF
bind_host: 0.0.0.0
bind_port: 3000
users:

name: admin
password: $2y$10$gIAKp1l.BME2k5p6mMYlj..4l5mhc8YBGZzI8J/6z8s8nJlQ6oP4y
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: zh-cn
theme: auto
debug_pprof: false
web_session_ttl: 720
dns:
bind_hosts:

0.0.0.0
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
safebrowsing_block_host: standard-block.dns.adguard.com
ratelimit: 20
ratelimit_whitelist: []
refuse_any: true
upstream_dns:
223.5.5.5
119.29.29.29
tls://dns.alidns.com
tls://doh.pub
upstream_dns_file: ""
bootstrap_dns:
223.5.5.5:53
119.29.29.29:53
all_servers: false
fastest_addr: false
fastest_timeout: 1s
allowed_clients: []
disallowed_clients: []
blocked_hosts:
version.bind
id.server
hostname.bind
trusted_proxies:
127.0.0.0/8
::1/128
cache_size: 4194304
cache_ttl_min: 0
cache_ttl_max: 0
cache_optimistic: false
bogus_nxdomain: []
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
safebrowsing_enabled: false
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
log_file: ""
log_max_backups: 0
log_max_size: 100
log_max_age: 3
log_compress: false
log_localtime: false
verbose: false
os:
group: ""
user: ""
rlimit_nofile: 0
schema_version: 17
EOF
log_success "AdGuardHome初始化YAML配置创建完成"



创建AdGuardHome初始化服务脚本
mkdir -p "package/base-files/files/etc/init.d"
cat > "package/base-files/files/etc/init.d/adguardhome" <<'EOF'
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
确保工作目录存在
mkdir -p "$workdir"
确保配置文件存在
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
chmod +x "package/base-files/files/etc/init.d/adguardhome"
log_success "AdGuardHome初始化服务脚本创建完成"
log_success "AdGuardHome LuCI识别配置完成"
-------------------- dnsmasq 配置 (禁用 DNS 功能，保留 DHCP) --------------------
log_step "配置dnsmasq (禁用DNS，保留DHCP)"
mkdir -p "package/base-files/files/etc/config"
cat > "package/base-files/files/etc/config/dhcp" <<EOF
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
log_success "dnsmasq配置完成 (DNS功能已禁用，DHCP功能保留)"
-------------------- firewall4/nftables 适配 --------------------
log_step "配置firewall4/nftables适配"
创建自定义nftables规则文件
mkdir -p "package/base-files/files/etc/nftables.d"
cat > "package/base-files/files/etc/nftables.d/adguardhome.nft" <<EOF
AdGuardHome DNS redirect rules
table inet adguardhome {
chain dnat_dns {
type nat hook prerouting priority dstnat; policy accept;
LAN DNS redirect
iifname "br-lan" tcp dport 53 dnat to 127.0.0.1:5353 comment "AdGuardHome TCP DNS redirect"
iifname "br-lan" udp dport 53 dnat to 127.0.0.1:5353 comment "AdGuardHome UDP DNS redirect"
WAN DNS redirect (optional, for router itself)
iifname != "br-lan" ip saddr != 127.0.0.0/8 tcp dport 53 dnat to 127.0.0.1:5353 comment "AdGuardHome WAN TCP DNS redirect"
iifname != "br-lan" ip saddr != 127.0.0.0/8 udp dport 53 dnat to 127.0.0.1:5353 comment "AdGuardHome WAN UDP DNS redirect"
}
chain accept_adguard {
type filter hook input priority 0; policy accept;
Allow AdGuardHome web interface
tcp dport 3000 accept comment "AdGuardHome Web Interface"
Allow AdGuardHome DNS
tcp dport 5353 accept comment "AdGuardHome DNS TCP"
udp dport 5353 accept comment "AdGuardHome DNS UDP"
}
}
EOF
log_success "nftables规则文件创建完成"
创建 firewall.user 文件 (作为备用方案)
cat > "package/base-files/files/etc/firewall.user" <<EOF
#!/bin/sh
AdGuardHome firewall rules
Load AdGuardHome nftables rules
if [ -f /etc/nftables.d/adguardhome.nft ]; then
nft -f /etc/nftables.d/adguardhome.nft 2>/dev/null
fi
Fallback rules if nftables config doesn't work
nft add table inet fw4 2>/dev/null || true
nft add chain inet fw4 dstnat '{ type nat hook prerouting priority dstnat; }' 2>/dev/null || true
nft add chain inet fw4 input_lan '{ type filter hook input priority filter; }' 2>/dev/null || true
DNS redirect rules
nft add rule inet fw4 dstnat iifname "br-lan" tcp dport 53 dnat to 127.0.0.1:5353 comment "AdGuardHome TCP" 2>/dev/null || true
nft add rule inet fw4 dstnat iifname "br-lan" udp dport 53 dnat to 127.0.0.1:5353 comment "AdGuardHome UDP" 2>/dev/null || true
Accept rules
nft add rule inet fw4 input_lan tcp dport 3000 accept comment "AdGuardHome Web" 2>/dev/null || true
nft add rule inet fw4 input_lan tcp dport 5353 accept comment "AdGuardHome DNS TCP" 2>/dev/null || true

nft add rule inet fw4 input_lan udp dport 5353 accept comment "AdGuardHome DNS UDP" 2>/dev/null || true
EOF
chmod +x "package/base-files/files/etc/firewall.user"
log_success "firewall.user备用脚本创建完成"
log_success "firewall4/nftables适配配置完成"
-------------------- 系统配置优化 --------------------
log_step "配置系统优化"
创建系统优化脚本
mkdir -p "package/base-files/files/etc/init.d"
cat > "package/base-files/files/etc/init.d/adguard-optimize" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
start() {
优化DNS解析
echo 'nameserver 127.0.0.1' > /tmp/resolv.conf
echo 'nameserver 223.5.5.5' >> /tmp/resolv.conf
设置AdGuardHome文件权限
chmod +x /usr/bin/AdGuardHome 2>/dev/null || true
确保工作目录权限正确
mkdir -p /etc/AdGuardHome
chmod 755 /etc/AdGuardHome
应用nftables规则
[ -f /etc/nftables.d/adguardhome.nft ] && nft -f /etc/nftables.d/adguardhome.nft 2>/dev/null || true
}
EOF
chmod +x "package/base-files/files/etc/init.d/adguard-optimize"
log_success "系统优化脚本创建完成"
log_success "系统优化配置完成"
-------------------- 插件集成 --------------------
log_step "集成sirpdboy插件"
mkdir -p package/custom
rm -rf package/custom/luci-app-watchdog package/custom/luci-app-partexp
log_info "克隆luci-app-watchdog插件..."
if retry_command "git clone --depth 1 https://github.com/sirpdboy/luci-app-watchdog.git package/custom/luci-app-watchdog"; then
log_success "luci-app-watchdog插件克隆成功"
else
log_error "luci-app-watchdog插件克隆失败"
fi
log_info "克隆luci-app-partexp插件..."
if retry_command "git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git package/custom/luci-app-partexp"; then
log_success "luci-app-partexp插件克隆成功"
else
log_error "luci-app-partexp插件克隆失败"
fi
更新和安装feeds
log_info "更新所有feeds..."
if retry_command "./scripts/feeds update -a"; then
log_success "feeds更新成功"
else
log_warn "feeds更新失败，但继续执行"
fi
log_info "安装所有feeds..."
if retry_command "./scripts/feeds install -a"; then
log_success "feeds安装成功"

else
log_warn "feeds安装失败，但继续执行"
fi
启用插件
if grep -q "^CONFIG_PACKAGE_luci-app-watchdog=y" .config; then
log_info "luci-app-watchdog 已启用"
else
echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> .config
log_success "已启用 luci-app-watchdog"
fi
if grep -q "^CONFIG_PACKAGE_luci-app-partexp=y" .config; then
log_info "luci-app-partexp 已启用"
else
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
log_success "已启用 luci-app-partexp"
fi
log_success "sirpdboy插件集成完成"
-------------------- 最终检查和配置清理 --------------------
log_step "执行最终配置检查和清理"
确保firewall4相关包启用
log_info "配置firewall4相关包..."
packages_to_enable=(
"CONFIG_PACKAGE_firewall4=y"
"CONFIG_PACKAGE_nftables=y"
"CONFIG_PACKAGE_kmod-nft-core=y"
"CONFIG_PACKAGE_kmod-nft-nat=y"
)
for package in "${packages_to_enable[@]}"; do
package_name=$(echo "$package" | cut -d'=' -f1)
if grep -q "^${package}" .config; then
log_info "${package_name} 已启用"
else
echo "$package" >> .config
log_success "已启用 ${package_name}"
fi
done
禁用可能冲突的防火墙
log_info "禁用可能冲突的防火墙包..."
packages_to_disable=(
"CONFIG_PACKAGE_iptables=n"
"CONFIG_PACKAGE_firewall=n"
)
for package in "${packages_to_disable[@]}"; do
package_name=$(echo "$package" | cut -d'=' -f1)
sed -i "/^${package_name}=y/d" .config
echo "$package" >> .config
log_success "已禁用 ${package_name}"
done
log_success "配置检查和清理完成"
-------------------- 最终检查和脚本摘要 --------------------
print_summary "$SCRIPT_START_TIME"
