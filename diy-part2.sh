#!/bin/bash
# OpenWrt 插件集成脚本 - 云编译环境适配版 (V6.1)
# 修复：版本检测失败导致的脚本退出问题

set -eo pipefail
export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '

# -------------------- 日志函数 --------------------
# （保持不变）
log_step() { echo -e "\n[$(date +'%H:%M:%S')] \033[1;36m📝 步骤：$*\033[0m"; }
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m" >&2; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m" >&2; }
log_debug() { [[ "$DEBUG_MODE" == "true" ]] && echo -e "[$(date +'%H:%M:%S')] \033[90m🐛 $*\033[0m"; }

# -------------------- 全局配置 --------------------
# （保持不变）
validation_passed=true
plugin_count=0
CONFIG_FILE=".config"
CUSTOM_PLUGINS_DIR="package/custom"
DEBUG_MODE=${DEBUG_MODE:-"false"}
CLOUD_MODE=${CLOUD_MODE:-"true"}

LAN_IFACE=${LAN_IFACE:-""}
WAN_IFACE=${WAN_IFACE:-""}
IS_DSA=false  # DSA架构标记

declare -A config_cache=()
declare -A DEPS=()  # 分层依赖管理（值为空格分隔的字符串）
GIT_CONNECT_TIMEOUT=30
GIT_CLONE_TIMEOUT=1800
MAX_RETRIES=3
OPENWRT_VERSION="unknown"

trap 'rm -rf /tmp/*_$$ 2>/dev/null || true' EXIT

# -------------------- 设备配置路径 --------------------
# （保持不变）
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
NETWORK_CFG_DIR="target/linux/ipq40xx/base-files/etc/board.d"
NETWORK_CFG="$NETWORK_CFG_DIR/02_network"

# -------------------- 分层依赖定义 --------------------
# （保持不变）
DEPS["kernel"]="CONFIG_KERNEL_IP_TRANSPARENT_PROXY=y CONFIG_KERNEL_NETFILTER=y CONFIG_KERNEL_NF_CONNTRACK=y CONFIG_KERNEL_NF_NAT=y CONFIG_KERNEL_NF_TPROXY=y CONFIG_KERNEL_IP6_NF_IPTABLES=y"
DEPS["drivers"]="CONFIG_PACKAGE_kmod-qca-nss-dp=y CONFIG_PACKAGE_kmod-qca-ssdk=y CONFIG_PACKAGE_kmod-mii=y CONFIG_PACKAGE_kmod-phy-qcom-ipq4019=y CONFIG_PACKAGE_kmod-of-mdio=y CONFIG_PACKAGE_kmod-mdio-gpio=y CONFIG_PACKAGE_kmod-fixed-phy=y CONFIG_PACKAGE_kmod-ath10k-ct=y CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y CONFIG_PACKAGE_kmod-ubi=y CONFIG_PACKAGE_kmod-ubifs=y"
DEPS["network"]="CONFIG_PACKAGE_bash=y CONFIG_PACKAGE_wget=y CONFIG_PACKAGE_tcpdump=y CONFIG_PACKAGE_traceroute=y CONFIG_PACKAGE_ss=y CONFIG_PACKAGE_ping=y CONFIG_PACKAGE_dnsmasq-full=y CONFIG_PACKAGE_firewall=y CONFIG_PACKAGE_udhcpc=y CONFIG_BUSYBOX_CONFIG_UDHCPC=y"
DEPS["openclash"]="CONFIG_PACKAGE_luci-app-openclash=y CONFIG_PACKAGE_luci-app-openclash_DNS_HIJACK=y CONFIG_PACKAGE_kmod-tun=y CONFIG_PACKAGE_coreutils-nohup=y CONFIG_PACKAGE_curl=y CONFIG_PACKAGE_jsonfilter=y CONFIG_PACKAGE_ca-certificates=y CONFIG_PACKAGE_ipset=y CONFIG_PACKAGE_ip-full=y CONFIG_PACKAGE_ruby=y CONFIG_PACKAGE_ruby-yaml=y CONFIG_PACKAGE_unzip=y CONFIG_PACKAGE_luci-compat=y CONFIG_PACKAGE_luci-base=y CONFIG_PACKAGE_kmod-inet-diag=y CONFIG_PACKAGE_luci-i18n-openclash-zh-cn=y"
DEPS["passwall2"]="CONFIG_PACKAGE_luci-app-passwall2=y CONFIG_PACKAGE_xray-core=y CONFIG_PACKAGE_sing-box=y CONFIG_PACKAGE_chinadns-ng=y CONFIG_PACKAGE_haproxy=y CONFIG_PACKAGE_hysteria=y CONFIG_PACKAGE_v2ray-geoip=y CONFIG_PACKAGE_v2ray-geosite=y CONFIG_PACKAGE_unzip=y CONFIG_PACKAGE_coreutils=y CONFIG_PACKAGE_coreutils-base64=y CONFIG_PACKAGE_coreutils-nohup=y CONFIG_PACKAGE_curl=y CONFIG_PACKAGE_ipset=y CONFIG_PACKAGE_ip-full=y CONFIG_PACKAGE_luci-compat=y CONFIG_PACKAGE_luci-lib-jsonc=y CONFIG_PACKAGE_tcping=y CONFIG_PACKAGE_luci-i18n-passwall2-zh-cn=y"
DEPS["target"]="CONFIG_TARGET_ipq40xx=y CONFIG_TARGET_ipq40xx_generic=y CONFIG_TARGET_DEVICE_ipq40xx_generic_DEVICE_mobipromo_cm520-79f=y"

