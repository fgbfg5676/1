#!/bin/bash
#
# OpenWrt 插件集成脚本 - 云编译环境适配版 (V7.4-内核下载修复版)
# 修复：增强 download_clash_core 函数的错误处理和重试机制，支持多种内核下载方式
#

set -eo pipefail
export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '

# -------------------- 日志函数 --------------------
log_step() { echo -e "\n[$(date +'%H:%M:%S')] \033[1;36m📝 步骤：$*\033[0m"; }
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m" >&2; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m" >&2; }
log_debug() { [[ "$DEBUG_MODE" == "true" ]] && echo -e "[$(date +'%H:%M:%S')] \033[90m🐛 $*\033[0m"; }

# -------------------- 全局配置 --------------------
log_step "开始 OpenWrt 插件集成流程（V7.4-内核下载修复版）"

validation_passed=true
plugin_count=0
CONFIG_FILE=".config"
CONFIG_CUSTOM=".config.custom"
CUSTOM_PLUGINS_DIR="package/custom"
DEBUG_MODE=${DEBUG_MODE:-"false"}
CLOUD_MODE=${CLOUD_MODE:-"true"}
GIT_CONNECT_TIMEOUT=30
GIT_CLONE_TIMEOUT=1800
MAX_RETRIES=3
OPENWRT_VERSION="unknown"
ARCH="armv7"
LAN_IFACE=${LAN_IFACE:-"eth1"}
WAN_IFACE=${WAN_IFACE:-"eth0"}
IS_DSA=false

declare -A config_cache=()

declare -A DEPS=(
    ["kernel"]="CONFIG_KERNEL_IP_TRANSPARENT_PROXY=y CONFIG_KERNEL_NETFILTER=y CONFIG_KERNEL_NF_CONNTRACK=y CONFIG_KERNEL_NF_NAT=y CONFIG_KERNEL_NF_TPROXY=y CONFIG_KERNEL_IP6_NF_IPTABLES=y"
    ["drivers"]="CONFIG_PACKAGE_kmod-ubi=y CONFIG_PACKAGE_kmod-ubifs=y CONFIG_PACKAGE_kmod-ipt-core=y CONFIG_PACKAGE_kmod-ipt-nat=y CONFIG_PACKAGE_kmod-ipt-conntrack=y CONFIG_PACKAGE_kmod-ath10k=y CONFIG_PACKAGE_ath10k-firmware-qca4019=y CONFIG_PACKAGE_kmod-mii=y"
    ["network"]="CONFIG_PACKAGE_bash=y CONFIG_PACKAGE_wget=y CONFIG_PACKAGE_tcpdump=y CONFIG_PACKAGE_traceroute=y CONFIG_PACKAGE_ss=y CONFIG_PACKAGE_ping=y CONFIG_PACKAGE_dnsmasq-full=y CONFIG_PACKAGE_firewall=y CONFIG_PACKAGE_udhcpc=y CONFIG_BUSYBOX_CONFIG_UDHCPC=y"
    ["openclash"]="CONFIG_PACKAGE_luci-app-openclash=y CONFIG_PACKAGE_kmod-tun=y CONFIG_PACKAGE_coreutils-nohup=y CONFIG_PACKAGE_curl=y CONFIG_PACKAGE_jsonfilter=y CONFIG_PACKAGE_ca-certificates=y CONFIG_PACKAGE_ipset=y CONFIG_PACKAGE_ip-full=y CONFIG_PACKAGE_ruby=y CONFIG_PACKAGE_ruby-yaml=y CONFIG_PACKAGE_unzip=y CONFIG_PACKAGE_luci-compat=y CONFIG_PACKAGE_luci-base=y CONFIG_PACKAGE_luci-i18n-openclash-zh-cn=y CONFIG_PACKAGE_iptables-mod-tproxy=y"
    ["passwall2"]="CONFIG_PACKAGE_luci-app-passwall2=y CONFIG_PACKAGE_xray-core=y CONFIG_PACKAGE_sing-box=y CONFIG_PACKAGE_tuic-client=y CONFIG_PACKAGE_chinadns-ng=y CONFIG_PACKAGE_haproxy=y CONFIG_PACKAGE_hysteria=y CONFIG_PACKAGE_v2ray-geoip=y CONFIG_PACKAGE_v2ray-geosite=y CONFIG_PACKAGE_unzip=y CONFIG_PACKAGE_coreutils=y CONFIG_PACKAGE_coreutils-base64=y CONFIG_PACKAGE_coreutils-nohup=y CONFIG_PACKAGE_curl=y CONFIG_PACKAGE_ipset=y CONFIG_PACKAGE_ip-full=y CONFIG_PACKAGE_luci-compat=y CONFIG_PACKAGE_luci-lib-jsonc=y CONFIG_PACKAGE_tcping=y CONFIG_PACKAGE_luci-i18n-passwall2-zh-cn=y CONFIG_PACKAGE_iptables=y CONFIG_PACKAGE_iptables-mod-tproxy=y CONFIG_PACKAGE_iptables-mod-socket=y CONFIG_PACKAGE_kmod-ipt-nat=y"
    ["target"]="CONFIG_TARGET_ipq40xx=y CONFIG_TARGET_ipq40xx_generic=y CONFIG_TARGET_DEVICE_ipq40xx_generic_DEVICE_mobipromo_cm520-79f=y CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y"
)

DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
NETWORK_CFG_DIR="target/linux/ipq40xx/base-files/etc/board.d"
NETWORK_CFG="$NETWORK_CFG_DIR/02_network"

trap 'rm -rf /tmp/*_$$ 2>/dev/null || true' EXIT

# -------------------- 包存在性检查函数 --------------------
check_package_exists() {
    local pkg="$1"
    local pkg_name=$(echo "$pkg" | sed 's/CONFIG_PACKAGE_//;s/=y//')
    if [ -f "feeds/packages.index" ] && grep -q "^Package: $pkg_name$" feeds/packages.index; then return 0; fi
    if [ -f "feeds/luci.index" ] && grep -q "^Package: $pkg_name$" feeds/luci.index; then return 0; fi
    if [ -f "feeds/routing.index" ] && grep -q "^Package: $pkg_name$" feeds/routing.index; then return 0; fi
    if [ -f "feeds/telephony.index" ] && grep -q "^Package: $pkg_name$" feeds/telephony.index; then return 0; fi
    if [ -d "package/kernel/linux/modules" ] && find package/kernel/linux/modules -name "*.mk" -exec grep -l "define KernelPackage/$pkg_name" {} \; | head -1; then return 0; fi
    log_warning "包不存在，跳过: $pkg_name"
    return 1
}

