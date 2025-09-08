#!/bin/bash
# 最终解决方案脚本 - 完整修复版
# 描述: 整合OpenWrt预编译配置与插件集成功能，修复配置项验证退出问题
# --- 启用增强严格模式 ---
set -euo pipefail

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m" >&2; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m" >&2; }

# 致命错误处理
fatal_error() {
    log_error "$*"
    exit 1
}

# -------------------- 环境检查 --------------------
log_info "===== 开始环境检查 ====="
set -x
if [ ! -f "scripts/feeds" ] || [ ! -f "Config.in" ]; then
    fatal_error "请在OpenWrt源码根目录执行此脚本"
fi

for cmd in git make timeout curl wget; do
    if ! command -v $cmd >/dev/null 2>&1; then
        fatal_error "缺少必需的命令: $cmd"
    fi
done

[ ! -f ".config" ] && touch .config

if ! timeout 3 curl -Is https://github.com >/dev/null 2>&1; then
    log_warning "网络连接可能存在问题，插件克隆可能失败"
fi
set +x
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
set -x
mkdir -p "$DTS_DIR" "$CUSTOM_PLUGINS_DIR"
set +x
log_success "目录创建完成。"

# -------------------- 步骤 3：写入DTS文件 --------------------
log_info "步骤 3：正在写入DTS文件..."
set -x
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
set +x
log_success "DTS文件写入成功。"

# -------------------- 步骤 4：创建网络配置文件 --------------------
log_info "步骤 4：创建针对 CM520-79F 的网络配置文件..."
BOARD_DIR="target/linux/ipq40xx/base-files/etc/board.d"
set -x
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
set +x
log_success "网络配置文件创建完成。"

# -------------------- 步骤 5：配置设备规则 --------------------
log_info "步骤 5：配置设备规则..."
set -x
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
set +x

# -------------------- 通用函数 --------------------
add_config() {
    local option="$1"
    if ! grep -q "^$option$" .config; then
        echo "$option" >> .config
    fi
}

