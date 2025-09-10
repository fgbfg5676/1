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
["partexp"]="CONFIG_PACKAGE_luci-app-partexp=y CONFIG_PACKAGE_parted=y CONFIG_PACKAGE_lsblk=y CONFIG_PACKAGE_fdisk=y CONFIG_PACKAGE_block-mount=y CONFIG_PACKAGE_kmod-fs-ext4=y CONFIG_PACKAGE_e2fsprogs=y CONFIG_PACKAGE_kmod-usb-storage=y CONFIG_PACKAGE_kmod-scsi-generic=y"
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

# 增强的架构检测函数
detect_target_arch() {
    local target_arch="armv7"  # 默认值
    
    log_info "开始检测目标架构..."
    
    # 1. 优先检查 IPQ40xx 平台（这是你的设备）
    if grep -q "CONFIG_TARGET_ipq40xx" "$CONFIG_FILE" 2>/dev/null; then
        target_arch="armv7"
        log_info "✓ 检测到 IPQ40xx 平台 → armv7 架构（CM520-79F 专用）"
        echo "$target_arch"
        return 0
    fi
    
    # 2. 检查其他平台
    if grep -q "CONFIG_TARGET_.*aarch64" "$CONFIG_FILE" 2>/dev/null; then
        target_arch="arm64"
        log_info "✓ 检测到 aarch64 平台 → arm64 架构"
    elif grep -q "CONFIG_TARGET_.*x86_64" "$CONFIG_FILE" 2>/dev/null; then
        target_arch="amd64"
        log_info "✓ 检测到 x86_64 平台 → amd64 架构"
    elif grep -q "CONFIG_TARGET_.*mips.*el" "$CONFIG_FILE" 2>/dev/null; then
        target_arch="mipsle"
        log_info "✓ 检测到 mipsel 平台 → mipsle 架构"
    elif grep -q "CONFIG_TARGET_.*mips" "$CONFIG_FILE" 2>/dev/null; then
        # 注意：对于 IPQ40xx，即使配置中包含 mips，实际也是 ARM
        if grep -q "CONFIG_TARGET_ipq" "$CONFIG_FILE" 2>/dev/null; then
            target_arch="armv7"
            log_info "✓ IPQ 系列芯片检测 → armv7 架构（覆盖 MIPS 检测）"
        else
            target_arch="mips"
            log_info "✓ 检测到纯 MIPS 平台 → mips 架构"
        fi
    else
        log_warning "⚠ 未明确检测到架构，使用默认 armv7"
    fi
    
    echo "$target_arch"
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
download_clash_core_improved() {
    log_step "云编译环境专用 OpenClash 内核下载 (mihomo/clash.meta)"
    local core_dir="package/base-files/files/etc/openclash/core"
    safe_mkdir "$core_dir"
    
    # 使用新的架构检测函数
    local target_arch=$(detect_target_arch)
    log_info "最终确定目标架构: $target_arch"
    
    # 云编译环境优化配置
    local download_timeout=120
    local connection_timeout=20
    local retry_delay=2
    
    # 精选稳定版本
    local kernel_versions=(
        "1.18.8"
        "1.18.6"
        "1.18.5"
        "1.17.0"
    )
    
    # 可靠的镜像源
    local mirror_prefixes=(
        "https://ghproxy.com/https://github.com"
        "https://github.com"
    )
    
    local temp_file="/tmp/clash_core_$$"
    local final_core_path="$core_dir/clash_meta"
    local download_success=false
    
    log_info "开始云环境内核下载流程..."
    
    # 使用预设稳定版本列表
    log_info "使用预设稳定版本列表，跳过 API 查询"
    
    # 下载循环
    for version in "${kernel_versions[@]}"; do
        if [ "$download_success" = true ]; then break; fi
        
        log_info "尝试下载内核版本: $version (架构: $target_arch)"
        
        # 根据架构定义下载路径
        local download_paths=()
        case "$target_arch" in
            "armv7"|"arm")
                download_paths=(
                    "/MetaCubeX/mihomo/releases/download/v$version/mihomo-linux-armv7-v$version.gz"
                    "/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-armv7-v$version.gz"
                    "/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-armv7.tar.gz"
                )
                ;;
            "arm64")
                download_paths=(
                    "/MetaCubeX/mihomo/releases/download/v$version/mihomo-linux-arm64-v$version.gz"
                    "/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-arm64-v$version.gz"
                )
                ;;
            "amd64")
                download_paths=(
                    "/MetaCubeX/mihomo/releases/download/v$version/mihomo-linux-amd64-v$version.gz"
                    "/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-amd64-v$version.gz"
                )
                ;;
            "mips")
                download_paths=(
                    "/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-mips-hardfloat-v$version.gz"
                    "/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-mips-v$version.gz"
                )
                ;;
        esac
        
        # 尝试下载
        for path in "${download_paths[@]}"; do
            if [ "$download_success" = true ]; then break; fi
            
            for mirror_prefix in "${mirror_prefixes[@]}"; do
                if [ "$download_success" = true ]; then break; fi
                
                local download_url="${mirror_prefix}${path}"
                local display_mirror=$(echo "$mirror_prefix" | sed 's|https://||' | cut -d'/' -f1)
                
                log_info "尝试下载: $(basename "$path") 来源: $display_mirror"
                
                # 使用 curl 下载
                if command -v curl >/dev/null 2>&1; then
                    rm -f "$temp_file" "$temp_file.gz" 2>/dev/null
                    
                    if timeout $download_timeout curl -fsSL \
                        --connect-timeout $connection_timeout \
                        --max-time $download_timeout \
                        --retry 1 --retry-delay $retry_delay \
                        --user-agent "OpenWrt-Build-Script/1.0" \
                        --location \
                        -o "$temp_file.gz" "$download_url" 2>/dev/null; then
                        
                        # 验证下载文件
                        if [ -f "$temp_file.gz" ] && [ -s "$temp_file.gz" ]; then
                            local file_size=$(stat -c%s "$temp_file.gz" 2>/dev/null || echo 0)
                            log_debug "下载文件大小: $file_size 字节"
                            
                            # 检查文件类型
                            if file "$temp_file.gz" 2>/dev/null | grep -q "gzip"; then
                                log_info "验证 gzip 文件完整性..."
                                if gunzip -t "$temp_file.gz" 2>/dev/null; then
                                    log_info "解压内核文件..."
                                    if gunzip -c "$temp_file.gz" > "$temp_file" 2>/dev/null; then
                                        if [ -s "$temp_file" ]; then
                                            local uncompressed_size=$(stat -c%s "$temp_file" 2>/dev/null || echo 0)
                                            log_debug "解压后文件大小: $uncompressed_size 字节"
                                            
                                            if file "$temp_file" 2>/dev/null | grep -q "ELF.*executable"; then
                                                if mv "$temp_file" "$final_core_path" 2>/dev/null; then
                                                    chmod +x "$final_core_path"
                                                    download_success=true
                                                    log_success "内核下载成功: v$version ($display_mirror)"
                                                    log_info "  文件路径: $final_core_path"
                                                    log_info "  文件大小: $uncompressed_size 字节"
                                                    break
                                                fi
                                            else
                                                log_warning "文件不是有效的可执行文件"
                                            fi
                                        fi
                                    fi
                                else
                                    log_warning "gzip 文件损坏"
                                fi
                            elif echo "$path" | grep -q "\.tar\.gz$"; then
                                log_info "处理 tar.gz 格式文件..."
                                local extract_dir="/tmp/clash_extract_$$"
                                mkdir -p "$extract_dir"
                                
                                if tar -xzf "$temp_file.gz" -C "$extract_dir" 2>/dev/null; then
                                    local clash_bin=$(find "$extract_dir" -name "clash*" -type f -executable 2>/dev/null | head -1)
                                    if [ -n "$clash_bin" ] && [ -f "$clash_bin" ]; then
                                        if file "$clash_bin" | grep -q "ELF.*executable"; then
                                            mv "$clash_bin" "$final_core_path"
                                            chmod +x "$final_core_path"
                                            download_success=true
                                            log_success "tar.gz 内核下载成功: $(basename "$clash_bin")"
                                        fi
                                    fi
                                fi
                                rm -rf "$extract_dir"
                            fi
                        else
                            log_warning "下载文件为空或不存在"
                        fi
                    else
                        log_debug "curl 下载失败: $download_url"
                    fi
                fi
                
                rm -f "$temp_file" "$temp_file.gz" 2>/dev/null
                [ "$download_success" = false ] && sleep 1
            done
        done
        
        [ "$download_success" = false ] && sleep 2
    done
    
    # 创建智能占位符
    if [ "$download_success" = false ]; then
        log_warning "所有下载尝试失败，创建智能占位符"
        create_smart_placeholder "$final_core_path" "$target_arch"
    fi
    
    # 创建链接
    setup_core_links "$core_dir"
    
    # 最终验证
    if [ -f "$final_core_path" ] && [ -x "$final_core_path" ]; then
        local file_size=$(stat -c%s "$final_core_path" 2>/dev/null || echo "0")
        log_info "内核文件信息:"
        log_info "  路径: $final_core_path"
        log_info "  大小: ${file_size} 字节"
        log_info "  架构: $target_arch"
        if [ "$download_success" = true ]; then
            log_success "状态: 真实内核文件下载成功"
        else
            log_info "状态: 智能占位符（支持路由器端自动下载）"
        fi
        return 0
    else
        log_error "内核文件创建失败"
        return 1
    fi
}

