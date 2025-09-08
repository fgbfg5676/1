#!/bin/bash
# 最终解决方案脚本 - 整合版
# 描述: 整合OpenWrt预编译配置与插件集成功能，移除AdGuardHome和sirpdboy插件
# --- 启用严格模式，任何错误立即终止 ---
set -e

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m" >&2; }

# -------------------- 环境检查 --------------------
log_info "===== 开始环境检查 ====="
if [ ! -f "scripts/feeds" ] || [ ! -f "Config.in" ]; then
    log_error "请在OpenWrt源码根目录执行此脚本"
fi

for cmd in git make timeout curl wget; do
    if ! command -v $cmd >/dev/null 2>&1; then
        log_error "缺少必需的命令: $cmd"
    fi
done

[ ! -f ".config" ] && touch .config

if ! timeout 3 curl -Is https://github.com >/dev/null 2>&1; then
    log_warning "网络连接可能存在问题，插件克隆可能失败"
fi
log_success "环境检查通过"

# =================== 预编译配置阶段 (Pre-Compile) ==================
log_info "===== 开始执行预编译配置 ====="

# -------------------- 步骤 1：基础变量定义 --------------------
log_info "步骤 1：定义基础变量..."
ARCH="armv7"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
CUSTOM_PLUGINS_DIR="package/custom"
log_success "基础变量定义完成。"

# -------------------- 步骤 2：创建必要的目录 --------------------
log_info "步骤 2：创建必要的目录..."
mkdir -p "$DTS_DIR" "$CUSTOM_PLUGINS_DIR"
log_success "目录创建完成。"

# -------------------- 步骤 3：写入DTS文件 --------------------
log_info "步骤 3：正在写入DTS文件..."
cat > "$DTS_FILE" <<'EOF'
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
		rng@22000 {
			status = "okay";
		};
		mdio@90000 {
			status = "okay";
			pinctrl-0 = <&mdio_pins>;
			pinctrl-names = "default";
			reset-gpios = <&tlmm 47 GPIO_ACTIVE_LOW>;
			reset-delay-us = <1000>;
		};
		ess-psgmii@98000 {
			status = "okay";
		};
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
				usb3_port1: port@1 {
					reg = <1>;
					#trigger-source-cells = <0>;
				};
				usb3_port2: port@2 {
					reg = <2>;
					#trigger-source-cells = <0>;
				};
			};
		};
		crypto@8e3a000 {
			status = "okay";
		};
		watchdog@b017000 {
			status = "okay";
		};
		ess-switch@c000000 {
			status = "okay";
		};
		edma@c080000 {
			status = "okay";
		};
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
		led_sys: can {
			label = "blue:can";
			gpios = <&tlmm 11 GPIO_ACTIVE_HIGH>;
		};
		wan {
			label = "blue:wan";
			gpios = <&led_gpio 0 GPIO_ACTIVE_LOW>;
		};
		lan1 {
			label = "blue:lan1";
			gpios = <&led_gpio 1 GPIO_ACTIVE_LOW>;
		};
		lan2 {
			label = "blue:lan2";
			gpios = <&led_gpio 2 GPIO_ACTIVE_LOW>;
		};
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
			partition@0 {
				label = "Bootloader";
				reg = <0x0 0xb00000>;
				read-only;
			};
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
			partition@b80000 {
				label = "rootfs";
				reg = <0xb80000 0x7480000>;
			};
		};
	};
};
&qpic_bam { status = "okay"; };
&tlmm {
	mdio_pins: mdio_pinmux {
		mux_1 {
			pins = "gpio6";
			function = "mdio";
			bias-pull-up;
		};
		mux_2 {
			pins = "gpio7";
			function = "mdc";
			bias-pull-up;
		};
	};
	nand_pins: nand_pins {
		pullups {
			pins = "gpio52", "gpio53", "gpio58", "gpio59";
			function = "qpic";
			bias-pull-up;
		};
		pulldowns {
			pins = "gpio54", "gpio55", "gpio56", "gpio57", "gpio60", "gpio61", "gpio62", "gpio63", "gpio64", "gpio65", "gpio66", "gpio67", "gpio68", "gpio69";
			function = "qpic";
			bias-pull-down;
		};
	};
};
&usb3_ss_phy { status = "okay"; };
&usb3_hs_phy { status = "okay"; };
&usb2_hs_phy { status = "okay"; };
&wifi0 { status = "okay"; nvmem-cell-names = "pre-calibration"; nvmem-cells = <&precal_art_1000>; qcom,ath10k-calibration-variant = "CM520-79F"; };
&wifi1 { status = "okay"; nvmem-cell-names = "pre-calibration"; nvmem-cells = <&precal_art_5000>; qcom,ath10k-calibration-variant = "CM520-79F"; };
EOF
log_success "DTS文件写入成功。"