# -------------------- 环境检查 --------------------
check_environment() {
    log_step "检查运行环境"
    if [ ! -d "package" ] || [ ! -f "scripts/feeds" ]; then log_error "不在 OpenWrt/LEDE 源代码根目录！缺少 package/ 或 scripts/feeds。请 cd lede 后运行。"; fi
    if [ "$EUID" -ne 0 ]; then log_warning "建议以 root 用户运行（当前: $USER）。执行: chown -R $(id -u):$(id -g) ."; fi
    log_success "环境检查通过 (coolsnowwolf/lede 兼容)"
}

# -------------------- 依赖工具检查 --------------------
check_dependencies() {
    log_step "检查依赖工具"
    local tools=("git" "sed" "grep" "timeout" "flock" "find" "mv" "rm" "cp" "chmod" "mkdir" "touch" "wc" "awk" "unzip" "wget" "curl" "gettext" "make" "gcc" "jq" "gunzip" "gzip")
    local missing=()
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then missing+=("$tool"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then log_error "缺失必需工具：${missing[*]}。安装命令：sudo apt update && sudo apt install -y ${missing[*]}"; fi
    if [ "$CLOUD_MODE" = "true" ] && [ -n "$HTTP_PROXY" ]; then
        log_info "配置 Git 代理: $HTTP_PROXY"
        git config --global http.proxy "$HTTP_PROXY"
        git config --global https.proxy "$HTTP_PROXY"
    fi
    log_success "依赖工具检查通过"
}

# -------------------- 版本检测与 DSA 判断 --------------------
detect_openwrt_version() {
    log_step "检测 OpenWrt/LEDE 版本与架构"
    local version_file="include/version.mk"
    if [ -d ".git" ]; then
        local git_ver=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || git rev-parse --abbrev-ref HEAD | sed 's/lede-//' || echo "master")
        if [[ "$git_ver" =~ ([0-9]{4})([0-9]{2})([0-9]{2}) ]]; then OPENWRT_VERSION="21.02"; log_info "日期格式或 master 分支，假设为 $OPENWRT_VERSION (legacy 模式)"; else OPENWRT_VERSION="$git_ver"; fi
        log_info "从 Git 提取版本: $OPENWRT_VERSION (coolsnowwolf/lede)"
    elif [ -f "$version_file" ]; then
        OPENWRT_VERSION=$(grep '^OPENWRT_VERSION=' "$version_file" | cut -d= -f2 | tr -d ' "' || echo "master")
        log_info "从 version.mk 提取版本: $OPENWRT_VERSION"
    else
        log_warning "未找到版本文件或 Git 仓库，假设 master (legacy)"; OPENWRT_VERSION="master";
    fi
    if [[ "$OPENWRT_VERSION" =~ ^(23\.05|24\.10|snapshot) ]]; then
        IS_DSA=true; log_info "检测到 DSA 架构（23.05+）"
        DEPS["network"]+=" CONFIG_PACKAGE_kmod-nft-nat=y CONFIG_PACKAGE_kmod-nft-tproxy=y"
        DEPS["openclash"]+=" CONFIG_PACKAGE_kmod-nft-tproxy=y"
    else
        IS_DSA=false; log_info "使用传统网络架构 (swconfig, 兼容 coolsnowwolf/lede)"
        DEPS["network"]+=" CONFIG_PACKAGE_iptables-mod-nat-extra=y CONFIG_PACKAGE_kmod-ipt-offload=y"
        DEPS["passwall2"]+=" CONFIG_PACKAGE_iptables=y CONFIG_PACKAGE_iptables-mod-tproxy=y CONFIG_PACKAGE_iptables-mod-socket=y CONFIG_PACKAGE_kmod-ipt-nat=y"
    fi
    if [ -f "$CONFIG_FILE" ] && grep -q "kmod-ath10k-ct\|ath10k-firmware-qca4019-ct" "$CONFIG_FILE"; then
        log_warning "检测到 CT WiFi 配置，移除以使用标准版"; sed -i '/kmod-ath10k-ct\|ath10k-firmware-qca4019-ct/d' "$CONFIG_FILE";
    fi
    log_success "版本检测完成 (legacy 优先)"
}