# 智能占位符创建函数
create_smart_placeholder() {
    local core_path="$1"
    local arch="$2"
    
    cat > "$core_path" << EOF
#!/bin/sh
# OpenClash 智能内核占位符 - 专为 CM520-79F 优化
# 架构: $arch

CORE_DIR="/etc/openclash/core"
CORE_FILE="\$CORE_DIR/clash_meta"
LOG_FILE="/tmp/openclash_core_download.log"

log_msg() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1" | tee -a "\$LOG_FILE"
}

download_core() {
    log_msg "开始自动下载 OpenClash 内核 (架构: $arch)..."
    
    local urls=(
        "https://ghproxy.com/https://github.com/vernesong/OpenClash/releases/download/Clash.Meta/clash-linux-$arch.tar.gz"
        "https://mirror.ghproxy.com/https://github.com/MetaCubeX/mihomo/releases/download/v1.18.8/mihomo-linux-$arch-v1.18.8.gz"
    )
    
    for url in "\${urls[@]}"; do
        log_msg "尝试下载: \$(basename "\$url")"
        if wget -qO- --connect-timeout=30 --read-timeout=60"\$url" > "/tmp/core_download.tmp" 2>/dev/null; then
            if [ -s "/tmp/core_download.tmp" ]; then
                if echo "\$url" | grep -q "\.gz\$"; then
                    if gunzip -c "/tmp/core_download.tmp" > "\$CORE_FILE.tmp" 2>/dev/null; then
                        if [ -s "\$CORE_FILE.tmp" ] && file "\$CORE_FILE.tmp" | grep -q "executable"; then
                            mv "\$CORE_FILE.tmp" "\$CORE_FILE"
                            chmod +x "\$CORE_FILE"
                            log_msg "内核下载成功!"
                            rm -f "/tmp/core_download.tmp"
                            return 0
                        fi
                    fi
                elif echo "\$url" | grep -q "\.tar\.gz\$"; then
                    local extract_dir="/tmp/clash_extract"
                    mkdir -p "\$extract_dir"
                    if tar -xzf "/tmp/core_download.tmp" -C "\$extract_dir" 2>/dev/null; then
                        local clash_bin=\$(find "\$extract_dir" -name "clash*" -type f -executable | head -1)
                        if [ -n "\$clash_bin" ] && [ -f "\$clash_bin" ]; then
                            if file "\$clash_bin" | grep -q "ELF.*executable"; then
                                mv "\$clash_bin" "\$CORE_FILE"
                                chmod +x "\$CORE_FILE"
                                log_msg "tar.gz 内核下载成功: \$(basename "\$clash_bin")"
                                rm -rf "\$extract_dir" "/tmp/core_download.tmp"
                                return 0
                            fi
                        fi
                    fi
                fi
            fi
        fi
    done
    log_msg "所有下载尝试失败!"
    return 1
}

