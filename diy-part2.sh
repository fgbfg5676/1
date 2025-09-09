#!/bin/bash
# OpenWrt 插件集成脚本 - 完整增强版
# 包含：DTS设备树、网络配置、插件集成、验证等完整功能

set -eo pipefail
export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '

# -------------------- 日志函数 --------------------
log_step() { echo -e "\n[$(date +'%H:%M:%S')] \033[1;36m📝 步骤：$*\033[0m"; }
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m" >&2; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m" >&2; }
log_debug() { echo -e "[$(date +'%H:%M:%S')] \033[90m🐛 $*\033[0m"; }

# -------------------- 全局变量 --------------------
validation_passed=true
plugin_count=0
CONFIG_FILE=".config"
CUSTOM_PLUGINS_DIR="package/custom"
DEBUG_MODE=${DEBUG_MODE:-"true"}

# -------------------- DTS配置变量（使用您提供的完整配置）--------------------
ARCH="armv7"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
ADGUARD_CORE_DIR="package/base-files/files/usr/bin"

# -------------------- 网络基础配置 --------------------
NETWORK_BASE_CONFIGS=(
    # IPQ40xx核心驱动
    "CONFIG_PACKAGE_kmod-qca-nss-dp=y"
    "CONFIG_PACKAGE_kmod-qca-ssdk=y"
    "CONFIG_PACKAGE_kmod-mii=y"
    "CONFIG_PACKAGE_kmod-phy-qcom-ipq4019=y"
    
    # 以太网支持
    "CONFIG_PACKAGE_kmod-of-mdio=y"
    "CONFIG_PACKAGE_kmod-mdio-gpio=y"
    "CONFIG_PACKAGE_kmod-fixed-phy=y"
    
    # DHCP客户端
    "CONFIG_BUSYBOX_CONFIG_UDHCPC=y"
    "CONFIG_PACKAGE_udhcpc=y"
    "CONFIG_BUSYBOX_CONFIG_UDHCP_DEBUG=y"
    
    # 网络工具
    "CONFIG_PACKAGE_tcpdump=y"
    "CONFIG_PACKAGE_traceroute=y"
    "CONFIG_PACKAGE_netstat=y"
    "CONFIG_PACKAGE_ss=y"
    "CONFIG_PACKAGE_ping=y"
    "CONFIG_PACKAGE_wget=y"
    
    # NAT和防火墙
    "CONFIG_PACKAGE_iptables-mod-nat-extra=y"
    "CONFIG_PACKAGE_kmod-nf-nathelper-extra=y"
    "CONFIG_PACKAGE_kmod-ipt-offload=y"
    
    # WiFi支持
    "CONFIG_PACKAGE_kmod-ath10k=y"
    "CONFIG_ATH10K_LEDS=y"
    "CONFIG_PACKAGE_ath10k-firmware-qca4019=y"
    
    # 系统工具
    "CONFIG_PACKAGE_htop=y"
    "CONFIG_PACKAGE_nano=y"
    "CONFIG_PACKAGE_bash=y"
)

# -------------------- DTS配置函数（使用您提供的完整配置）--------------------
setup_device_tree() {
    log_step "配置CM520-79F设备树支持"
    
    # -------------------- 步驟 1：基礎變量定義 --------------------
    log_info "步驟 1：定義基礎變量..."
    mkdir -p "$DTS_DIR" "$CUSTOM_PLUGINS_DIR" "$ADGUARD_CORE_DIR"
    log_success "基礎變量定義完成。"

    # -------------------- 步驟 2：創建必要的目錄 --------------------
    log_info "步驟 2：創建必要的目錄..."
    mkdir -p "$DTS_DIR" "$CUSTOM_PLUGINS_DIR" "$ADGUARD_CORE_DIR"
    log_success "目錄創建完成。"

    # -------------------- 步驟 3：寫入DTS文件 --------------------
    log_info "步驟 3：正在寫入100%正確的DTS文件..."
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
    log_success "DTS文件寫入成功。"

    # -------------------- 步驟 4：創建網絡配置文件 --------------------
    log_info "步驟 4：創建針對 CM520-79F 的網絡配置文件..."
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
    chmod +x "$BOARD_DIR/02_network"
    log_success "網絡配置文件創建完成。"

    # -------------------- 步驟 5：配置設備規則 --------------------
    log_info "步驟 5：配置設備規則..."
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
    
    return 0
}

