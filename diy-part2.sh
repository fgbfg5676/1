#!/bin/bash
# OpenWrt 插件集成脚本 - 云编译环境适配版 (V6)
# 核心特性：DSA网络架构适配、依赖冲突自动修复、版本智能识别
# 支持插件：OpenClash 0.47+（自动下载内核）、Passwall2（含依赖组件）
# 兼容版本：OpenWrt 22.03+（DSA）、24.10+（nft优先）

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
validation_passed=true
plugin_count=0
CONFIG_FILE=".config"
CUSTOM_PLUGINS_DIR="package/custom"
DEBUG_MODE=${DEBUG_MODE:-"false"}
CLOUD_MODE=${CLOUD_MODE:-"true"}

# 网络接口配置（DSA模式自动适配）
LAN_IFACE=${LAN_IFACE:-""}
WAN_IFACE=${WAN_IFACE:-""}
IS_DSA=false  # DSA架构标记

# 云编译参数
declare -A config_cache=()
declare -A DEPS=()  # 分层依赖管理
GIT_CONNECT_TIMEOUT=30
GIT_CLONE_TIMEOUT=1800  # 延长克隆超时
MAX_RETRIES=3  # 增加重试次数
OPENWRT_VERSION="unknown"

# 临时文件清理
trap 'rm -rf /tmp/*_$$ 2>/dev/null || true' EXIT

# -------------------- 设备配置路径 --------------------
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
NETWORK_CFG_DIR="target/linux/ipq40xx/base-files/etc/board.d"
NETWORK_CFG="$NETWORK_CFG_DIR/02_network"

# -------------------- 分层依赖定义（增强版） --------------------
# 1. 内核基础依赖
DEPS["kernel"]=(
    "CONFIG_KERNEL_IP_TRANSPARENT_PROXY=y"
    "CONFIG_KERNEL_NETFILTER=y"
    "CONFIG_KERNEL_NF_CONNTRACK=y"
    "CONFIG_KERNEL_NF_NAT=y"
    "CONFIG_KERNEL_NF_TPROXY=y"
    "CONFIG_KERNEL_IP6_NF_IPTABLES=y"
)

# 2. 硬件驱动依赖
DEPS["drivers"]=(
    "CONFIG_PACKAGE_kmod-qca-nss-dp=y"
    "CONFIG_PACKAGE_kmod-qca-ssdk=y"
    "CONFIG_PACKAGE_kmod-mii=y"
    "CONFIG_PACKAGE_kmod-phy-qcom-ipq4019=y"
    "CONFIG_PACKAGE_kmod-of-mdio=y"
    "CONFIG_PACKAGE_kmod-mdio-gpio=y"
    "CONFIG_PACKAGE_kmod-fixed-phy=y"
    "CONFIG_PACKAGE_kmod-ath10k-ct=y"
    "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y"
    "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y"
    "CONFIG_PACKAGE_kmod-ubi=y"
    "CONFIG_PACKAGE_kmod-ubifs=y"
)

# 3. 网络核心依赖
DEPS["network"]=(
    "CONFIG_PACKAGE_bash=y"
    "CONFIG_PACKAGE_wget=y"
    "CONFIG_PACKAGE_tcpdump=y"
    "CONFIG_PACKAGE_traceroute=y"
    "CONFIG_PACKAGE_ss=y"
    "CONFIG_PACKAGE_ping=y"
    "CONFIG_PACKAGE_dnsmasq-full=y"
    "CONFIG_PACKAGE_firewall=y"
    "CONFIG_PACKAGE_udhcpc=y"
    "CONFIG_BUSYBOX_CONFIG_UDHCPC=y"
)

# 4. OpenClash 依赖（含中文支持）
DEPS["openclash"]=(
    "CONFIG_PACKAGE_luci-app-openclash=y"
    "CONFIG_PACKAGE_luci-app-openclash_DNS_HIJACK=y"
    "CONFIG_PACKAGE_kmod-tun=y"
    "CONFIG_PACKAGE_coreutils-nohup=y"
    "CONFIG_PACKAGE_curl=y"
    "CONFIG_PACKAGE_jsonfilter=y"
    "CONFIG_PACKAGE_ca-certificates=y"
    "CONFIG_PACKAGE_ipset=y"
    "CONFIG_PACKAGE_ip-full=y"
    "CONFIG_PACKAGE_ruby=y"
    "CONFIG_PACKAGE_ruby-yaml=y"
    "CONFIG_PACKAGE_unzip=y"
    "CONFIG_PACKAGE_luci-compat=y"
    "CONFIG_PACKAGE_luci-base=y"
    "CONFIG_PACKAGE_kmod-inet-diag=y"
    "CONFIG_PACKAGE_luci-i18n-openclash-zh-cn=y"  # 中文支持
)