download_core
EOF
    chmod +x "$core_path"
    log_success "智能占位符创建完成: $core_path"
}

# 创建内核链接
setup_core_links() {
    local core_dir="$1"
    local file_path_base="$core_dir/clash_meta"
    local link_name_base="$core_dir/clash"
    log_info "创建内核文件软链接..."
    if [ -f "$file_path_base" ]; then
        if [ ! -f "$link_name_base" ] || [ ! -L "$link_name_base" ]; then
            ln -s "$file_path_base" "$link_name_base"
            log_success "clash -> clash_meta 软链接创建成功"
        fi
        log_success "内核文件和链接准备就绪"
    else
        log_warning "clash_meta 文件不存在，无法创建软链接"
    fi
}

# 导入 Passwall2 密钥
import_passwall_keys() {
    log_step "导入 Passwall2 软件源密钥"
    local key_dir="package/base-files/files/etc/opkg/keys"
    safe_mkdir "$key_dir"
    # 使用 ghproxy.com 镜像作为首选，以提高成功率
    local key_urls=("https://ghproxy.com/https://downloads.openwrt.org/snapshots/keys/6243c1c880731018a6251b66789c7785659653d0" "https://ghproxy.com/https://github.com/xiaorouji/openwrt-passwall2/raw/main/keys/9a22e228.pub")
    local success=false
    for url in "${key_urls[@]}"; do
        local key_file="$key_dir/$(basename "$url" | cut -d'?' -f1)"
        log_info "尝试下载密钥: $(basename "$url" | cut -d'?' -f1)"
        if wget --no-check-certificate -O "$key_file" --timeout=30 --tries=2 "$url" 2>/dev/null; then
            chmod 644 "$key_file" 2>/dev/null || true
            log_success "密钥导入成功: $(basename "$url" | cut -d'?' -f1)"
            success=true
            break # 成功后立即退出循环
        else
            log_warning "密钥下载失败: $url"
        fi
    done
    if [ "$success" = false ]; then
        log_warning "所有密钥下载尝试失败，但这通常不影响编译。"
    fi
    log_success "Passwall2 密钥导入完成"
}