# -------------------- 版本检测与DSA判断（关键修复） --------------------
detect_openwrt_version() {
    log_step "检测OpenWrt版本与架构"  # 增加日志，确认函数执行
    local version_file="include/version.mk"
    local major_ver minor_ver

    # 检查版本文件是否存在
    if [ ! -f "$version_file" ]; then
        log_warning "未找到版本文件: $version_file（可能路径错误）"
        log_info "强制使用DSA兼容模式"
        IS_DSA=true
        return  # 不退出，继续执行
    fi

    # 读取版本号（关键修复：允许grep失败，避免管道导致脚本退出）
    OPENWRT_VERSION=$(grep '^OPENWRT_VERSION=' "$version_file" | cut -d= -f2 | tr -d ' "' || true)
    
    # 处理版本号为空的情况
    if [ -z "$OPENWRT_VERSION" ]; then
        log_warning "无法从 $version_file 中提取版本号"
        log_info "默认使用DSA架构兼容模式"
        IS_DSA=true
        return
    fi

    # 正常版本处理
    log_info "检测到 OpenWrt 版本: $OPENWRT_VERSION"
    
    # 判断DSA架构
    if [[ "$OPENWRT_VERSION" =~ ^22\.03 || "$OPENWRT_VERSION" =~ ^23\.05 || "$OPENWRT_VERSION" =~ ^24\.10 || "$OPENWRT_VERSION" == "snapshot" ]]; then
        IS_DSA=true
        log_info "检测到 DSA 架构（22.03+）"
    else
        IS_DSA=false
        log_info "使用传统网络架构"
    fi

    # 版本适配（保持不变）
    if [[ "$OPENWRT_VERSION" =~ ^24\.10 || "$OPENWRT_VERSION" == "snapshot" ]]; then
        log_info "版本 24.10+ 启用 nft-tproxy 支持"
        DEPS["network"]+=" CONFIG_PACKAGE_kmod-nft-nat=y CONFIG_PACKAGE_kmod-nft-tproxy=y"
        DEPS["openclash"]+=" CONFIG_PACKAGE_kmod-nft-tproxy=y"
    else
        log_info "旧版本启用 iptables 兼容模式"
        DEPS["network"]+=" CONFIG_PACKAGE_iptables-mod-nat-extra=y CONFIG_PACKAGE_kmod-ipt-offload=y"
        DEPS["passwall2"]+=" CONFIG_PACKAGE_iptables=y CONFIG_PACKAGE_iptables-mod-tproxy=y CONFIG_PACKAGE_iptables-mod-socket=y CONFIG_PACKAGE_kmod-ipt-nat=y"
    fi
}

