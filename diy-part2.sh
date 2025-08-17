#!/bin/bash
# 最終解決方案腳本 v20：提升Shell兼容性，解決罕見的read命令報錯問題

# --- 啟用嚴格模式 ---
set -euo pipefail

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }

# -------------------- 前置條件檢查 --------------------
log_info "正在檢查環境依賴..."
if ! command -v jq > /dev/null; then
    log_error "依賴工具 'jq' 未安裝。請在您的編譯主機上安裝jq（例如：sudo apt-get install jq），然後再運行此腳本。"
fi
log_success "環境依賴檢查通過。"

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=60 --tries=3 --retry-connrefused --connect-timeout=20 -L"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
CUSTOM_PLUGINS_DIR="package/custom"
FILES_DIR="$(pwd)/files"

# -------------------- 步驟 1：定義最終完美的DTS內容 --------------------
# --- 關鍵優化：使用最通用的方式定義多行字符串，以增強Shell兼容性 ---
FINAL_PERFECT_DTS='/dts-v1/;
// SPDX-License-Identifier: GPL-2.0-or-later OR MIT
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
		usb3@8af8800 { status = "okay"; dwc3@8a00000 { #address-cells = <1>; #size-cells = <0>; usb3_port1: port@1 { reg = <1>; #trigger-source-cells = <0; }; usb3_port2: port@2 { reg = <2>; #trigger-source-cells = <0; }; }; };
		crypto@8e3a000 { status = "okay"; };
		watchdog@b017000 { status = "okay"; };
		ess-switch@c000000 { status = "okay"; };
		edma@c080000 { status = "okay"; };
	};
	led_spi { compatible = "spi-gpio"; #address-cells = <1>; #size-cells = <0>; sck-gpios = <&tlmm 40 GPIO_ACTIVE_HIGH>; mosi-gpios = <&tlmm 36 GPIO_ACTIVE_HIGH>; num-chipselects = <0>; led_gpio: led_gpio@0 { compatible = "fairchild,74hc595"; reg = <0>; gpio-controller; #gpio-cells = <2>; registers-number = <1>; spi-max-frequency = <1000000>; }; };
	leds { compatible = "gpio-leds"; usb { label = "blue:usb"; gpios = <&tlmm 10 GPIO_ACTIVE_HIGH>; linux,default-trigger = "usbport"; trigger-sources = <&usb3_port1>, <&usb3_port2>, <&usb2_port1>; }; led_sys: can { label = "blue:can"; gpios = <&tlmm 11 GPIO_ACTIVE_HIGH>; }; wan { label = "blue:wan"; gpios = <&led_gpio 0 GPIO_ACTIVE_LOW>; }; lan1 { label = "blue:lan1"; gpios = <&led_gpio 1 GPIO_ACTIVE_LOW>; }; lan2 { label = "blue:lan2"; gpios = <&led_gpio 2 GPIO_ACTIVE_LOW>; }; wlan2g { label = "blue:wlan2g"; gpios = <&led_gpio 5 GPIO_ACTIVE_LOW>; linux,default-trigger = "phy0tpt"; }; wlan5g { label = "blue:wlan5g"; gpios = <&led_gpio 6 GPIO_ACTIVE_LOW>; linux,default-trigger = "phy1tpt"; }; };
	keys { compatible = "gpio-keys"; reset { label = "reset"; gpios = <&tlmm 18 GPIO_ACTIVE_LOW>; linux,code = <KEY_RESTART>; }; };
};
&blsp_dma { status = "okay"; };
&blsp1_uart1 { status = "okay"; };
&blsp1_uart2 { status = "okay"; };
&cryptobam { status = "okay"; };
&gmac0 { status = "okay"; nvmem-cells = <&macaddr_art_1006>; nvmem-cell-names = "mac-address"; };
&gmac1 { status = "okay"; nvmem-cells = <&macaddr_art_5006>; nvmem-cell-names = "mac-address"; };
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
	mdio_pins: mdio_pinmux { mux_1 { pins = "gpio6"; function = "mdio"; bias-pull-up; }; mux_2 { pins = "gpio7"; function = "mdc"; bias-pull-up; }; };
	nand_pins: nand_pins { pullups { pins = "gpio52", "gpio53", "gpio58", "gpio59"; function = "qpic"; bias-pull-up; }; pulldowns { pins = "gpio54", "gpio55", "gpio56", "gpio57", "gpio60", "gpio61", "gpio62", "gpio63", "gpio64", "gpio65", "gpio66", "gpio67", "gpio68", "gpio69"; function = "qpic"; bias-pull-down; }; };
};
&usb3_ss_phy { status = "okay"; };
&usb3_hs_phy { status = "okay"; };
&usb2_hs_phy { status = "okay"; };
&wifi0 { status = "okay"; nvmem-cell-names = "pre-calibration"; nvmem-cells = <&precal_art_1000>; qcom,ath10k-calibration-variant = "CM520-79F"; };
&wifi1 { status = "okay"; nvmem-cell-names = "pre-calibration"; nvmem-cells = <&precal_art_5000>; qcom,ath10k-calibration-variant = "CM520-79F"; };
'