# 集成自定义插件
add_custom_plugins() {
    log_step "集成自定义插件"
    safe_mkdir "$CUSTOM_PLUGINS_DIR"
    local plugins=(
        "https://github.com/immortalwrt/luci-app-partexp.git"
        "https://github.com/xiaorouji/openwrt-passwall2.git"
        "https://github.com/vernesong/OpenClash.git"
    )
    for repo in "${plugins[@]}"; do
        local repo_name=$(basename "$repo" .git)
        local plugin_path="$CUSTOM_PLUGINS_DIR/$repo_name"
        log_info "正在处理插件: $repo_name"
        if [ -d "$plugin_path" ]; then
            log_warning "插件目录已存在，跳过克隆: $repo_name"
        else
            if try_git_mirrors "$repo" "$plugin_path"; then
                plugin_count=$((plugin_count + 1))
            else
                validation_passed=false
            fi
        fi
    done
    if [ "$validation_passed" = true ]; then log_success "所有插件集成完成（共 $plugin_count 个）"; else log_warning "部分插件集成失败，请检查日志"; fi
}

# 检查并添加依赖
check_all_dependencies() {
    log_step "检查并添加所有插件依赖"
    add_deps_by_layer "target"
    add_deps_by_layer "kernel"
    add_deps_by_layer "drivers"
    add_deps_by_layer "network"
    add_deps_by_layer "openclash"
    add_deps_by_layer "passwall2"
    add_deps_by_layer "partexp"
    log_success "所有依赖检查并添加完成"
}

# 生成最终配置文件
generate_config_file() {
    log_step "生成最终 .config 文件"
    cat "$CONFIG_CUSTOM" >> "$CONFIG_FILE" 2>/dev/null || true
    rm -f "$CONFIG_CUSTOM" 2>/dev/null
    log_success "配置已合并，请运行 'make menuconfig' 和 'make -j$(nproc)' 开始编译"
}

# -------------------- 主函数 --------------------
main() {
    check_environment
    check_dependencies
    detect_openwrt_version
    init_config_cache
    
    setup_device_tree
    
    import_passwall_keys
    add_custom_plugins
    check_all_dependencies
    
    download_clash_core_improved
    
    generate_config_file
    
    log_success "脚本执行完毕！"
}

main "$@"