# -------------------- 步骤 4：创建网络配置文件 --------------------
log_info "步骤 4：创建针对 CM520-79F 的网络配置文件..."
BOARD_DIR="target/linux/ipq40xx/base-files/etc/board.d"
mkdir -p "$BOARD_DIR"
cat > "$BOARD_DIR/02_network" <<EOF
#!/bin/sh
. /lib/functions/system.sh
ipq40xx_board_detect() {
	local machine
	machine=\$(board_name)
	case "\$machine" in
	"mobipromo,cm520-79f")
		ucidef_set_interfaces_lan_wan "eth1" "eth0"
		;;
	esac
}
boot_hook_add preinit_main ipq40xx_board_detect
EOF
log_success "网络配置文件创建完成。"

# -------------------- 步骤 5：配置设备规则 --------------------
log_info "步骤 5：配置设备规则..."
if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    cat <<EOF >> "$GENERIC_MK"
define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 81920k
  IMAGE/trx := append-kernel | pad-to \$(KERNEL_SIZE) | append-rootfs | trx -o \$@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
    log_success "设备规则添加完成。"
else
    sed -i 's/IMAGE_SIZE := 32768k/IMAGE_SIZE := 81920k/' "$GENERIC_MK"
    log_info "设备规则已存在，更新IMAGE_SIZE。"
fi

# -------------------- 通用函数 --------------------
add_config() {
    local option="$1"
    if ! grep -q "^$option$" .config; then
        echo "$option" >> .config
    fi
}

fetch_plugin() {
    local repo="$1"
    local plugin_name="$2"
    local subdir="$3"
    shift 3
    local deps=("$@")
    local temp_dir="package/${plugin_name}-temp"
    local max_retries=3
    local retry_count=0
    local success=0

    log_info "清理旧版 ${plugin_name}..."
    rm -rf feeds/luci/applications/"$plugin_name" 2>/dev/null
    rm -rf feeds/packages/net/"$plugin_name" 2>/dev/null
    rm -rf feeds/routing/"$plugin_name" 2>/dev/null
    [ -n "$CUSTOM_PLUGINS_DIR" ] && rm -rf "${CUSTOM_PLUGINS_DIR}/${plugin_name}" 2>/dev/null
    rm -rf "package/${plugin_name}" "$temp_dir" 2>/dev/null

    if ! git ls-remote "$repo" >/dev/null 2>&1; then
        log_error "无法访问仓库: $repo，请检查网络"
        return 1
    fi

    while [ $retry_count -lt $max_retries ]; do
        ((retry_count++))
        log_info "克隆 ${plugin_name} (尝试 $retry_count/$max_retries)..."
        if timeout 120 git clone --depth 1 --single-branch "$repo" "$temp_dir" >/dev/null 2>&1; then
            success=1
            break
        else
            [ -d "$temp_dir" ] && rm -rf "$temp_dir"
            [ $retry_count -lt $max_retries ] && sleep 3
        fi
    done

    if [ $success -eq 0 ]; then
        log_error "${plugin_name} 克隆失败，已重试 $max_retries 次"
        return 1
    fi

    local source_path="$temp_dir"
    [ -n "$subdir" ] && [ "$subdir" != "." ] && source_path="$temp_dir/$subdir"

    if [ ! -d "$source_path" ]; then
        log_error "${plugin_name} 源目录不存在: $source_path"
        rm -rf "$temp_dir"
        return 1
    fi

    if [ ! -f "$source_path/Makefile" ]; then
        local found_makefile=$(find "$source_path" -maxdepth 2 -name Makefile -print -quit)
        if [ -n "$found_makefile" ]; then
            source_path=$(dirname "$found_makefile")
            log_warning "使用子目录 Makefile: $source_path/Makefile"
        else
            log_error "${plugin_name} 缺少 Makefile"
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    if ! mv "$source_path" "package/$plugin_name" 2>/dev/null; then
        log_error "${plugin_name} 移动失败"
        rm -rf "$temp_dir"
        return 1
    fi
    rm -rf "$temp_dir"

    for dep in "${deps[@]}"; do
        [ -n "$dep" ] && add_config "$dep"
    done
    log_info "${plugin_name} 依赖项配置完成"
    log_success "${plugin_name} 集成成功"
    return 0
}

# -------------------- 插件集成 --------------------
log_info "开始插件集成过程..."

OPENCLASH_DEPS=(
    "CONFIG_PACKAGE_luci-app-openclash=y"
    "CONFIG_PACKAGE_iptables-mod-tproxy=y"
    "CONFIG_PACKAGE_kmod-tun=y"
    "CONFIG_PACKAGE_dnsmasq-full=y"
    "CONFIG_PACKAGE_coreutils-nohup=y"
    "CONFIG_PACKAGE_bash=y"
    "CONFIG_PACKAGE_curl=y"
    "CONFIG_PACKAGE_jsonfilter=y"
    "CONFIG_PACKAGE_ca-certificates=y"
    "CONFIG_PACKAGE_iptables-mod-socket=y"
    "CONFIG_PACKAGE_iptables-mod-conntrack-extra=y"
)
fetch_plugin "https://github.com/vernesong/OpenClash.git" "luci-app-openclash" "luci-app-openclash" "${OPENCLASH_DEPS[@]}"