# -------------------- 步驟 2：寫入DTS文件 --------------------
log_info "正在寫入最終的、預先合併好的DTS文件..."
mkdir -p "$DTS_DIR"
echo "$FINAL_PERFECT_DTS" > "$DTS_FILE"
log_success "DTS文件寫入成功。"

# ... (腳本的其餘部分與v19完全相同，此處省略以保持簡潔) ...
# ... (The rest of the script is identical to v19 and is omitted for brevity) ...

# -------------------- 步驟 3：創建網絡配置文件 --------------------
# (保持不變)
log_info "創建針對 CM520-79F 的網絡配置文件..."
BOARD_DIR="target/linux/ipq40xx/base-files/etc/board.d"
mkdir -p "$BOARD_DIR"
cat > "$BOARD_DIR/02_network" <<'EOF'
#!/bin/sh
. /lib/functions/system.sh
ipq40xx_board_detect() {
	local machine
	machine=$(board_name)
	case "$machine" in
	"mobipromo,cm520-79f")
		ucidef_set_interfaces_lan_wan "eth1" "eth0"
		;;
	esac
}
boot_hook_add preinit_main ipq40xx_board_detect
EOF
log_success "網絡配置文件創建完成"

# -------------------- 步驟 4：設備規則配置 --------------------
# (保持不變)
log_info "配置設備規則..."
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
    log_success "设备规则添加完成"
else
    sed -i 's/IMAGE_SIZE := 32768k/IMAGE_SIZE := 81920k/' "$GENERIC_MK"
    log_info "设备规则已存在，更新IMAGE_SIZE"
fi

# -------------------- 步驟 5：集成插件（零依賴自適應版） --------------------

# --- AdGuardHome集成 ---
log_info "集成AdGuardHome..."
mkdir -p "$FILES_DIR/usr/bin"
mkdir -p "$FILES_DIR/etc/AdGuardHome"
mkdir -p "$FILES_DIR/etc/config"
mkdir -p "$FILES_DIR/etc/init.d"
mkdir -p "$FILES_DIR/etc/hotplug.d/iface"

# 使用jq和備用匹配，確保URL獲取萬無一失
log_info "正在通過API獲取最新的AdGuardHome下載鏈接..."
API_RESPONSE=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest )
ADGUARD_URL=$(echo "$API_RESPONSE" | jq -r '.assets[] | .browser_download_url | select(contains("linux_armv7.tar.gz"))')
if [ -z "$ADGUARD_URL" ]; then
    log_info "未找到armv7版本，嘗試查找通用的arm版本..."
    ADGUARD_URL=$(echo "$API_RESPONSE" | jq -r '.assets[] | .browser_download_url | select(contains("linux_arm.tar.gz"))')
fi

# 在獲取失敗時，明確報錯並終止
if [ -z "$ADGUARD_URL" ]; then
    log_error "通過API獲取AdGuardHome核心下載地址失敗！"
fi

log_success "成功獲取下載鏈接: $ADGUARD_URL"
ADGUARD_TMP_TAR="/tmp/AdGuardHome.tar.gz"
if wget $WGET_OPTS -O "$ADGUARD_TMP_TAR" "$ADGUARD_URL"; then
    log_success "AdGuardHome核心下載成功。"
    TMP_DIR=$(mktemp -d)
    tar -zxf "$ADGUARD_TMP_TAR" -C "$TMP_DIR" --warning=no-unknown-keyword
    ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -n 1)
    if [ -n "$ADG_EXE" ]; then
        log_info "找到核心文件: $ADG_EXE"
        cp "$ADG_EXE" "$FILES_DIR/usr/bin/AdGuardHome"
        chmod +x "$FILES_DIR/usr/bin/AdGuardHome"
        log_success "AdGuardHome核心已成功複製並設置權限。"
    else
        log_error "在解壓的目錄中未找到AdGuardHome可執行文件！"
    fi
    rm -rf "$TMP_DIR" "$ADGUARD_TMP_TAR"