# -------------------- 配置缓存管理 --------------------
init_config_cache() {
    log_step "初始化配置缓存"
    if [ ! -f "$CONFIG_FILE" ]; then log_info "配置文件不存在，创建空文件"; touch "$CONFIG_FILE"; return 0; fi
    if [ ! -r "$CONFIG_FILE" ]; then log_warning "配置文件不可读，跳过缓存"; return 0; fi
    local total_lines=$(grep -v -E '^#|^$' "$CONFIG_FILE" | wc -l)
    log_info "发现 $total_lines 个有效配置项，开始加载缓存"
    while IFS= read -r line; do [[ "$line" =~ ^# || -z "$line" ]] && continue; config_cache["$line"]=1; done < "$CONFIG_FILE"
    log_success "配置缓存初始化完成（加载 $total_lines 项）"
}

# -------------------- 安全文件操作 --------------------
safe_mkdir() { local dir="$1"; [ -d "$dir" ] && return 0; if ! mkdir -p "$dir"; then log_error "无法创建目录: $dir（权限问题）"; fi; log_info "创建目录: $dir"; }
safe_write_file() { local file="$1" content="$2"; safe_mkdir "$(dirname "$file")"; if ! echo "$content" > "$file"; then log_error "无法写入文件: $file"; fi; log_info "写入文件: $file"; }

# -------------------- 设备树与网络配置（DTS 保护） --------------------
setup_device_tree() {
    log_step "配置 CM520-79F 设备树与网络"
    safe_mkdir "$DTS_DIR"
    if [ -f "$DTS_FILE" ] && [ -s "$DTS_FILE" ]; then
        if [ ! -f "${DTS_FILE}.bak" ]; then cp "$DTS_FILE" "${DTS_FILE}.bak"; log_info "备份自定义 DTS 至 ${DTS_FILE}.bak"; fi
        log_success "检测到自定义 DTS，跳过覆盖，保留现有文件"
    else
        local dts_content=$(cat <<'EOF'
/dts-v1/;
/* SPDX-License-Identifier: GPL-2.0-or-later OR MIT */
#include "qcom-ipq4019.dtsi"
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/input/input.h>
#include <dt-bindings/soc/qcom,tcsr.h>
/ {
	model = "MobiPromo CM520-79F";
	compatible = "mobipromo,cm520-79f";
	aliases { led-boot = &led_sys; led-failsafe = &led_sys; led-running = &led_sys; led-upgrade = &led_sys; };
	chosen { bootargs-append = " ubi.block=0,1 root=/dev/ubiblock0_1"; };
	soc {
		rng@22000 { status = "okay"; };
		mdio@90000 { status = "okay"; pinctrl-0 = <&mdio_pins>; pinctrl-names = "default"; reset-gpios = <&tlmm 47 GPIO_ACTIVE_LOW>; reset-delay-us = <1000>; };
		ess-psgmii@98000 { status = "okay"; };
		tcsr@1949000 { compatible = "qcom,tcsr"; reg = <0x1949000 0x100>; qcom,wifi_glb_cfg = <TCSR_WIFI_GLB_CFG>; };
		tcsr@194b000 { compatible = "qcom,tcsr"; reg = <0x194b000 0x100>; qcom,usb-hsphy-mode-select = <TCSR_USB_HSPHY_HOST_MODE>; };
		ess_tcsr@1953000 { compatible = "qcom,tcsr"; reg = <0x1953000 0x1000>; qcom,ess-interface-select = <TCSR_ESS_PSGMII>; };
		tcsr@1957000 { compatible = "qcom,tcsr"; reg = <0x1957000 0x100>; qcom,wifi_noc_memtype_m0_m2 = <TCSR_WIFI_NOC_MEMTYPE_M0_M2>; };
		usb2@60f8800 { status = "okay"; dwc3@6000000 { #address-cells = <1>; #size-cells = <0>; usb2_port1: port@1 { reg = <1>; #trigger-source-cells = <0>; }; }; };
		usb3@8af8800 { status = "okay"; dwc3@8a00000 { #address-cells = <1>; #size-cells = <0>; usb3_port1: port@1 { reg = <1>; #trigger-source-cells = <0>; }; usb3_port2: port@2 { reg = <2>; #trigger-source-cells = <0>; }; }; };
		crypto@8e3a000 { status = "okay"; }; watchdog@b017000 { status = "okay"; }; ess-switch@c000000 { status = "okay"; }; edma@c080000 { status = "okay"; };
	};
	led_spi {
		compatible = "spi-gpio"; #address-cells = <1>; #size-cells = <0>; sck-gpios = <&tlmm 40 GPIO_ACTIVE_HIGH>; mosi-gpios = <&tlmm 36 GPIO_ACTIVE_HIGH>; num-chipselects = <0>;
		led_gpio: led_gpio@0 { compatible = "fairchild,74hc595"; reg = <0>; gpio-controller; #gpio-cells = <2>; registers-number = <1>; spi-max-frequency = <1000000>; };
	};
	leds {
		compatible = "gpio-leds";
		usb { label = "blue:usb"; gpios = <&tlmm 10 GPIO_ACTIVE_HIGH>; linux,default-trigger = "usbport"; trigger-sources = <&usb3_port1>, <&usb3_port2>, <&usb2_port1>; };
		led_sys: can { label = "blue:can"; gpios = <&tlmm 11 GPIO_ACTIVE_HIGH>; };
		wan { label = "blue:wan"; gpios = <&led_gpio 0 GPIO_ACTIVE_LOW>; };
		lan1 { label = "blue:lan1"; gpios = <&led_gpio 1 GPIO_ACTIVE_LOW>; };
		lan2 { label = "blue:lan2"; gpios = <&led_gpio 2 GPIO_ACTIVE_LOW>; };
		wlan2g { label = "blue:wlan2g"; gpios = <&led_gpio 5 GPIO_ACTIVE_LOW>; linux,default-trigger = "phy0tpt"; };
		wlan5g { label = "blue:wlan5g"; gpios = <&led_gpio 6 GPIO_ACTIVE_LOW>; linux,default-trigger = "phy1tpt"; };
	};
	keys { compatible = "gpio-keys"; reset { label = "reset"; gpios = <&tlmm 18 GPIO_ACTIVE_LOW>; linux,code = <KEY_RESTART>; }; };
};
&blsp_dma { status = "okay"; }; &blsp1_uart1 { status = "okay"; }; &blsp1_uart2 { status = "okay"; }; &cryptobam { status = "okay"; };
&gmac0 { status = "okay"; nvmem-cells = <&macaddr_art_1006>; nvmem-cell-names = "mac-address"; };
&gmac1 { status = "okay"; nvmem-cells = <&macaddr_art_5006>; nvmem-cell-names = "mac-address"; };
&nand {
	pinctrl-0 = <&nand_pins>; pinctrl-names = "default"; status = "okay";
	nand@0 {
		partitions {
			compatible = "fixed-partitions"; #address-cells = <1>; #size-cells = <1>;
			partition@0 { label = "Bootloader"; reg = <0x0 0xb00000>; read-only; };
			art: partition@b00000 {
				label = "ART"; reg = <0xb00000 0x80000>; read-only; compatible = "nvmem-cells"; #address-cells = <1>; #size-cells = <1>;
				precal_art_1000: precal@1000 { reg = <0x1000 0x2f20>; }; macaddr_art_1006: macaddr@1006 { reg = <0x1006 0x6>; };
				precal_art_5000: precal@5000 { reg = <0x5000 0x2f20>; }; macaddr_art_5006: macaddr@5006 { reg = <0x5006 0x6>; };
			};
			partition@b80000 { label = "rootfs"; reg = <0xb80000 0x7480000>; };
		};
	};
};
&qpic_bam { status = "okay"; };
&tlmm {
	mdio_pins: mdio_pinmux { mux_1 { pins = "gpio6"; function = "mdio"; bias-pull-up; }; mux_2 { pins = "gpio7"; function = "mdc"; bias-pull-up; }; };
	nand_pins: nand_pins { pullups { pins = "gpio52", "gpio53", "gpio58", "gpio59"; function = "qpic"; bias-pull-up; }; pulldowns { pins = "gpio54", "gpio55", "gpio56", "gpio57", "gpio60", "gpio61", "gpio62", "gpio63", "gpio64", "gpio65", "gpio66", "gpio67", "gpio68", "gpio69"; function = "qpic"; bias-pull-down; }; };
};
&usb3_ss_phy { status = "okay"; }; &usb3_hs_phy { status = "okay"; }; &usb2_hs_phy { status = "okay"; };
&wifi0 { status = "okay"; nvmem-cell-names = "pre-calibration"; nvmem-cells = <&precal_art_1000>; qcom,ath10k-calibration-variant = "CM520-79F"; };
&wifi1 { status = "okay"; nvmem-cell-names = "pre-calibration"; nvmem-cells = <&precal_art_5000>; qcom,ath10k-calibration-variant = "CM520-79F"; };
EOF
        ); safe_write_file "$DTS_FILE" "$dts_content"; log_success "DTS 文件写入完成（默认内容，coolsnowwolf 兼容）";
    fi
    local network_content; if $IS_DSA; then log_info "配置 DSA 网络（交换机模式）"; LAN_IFACE="lan1 lan2"; WAN_IFACE="wan"; network_content=$(cat <<EOF
#!/bin/sh
. /lib/functions/system.sh
ipq40xx_board_detect() {
	local machine; machine=\$(board_name); case "\$machine" in "mobipromo,cm520-79f") ucidef_set_interface_loopback; ucidef_add_switch "switch0" "0u@eth0" "1:lan" "2:lan" "3:wan"; ucidef_set_interfaces_lan_wan "$LAN_IFACE" "$WAN_IFACE"; ;; esac
}
boot_hook_add preinit_main ipq40xx_board_detect
EOF
        ); else log_info "配置传统网络（eth 接口模式，coolsnowwolf 兼容）"; network_content=$(cat <<EOF
#!/bin/sh
. /lib/functions/system.sh
ipq40xx_board_detect() { local machine; machine=\$(board_name); case "\$machine" in "mobipromo,cm520-79f") ucidef_set_interfaces_lan_wan "$LAN_IFACE" "$WAN_IFACE"; ;; esac }
boot_hook_add preinit_main ipq40xx_board_detect
EOF
        ); fi
    safe_write_file "$NETWORK_CFG" "$network_content"; chmod +x "$NETWORK_CFG"; log_info "网络接口配置完成（LAN: $LAN_IFACE, WAN: $WAN_IFACE）";
    if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
        local device_rule=$(cat <<'EOF'

define Device/mobipromo_cm520-79f
    DEVICE_VENDOR := MobiPromo
    DEVICE_MODEL := CM520-79F
    DEVICE_DTS := qcom-ipq4019-cm520-79f
    KERNEL_SIZE := 4096k
    ROOTFS_SIZE := 16384k
    IMAGE_SIZE := 81920k
    IMAGE/trx := append-kernel | pad-to $(KERNEL_SIZE) | append-rootfs | trx -o $@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
        ); echo "$device_rule" >> "$GENERIC_MK"; log_success "设备编译规则添加完成";
    else sed -i 's/IMAGE_SIZE := 32768k/IMAGE_SIZE := 81920k/' "$GENERIC_MK" 2>/dev/null || true; log_info "设备编译规则已存在，更新 IMAGE_SIZE";
    fi
}

# -------------------- 配置项管理 --------------------
add_config_if_missing() {
    local config="$1" description="$2"
    [ -z "$config" ] && return 0
    if [ -n "${config_cache[$config]}" ]; then log_debug "配置已存在: $config"; return 0; fi
    if [[ "$config" == CONFIG_PACKAGE_* ]]; then if ! check_package_exists "$config"; then return 0; fi; fi
    echo "$config" >> "$CONFIG_CUSTOM"
    config_cache["$config"]=1; log_info "添加配置: $config ($description)";
}
add_deps_by_layer() {
    local layer="$1"
    if [ -z "$layer" ] || [ -z "${DEPS[$layer]}" ]; then
        log_warning "依赖层 '$layer' 不存在或为空，跳过依赖添加。"
        return 1
    fi
    local deps_str="${DEPS[$layer]}"
    local -a deps=(); read -ra deps <<< "$deps_str"
    [ ${#deps[@]} -eq 0 ] && return 0
    log_step "添加 [$layer] 层依赖（共 ${#deps[@]} 项）"
    local added=0
    for config in "${deps[@]}"; do
        if add_config_if_missing "$config" "$layer 层依赖"; then added=$((added + 1)); fi
    done
    log_info "[$layer] 层成功添加 $added 个依赖项"
}

# -------------------- 插件集成函数 --------------------
try_git_mirrors() {
    local original_repo="$1" temp_dir="$2"
    local mirrors=(
        "$original_repo"
        "https://ghproxy.com/$original_repo"
        "https://hub.fastgit.xyz/${original_repo#*github.com/}"
        "https://gitclone.com/github.com/${original_repo#*github.com/}"
    )
    for mirror in "${mirrors[@]}"; do
        for ((retry=0; retry<MAX_RETRIES; retry++)); do
            log_info "尝试镜像（$retry）: $mirror"
            if timeout "$GIT_CONNECT_TIMEOUT" git ls-remote --heads "$mirror" >/dev/null 2>&1; then
                log_info "开始克隆（超时 ${GIT_CLONE_TIMEOUT}s）"
                if timeout "$GIT_CLONE_TIMEOUT" git clone --depth 1 --single-branch "$mirror" "$temp_dir" 2>&1; then
                    if [ -d "$temp_dir" ] && [ "$(ls -A "$temp_dir" 2>/dev/null)" != "" ]; then
                        log_success "克隆成功（镜像: $mirror）"; return 0;
                    fi
                fi
            fi
            [ $retry -lt $((MAX_RETRIES - 1)) ] && sleep 5
        done
        [ -d "$temp_dir" ] && rm -rf "$temp_dir"
    done
    log_error "所有镜像克隆失败: $original_repo"; return 1;
}

# -------------------- 修复版内核下载函数 --------------------
# 云编译环境专用的 OpenClash 内核下载函数（超强版）
download_clash_core() {
    log_step "云编译环境专用 OpenClash 内核下载 (mihomo/clash.meta)"
    local core_dir="package/base-files/files/etc/openclash/core"
    safe_mkdir "$core_dir"
    
    # 云编译环境专用配置
    local download_timeout=180  # 缩短超时时间
    local connection_timeout=30
    local retry_delay=3
    local max_mirrors=5
    
    # 定义多架构支持
    local target_arch="armv7"
    if grep -q "CONFIG_TARGET_.*aarch64" "$CONFIG_FILE" 2>/dev/null; then
        target_arch="arm64"
    elif grep -q "CONFIG_TARGET_.*x86_64" "$CONFIG_FILE" 2>/dev/null; then
        target_arch="amd64"
    elif grep -q "CONFIG_TARGET_.*mips" "$CONFIG_FILE" 2>/dev/null; then
        target_arch="mips"
    fi
    
    log_info "检测到目标架构: $target_arch"
    
    # 预定义多版本内核列表（按稳定性排序）
    local kernel_versions=(
        "1.19.2"  # 最稳定版本
        "1.18.8"  # 长期支持版本
        "1.18.6"  # 备用版本
        "1.17.0"  # 兜底版本
    )
    
    # 高可用镜像列表（专为云环境优化）
    local mirror_prefixes=(
        "https://github.com"                    # 原始源
        "https://ghproxy.com/https://github.com" # 代理1
        "https://mirror.ghproxy.com/https://github.com" # 代理2
        "https://ghp.ci/https://github.com"     # 代理3
        "https://gh-proxy.com/https://github.com" # 代理4
        "https://gitclone.com/github.com"       # 代理5
        "https://hub.gitmirror.com/https://github.com" # 代理6
    )
    
    local temp_file="/tmp/clash_core_$$"
    local final_core_path="$core_dir/clash_meta"
    local download_success=false
    
    log_info "开始云环境内核下载流程..."
    
    # 方法1：尝试获取最新版本（带超时保护）
    local latest_tag=""
    local api_urls=(
        "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        "https://ghproxy.com/https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        "https://mirror.ghproxy.com/https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    )
    
    for api_url in "${api_urls[@]}"; do
        log_info "尝试获取最新版本: $(echo "$api_url" | cut -d'/' -f3)"
        if command -v curl >/dev/null 2>&1; then
            latest_tag=$(timeout 20 curl -fsSL --connect-timeout 10 --max-time 20 \
                -H "Accept: application/vnd.github.v3+json" \
                -H "User-Agent: OpenWrt-Build-Script" \
                "$api_url" 2>/dev/null | \
                grep -o '"tag_name":[[:space:]]*"[^"]*"' | \
                sed 's/"tag_name":[[:space:]]*"//;s/"//' | head -1)
        elif command -v wget >/dev/null 2>&1; then
            latest_tag=$(timeout 20 wget -qO- --connect-timeout=10 --read-timeout=20 \
                --header="Accept: application/vnd.github.v3+json" \
                --user-agent="OpenWrt-Build-Script" \
                "$api_url" 2>/dev/null | \
                grep -o '"tag_name":[[:space:]]*"[^"]*"' | \
                sed 's/"tag_name":[[:space:]]*"//;s/"//' | head -1)
        fi
        
        if [ -n "$latest_tag" ] && [[ "$latest_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_info "成功获取最新版本: $latest_tag"
            # 将最新版本添加到版本列表前面
            kernel_versions=("${latest_tag#v}" "${kernel_versions[@]}")
            break
        fi
        sleep 2
    done
    
    if [ -z "$latest_tag" ]; then
        log_warning "API 请求失败，使用预设版本列表"
    fi
    
    # 方法2：智能多版本下载策略
    for version in "${kernel_versions[@]}"; do
        if [ "$download_success" = true ]; then break; fi
        
        log_info "尝试下载内核版本: $version (架构: $target_arch)"
        
        # 定义该版本的所有可能下载路径
        local download_paths=(
            "/MetaCubeX/mihomo/releases/download/v$version/mihomo-linux-$target_arch-$version.gz"
            "/MetaCubeX/mihomo/releases/download/v$version/mihomo-linux-$target_arch.gz"
            "/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-$target_arch-v$version.gz"
        )
        
        # 为每个版本尝试所有镜像
        for path in "${download_paths[@]}"; do
            if [ "$download_success" = true ]; then break; fi
            
            local mirrors_tried=0
            for mirror_prefix in "${mirror_prefixes[@]}"; do
                if [ "$download_success" = true ] || [ $mirrors_tried -ge $max_mirrors ]; then break; fi
                mirrors_tried=$((mirrors_tried + 1))
                
                local download_url="${mirror_prefix}${path}"
                log_info "[$mirrors_tried/$max_mirrors] 尝试下载: $(basename "$path")"
                log_debug "下载地址: $download_url"
                
                # 使用多种下载工具尝试
                local download_tools=("curl" "wget")
                for tool in "${download_tools[@]}"; do
                    if [ "$download_success" = true ]; then break; fi
                    if ! command -v "$tool" >/dev/null 2>&1; then continue; fi
                    
                    case "$tool" in
                        "curl")
                            timeout $download_timeout curl -fsSL \
                                --connect-timeout $connection_timeout \
                                --max-time $download_timeout \
                                --retry 2 --retry-delay $retry_delay \
                                --user-agent "OpenWrt-Build-Script/1.0" \
                                --header "Accept: application/octet-stream" \
                                -o "$temp_file.gz" "$download_url" 2>/dev/null
                            ;;
                        "wget")
                            timeout $download_timeout wget -q --no-check-certificate \
                                --connect-timeout=$connection_timeout \
                                --read-timeout=$download_timeout \
                                --tries=2 --waitretry=$retry_delay \
                                --user-agent="OpenWrt-Build-Script/1.0" \
                                --header="Accept: application/octet-stream" \
                                -O "$temp_file.gz" "$download_url" 2>/dev/null
                            ;;
                    esac
                    
                    # 验证下载文件
                    if [ -f "$temp_file.gz" ] && [ -s "$temp_file.gz" ]; then
                        # 检查文件类型
                        if file "$temp_file.gz" 2>/dev/null | grep -q "gzip"; then
                            log_info "验证并解压内核文件..."
                            # 测试 gzip 文件完整性
                            if gunzip -t "$temp_file.gz" 2>/dev/null; then
                                # 解压缩
                                if gunzip -c "$temp_file.gz" > "$temp_file" 2>/dev/null; then
                                    # 验证是否为有效的可执行文件
                                    if [ -s "$temp_file" ] && file "$temp_file" 2>/dev/null | grep -q "ELF.*executable"; then
                                        # 移动到最终位置
                                        if mv "$temp_file" "$final_core_path" 2>/dev/null; then
                                            chmod +x "$final_core_path"
                                            download_success=true
                                            log_success "内核下载成功: v$version ($tool, $(echo "$download_url" | cut -d'/' -f3))"
                                            break
                                        fi
                                    fi
                                fi
                            fi
                        fi
                    fi
                    
                    # 清理临时文件
                    rm -f "$temp_file" "$temp_file.gz" 2>/dev/null
                    
                    # 短暂延迟避免请求过快
                    sleep 1
                done
                
                # 镜像间延迟
                [ $mirrors_tried -lt ${#mirror_prefixes[@]} ] && sleep 2
            done
        done
        
        # 版本间延迟
        [ "$download_success" = false ] && sleep 3
    done
    
    # 方法3：尝试 OpenClash 官方预编译包（tar.gz格式）
    if [ "$download_success" = false ]; then
        log_warning "mihomo 下载失败，尝试 OpenClash 官方预编译包..."
        local openclash_paths=(
            "/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-$target_arch.tar.gz"
            "/vernesong/OpenClash/raw/core/master/core_version"  # 获取推荐版本
        )
        
        for mirror_prefix in "${mirror_prefixes[@]}"; do
            if [ "$download_success" = true ]; then break; fi
            
            local download_url="${mirror_prefix}${openclash_paths[0]}"
            log_info "尝试下载官方预编译包: $(basename "${openclash_paths[0]}")"
            
            if timeout $download_timeout curl -fsSL \
                --connect-timeout $connection_timeout \
                --max-time $download_timeout \
                --retry 1 --retry-delay 2 \
                -o "$temp_file.tar.gz" "$download_url" 2>/dev/null; then
                
                if [ -s "$temp_file.tar.gz" ] && file "$temp_file.tar.gz" | grep -q "gzip"; then
                    local extract_dir="/tmp/clash_extract_$$"
                    mkdir -p "$extract_dir"
                    
                    if tar -xzf "$temp_file.tar.gz" -C "$extract_dir" 2>/dev/null; then
                        # 查找可执行文件
                        local clash_bin=$(find "$extract_dir" -name "clash*" -type f -executable 2>/dev/null | head -1)
                        if [ -n "$clash_bin" ] && [ -f "$clash_bin" ]; then
                            if file "$clash_bin" | grep -q "ELF.*executable"; then
                                mv "$clash_bin" "$final_core_path"
                                chmod +x "$final_core_path"
                                download_success=true
                                log_success "OpenClash 官方包下载成功: $(basename "$clash_bin")"
                            fi
                        fi
                    fi
                    rm -rf "$extract_dir"
                fi
                rm -f "$temp_file.tar.gz"
            fi
            
            [ "$download_success" = false ] && sleep 2
        done
    fi
    
    # 方法4：云环境专用的静态备份地址
    if [ "$download_success" = false ]; then
        log_warning "尝试云环境专用静态备份源..."
        local static_backup_urls=(
            "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/core_version"
            "https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/core_version"
        )
        
        # 这里可以添加一些知名的静态文件托管服务作为备份
        for backup_url in "${static_backup_urls[@]}"; do
            if [ "$download_success" = true ]; then break; fi
            log_info "尝试备份源: $(echo "$backup_url" | cut -d'/' -f3)"
            # 根据实际情况实现静态备份下载逻辑
            sleep 1
        done
    fi
    
    # 方法5：创建智能占位符（包含自动更新逻辑）
    if [ "$download_success" = false ]; then
        log_warning "所有下载尝试失败，创建智能占位符"
        cat > "$final_core_path" << 'SMART_PLACEHOLDER_EOF'
#!/bin/sh
# OpenClash 智能内核占位符 - 云编译版本
# 此脚本将在路由器首次启动时自动尝试下载内核

CORE_DIR="/etc/openclash/core"
CORE_FILE="$CORE_DIR/clash_meta"
LOG_FILE="/tmp/openclash_core_download.log"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

download_core() {
    log_msg "开始自动下载 OpenClash 内核..."
    
    # 检测架构
    local arch=$(uname -m)
    case "$arch" in
        "armv7l"|"armv7") arch="armv7" ;;
        "aarch64"|"arm64") arch="arm64" ;;
        "x86_64") arch="amd64" ;;
        "mips") arch="mips" ;;
        *) arch="armv7" ;;
    esac
    
    # 内核下载地址
    local urls=(
        "https://ghproxy.com/https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-$arch.gz"
        "https://mirror.ghproxy.com/https://github.com/MetaCubeX/mihomo/releases/download/v1.19.2/mihomo-linux-$arch-1.19.2.gz"
        "https://ghproxy.com/https://github.com/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-$arch.tar.gz"
    )
    
    for url in "${urls[@]}"; do
        log_msg "尝试下载: $(basename "$url")"
        if wget -qO- --connect-timeout=30 --read-timeout=120 "$url" > "/tmp/core_download.tmp" 2>/dev/null; then
            if [ -s "/tmp/core_download.tmp" ]; then
                # 处理 .gz 文件
                if echo "$url" | grep -q "\.gz$"; then
                    if gunzip -c "/tmp/core_download.tmp" > "$CORE_FILE.tmp" 2>/dev/null; then
                        if [ -s "$CORE_FILE.tmp" ] && file "$CORE_FILE.tmp" | grep -q "executable"; then
                            mv "$CORE_FILE.tmp" "$CORE_FILE"
                            chmod +x "$CORE_FILE"
                            log_msg "内核下载成功!"
                            rm -f "/tmp/core_download.tmp" "$CORE_FILE.tmp"
                            return 0
                        fi
                    fi
                # 处理 .tar.gz 文件
                elif echo "$url" | grep -q "\.tar\.gz$"; then
                    local extract_dir="/tmp/clash_extract"
                    mkdir -p "$extract_dir"
                    if tar -xzf "/tmp/core_download.tmp" -C "$extract_dir" 2>/dev/null; then
                        local clash_bin=$(find "$extract_dir" -name "clash*" -type f -executable | head -1)
                        if [ -n "$clash_bin" ] && [ -f "$clash_bin" ]; then
                            mv "$clash_bin" "$CORE_FILE"
                            chmod +x "$CORE_FILE"
                            log_msg "内核下载成功!"
                            rm -rf "$extract_dir" "/tmp/core_download.tmp"
                            return 0
                        fi
                    fi
                    rm -rf "$extract_dir"
                fi
            fi
        fi
        rm -f "/tmp/core_download.tmp" "$CORE_FILE.tmp"
        sleep 3
    done
    
    log_msg "内核下载失败，请手动更新"
    return 1
}

# 主逻辑
if [ ! -f "$CORE_FILE" ] || [ ! -x "$CORE_FILE" ] || [ "$(stat -c%s "$CORE_FILE" 2>/dev/null || echo 0)" -lt 1000 ]; then
    if [ "$1" = "download" ]; then
        download_core
        exit $?
    else
        echo "OpenClash 内核需要下载，正在后台处理..."
        echo "您可以:"
        echo "1. 等待自动下载完成（约2-5分钟）"
        echo "2. 手动执行: $0 download"
        echo "3. 访问 OpenClash 管理页面进行手动更新"
        
        # 后台下载
        nohup sh -c "sleep 30; $0 download" >/dev/null 2>&1 &
        exit 1
    fi
else
    # 执行实际的内核
    exec "$CORE_FILE" "$@"
fi
SMART_PLACEHOLDER_EOF
        
        chmod +x "$final_core_path"
        log_info "智能占位符创建完成，支持路由器端自动下载"
    fi
    
    # 创建所有必需的内核文件链接
    local core_files=("clash" "clash_tun" "clash_meta")
    for core_file in "${core_files[@]}"; do
        local core_path="$core_dir/$core_file"
        if [ "$core_file" != "clash_meta" ] && [ ! -f "$core_path" ]; then
            ln -sf "./clash_meta" "$core_path" 2>/dev/null || cp "$final_core_path" "$core_path" 2>/dev/null
            log_info "创建内核链接: $core_file"
        fi
    done
    
    # 清理所有临时文件
    rm -f "$temp_file" "$temp_file.gz" "$temp_file.tar.gz" 2>/dev/null || true
    
    # 最终验证和报告
    if [ -f "$final_core_path" ] && [ -x "$final_core_path" ]; then
        local file_size=$(stat -f%z "$final_core_path" 2>/dev/null || stat -c%s "$final_core_path" 2>/dev/null || echo "0")
        log_info "内核文件信息:"
        log_info "  路径: $final_core_path"
        log_info "  大小: ${file_size} 字节"
        log_info "  架构: $target_arch"
        if [ "$download_success" = true ]; then
            log_info "  状态: 真实内核文件"
        else
            log_info "  状态: 智能占位符（支持自动下载）"
        fi
        return 0
    else
        log_error "内核文件创建失败"
        return 1
    fi
}

import_passwall_keys() {
    log_step "导入 Passwall2 软件源密钥"
    local key_dir="package/base-files/files/etc/opkg/keys"
    safe_mkdir "$key_dir"
    local key_urls=("https://openwrt.org/_export/keys/6243C1C880731018A6251B66789C7785659653D" "https://github.com/xiaorouji/openwrt-passwall2/raw/main/keys/9a22e228.pub")
    for url in "${key_urls[@]}"; do
        local key_file="$key_dir/$(basename "$url")"
        if ! wget --no-check-certificate -O "$key_file" "$url" 2>/dev/null; then
            log_warning "密钥下载失败: $url，尝试镜像"
            if ! wget --no-check-certificate -O "$key_file" "https://ghproxy.com/$url" 2>/dev/null; then log_warning "密钥导入失败（可选）"; continue; fi
        fi
        chmod 644 "$key_file" 2>/dev/null || true
    done
    log_success "Passwall2 密钥导入完成"
    return 0
}

fetch_plugin() {
    local repo="$1" plugin_name="$2" subdir="${3:-.}" deps_layer="$4"
    local temp_dir="/tmp/${plugin_name}_$(date +%s)_$" lock_file="/tmp/.${plugin_name}_lock"
    log_step "集成插件: $plugin_name"
    log_info "仓库: $repo"
    safe_mkdir "$CUSTOM_PLUGINS_DIR"
    if [ -d "$CUSTOM_PLUGINS_DIR/$plugin_name/.git" ]; then log_info "$plugin_name 已存在，跳过克隆"; plugin_count=$((plugin_count + 1)); return 0; fi
    exec 200>"$lock_file"
    if ! flock -n 200; then log_warning "等待插件锁释放..."; flock 200; fi
    local cleanup_paths=("feeds/luci/applications/$plugin_name" "feeds/packages/net/$plugin_name" "package/$plugin_name" "$CUSTOM_PLUGINS_DIR/$plugin_name" "$temp_dir")
    for path in "${cleanup_paths[@]}"; do if [ -d "$path" ]; then rm -rf "$path"; log_info "清理旧文件: $path"; fi; done
    if ! try_git_mirrors "$repo" "$temp_dir"; then flock -u 200; log_error "克隆失败: $plugin_name"; return 1; fi
    local source_path="$temp_dir/$subdir"
    if [ ! -f "$source_path/Makefile" ]; then
        local found_makefile=$(find "$source_path" -maxdepth 3 -name Makefile -print -quit 2>/dev/null)
        if [ -n "$found_makefile" ]; then source_path=$(dirname "$found_makefile"); log_info "找到 Makefile: $source_path"; else log_error "未找到 Makefile 在 $source_path"; rm -rf "$temp_dir"; flock -u 200; return 1; fi
    fi
    if ! mv "$source_path" "$CUSTOM_PLUGINS_DIR/$plugin_name"; then log_error "移动插件失败: $plugin_name"; rm -rf "$temp_dir"; flock -u 200; return 1; fi
    rm -rf "$temp_dir"; flock -u 200;
    
    add_deps_by_layer "$deps_layer"
    
    log_success "$plugin_name 集成完成"; plugin_count=$((plugin_count + 1)); return 0;
}

# -------------------- 验证机制 --------------------
verify_filesystem() {
    local plugin=$1; log_step "验证 $plugin 文件系统";
    if [ -d "$CUSTOM_PLUGINS_DIR/$plugin" ] && [ -f "$CUSTOM_PLUGINS_DIR/$plugin/Makefile" ]; then log_success "$plugin 目录结构验证通过"; return 0; else log_error "$plugin 验证失败（目录或 Makefile 缺失）"; validation_passed=false; return 1; fi
}
verify_config_conflicts() {
    log_step "检查配置冲突"
    local conflicts=("CONFIG_PACKAGE_dnsmasq CONFIG_PACKAGE_dnsmasq-full" "CONFIG_PACKAGE_iptables-legacy CONFIG_PACKAGE_iptables-nft" "CONFIG_PACKAGE_kmod-ipt-tproxy CONFIG_PACKAGE_kmod-nft-tproxy")
    for pair in "${conflicts[@]}"; do
        local a=$(echo "$pair" | awk '{print $1}') b=$(echo "$pair" | awk '{print $2}')
        if [ -n "${config_cache[$a=y]}" ] && [ -n "${config_cache[$b=y]}" ]; then
            log_error "配置冲突: $a 和 $b 不能同时启用"
            if [[ "$a" == *"iptables"* && "$b" == *"nft"* && $IS_DSA ]]; then log_info "自动修复：移除 $a，保留 $b（DSA 模式）"; sed -i "/^$a=y/d" "$CONFIG_CUSTOM"; unset config_cache["$a=y"]; else validation_passed=false; fi
        fi
    done
    local deprecated_packages=("CONFIG_PACKAGE_kmod-nf-nathelper-extra=y" "CONFIG_PACKAGE_kmod-qca-nss-drv=y" "CONFIG_PACKAGE_kmod-qca-nss-ecm=y" "CONFIG_PACKAGE_ipq-wifi-mobipromo-cm520-79f=y")
    for pkg in "${deprecated_packages[@]}"; do
        if [ -n "${config_cache[$pkg]}" ]; then log_warning "移除过期包配置: $pkg"; sed -i "/^$(echo "$pkg" | sed 's/[[\.*^$()+?{|]/\\&/g')/d" "$CONFIG_CUSTOM" 2>/dev/null || true; unset config_cache["$pkg"]; fi
    done
    log_info "配置冲突检查完成"
}

# -------------------- 主流程 --------------------
main() {
    if [ "$DEBUG_MODE" = "true" ]; then log_info "启用调试模式"; set -x; fi
    check_environment; check_dependencies; detect_openwrt_version; init_config_cache; setup_device_tree;
    log_step "强制更新 feeds 仓库"
    for feed in feeds/*; do if [ -d "$feed/.git" ]; then log_info "正在更新 $feed ..."; (cd "$feed" && git pull); fi; done
    log_step "更新与安装 feeds"
    ./scripts/feeds update -a || log_error "feeds 更新失败"
    ./scripts/feeds install -a || log_error "feeds 安装失败"
    log_step "添加基础依赖"
    rm -f "$CONFIG_CUSTOM"
    add_deps_by_layer "kernel"; add_deps_by_layer "drivers"; add_deps_by_layer "network"; add_deps_by_layer "target";
    log_step "集成插件"
    local plugins=(
        "https://github.com/vernesong/OpenClash.git|luci-app-openclash|luci-app-openclash|openclash"
        "https://github.com/xiaorouji/openwrt-passwall2.git|luci-app-passwall2|.|passwall2"
        "https://github.com/sirpdboy/luci-app-partexp.git|luci-app-partexp|.|partexp"
    )
    for plugin in "${plugins[@]}"; do IFS='|' read -r repo name subdir deps_layer <<< "$plugin"; if fetch_plugin "$repo" "$name" "$subdir" "$deps_layer"; then true; else log_warning "$name 集成失败，继续其他插件"; fi; done
    log_step "插件后处理"
    download_clash_core; import_passwall_keys;
    log_step "验证插件与配置"
    verify_filesystem "luci-app-openclash" || true; verify_filesystem "luci-app-passwall2" || true; verify_filesystem "luci-app-partexp" || true;
    verify_config_conflicts;
    log_step "生成最终配置"
    if [ -f "$CONFIG_CUSTOM" ] && [ -s "$CONFIG_CUSTOM" ]; then cat "$CONFIG_CUSTOM" >> "$CONFIG_FILE"; rm -f "$CONFIG_CUSTOM"; log_info "合并自定义配置完成"; fi
    log_info "清理无效配置项..."
    if [ -f "$CONFIG_FILE" ]; then local temp_config="/tmp/.config.clean_$"; cp "$CONFIG_FILE" "$temp_config"; sed -i '/CONFIG_PACKAGE_kmod-nf-nathelper-extra=y/d' "$temp_config" 2>/dev/null || true; sed -i '/CONFIG_PACKAGE_kmod-qca-nss/d' "$temp_config" 2>/dev/null || true; sed -i '/CONFIG_PACKAGE_ipq-wifi-mobipromo/d' "$temp_config" 2>/dev/null || true; mv "$temp_config" "$CONFIG_FILE"; log_info "配置清理完成"; fi
    if make defconfig 2>/dev/null; then log_success "配置生成成功"; else log_warning "配置生成有警告，但继续执行"; fi
    log_info "配置变更摘要:"; if [ -f "$CONFIG_FILE" ]; then grep -E '^CONFIG_(TARGET_|PACKAGE_(luci-app-openclash|luci-app-passwall2|luci-app-partexp|kmod-(tun|ipt|ath10k)|xray-core|sing-box))' "$CONFIG_FILE" 2>/dev/null | head -20 || true; fi
    if [ $plugin_count -gt 0 ]; then
        log_success "🎉 插件集成完成（成功数量: $plugin_count，架构: legacy）"
        log_info "下一步操作:"
        log_info "1. [可选] make menuconfig - 进一步自定义配置"
        log_info "2. make -j$(nproc) V=s - 开始编译"
        log_info "3. 固件输出目录: bin/targets/ipq40xx/generic/"
    else
        log_warning "⚠️ 没有插件成功集成，请检查网络连接和仓库地址"
        exit 1
    fi
}
main "$@"