# -------------------- 其他函数（保持不变） --------------------
check_dependencies() {
    # （原逻辑不变）
    local tools=("git" "sed" "grep" "timeout" "flock" "find" "mv" "rm" "cp" "chmod" 
                 "mkdir" "touch" "wc" "awk" "unzip" "xsltproc" "gettext" "dtc" "make" "gcc")
    local missing=()
    
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺失必需工具：${missing[*]}"
        log_error "安装命令：apt update && apt install -y ${missing[*]}"
    fi
    log_success "依赖工具检查通过"

    if [ "$CLOUD_MODE" = "true" ] && [ -n "$HTTP_PROXY" ]; then
        log_info "配置git代理: $HTTP_PROXY"
        git config --global http.proxy "$HTTP_PROXY"
        git config --global https.proxy "$HTTP_PROXY"
    fi
}

init_config_cache() {
    # （原逻辑不变）
    if [ -f "$CONFIG_FILE" ]; then
        log_debug "加载配置缓存（行数: $(wc -l < "$CONFIG_FILE")）"
        while IFS= read -r line; do
            [[ "$line" =~ ^# || -z "$line" ]] && continue
            config_cache["$line"]=1
        done < "$CONFIG_FILE"
    fi
}

safe_mkdir() {
    # （原逻辑不变）
    local dir="$1"
    [ -d "$dir" ] && return 0
    if ! mkdir -p "$dir"; then
        log_error "无法创建目录: $dir（权限问题）"
    fi
    log_debug "创建目录: $dir"
}

safe_write_file() {
    # （原逻辑不变）
    local file="$1"
    local content="$2"
    safe_mkdir "$(dirname "$file")"
    if ! echo "$content" > "$file"; then
        log_error "无法写入文件: $file"
    fi
    log_debug "写入文件: $file"
}

setup_device_tree() {
    # （原逻辑不变）
    log_step "配置CM520-79F设备树与网络"
    
    if [ -f "$DTS_FILE" ]; then
        cp "$DTS_FILE" "${DTS_FILE}.bak" || log_error "DTS备份失败"
        log_info "已备份原DTS至 ${DTS_FILE}.bak"
    fi

    safe_mkdir "$DTS_DIR"
    local dts_content=$(cat <<'EOF'
/dts-v1/;
// SPDX-License-Identifier: GPL-2.0-or-later OR MIT

#include "qcom-ipq4019.dtsi"
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/input/input.h>
#include <dt-bindings/soc/qcom,tcsr.h>

/ {
	model = "MobiPromo CM520-79F";
	compatible = "mobipromo,cm520-79f";

	aliases {
		led-boot = &led_sys;
		led-failsafe = &led_sys;
		led-running = &led_sys;
		led-upgrade = &led_sys;
	};

	chosen {
		bootargs-append = " ubi.block=0,1 root=/dev/ubiblock0_1";
	};

	soc {
		rng@22000 { status = "okay"; };
		mdio@90000 {
			status = "okay";
			pinctrl-0 = <&mdio_pins>;
			pinctrl-names = "default";
			reset-gpios = <&tlmm 47 GPIO_ACTIVE_LOW>;
			reset-delay-us = <1000>;
		};
		ess-psgmii@98000 { status = "okay"; };
		tcsr@1949000 {
			compatible = "qcom,tcsr";
			reg = <0x1949000 0x100>;
			qcom,wifi_glb_cfg = <TCSR_WIFI_GLB_CFG>;
		};
		tcsr@194b000 {
			compatible = "qcom,tcsr";
			reg = <0x194b000 0x100>;
			qcom,usb-hsphy-mode-select = <TCSR_USB_HSPHY_HOST_MODE>;
		};
		ess_tcsr@1953000 {
			compatible = "qcom,tcsr";
			reg = <0x1953000 0x1000>;
			qcom,ess-interface-select = <TCSR_ESS_PSGMII>;
		};
		tcsr@1957000 {
			compatible = "qcom,tcsr";
			reg = <0x1957000 0x100>;
			qcom,wifi_noc_memtype_m0_m2 = <TCSR_WIFI_NOC_MEMTYPE_M0_M2>;
		};
		usb2@60f8800 {
			status = "okay";
			dwc3@6000000 {
				#address-cells = <1>;
				#size-cells = <0>;
				usb2_port1: port@1 {
					reg = <1>;
					#trigger-source-cells = <0>;
				};
			};
		};
		usb3@8af8800 {
			status = "okay";
			dwc3@8a00000 {
				#address-cells = <1>;
				#size-cells = <0>;
				usb3_port1: port@1 { reg = <1>; #trigger-source-cells = <0>; };
				usb3_port2: port@2 { reg = <2>; #trigger-source-cells = <0>; };
			};
		};
		crypto@8e3a000 { status = "okay"; };
		watchdog@b017000 { status = "okay"; };
		ess-switch@c000000 { status = "okay"; };
		edma@c080000 { status = "okay"; };
	};

	led_spi {
		compatible = "spi-gpio";
		#address-cells = <1>;
		#size-cells = <0>;
		sck-gpios = <&tlmm 40 GPIO_ACTIVE_HIGH>;
		mosi-gpios = <&tlmm 36 GPIO_ACTIVE_HIGH>;
		num-chipselects = <0>;
		led_gpio: led_gpio@0 {
			compatible = "fairchild,74hc595";
			reg = <0>;
			gpio-controller;
			#gpio-cells = <2>;
			registers-number = <1>;
			spi-max-frequency = <1000000>;
		};
	};

	leds {
		compatible = "gpio-leds";
		usb {
			label = "blue:usb";
			gpios = <&tlmm 10 GPIO_ACTIVE_HIGH>;
			linux,default-trigger = "usbport";
			trigger-sources = <&usb3_port1>, <&usb3_port2>, <&usb2_port1>;
		};
		led_sys: can { label = "blue:can"; gpios = <&tlmm 11 GPIO_ACTIVE_HIGH>; };
		wan { label = "blue:wan"; gpios = <&led_gpio 0 GPIO_ACTIVE_LOW>; };
		lan1 { label = "blue:lan1"; gpios = <&led_gpio 1 GPIO_ACTIVE_LOW>; };
		lan2 { label = "blue:lan2"; gpios = <&led_gpio 2 GPIO_ACTIVE_LOW>; };
		wlan2g {
			label = "blue:wlan2g";
			gpios = <&led_gpio 5 GPIO_ACTIVE_LOW>;
			linux,default-trigger = "phy0tpt";
		};
		wlan5g {
			label = "blue:wlan5g";
			gpios = <&led_gpio 6 GPIO_ACTIVE_LOW>;
			linux,default-trigger = "phy1tpt";
		};
	};

	keys {
		compatible = "gpio-keys";
		reset {
			label = "reset";
			gpios = <&tlmm 18 GPIO_ACTIVE_LOW>;
			linux,code = <KEY_RESTART>;
		};
	};
};

&blsp_dma { status = "okay"; };
&blsp1_uart1 { status = "okay"; };
&blsp1_uart2 { status = "okay"; };
&cryptobam { status = "okay"; };

&gmac0 {
	status = "okay";
	nvmem-cells = <&macaddr_art_1006>;
	nvmem-cell-names = "mac-address";
};

&gmac1 {
	status = "okay";
	nvmem-cells = <&macaddr_art_5006>;
	nvmem-cell-names = "mac-address";
};

&nand {
	pinctrl-0 = <&nand_pins>;
	pinctrl-names = "default";
	status = "okay";
	nand@0 {
		partitions {
			compatible = "fixed-partitions";
			#address-cells = <1>;
			#size-cells = <1>;
			partition@0 { label = "Bootloader"; reg = <0x0 0xb00000>; read-only; };
			art: partition@b00000 {
				label = "ART";
				reg = <0xb00000 0x80000>;
				read-only;
				compatible = "nvmem-cells";
				#address-cells = <1>;
				#size-cells = <1>;
				precal_art_1000: precal@1000 { reg = <0x1000 0x2f20>; };
				macaddr_art_1006: macaddr@1006 { reg = <0x1006 0x6>; };
				precal_art_5000: precal@5000 { reg = <0x5000 0x2f20>; };
				macaddr_art_5006: macaddr@5006 { reg = <0x5006 0x6>; };
			};
			partition@b80000 { label = "rootfs"; reg = <0xb80000 0x7480000>; };
		};
	};
};

&qpic_bam { status = "okay"; };

&tlmm {
	mdio_pins: mdio_pinmux {
		mux_1 { pins = "gpio6"; function = "mdio"; bias-pull-up; };
		mux_2 { pins = "gpio7"; function = "mdc"; bias-pull-up; };
	};
	nand_pins: nand_pins {
		pullups { pins = "gpio52", "gpio53", "gpio58", "gpio59"; function = "qpic"; bias-pull-up; };
		pulldowns { pins = "gpio54", "gpio55", "gpio56", "gpio57", "gpio60", "gpio61", "gpio62", "gpio63", "gpio64", "gpio65", "gpio66", "gpio67", "gpio68", "gpio69"; function = "qpic"; bias-pull-down; };
	};
};

&usb3_ss_phy { status = "okay"; };
&usb3_hs_phy { status = "okay"; };
&usb2_hs_phy { status = "okay"; };
&wifi0 { status = "okay"; nvmem-cell-names = "pre-calibration"; nvmem-cells = <&precal_art_1000>; qcom,ath10k-calibration-variant = "CM520-79F"; };
&wifi1 { status = "okay"; nvmem-cell-names = "pre-calibration"; nvmem-cells = <&precal_art_5000>; qcom,ath10k-calibration-variant = "CM520-79F"; };
EOF
    )
    safe_write_file "$DTS_FILE" "$dts_content"
    log_success "DTS文件配置完成"

    safe_mkdir "$NETWORK_CFG_DIR"
    local network_content
    if $IS_DSA; then
        log_info "配置DSA网络（交换机模式）"
        [ -z "$LAN_IFACE" ] && LAN_IFACE="lan1 lan2"
        [ -z "$WAN_IFACE" ] && WAN_IFACE="wan"
        
        network_content=$(cat <<EOF
#!/bin/sh
. /lib/functions/system.sh
ipq40xx_board_detect() {
	local machine
	machine=\$(board_name)
	case "\$machine" in
	"mobipromo,cm520-79f")
		ucidef_set_interface_loopback
		ucidef_add_switch "switch0" \\
			"0u@eth0" "1:lan" "2:lan" "3:wan"
		ucidef_set_interfaces_lan_wan "$LAN_IFACE" "$WAN_IFACE"
		;;
	esac
}
boot_hook_add preinit_main ipq40xx_board_detect
EOF
        )
    else
        log_info "配置传统网络（eth接口模式）"
        [ -z "$LAN_IFACE" ] && LAN_IFACE="eth1"
        [ -z "$WAN_IFACE" ] && WAN_IFACE="eth0"
        
        network_content=$(cat <<EOF
#!/bin/sh
. /lib/functions/system.sh
ipq40xx_board_detect() {
	local machine
	machine=\$(board_name)
	case "\$machine" in
	"mobipromo,cm520-79f")
		ucidef_set_interfaces_lan_wan "$LAN_IFACE" "$WAN_IFACE"
		;;
	esac
}
boot_hook_add preinit_main ipq40xx_board_detect
EOF
        )
    fi
    safe_write_file "$NETWORK_CFG" "$network_content"
    chmod +x "$NETWORK_CFG"
    log_info "网络接口配置完成（LAN: $LAN_IFACE, WAN: $WAN_IFACE）"

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
        )
        echo "$device_rule" >> "$GENERIC_MK"
        log_success "设备编译规则添加完成"
    else
        sed -i 's/IMAGE_SIZE := 32768k/IMAGE_SIZE := 81920k/' "$GENERIC_MK"
        log_info "设备编译规则已存在，更新IMAGE_SIZE"
    fi
}

add_config_if_missing() {
    # （原逻辑不变）
    local config="$1"
    local description="$2"
    
    [ -z "$config" ] && log_error "配置项不能为空"
    
    if [ -f "$CONFIG_FILE" ]; then
        sed -i.bak "/^# $config is not set/d" "$CONFIG_FILE"
        sed -i.bak "/^$config=.*$/d" "$CONFIG_FILE"
        rm -f "$CONFIG_FILE.bak"
    fi
    
    if [ -n "${config_cache[$config]}" ]; then
        log_debug "配置已存在: $config"
        return 0
    fi
    
    if ! echo "$config" >> "$CONFIG_FILE"; then
        log_error "无法写入配置: $config"
    fi
    config_cache["$config"]=1
    log_info "添加配置: $config"
    [ -n "$description" ] && log_debug "说明: $description"
}

add_deps_by_layer() {
    # （原逻辑不变）
    local layer="$1"
    local deps_str="${DEPS[$layer]}"
    local -a deps=()

    read -ra deps <<< "$deps_str"
    
    [ ${#deps[@]} -eq 0 ] && return 0
    
    log_step "添加[$layer]层依赖（共${#deps[@]}项）"
    for config in "${deps[@]}"; do
        add_config_if_missing "$config" "$layer层依赖"
    done
}

try_git_mirrors() {
    # （原逻辑不变）
    local original_repo="$1"
    local temp_dir="$2"
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
                log_info "开始克隆（超时${GIT_CLONE_TIMEOUT}s）"
                if timeout "$GIT_CLONE_TIMEOUT" git clone --depth 1 --single-branch \
                    "$mirror" "$temp_dir" 2>&1; then
                    if [ -d "$temp_dir" ] && [ "$(ls -A "$temp_dir" 2>/dev/null)" != "" ]; then
                        log_success "克隆成功（镜像: $mirror）"
                        return 0
                    fi
                fi
            fi
            [ $retry -lt $((MAX_RETRIES - 1)) ] && sleep 5
        done
        [ -d "$temp_dir" ] && rm -rf "$temp_dir"
    done
    
    log_error "所有镜像克隆失败: $original_repo"
    return 1
}

download_clash_core() {
    # （原逻辑不变）
    local core_dir="/etc/openclash/core"
    local temp_core="/tmp/clash_meta_$$"
    local arch="armv7"
    
    log_step "下载OpenClash内核（clash_meta）"
    safe_mkdir "$core_dir"
    
    local core_url="https://github.com/MetaCubeX/Clash.Meta/releases/latest/download/clash-meta-linux-armv7"
    
    if ! wget --no-check-certificate -O "$temp_core" "$core_url"; then
        log_warning "主地址下载失败，尝试镜像"
        core_url="https://ghproxy.com/$core_url"
        if ! wget --no-check-certificate -O "$temp_core" "$core_url"; then
            log_error "Clash内核下载失败"
            return 1
        fi
    fi
    
    mv "$temp_core" "$core_dir/clash_meta"
    chmod +x "$core_dir/clash_meta"
    log_success "Clash内核安装完成: $core_dir/clash_meta"
    return 0
}

import_passwall_keys() {
    # （原逻辑不变）
    log_step "导入Passwall2软件源密钥"
    local key_dir="/etc/opkg/keys"
    safe_mkdir "$key_dir"
    
    local key_urls=(
        "https://openwrt.org/_export/keys/6243C1C880731018A6251B66789C7785659653D"
        "https://github.com/xiaorouji/openwrt-passwall2/raw/main/keys/9a22e228.pub"
    )
    
    for url in "${key_urls[@]}"; do
        local key_file="$key_dir/$(basename "$url")"
        if ! wget --no-check-certificate -O "$key_file" "$url"; then
            log_warning "密钥下载失败: $url，尝试镜像"
            if ! wget --no-check-certificate -O "$key_file" "https://ghproxy.com/$url"; then
                log_error "密钥导入失败"
                return 1
            fi
        fi
        chmod 644 "$key_file"
    done
    log_success "Passwall2密钥导入完成"
    return 0
}

fetch_plugin() {
    # （原逻辑不变）
    local repo="$1"
    local plugin_name="$2"
    local subdir="${3:-.}"
    shift 3
    local deps_layer="$1"
    local temp_dir="/tmp/${plugin_name}_$(date +%s)_$$"
    local lock_file="/tmp/.${plugin_name}_lock"
    
    log_step "集成插件: $plugin_name"
    log_info "仓库: $repo"
    log_info "目标路径: $CUSTOM_PLUGINS_DIR/$plugin_name"

    exec 200>"$lock_file"
    if ! flock -n 200; then
        log_warning "等待插件锁释放..."
        flock 200
    fi

    local cleanup_paths=(
        "feeds/luci/applications/$plugin_name"
        "feeds/packages/net/$plugin_name"
        "package/$plugin_name"
        "$CUSTOM_PLUGINS_DIR/$plugin_name"
        "$temp_dir"
    )
    for path in "${cleanup_paths[@]}"; do
        if [ -d "$path" ]; then
            log_info "清理旧文件: $path"
            rm -rf "$path"
        fi
    done

    if ! try_git_mirrors "$repo" "$temp_dir"; then
        flock -u 200
        return 1
    fi

    local source_path="$temp_dir/$subdir"
    if [ ! -f "$source_path/Makefile" ]; then
        log_info "在子目录搜索Makefile..."
        local found_makefile=$(find "$source_path" -maxdepth 3 -name Makefile -print -quit)
        if [ -n "$found_makefile" ]; then
            source_path=$(dirname "$found_makefile")
            log_info "找到Makefile: $source_path"
        else
            log_error "未找到Makefile"
            rm -rf "$temp_dir"
            flock -u 200
            return 1
        fi
    fi

    safe_mkdir "$CUSTOM_PLUGINS_DIR"
    if ! mv "$source_path" "$CUSTOM_PLUGINS_DIR/$plugin_name"; then
        log_error "移动插件失败"
        rm -rf "$temp_dir"
        flock -u 200
        return 1
    fi

    rm -rf "$temp_dir"
    flock -u 200

    if [ -n "$deps_layer" ] && [ -n "${DEPS[$deps_layer]}" ]; then
        log_info "添加插件依赖层: $deps_layer"
        add_deps_by_layer "$deps_layer"
    fi

    log_success "$plugin_name 集成完成"
    return 0
}

verify_filesystem() {
    # （原逻辑不变）
    local plugin=$1
    log_step "验证 $plugin 文件系统"
    
    if [ -d "$CUSTOM_PLUGINS_DIR/$plugin" ] && [ -f "$CUSTOM_PLUGINS_DIR/$plugin/Makefile" ]; then
        log_success "$plugin 目录结构验证通过"
        plugin_count=$((plugin_count + 1))
        return 0
    else
        log_error "$plugin 验证失败（目录或Makefile缺失）"
        validation_passed=false
        return 1
    fi
}

verify_config_conflicts() {
    # （原逻辑不变）
    log_step "检查配置冲突"
    local conflicts=(
        "CONFIG_PACKAGE_dnsmasq CONFIG_PACKAGE_dnsmasq-full"
        "CONFIG_PACKAGE_iptables-legacy CONFIG_PACKAGE_iptables-nft"
        "CONFIG_PACKAGE_kmod-ipt-tproxy CONFIG_PACKAGE_kmod-nft-tproxy"
    )
    
    for pair in "${conflicts[@]}"; do
        local a=$(echo "$pair" | awk '{print $1}')
        local b=$(echo "$pair" | awk '{print $2}')
        if [ -n "${config_cache[$a=y]}" ] && [ -n "${config_cache[$b=y]}" ]; then
            log_error "配置冲突: $a 和 $b 不能同时启用"
            if [[ "$a" == *"iptables"* && "$b" == *"nft"* && $IS_DSA ]]; then
                log_info "自动修复：移除 $a，保留 $b（DSA模式）"
                sed -i "/^$a=y/d" "$CONFIG_FILE"
                unset config_cache["$a=y"]
            else
                validation_passed=false
            fi
        fi
    done
}

# -------------------- 主流程 --------------------
main() {
    log_step "OpenWrt插件集成流程启动（V6.1）"
    
    if [ "$EUID" -ne 0 ]; then
        log_warning "建议以root用户运行（当前: $USER）"
    fi

    # 初始化检查（按顺序执行，增加日志定位）
    log_info "开始依赖工具检查"
    check_dependencies
    
    log_info "开始版本与架构检测"  # 新增日志，确认执行到此处
    detect_openwrt_version
    
    log_info "开始配置缓存初始化"
    init_config_cache
    
    log_info "创建自定义插件目录"
    safe_mkdir "$CUSTOM_PLUGINS_DIR"

    if [ "$DEBUG_MODE" = "true" ]; then
        log_info "启用调试模式"
        set -x
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "配置文件不存在，创建空文件"
        touch "$CONFIG_FILE"
    elif [ ! -w "$CONFIG_FILE" ]; then
        log_error "配置文件不可写: $CONFIG_FILE"
    fi

    setup_device_tree

    log_step "更新软件源"
    ./scripts/feeds update -a || log_error "feeds更新失败"
    ./scripts/feeds install -a || log_error "feeds安装失败"

    add_deps_by_layer "kernel"
    add_deps_by_layer "drivers"
    add_deps_by_layer "network"
    add_deps_by_layer "target"

    log_step "集成插件"
    local plugins=(
        "https://github.com/vernesong/OpenClash.git|luci-app-openclash|luci-app-openclash|openclash"
        "https://github.com/xiaorouji/openwrt-passwall2.git|luci-app-passwall2|.|passwall2"
    )

    for plugin in "${plugins[@]}"; do
        IFS='|' read -r repo name subdir deps_layer <<< "$plugin"
        if ! fetch_plugin "$repo" "$name" "$subdir" "$deps_layer"; then
            log_error "$name 集成失败，中断流程"
            exit 1
        fi
    done

    log_step "插件后处理"
    download_clash_core
    import_passwall_keys

    verify_filesystem "luci-app-openclash"
    verify_filesystem "luci-app-passwall2"
    verify_config_conflicts

    log_step "生成最终配置"
    make defconfig || log_error "配置生成失败"

    log_info "配置变更摘要:"
    grep -E '^CONFIG_PACKAGE_(luci-app-openclash|luci-app-passwall2|kmod-nft-tproxy|iptables)' "$CONFIG_FILE" || true

    log_step "集成流程完成"
    if $validation_passed && [ $plugin_count -eq 2 ]; then
        log_success "🎉 所有插件集成成功（数量: $plugin_count）"
        log_info "建议操作:"
        log_info "1. 如需调整配置：make menuconfig"
        log_info "2. 开始编译：make -j$(nproc) V=s"
        exit 0
    elif [ $plugin_count -gt 0 ]; then
        log_warning "⚠️ 部分插件集成成功（数量: $plugin_count）"
        exit 0
    else
        log_error "❌ 所有插件集成失败"
        exit 1
    fi
}

main "$@"