else
    log_error "AdGuardHome核心下載失敗！"
fi

# 創建兼顧安全與閃存壽命的YAML配置文件
log_info "創建安全的AdGuardHome YAML配置文件..."
cat > "$FILES_DIR/etc/AdGuardHome/AdGuardHome.yaml" <<EOF
workdir: /tmp/AdGuardHome
bind_host: 0.0.0.0
bind_port: 3000
users: []
dns:
  bind_host: 0.0.0.0
  port: 53
  upstream_dns:
    - 223.5.5.5
    - 119.29.29.29
  cache_size: 4194304
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
log:
  file: /tmp/AdGuardHome.log
EOF
log_success "YAML配置文件創建完成 。"

# 創建對應的UCI配置文件
log_info "創建AdGuardHome的UCI配置文件..."
cat > "$FILES_DIR/etc/config/adguardhome" <<EOF
config adguardhome 'global'
	option adg_enabled '1'
	option adg_forcedns '0'
	option adg_bin_path '/usr/bin/AdGuardHome'
	option adg_config_path '/etc/AdGuardHome/AdGuardHome.yaml'
EOF
log_success "UCI配置文件創建完成。"

# 創建專業的init.d啟動腳本
log_info "創建AdGuardHome的init.d啟動腳本..."
cat > "$FILES_DIR/etc/init.d/adguardhome" <<'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

CONF_FILE="/etc/AdGuardHome/AdGuardHome.yaml"
BIN_FILE="/usr/bin/AdGuardHome"
WORKDIR="/tmp/AdGuardHome"

validate_config() {
    [ ! -x "$BIN_FILE" ] && { echo "Binary not found or not executable: $BIN_FILE"; return 1; }
    [ ! -f "$CONF_FILE" ] && { echo "Config file not found: $CONF_FILE"; return 1; }
    mkdir -p "$WORKDIR"
    return 0
}

start_service() {
    validate_config || return 1
    ulimit -n 8192
    procd_open_instance
    procd_set_param command "$BIN_FILE" -c "$CONF_FILE" --no-check-update
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod +x "$FILES_DIR/etc/init.d/adguardhome"
log_success "init.d啟動腳本創建完成。"

# 創建智能檢測的hotplug腳本
log_info "創建AdGuardHome的hotplug腳本..."
cat > "$FILES_DIR/etc/hotplug.d/iface/99-adguardhome" <<'EOF'
#!/bin/sh

# 當LAN口就緒時，智能檢測網絡連通性後再啟動AdGuardHome
if [ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "lan" ]; then
    (
        # 循環檢測網絡，最多等待30秒
        RETRY_COUNT=0
        while [ $RETRY_COUNT -lt 15 ]; do
            if ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then
                # 網絡就緒，重啟服務
                /etc/init.d/adguardhome enabled && /etc/init.d/adguardhome restart
                exit 0
            fi
            RETRY_COUNT=$((RETRY_COUNT + 1))
            sleep 2
        done
    ) &
fi
EOF
chmod +x "$FILES_DIR/etc/hotplug.d/iface/99-adguardhome"
log_success "hotplug腳本創建完成。"

# --- sirpdboy插件集成 ---
log_info "集成sirpdboy插件..."
mkdir -p "$CUSTOM_PLUGINS_DIR"
if git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git "$CUSTOM_PLUGINS_DIR/luci-app-partexp"; then
  log_success "sirpdboy插件克隆成功"
else
  log_error "sirpdboy插件克隆失敗"
fi

# -------------------- 步驟 6：最終配置 --------------------
log_info "更新和安裝所有feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

log_info "啟用必要的軟件包..."
# 創建或清空 .config.custom 文件
> .config.custom
echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> .config.custom
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config.custom
echo "CONFIG_PACKAGE_parted=y" >> .config.custom
echo "CONFIG_PACKAGE_resize2fs=y" >> .config.custom
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config.custom
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config.custom
echo "CONFIG_PACKAGE_jq=y" >> .config.custom

# 使用通用的cat命令合併配置 ，增強兼容性
log_info "合併自定義配置..."
cat .config.custom >> .config

log_info "生成最終配置文件..."
make defconfig
log_success "軟件包啟用和依賴處理完成。"

log_success "所有配置完成，準備開始編譯..."