# 5. Passwall2 依赖（含中文支持）
DEPS["passwall2"]=(
    "CONFIG_PACKAGE_luci-app-passwall2=y"
    "CONFIG_PACKAGE_xray-core=y"
    "CONFIG_PACKAGE_sing-box=y"
    "CONFIG_PACKAGE_chinadns-ng=y"
    "CONFIG_PACKAGE_haproxy=y"
    "CONFIG_PACKAGE_hysteria=y"
    "CONFIG_PACKAGE_v2ray-geoip=y"
    "CONFIG_PACKAGE_v2ray-geosite=y"
    "CONFIG_PACKAGE_unzip=y"
    "CONFIG_PACKAGE_coreutils=y"
    "CONFIG_PACKAGE_coreutils-base64=y"
    "CONFIG_PACKAGE_coreutils-nohup=y"
    "CONFIG_PACKAGE_curl=y"
    "CONFIG_PACKAGE_ipset=y"
    "CONFIG_PACKAGE_ip-full=y"
    "CONFIG_PACKAGE_luci-compat=y"
    "CONFIG_PACKAGE_luci-lib-jsonc=y"
    "CONFIG_PACKAGE_tcping=y"
    "CONFIG_PACKAGE_luci-i18n-passwall2-zh-cn=y"  # 中文支持
)

# 6. 目标设备配置
DEPS["target"]=(
    "CONFIG_TARGET_ipq40xx=y"
    "CONFIG_TARGET_ipq40xx_generic=y"
    "CONFIG_TARGET_DEVICE_ipq40xx_generic_DEVICE_mobipromo_cm520-79f=y"
)

# -------------------- 版本检测与DSA判断 --------------------
detect_openwrt_version() {
    local version_file="include/version.mk"
    local major_ver minor_ver

    if [ -f "$version_file" ]; then
        # 提取主版本号（如22.03、24.10）
        OPENWRT_VERSION=$(grep '^OPENWRT_VERSION=' "$version_file" | cut -d= -f2 | tr -d ' "')
        log_info "检测到 OpenWrt 版本: $OPENWRT_VERSION"
        
        # 判断是否为DSA架构（22.03+）
        if [[ "$OPENWRT_VERSION" =~ ^22\.03 || "$OPENWRT_VERSION" =~ ^23\.05 || "$OPENWRT_VERSION" =~ ^24\.10 || "$OPENWRT_VERSION" == "snapshot" ]]; then
            IS_DSA=true
            log_info "检测到 DSA 架构（22.03+）"
        else
            IS_DSA=false
            log_info "使用传统网络架构"
        fi

        # 版本适配：24.10+ 启用nft，旧版本保留iptables
        if [[ "$OPENWRT_VERSION" =~ ^24\.10 || "$OPENWRT_VERSION" == "snapshot" ]]; then
            log_info "版本 24.10+ 启用 nft-tproxy 支持"
            DEPS["network"]+=("CONFIG_PACKAGE_kmod-nft-nat=y")
            DEPS["network"]+=("CONFIG_PACKAGE_kmod-nft-tproxy=y")
            DEPS["openclash"]+=("CONFIG_PACKAGE_kmod-nft-tproxy=y")  # 明确添加OpenClash依赖
        else
            log_info "旧版本启用 iptables 兼容模式"
            DEPS["network"]+=("CONFIG_PACKAGE_iptables-mod-nat-extra=y")
            DEPS["network"]+=("CONFIG_PACKAGE_kmod-ipt-offload=y")
            DEPS["passwall2"]+=("CONFIG_PACKAGE_iptables=y")
            DEPS["passwall2"]+=("CONFIG_PACKAGE_iptables-mod-tproxy=y")
            DEPS["passwall2"]+=("CONFIG_PACKAGE_iptables-mod-socket=y")
            DEPS["passwall2"]+=("CONFIG_PACKAGE_kmod-ipt-nat=y")
        fi
    else
        log_warning "未找到版本文件，默认使用DSA架构兼容模式"
        IS_DSA=true
    fi
}