PASSWALL2_DEPS=(
    "CONFIG_PACKAGE_luci-app-passwall2=y"
    "CONFIG_PACKAGE_xray-core=y"
    "CONFIG_PACKAGE_sing-box=y"
    "CONFIG_PACKAGE_chinadns-ng=y"
    "CONFIG_PACKAGE_haproxy=y"
    "CONFIG_PACKAGE_hysteria=y"
    "CONFIG_PACKAGE_v2ray-geoip=y"
    "CONFIG_PACKAGE_v2ray-geosite=y"
    "CONFIG_PACKAGE_unzip=y"
    "CONFIG_PACKAGE_iptables-mod-socket=y"
    "CONFIG_PACKAGE_iptables-mod-conntrack-extra=y"
)
fetch_plugin "https://github.com/xiaorouji/openwrt-passwall2.git" "luci-app-passwall2" "." "${PASSWALL2_DEPS[@]}"

# -------------------- 更新 feeds --------------------
log_info "更新 feeds..."
./scripts/feeds update -a >/dev/null 2>&1 || { log_warning "Feeds 更新失败，尝试部分更新..."; ./scripts/feeds update luci packages routing >/dev/null 2>&1 || log_error "部分 feeds 更新失败"; }
./scripts/feeds install -a >/dev/null 2>&1 || { log_warning "Feeds 安装失败，尝试重试..."; ./scripts/feeds install -a >/dev/null 2>&1 || log_error "Feeds 重试失败"; }
log_success "Feeds 更新与安装完成"

# -------------------- 生成最终配置文件 --------------------
log_info "正在启用必要的软件包并生成最终配置..."
# 创建临时配置文件
CONFIG_FILE=".config.custom"
rm -f $CONFIG_FILE

# 添加基础依赖
echo "CONFIG_PACKAGE_kmod-ubi=y" >> $CONFIG_FILE
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> $CONFIG_FILE
echo "CONFIG_PACKAGE_trx=y" >> $CONFIG_FILE
echo "CONFIG_PACKAGE_kmod-ath10k-ct=y" >> $CONFIG_FILE
echo "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y" >> $CONFIG_FILE
echo "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" >> $CONFIG_FILE
echo "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y" >> $CONFIG_FILE
echo "CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y" >> $CONFIG_FILE

# 合并配置到主配置文件
cat $CONFIG_FILE >> .config
rm -f $CONFIG_FILE

# 生成最终配置
make defconfig
log_success "最终配置文件生成完成。"

# -------------------- 验证插件 --------------------
validation_passed=true

verify_filesystem() {
    local plugin=$1
    if [ -d "package/$plugin" ] && [ -f "package/$plugin/Makefile" ]; then
        log_success "$plugin 目录和 Makefile 验证通过"
    else
        log_error "$plugin 目录或 Makefile 缺失"
        validation_passed=false
    fi
}

verify_filesystem "luci-app-openclash"
verify_filesystem "luci-app-passwall2"

verify_configs() {
    local plugin_name=$1
    shift
    local deps=("$@")
    local missing=0
    log_info "验证 $plugin_name 配置项..."
    for config in "${deps[@]}"; do
        if grep -q "^$config$" .config; then
            log_info "✅ $config"
        else
            log_error "❌ $config (未找到)"
            missing=$((missing+1))
            validation_passed=false
        fi
    done
    if [ $missing -eq 0 ]; then
        log_success "$plugin_name 所有配置项验证通过"
    else
        log_error "$plugin_name 缺少 $missing 个配置项"
    fi
}

verify_configs "OpenClash" "${OPENCLASH_DEPS[@]}"
verify_configs "Passwall2" "${PASSWALL2_DEPS[@]}"

verify_feeds_visibility() {
    log_info "验证插件在 feeds 中的可见性..."
    ./scripts/feeds list | grep -q "luci-app-openclash" && log_success "OpenClash 在 feeds 中可见" || log_warning "OpenClash 在 feeds 中不可见"
    ./scripts/feeds list | grep -q "luci-app-passwall2" && log_success "Passwall2 在 feeds 中可见" || log_warning "Passwall2 在 feeds 中不可见"
}
verify_feeds_visibility

# -------------------- 最终报告 --------------------
if $validation_passed; then
    log_success "所有插件集成验证通过"
else
    log_error "插件集成验证失败，请检查错误日志"
    log_info "调试建议:"
    log_info "1. 检查网络连接和Git访问权限"
    log_info "2. 查看 .config 文件确认配置项"
    log_info "3. 手动检查 package/ 目录下的插件目录"
    log_info "4. 运行 'make menuconfig' 确认插件是否可用"
    exit 1
fi

log_success "所有预编译步骤和插件集成均已成功完成！"
log_info "接下来请执行 'make' 命令进行编译。"
exit 0