# -------------------- 智能配置添加函数 --------------------
add_config_if_missing() {
    local config="$1"
    local description="$2"
    
    if [ -z "$config" ]; then
        log_warning "配置项为空，跳过"
        return 1
    fi
    
    # 检查配置是否已存在
    if grep -q "^${config}$" "$CONFIG_FILE" 2>/dev/null; then
        log_debug "配置已存在: $config"
        return 0
    fi
    
    # 添加配置
    echo "$config" >> "$CONFIG_FILE"
    if [ $? -eq 0 ]; then
        log_info "添加配置: $config"
        [ -n "$description" ] && log_debug "  说明: $description"
        return 0
    else
        log_error "无法添加配置: $config"
        return 1
    fi
}

# -------------------- 添加网络基础配置 --------------------
add_network_base_configs() {
    log_step "添加网络基础配置（解决联网问题）"
    
    local added_count=0
    local total_count=${#NETWORK_BASE_CONFIGS[@]}
    
    log_info "准备添加 $total_count 项网络基础配置..."
    
    for config in "${NETWORK_BASE_CONFIGS[@]}"; do
        if add_config_if_missing "$config" "网络基础配置"; then
            ((added_count++))
        fi
    done
    
    log_success "网络配置添加完成: $added_count/$total_count 项"
    
    if [ $added_count -gt 0 ]; then
        log_info "新添加的配置将在下次 make menuconfig 时生效"
        log_info "这些配置主要解决 IPQ40xx 设备的网络连接问题"
    fi
}

# -------------------- 验证变量是否为有效数字 --------------------
is_number() {
    local var="$1"
    [[ "$var" =~ ^[0-9]+$ ]]
}

# -------------------- 安全递增插件计数 --------------------
increment_plugin_count() {
    if ! is_number "$plugin_count"; then
        log_error "plugin_count 不是有效数字（当前值: '$plugin_count'），将重置为0"
        plugin_count=0
    fi
    
    local new_count=$((plugin_count + 1))
    log_debug "plugin_count 从 $plugin_count 递增到 $new_count"
    plugin_count="$new_count"
}

# -------------------- 镜像仓库支持 --------------------
try_git_mirrors() {
    local original_repo="$1"
    local temp_dir="$2"
    local mirrors=(
        "$original_repo"                                    # 原始地址
        "${original_repo/github.com/ghproxy.com\/github.com}"  # GitHub代理
        "${original_repo/github.com/hub.fastgit.xyz}"     # FastGit镜像
        "${original_repo/github.com/gitclone.com\/github.com}" # GitClone镜像
    )
    
    for mirror in "${mirrors[@]}"; do
        log_info "尝试镜像: $mirror"
        
        # 测试连接性
        if timeout 10 git ls-remote --heads "$mirror" >/dev/null 2>&1; then
            log_info "连接测试成功，开始克隆..."
            
            if timeout 300 git clone --depth 1 --single-branch \
                --progress "$mirror" "$temp_dir" 2>&1; then
                
                if [ -d "$temp_dir" ] && [ "$(ls -A "$temp_dir" 2>/dev/null)" != "" ]; then
                    log_success "克隆成功！使用镜像: $mirror"
                    return 0
                fi
            fi
        fi
        
        log_warning "镜像失败: $mirror"
        [ -d "$temp_dir" ] && rm -rf "$temp_dir"
    done
    
    return 1
}

# -------------------- 增强的插件集成函数 --------------------
fetch_plugin() {
    local repo="$1"
    local plugin_name="$2"
    local subdir="${3:-.}"
    shift 3
    local deps=("$@")
    
    local temp_dir="/tmp/${plugin_name}_$(date +%s)_$$"
    local success=0
    
    log_step "开始集成插件: $plugin_name"
    log_info "仓库地址: $repo"
    log_info "目标路径: package/$plugin_name"
    
    # 锁文件处理
    local lock_file="/tmp/.${plugin_name}_lock"
    exec 200>"$lock_file"
    if ! flock -n 200; then
        log_warning "插件 $plugin_name 正在被处理，等待锁释放..."
        flock 200
    fi
    
    # 清理旧版本
    log_info "清理旧版 $plugin_name 相关文件..."
    local cleanup_paths=(
        "feeds/luci/applications/$plugin_name"
        "feeds/packages/net/$plugin_name"
        "package/$plugin_name"
        "$CUSTOM_PLUGINS_DIR/$plugin_name"
        "$temp_dir"
    )
    for path in "${cleanup_paths[@]}"; do
        if [ -d "$path" ]; then
            log_info "删除旧路径: $path"
            rm -rf "$path" || log_warning "无法删除 $path"
        fi
    done
    
    # 使用镜像克隆
    log_info "开始多镜像克隆尝试..."
    if try_git_mirrors "$repo" "$temp_dir"; then
        success=1
    else
        log_error "所有镜像均克隆失败"
        flock -u 200
        return 1
    fi
    
    # 处理子目录
    local source_path="$temp_dir/$subdir"
    if [ ! -d "$source_path" ]; then
        log_error "源目录不存在: $source_path"
        log_info "临时目录结构："
        ls -la "$temp_dir" 2>/dev/null || true
        rm -rf "$temp_dir"
        flock -u 200
        return 1
    fi
    
    # 验证Makefile存在
    if [ ! -f "$source_path/Makefile" ]; then
        log_error "$plugin_name 缺少关键文件: Makefile"
        log_info "在 $source_path 中搜索Makefile..."
        local found_makefile=$(find "$source_path" -maxdepth 3 -name Makefile -print -quit)
        if [ -n "$found_makefile" ]; then
            log_info "找到Makefile: $found_makefile"
            source_path=$(dirname "$found_makefile")
        else
            log_error "未找到Makefile，集成失败"
            rm -rf "$temp_dir"
            flock -u 200
            return 1
        fi
    fi
    
    # 移动插件到目标目录
    log_info "移动插件到 package 目录..."
    mkdir -p "package"
    if ! mv "$source_path" "package/$plugin_name"; then
        log_error "移动失败！"
        log_info "源路径: $source_path"
        log_info "目标路径: package/$plugin_name"
        rm -rf "$temp_dir"
        flock -u 200
        return 1
    fi
    
    # 清理临时文件
    rm -rf "$temp_dir"
    flock -u 200
    
    # 验证集成结果
    if [ -d "package/$plugin_name" ] && [ -f "package/$plugin_name/Makefile" ]; then
        log_success "$plugin_name 集成成功！"
        log_info "最终路径: package/$plugin_name"
        
        # 添加依赖配置
        if [ ${#deps[@]} -gt 0 ]; then
            log_info "添加 ${#deps[@]} 个依赖配置项..."
            for dep in "${deps[@]}"; do
                if [ -n "$dep" ]; then
                    add_config_if_missing "$dep" "$plugin_name 依赖"
                fi
            done
        fi
        return 0
    else
        log_error "$plugin_name 集成验证失败"
        return 1
    fi
}

# -------------------- 验证文件系统函数 --------------------
verify_filesystem() {
    local plugin=$1
    log_step "验证 $plugin 文件系统"
    
    log_debug "进入 verify_filesystem，当前 plugin_count: '$plugin_count'"
    
    if [ -d "package/$plugin" ]; then
        log_debug "目录存在: package/$plugin"
        if [ -f "package/$plugin/Makefile" ]; then
            log_debug "Makefile存在: package/$plugin/Makefile"
            log_success "$plugin 目录和Makefile均存在"
            
            increment_plugin_count
            
            log_debug "验证 $plugin 后，plugin_count 已更新为: $plugin_count"
            return 0
        else
            log_error "$plugin 目录存在，但缺少Makefile"
            validation_passed=false
        fi
    else
        log_error "$plugin 目录不存在（集成失败）"
        validation_passed=false
    fi
    
    return 0
}

# -------------------- 验证配置项函数 --------------------
verify_configs() {
    local plugin_name="$1"
    shift
    local deps=("$@")
    local missing=0
    local found=0
    local total=${#deps[@]}

    log_step "验证 $plugin_name 配置项（共 $total 项）"
    
    set +e
    for index in "${!deps[@]}"; do
        local config="${deps[$index]}"
        local item_num=$((index + 1))
        
        log_debug "处理第 $item_num 项: $config"
        
        if [ -z "$config" ]; then
            log_warning "第 $item_num 项：配置项为空，跳过"
            ((missing++))
            continue
        fi
        
        if [ ! -w "$CONFIG_FILE" ]; then
            log_warning "$CONFIG_FILE 不可写，无法添加配置项"
        fi
        
        if grep -q "^${config}$" "$CONFIG_FILE" 2>/dev/null; then
            log_info "第 $item_num 项: ✅ $config"
            ((found++))
        else
            log_warning "第 $item_num 项: ❌ $config（.config中未找到）"
            ((missing++))
        fi
    done
    set -e
    
    log_info "$plugin_name 配置项验证汇总："
    log_info "  总数量: $total"
    log_info "  找到: $found"
    log_info "  缺失: $missing"
    
    if [ $missing -eq 0 ]; then
        log_success "$plugin_name 配置项全部验证通过"
    else
        log_warning "$plugin_name 存在 $missing 个缺失配置项"
        validation_passed=false
    fi
}

# -------------------- 检查配置文件有效性 --------------------
check_config_file() {
    log_step "检查配置文件"
    log_info "目标文件: $CONFIG_FILE"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "配置文件不存在，创建空文件..."
        touch "$CONFIG_FILE" || { log_error "无法创建 $CONFIG_FILE"; return 1; }
    fi
    
    if [ ! -r "$CONFIG_FILE" ]; then
        log_error "配置文件不可读取（权限问题）"
        return 1
    fi
    
    if [ ! -w "$CONFIG_FILE" ]; then
        log_warning "配置文件不可写，后续可能无法添加依赖项"
    fi
    
    if [ -z "$(cat "$CONFIG_FILE" 2>/dev/null)" ]; then
        log_warning "配置文件为空，可能需要手动配置"
    else
        log_success "配置文件有效（行数: $(wc -l < "$CONFIG_FILE")）"
    fi
    return 0
}

# -------------------- 插件依赖配置 --------------------
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
    "CONFIG_PACKAGE_ipset=y"
    "CONFIG_PACKAGE_ip-full=y"
    "CONFIG_PACKAGE_iptables-mod-extra=y"
    "CONFIG_PACKAGE_ruby=y"
    "CONFIG_PACKAGE_ruby-yaml=y"
    "CONFIG_PACKAGE_unzip=y"
    "CONFIG_PACKAGE_luci-compat=y"
    "CONFIG_PACKAGE_luci-base=y"
    "CONFIG_PACKAGE_kmod-inet-diag=y"
)

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
    "CONFIG_PACKAGE_iptables=y"
    "CONFIG_PACKAGE_iptables-mod-tproxy=y"
    "CONFIG_PACKAGE_iptables-mod-socket=y"
    "CONFIG_PACKAGE_kmod-ipt-nat=y"
    "CONFIG_PACKAGE_coreutils=y"
    "CONFIG_PACKAGE_coreutils-base64=y"
    "CONFIG_PACKAGE_coreutils-nohup=y"
    "CONFIG_PACKAGE_curl=y"
    "CONFIG_PACKAGE_ipset=y"
    "CONFIG_PACKAGE_ip-full=y"
    "CONFIG_PACKAGE_luci-compat=y"
    "CONFIG_PACKAGE_luci-lib-jsonc=y"
    "CONFIG_PACKAGE_tcping=y"
    "CONFIG_PACKAGE_dns2socks=y"
    "CONFIG_PACKAGE_ipt2socks=y"
    "CONFIG_PACKAGE_microsocks=y"
)

# -------------------- 注释插件函数 --------------------
comment_config_if_exists() {
    local config_name="$1"
    if grep -q "^CONFIG_PACKAGE_${config_name}=" "$CONFIG_FILE"; then
        sed -i "s/^CONFIG_PACKAGE_${config_name}=.*/# CONFIG_PACKAGE_${config_name} is not set/" "$CONFIG_FILE"
        log_success "已注释掉插件: $config_name"
    else
        log_info "配置 $config_name 不存在，跳过注释"
    fi
}

# -------------------- 主流程 --------------------
main() {
    log_step "开始OpenWrt插件集成与验证流程"
    
    # 调试：验证初始 plugin_count
    log_debug "主流程开始，初始 plugin_count: '$plugin_count'（类型: $(declare -p plugin_count 2>/dev/null)）"
    
    # 启用调试输出
    if [ "$DEBUG_MODE" = "true" ]; then
        log_info "启用调试模式，将输出详细命令执行日志"
        set -x
    fi
    
    # 检查基础环境
    check_config_file || log_warning "配置文件检查有问题，继续执行..."
    
    # -------------------- 注释掉不需要的插件 --------------------
    log_step "注释掉不需要的插件"
    comment_config_if_exists "luci-app-kms"

    # 这里继续 DTS 配置和插件集成...
	
    # DTS设备树配置
    log_step "配置DTS设备树支持"
    if setup_device_tree; then
        log_success "DTS设备树配置完成"
    else
        log_error "DTS设备树配置失败"
        validation_passed=false
    fi
    
    # 添加网络基础配置
    add_network_base_configs
    
    # 创建必要目录
    log_step "创建必要目录"
    mkdir -p "$CUSTOM_PLUGINS_DIR" "package"
    log_debug "创建目录: $CUSTOM_PLUGINS_DIR 和 package"
    
    # 集成插件
    log_step "开始集成插件"
    
    log_step "集成 OpenClash"
    if fetch_plugin "https://github.com/vernesong/OpenClash.git" \
        "luci-app-openclash" "luci-app-openclash" "${OPENCLASH_DEPS[@]}"; then
        log_success "OpenClash 集成流程完成"
    else
        log_error "OpenClash 集成失败，将跳过其验证步骤"
    fi
    
    log_step "集成 Passwall2"
    if fetch_plugin "https://github.com/xiaorouji/openwrt-passwall2.git" \
        "luci-app-passwall2" "." "${PASSWALL2_DEPS[@]}"; then
        log_success "Passwall2 集成流程完成"
    else
        log_error "Passwall2 集成失败，将跳过其验证步骤"
    fi
    
    # 验证插件文件系统（关键步骤，使用安全递增）
    log_step "开始文件系统验证"
    verify_filesystem "luci-app-openclash"
    log_debug "OpenClash 文件系统验证后，plugin_count: $plugin_count"
    
    verify_filesystem "luci-app-passwall2"
    log_debug "Passwall2 文件系统验证后，plugin_count: $plugin_count"
    
    # 验证配置项
    log_step "开始配置项验证"
    if [ -d "package/luci-app-openclash" ]; then
        log_debug "开始验证 OpenClash 配置项，共 ${#OPENCLASH_DEPS[@]} 项"
        verify_configs "OpenClash" "${OPENCLASH_DEPS[@]}"
        log_debug "OpenClash 配置项验证完成"
    else
        log_info "OpenClash 未集成，跳过配置项验证"
    fi
    
    if [ -d "package/luci-app-passwall2" ]; then
        log_debug "开始验证 Passwall2 配置项，共 ${#PASSWALL2_DEPS[@]} 项"
        verify_configs "Passwall2" "${PASSWALL2_DEPS[@]}"
        log_debug "Passwall2 配置项验证完成"
    else
        log_info "Passwall2 未集成，跳过配置项验证"
    fi
    
    # 最终报告
    log_step "流程执行完成，生成报告"
    log_debug "最终 plugin_count: $plugin_count（类型: $(declare -p plugin_count 2>/dev/null)）"
    
    if $validation_passed && [ $plugin_count -gt 0 ]; then
        log_success "🎉 所有验证通过！成功集成 $plugin_count 个插件"
        log_info "DTS配置、网络基础和插件已就绪"
        log_info "建议执行: make defconfig && make menuconfig 确认配置，然后 make -j\$(nproc) V=s 编译"
        exit 0
    elif [ $plugin_count -gt 0 ]; then
        log_warning "⚠️  部分验证未通过，但成功集成 $plugin_count 个插件"
        log_info "可以尝试继续编译，或根据警告修复问题"
        exit 0
    else
        log_error "❌ 所有插件集成失败"
        log_info "修复建议："
        log_info "1. 检查网络连接（尤其是GitHub访问）"
        log_info "2. 确认插件仓库地址正确"
        log_info "3. 检查用户权限（是否有权限操作文件）"
        log_info "4. 清理后重试：rm -rf package/luci-app-* target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019-cm520-79f.dts && ./脚本名"
        exit 1
    fi
}

# 启动主流程
main