# -------------------- 依赖工具检查 --------------------
check_dependencies() {
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

    # 云环境代理配置（如果有环境变量）
    if [ "$CLOUD_MODE" = "true" ] && [ -n "$HTTP_PROXY" ]; then
        log_info "配置git代理: $HTTP_PROXY"
        git config --global http.proxy "$HTTP_PROXY"
        git config --global https.proxy "$HTTP_PROXY"
    fi
}

# -------------------- 配置缓存管理 --------------------
init_config_cache() {
    if [ -f "$CONFIG_FILE" ]; then
        log_debug "加载配置缓存（行数: $(wc -l < "$CONFIG_FILE")）"
        while IFS= read -r line; do
            [[ "$line" =~ ^# || -z "$line" ]] && continue
            config_cache["$line"]=1
        done < "$CONFIG_FILE"
    fi
}

# -------------------- 安全文件操作 --------------------
safe_mkdir() {
    local dir="$1"
    [ -d "$dir" ] && return 0
    if ! mkdir -p "$dir"; then
        log_error "无法创建目录: $dir（权限问题）"
    fi
    log_debug "创建目录: $dir"
}

safe_write_file() {
    local file="$1"
    local content="$2"
    safe_mkdir "$(dirname "$file")"
    if ! echo "$content" > "$file"; then
        log_error "无法写入文件: $file"
    fi
    log_debug "写入文件: $file"
}

# -------------------- 设备树与网络配置（DSA适配） --------------------
setup_device_tree() {
    log_step "配置CM520-79F设备树与网络"
    
    # 备份已有DTS
    if [ -f "$DTS_FILE" ]; then
        cp "$DTS_FILE" "${DTS_FILE}.bak" || log_error "DTS备份失败"
        log_info "已备份原DTS至 ${DTS_FILE}.bak"
    fi

    # 写入设备树（兼容DSA）
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

    # 配置网络接口（DSA/传统模式自动适配）
    safe_mkdir "$NETWORK_CFG_DIR"
    local network_content
    if $IS_DSA; then
        # DSA模式配置（交换机+lan/wan接口）
        log_info "配置DSA网络（交换机模式）"
        # 自动设置接口（用户未指定时）
        [ -z "$LAN_IFACE" ] && LAN_IFACE="lan1 lan2"  # 假设2个LAN口
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
		# 配置交换机（4个物理端口）
		ucidef_add_switch "switch0" \\
			"0u@eth0" "1:lan" "2:lan" "3:wan"  # 端口映射：1-2为LAN，3为WAN
		# 配置LAN/WAN接口
		ucidef_set_interfaces_lan_wan "$LAN_IFACE" "$WAN_IFACE"
		;;
	esac
}
boot_hook_add preinit_main ipq40xx_board_detect
EOF
        )
    else
        # 传统模式配置（eth接口）
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

    # 配置设备编译规则（DSA兼容）
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

# -------------------- 配置项管理（冲突修复） --------------------
add_config_if_missing() {
    local config="$1"
    local description="$2"
    
    [ -z "$config" ] && log_error "配置项不能为空"
    
    # 强制移除旧配置（解决冲突）
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

# 批量添加分层依赖
add_deps_by_layer() {
    local layer="$1"
    local deps=("${DEPS[$layer]}")
    
    [ ${#deps[@]} -eq 0 ] && return 0
    
    log_step "添加[$layer]层依赖（共${#deps[@]}项）"
    for config in "${deps[@]}"; do
        add_config_if_missing "$config" "$layer层依赖"
    done
}

# -------------------- 插件集成（含内核下载） --------------------
try_git_mirrors() {
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

# 下载OpenClash内核
download_clash_core() {
    local core_dir="/etc/openclash/core"
    local temp_core="/tmp/clash_meta_$$"
    local arch="armv7"  # 适配CM520-79F架构
    
    log_step "下载OpenClash内核（clash_meta）"
    safe_mkdir "$core_dir"
    
    # 最新版本下载地址（armv7）
    local core_url="https://github.com/MetaCubeX/Clash.Meta/releases/latest/download/clash-meta-linux-armv7"
    
    if ! wget --no-check-certificate -O "$temp_core" "$core_url"; then
        log_warning "主地址下载失败，尝试镜像"
        core_url="https://ghproxy.com/$core_url"
        if ! wget --no-check-certificate -O "$temp_core" "$core_url"; then
            log_error "Clash内核下载失败"
            return 1
        fi
    fi
    
    # 安装内核
    mv "$temp_core" "$core_dir/clash_meta"
    chmod +x "$core_dir/clash_meta"
    log_success "Clash内核安装完成: $core_dir/clash_meta"
    return 0
}

# 导入Passwall2密钥
import_passwall_keys() {
    log_step "导入Passwall2软件源密钥"
    local key_dir="/etc/opkg/keys"
    safe_mkdir "$key_dir"
    
    # 密钥文件（来自官方源）
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
    local repo="$1"
    local plugin_name="$2"
    local subdir="${3:-.}"
    shift 3
    local deps_layer="$1"  # 依赖层名称
    local temp_dir="/tmp/${plugin_name}_$(date +%s)_$$"
    local lock_file="/tmp/.${plugin_name}_lock"
    
    log_step "集成插件: $plugin_name"
    log_info "仓库: $repo"
    log_info "目标路径: $CUSTOM_PLUGINS_DIR/$plugin_name"

    # 加锁防止并行冲突
    exec 200>"$lock_file"
    if ! flock -n 200; then
        log_warning "等待插件锁释放..."
        flock 200
    fi

    # 清理旧文件
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

    # 克隆插件
    if ! try_git_mirrors "$repo" "$temp_dir"; then
        flock -u 200
        return 1
    fi

    # 定位插件目录（查找Makefile）
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

    # 移动插件到自定义目录
    safe_mkdir "$CUSTOM_PLUGINS_DIR"
    if ! mv "$source_path" "$CUSTOM_PLUGINS_DIR/$plugin_name"; then
        log_error "移动插件失败"
        rm -rf "$temp_dir"
        flock -u 200
        return 1
    fi

    # 清理临时文件并释放锁
    rm -rf "$temp_dir"
    flock -u 200

    # 添加插件依赖
    if [ -n "$deps_layer" ] && [ ${#DEPS[$deps_layer]} -gt 0 ]; then
        log_info "添加插件依赖层: $deps_layer"
        add_deps_by_layer "$deps_layer"
    fi

    log_success "$plugin_name 集成完成"
    return 0
}

# -------------------- 验证机制 --------------------
verify_filesystem() {
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
            # 自动修复：保留新版本需要的配置
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
    log_step "OpenWrt插件集成流程启动（V6）"
    
    # 权限提示
    if [ "$EUID" -ne 0 ]; then
        log_warning "建议以root用户运行（当前: $USER）"
    fi

    # 初始化检查
    check_dependencies
    detect_openwrt_version
    init_config_cache
    safe_mkdir "$CUSTOM_PLUGINS_DIR"

    # 调试模式启用
    if [ "$DEBUG_MODE" = "true" ]; then
        log_info "启用调试模式"
        set -x
    fi

    # 检查配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "配置文件不存在，创建空文件"
        touch "$CONFIG_FILE"
    elif [ ! -w "$CONFIG_FILE" ]; then
        log_error "配置文件不可写: $CONFIG_FILE"
    fi

    # 配置设备与网络（DSA适配）
    setup_device_tree

    # 更新feeds（在插件克隆前执行）
    log_step "更新软件源"
    ./scripts/feeds update -a || log_error "feeds更新失败"
    ./scripts/feeds install -a || log_error "feeds安装失败"

    # 添加核心依赖
    add_deps_by_layer "kernel"
    add_deps_by_layer "drivers"
    add_deps_by_layer "network"
    add_deps_by_layer "target"

    # 集成插件
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

    # 插件后处理
    log_step "插件后处理"
    download_clash_core  # OpenClash内核
    import_passwall_keys  # Passwall2密钥

    # 验证流程
    verify_filesystem "luci-app-openclash"
    verify_filesystem "luci-app-passwall2"
    verify_config_conflicts

    # 生成最终配置
    log_step "生成最终配置"
    make defconfig || log_error "配置生成失败"

    # 输出配置差异
    log_info "配置变更摘要:"
    grep -E '^CONFIG_PACKAGE_(luci-app-openclash|luci-app-passwall2|kmod-nft-tproxy|iptables)' "$CONFIG_FILE" || true

    # 输出报告
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

# 启动主流程
main "$@"