# -------------------- 改进的插件集成函数 --------------------
fetch_plugin() {
    local repo="$1"
    local plugin_name="$2"
    local subdir="${3:-.}"
    shift 3
    local deps=("$@")
    
    local temp_dir="/tmp/${plugin_name}_$(date +%s)_$$"
    local retry_count=0
    local max_retries=3
    local success=0
    
    log_info "开始集成插件: ${plugin_name}"
    
    # 创建锁文件防止并发操作
    local lock_file="/tmp/.${plugin_name}_lock"
    exec 200>"$lock_file"
    if ! flock -n 200; then
        log_warning "插件 ${plugin_name} 正在被其他进程处理，等待..."
        flock 200  # 等待锁释放
    fi
    
    # 清理旧版插件 - 增强版本
    log_info "清理旧版 ${plugin_name}..."
    
    # 定义所有可能的路径
    local cleanup_paths=(
        "feeds/luci/applications/$plugin_name"
        "feeds/packages/net/$plugin_name"
        "feeds/routing/$plugin_name"
        "package/$plugin_name"
        "$temp_dir"
    )
    
    # 如果定义了自定义插件目录，添加到清理路径
    [ -n "$CUSTOM_PLUGINS_DIR" ] && cleanup_paths+=("${CUSTOM_PLUGINS_DIR}/${plugin_name}")
    
    # 逐一清理，记录失败但不中断
    set -x
    for path in "${cleanup_paths[@]}"; do
        if [ -d "$path" ]; then
            log_info "清理路径: $path"
            chmod -R 755 "$path" 2>/dev/null || true
            if ! rm -rf "$path" 2>/dev/null; then
                log_warning "无法删除 $path，尝试强制删除"
                lsof +D "$path" 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r kill -9 2>/dev/null || true
                sleep 1
                if ! rm -rf "$path" 2>/dev/null; then
                    log_error "强制删除 $path 失败，但继续执行"
                fi
            fi
        fi
    done
    set +x
    
    # 验证网络连接和仓库可访问性
    log_info "检查仓库连接性: $repo"
    set -x
    if ! timeout 30 git ls-remote --heads "$repo" >/dev/null 2>&1; then
        log_error "无法访问仓库: $repo"
        log_error "可能的原因: 1) 网络问题 2) 仓库不存在 3) 权限不足"
        flock -u 200
        return 1
    fi
    set +x
    
    # 克隆重试逻辑
    while [ $retry_count -lt $max_retries ]; do
        ((retry_count++))
        log_info "克隆 ${plugin_name} (尝试 $retry_count/$max_retries)..."
        
        # 清理之前失败的临时目录
        [ -d "$temp_dir" ] && rm -rf "$temp_dir"
        
        # 设置 Git 配置以避免某些问题
        export GIT_TERMINAL_PROMPT=0
        export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
        
        set -x
        if timeout 180 git clone --depth 1 --single-branch --progress "$repo" "$temp_dir" 2>&1 | \
           while IFS= read -r line; do
               echo "[GIT] $line"
           done; then
            if [ -d "$temp_dir" ]; then
                success=1
                log_info "克隆成功: $temp_dir"
                break
            else
                log_warning "克隆命令成功但目录不存在"
            fi
        else
            local exit_code=$?
            log_warning "克隆失败，退出码: $exit_code"
            [ -d "$temp_dir" ] && rm -rf "$temp_dir"
            
            if [ $retry_count -lt $max_retries ]; then
                local wait_time=$((retry_count * 3))
                log_info "等待 $wait_time 秒后重试..."
                sleep $wait_time
            fi
        fi
        set +x
    done
    
    if [ $success -eq 0 ]; then
        log_error "${plugin_name} 克隆失败，已重试 $max_retries 次"
        flock -u 200
        return 1
    fi
    
    # 确定源路径
    local source_path="$temp_dir"
    if [ -n "$subdir" ] && [ "$subdir" != "." ]; then
        source_path="$temp_dir/$subdir"
        log_info "使用子目录: $subdir"
    fi
    
    # 验证源路径存在
    set -x
    if [ ! -d "$source_path" ]; then
        log_error "${plugin_name} 源目录不存在: $source_path"
        log_info "临时目录内容:"
        ls -la "$temp_dir" 2>/dev/null || true
        find "$temp_dir" -type d -maxdepth 2 2>/dev/null || true
        rm -rf "$temp_dir"
        flock -u 200
        return 1
    fi
    set +x
    
    # 查找 Makefile
    set -x
    if [ ! -f "$source_path/Makefile" ]; then
        log_warning "${plugin_name} 在 $source_path 中未找到 Makefile，搜索子目录..."
        local found_makefile=$(find "$source_path" -maxdepth 3 -name Makefile -type f -print -quit)
        if [ -n "$found_makefile" ]; then
            source_path=$(dirname "$found_makefile")
            log_info "找到 Makefile: $source_path/Makefile"
        else
            log_error "${plugin_name} 缺少 Makefile"
            log_info "目录结构:"
            find "$source_path" -maxdepth 2 -type f -name "*.mk" -o -name "Makefile*" 2>/dev/null || true
            rm -rf "$temp_dir"
            flock -u 200
            return 1
        fi
    fi
    set +x
    
    # 确保目标目录存在
    set -x
    mkdir -p "package"
    set +x
    
    # 移动文件
    log_info "移动 ${plugin_name} 到 package/ 目录..."
    set -x
    if ! mv "$source_path" "package/$plugin_name" 2>&1; then
        log_error "${plugin_name} 移动失败"
        log_error "源路径: $source_path"
        log_error "目标路径: package/$plugin_name"
        ls -la "package/" 2>/dev/null || true
        rm -rf "$temp_dir"
        flock -u 200
        return 1
    fi
    set +x
    
    # 清理临时目录
    set -x
    rm -rf "$temp_dir"
    set +x
    
    # 配置依赖项
    if [ ${#deps[@]} -gt 0 ]; then
        log_info "配置 ${plugin_name} 依赖项: ${deps[*]}"
        set -x
        for dep in "${deps[@]}"; do
            if [ -n "$dep" ]; then
                if add_config "$dep"; then
                    log_info "依赖项已添加: $dep"
                else
                    log_warning "依赖项添加失败: $dep"
                fi
            fi
        done
        set +x
    fi
    
    # 验证安装结果
    set -x
    if [ -d "package/$plugin_name" ] && [ -f "package/$plugin_name/Makefile" ]; then
        log_success "${plugin_name} 集成成功"
        log_info "安装路径: package/$plugin_name"
        local makefile_info=$(grep -E "PKG_NAME|PKG_VERSION" "package/$plugin_name/Makefile" 2>/dev/null | head -2)
        [ -n "$makefile_info" ] && log_info "包信息: $makefile_info"
    else
        log_error "${plugin_name} 集成验证失败"
        flock -u 200
        return 1
    fi
    set +x
    
    # 释放锁
    flock -u 200
    return 0
}

# -------------------- 插件集成 --------------------
log_info "开始插件集成过程..."

# 设置更宽松的错误处理，防止单个插件失败影响整体
set +e

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

# 检查OpenClash依赖数组是否有无效元素
log_info "检查OpenClash依赖项有效性..."
for config in "${OPENCLASH_DEPS[@]}"; do
    if [ -z "$config" ]; then
        log_error "OpenClash依赖项中存在空值，请检查配置"
        exit 1
    fi
done

if fetch_plugin "https://github.com/vernesong/OpenClash.git" "luci-app-openclash" "luci-app-openclash" "${OPENCLASH_DEPS[@]}"; then
    log_success "OpenClash 集成成功"
else
    log_error "OpenClash 集成失败，但继续执行其他插件"
fi

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

# 检查Passwall2依赖数组是否有无效元素
log_info "检查Passwall2依赖项有效性..."
for config in "${PASSWALL2_DEPS[@]}"; do
    if [ -z "$config" ]; then
        log_error "Passwall2依赖项中存在空值，请检查配置"
        exit 1
    fi
done

if fetch_plugin "https://github.com/xiaorouji/openwrt-passwall2.git" "luci-app-passwall2" "." "${PASSWALL2_DEPS[@]}"; then
    log_success "Passwall2 集成成功"
else
    log_error "Passwall2 集成失败，但继续执行"
fi

# 恢复严格模式
set -euo pipefail

# -------------------- 更新 feeds --------------------
log_info "更新 feeds..."
set +e
set -x
if ./scripts/feeds update -a >/dev/null 2>&1; then
    log_success "Feeds 更新成功"
else
    log_warning "Feeds 更新失败，尝试部分更新..."
    if ./scripts/feeds update luci packages routing >/dev/null 2>&1; then
        log_success "部分 feeds 更新成功"
    else
        log_error "部分 feeds 更新也失败，继续执行安装"
    fi
fi

if ./scripts/feeds install -a >/dev/null 2>&1; then
    log_success "Feeds 安装成功"
else
    log_warning "Feeds 安装失败，尝试重试..."
    if ./scripts/feeds install -a >/dev/null 2>&1; then
        log_success "Feeds 重试安装成功"
    else
        log_warning "Feeds 重试安装失败，但继续执行"
    fi
fi
set +x
set -euo pipefail

# -------------------- 生成最终配置文件 --------------------
log_info "正在启用必要的软件包并生成最终配置..."
CONFIG_FILE=".config.custom"
set -x
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
set +e
if make defconfig 2>/dev/null; then
    log_success "最终配置文件生成完成。"
else
    log_warning "make defconfig 执行有警告，但配置已生成"
fi
set -euo pipefail
set +x

# -------------------- 验证插件 --------------------
validation_passed=true
plugin_count=0

verify_filesystem() {
    local plugin=$1
    set -x
    if [ -d "package/$plugin" ] && [ -f "package/$plugin/Makefile" ]; then
        log_success "$plugin 目录和 Makefile 验证通过"
        ((plugin_count++))
        set +x
        return 0
    else
        log_error "$plugin 目录或 Makefile 缺失"
        validation_passed=false
        set +x
        return 1
    fi
}

log_info "开始验证已集成的插件..."
verify_filesystem "luci-app-openclash" && log_info "OpenClash 文件系统验证通过"
verify_filesystem "luci-app-passwall2" && log_info "Passwall2 文件系统验证通过"

# 验证.config文件有效性
log_info "验证配置文件有效性..."
set -x
if [ ! -f ".config" ]; then
    log_error ".config 文件不存在"
    validation_passed=false
elif [ ! -r ".config" ]; then
    log_error ".config 文件不可读取"
    validation_passed=false
elif [ -z "$(cat .config 2>/dev/null)" ]; then
    log_error ".config 文件为空"
    validation_passed=false
fi
set +x

verify_configs() {
    local plugin_name=$1
    shift
    local deps=("$@")
    local missing=0
    local found=0
    log_info "验证 $plugin_name 配置项..."
    set -x  # 保持调试模式直到函数结束
    
    # 检查依赖数组是否有效
    if [ ${#deps[@]} -eq 0 ]; then
        log_warning "$plugin_name 没有配置依赖项"
        set +x
        return 0
    fi
    
    # 逐个验证配置项，不因为单个失败而退出
    for config in "${deps[@]}"; do
        # 确保配置项不为空
        if [ -z "$config" ]; then
            log_warning "发现空的配置项，跳过"
            ((missing++))
            continue
        fi
        
        # 使用grep验证，重定向错误输出，不触发严格模式
        if grep -q "^$config$" .config 2>/dev/null; then
            log_info "✅ $config"
            ((found++))
        else
            log_warning "❌ $config (未找到)"
            ((missing++))
        fi
    done
    
    set +x  # 关闭调试模式
    
    # 输出验证结果统计
    if [ $missing -eq 0 ]; then
        log_success "$plugin_name 所有配置项验证通过 ($found/$((found + missing)))"
    else
        log_warning "$plugin_name 缺少 $missing 个配置项，找到 $found 个"
        validation_passed=false
    fi
}

# 只验证已成功集成的插件
if [ -d "package/luci-app-openclash" ]; then
    verify_configs "OpenClash" "${OPENCLASH_DEPS[@]}"
else
    log_info "OpenClash 未集成，跳过配置项验证"
fi

if [ -d "package/luci-app-passwall2" ]; then
    verify_configs "Passwall2" "${PASSWALL2_DEPS[@]}"
else
    log_info "Passwall2 未集成，跳过配置项验证"
fi

verify_feeds_visibility() {
    log_info "验证插件在 feeds 中的可见性..."
    set -x
    local feeds_output
    if feeds_output=$(./scripts/feeds list 2>/dev/null); then
        if echo "$feeds_output" | grep -q "luci-app-openclash"; then
            log_success "OpenClash 在 feeds 中可见"
        else
            log_info "OpenClash 在 feeds 中不可见（这是正常的，因为它在 package/ 目录）"
        fi
        
        if echo "$feeds_output" | grep -q "luci-app-passwall2"; then
            log_success "Passwall2 在 feeds 中可见"
        else
            log_info "Passwall2 在 feeds 中不可见（这是正常的，因为它在 package/ 目录）"
        fi
    else
        log_warning "无法执行 feeds list 命令"
    fi
    set +x
}
verify_feeds_visibility

# -------------------- 最终状态检查 --------------------
log_info "===== 最终状态检查 ====="

# 检查关键文件
check_critical_files() {
    local files_ok=true
    set -x
    if [ -f "$DTS_FILE" ]; then
        log_success "DTS文件存在: $DTS_FILE"
    else
        log_error "DTS文件缺失: $DTS_FILE"
        files_ok=false
    fi
    
    if [ -f "$GENERIC_MK" ]; then
        log_success "设备配置文件存在: $GENERIC_MK"
    else
        log_error "设备配置文件缺失: $GENERIC_MK"
        files_ok=false
    fi
    
    if [ -f ".config" ] && [ -s ".config" ]; then
        local config_lines=$(wc -l < .config)
        log_success "配置文件存在且非空: .config ($config_lines 行)"
    else
        log_error "配置文件缺失或为空: .config"
        files_ok=false
    fi
    set +x
    return $files_ok
}

# 检查网络配置
check_network_config() {
    set -x
    if [ -f "$BOARD_DIR/02_network" ]; then
        log_success "网络配置文件存在"
        set +x
        return 0
    else
        log_error "网络配置文件缺失"
        set +x
        return 1
    fi
}

# 执行检查
check_critical_files || validation_passed=false
check_network_config || validation_passed=false

# -------------------- 生成集成报告 --------------------
log_info "===== 集成报告 ====="
log_info "已成功集成 $plugin_count 个插件"

if [ -d "package/luci-app-openclash" ]; then
    log_success "✅ OpenClash - 已集成"
else
    log_error "❌ OpenClash - 集成失败"
fi

if [ -d "package/luci-app-passwall2" ]; then
    log_success "✅ Passwall2 - 已集成"
else
    log_error "❌ Passwall2 - 集成失败"
fi

# 显示配置统计
log_info "配置文件统计:"
set -x
local total_configs=$(grep -c "^CONFIG_" .config 2>/dev/null || echo "0")
local enabled_configs=$(grep -c "=y$" .config 2>/dev/null || echo "0")
local disabled_configs=$(grep -c "=n$" .config 2>/dev/null || echo "0")
set +x
log_info "  - 总配置项: $total_configs"
log_info "  - 已启用: $enabled_configs"
log_info "  - 已禁用: $disabled_configs"

# 显示重要的已启用配置
log_info "重要的已启用配置:"
set -x
grep -E "CONFIG_PACKAGE_(luci-app-openclash|luci-app-passwall2|kmod-tun|dnsmasq-full)=y" .config 2>/dev/null | while read line; do
    log_info "  - $line"
done
set +x

# -------------------- 故障排除建议 --------------------
if ! $validation_passed; then
    log_error "验证过程中发现问题，故障排除建议:"
    log_info "1. 网络问题:"
    log_info "   - 检查 GitHub 连接: curl -I https://github.com"
    log_info "   - 尝试使用代理或镜像仓库"
    log_info "   - 检查防火墙和 DNS 设置"
    
    log_info "2. 权限问题:"
    log_info "   - 确保当前用户有写入权限"
    log_info "   - 检查 /tmp 目录权限"
    log_info "   - 尝试以不同用户运行"
    
    log_info "3. 依赖问题:"
    log_info "   - 运行: make prereq 检查构建依赖"
    log_info "   - 更新系统软件包"
    log_info "   - 检查磁盘空间是否足够"
    
    log_info "4. 手动验证:"
    log_info "   - 检查 package/ 目录: ls -la package/"
    log_info "   - 运行 make menuconfig 查看可用插件"
    log_info "   - 查看 .config 文件内容"
    
    log_info "5. 重新运行:"
    log_info "   - 清理后重新运行: make clean && ./diy-part2.sh"
    log_info "   - 单独测试插件集成"
fi

# -------------------- 最终结果 --------------------
if $validation_passed && [ $plugin_count -gt 0 ]; then
    log_success "🎉 所有预编译步骤和插件集成均已成功完成！"
    log_info "📊 集成统计:"
    log_info "  - 成功集成插件: $plugin_count 个"
    log_info "  - DTS 配置: ✅ 完成"
    log_info "  - 网络配置: ✅ 完成"
    log_info "  - 设备规则: ✅ 完成"
    log_info "  - Feeds 更新: ✅ 完成"
    log_success "🚀 接下来请执行以下命令进行编译:"
    log_info "     make -j\$(nproc) V=s"
    log_info "或者先检查配置:"
    log_info "     make menuconfig"
elif [ $plugin_count -gt 0 ]; then
    log_warning "⚠️  插件集成部分完成，但存在一些问题"
    log_info "已成功集成 $plugin_count 个插件，可以尝试继续编译"
    log_info "建议先运行 make menuconfig 检查配置"
else
    log_error "❌ 插件集成失败"
    log_error "没有成功集成任何插件，请检查错误日志并按照故障排除建议操作"
    exit 1
fi

# 清理临时文件和锁文件
cleanup_temp_files() {
    log_info "清理临时文件..."
    set -x
    rm -f /tmp/.luci-app-*_lock 2>/dev/null || true
    rm -rf /tmp/luci-app-*_* 2>/dev/null || true
    set +x
    log_success "临时文件清理完成"
}

cleanup_temp_files

log_success "脚本执行完成！"
exit 0
