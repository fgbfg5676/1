#!/bin/bash
#
# Manus-V1.9: OpenWrt 雲編譯一站式解決方案 (最終完整版)
#
# V1.9 更新日誌:
# 1. 恢復權限檢查: 根據您的要求，在 chmod 命令後恢復了對核心文件和軟鏈接的權限驗證提示。
# 2. 邏輯完整性: 確保所有文件操作、權限設置和後續驗證的流程完整且順序正確。
#
# 使用方法:
# 1. 將此腳本保存為 manus_build.sh。
# 2. 放置於 OpenWrt 源碼根目錄下。
# 3. 執行 chmod +x manus_build.sh。
# 4. 執行 ./manus_build.sh。
# 5. 腳本成功執行後，運行 make -j$(nproc) 開始編譯。
#

# --- 嚴格模式 ---
set -euo pipefail

# --- 日誌函數 ---
log_step() { echo -e "\n[$(date +'%H:%M:%S')] \033[1;36m📝 $1\033[0m"; }
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $1\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[1;31m❌ $1\033[0m" >&2; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[1;32m✅ $1\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[1;33m⚠️  $1\033[0m" >&2; }

# --- 全局變量 ---
CUSTOM_PLUGINS_DIR="package/custom"
GIT_CLONE_TIMEOUT=600 # 10 分鐘
DOWNLOAD_TIMEOUT=300  # 5 分鐘

# =================================================================
# 步驟 1: 環境與依賴檢查
# =================================================================
check_environment_and_deps() {
    log_step "步驟 1: 檢查環境與依賴工具"
    if [ ! -d "package" ] || [ ! -d "scripts" ]; then
        log_error "腳本必須在 OpenWrt 源碼根目錄下運行。請檢查當前路徑。"
    fi

    local tools=("git" "curl" "wget" "unzip" "grep" "sed" "awk" "gzip")
    local missing=()
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺失必需工具: ${missing[*]}。請先安裝它們。"
    fi
    log_success "環境與依賴檢查通過。"
}

# =================================================================
# 步驟 2: 設備特定配置 (CM520-79F)
# =================================================================
setup_device_config() {
    log_step "步驟 2: 配置 CM520-79F 專用設備文件"

    local DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
    local DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
    mkdir -p "$DTS_DIR"
    cat > "$DTS_FILE" <<'EOF'
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
    log_success "DTS 文件寫入成功: $DTS_FILE"

    local BOARD_DIR="target/linux/ipq40xx/base-files/etc/board.d"
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
    log_success "網絡配置文件創建完成: $BOARD_DIR/02_network"

    local GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
    if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
        cat <<'EOF' >> "$GENERIC_MK"

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
        log_success "設備規則已添加至 $GENERIC_MK"
    else
        sed -i 's/IMAGE_SIZE := .*/IMAGE_SIZE := 81920k/' "$GENERIC_MK"
        log_success "設備規則已存在，IMAGE_SIZE 已更新為 81920k。"
    fi
}

# =================================================================
# 步驟 3: 集成插件 (增強網絡版)
# =================================================================
clone_repo() {
    local repo_url="$1"
    local repo_name=$(basename "$repo_url" .git)
    local target_dir="$CUSTOM_PLUGINS_DIR/$repo_name"
    
    if [ -d "$target_dir" ]; then
        log_warning "插件 '$repo_name' 已存在，跳過克隆。"
        return
    fi

    local mirrors=(
        "https://ghproxy.com/${repo_url}"
        "https://gitclone.com/${repo_url}"
        "https://github.moeyy.xyz/${repo_url}"
        "${repo_url}"
     )

    log_info "正在克隆插件: $repo_name"
    local success=false
    for mirror in "${mirrors[@]}"; do
        log_info "嘗試使用鏡像: ${mirror} ..."
        if timeout "$GIT_CLONE_TIMEOUT" git clone --depth 1 "$mirror" "$target_dir"; then
            log_success "使用鏡像 '${mirror}' 克隆成功。"
            success=true
            break
        else
            log_warning "使用鏡像 '${mirror}' 克隆失敗。"
            rm -rf "$target_dir"
        fi
    done

    if [ "$success" = false ]; then
        log_error "克隆插件 '$repo_name' 徹底失敗，所有鏡像均無效。"
    fi
}

setup_plugins() {
    log_step "步驟 3: 集成自定義插件 (OpenClash, Passwall2, Partexp)"
    mkdir -p "$CUSTOM_PLUGINS_DIR"
    
    clone_repo "https://github.com/vernesong/OpenClash.git"
    clone_repo "https://github.com/xiaorouji/openwrt-passwall2.git"
    clone_repo "https://github.com/sirpdboy/luci-app-partexp.git"
    
    log_success "所有插件倉庫克隆完成 。"
}

# =================================================================
# 步驟 4: 為 OpenClash 準備 Mihomo 核心
# =================================================================
setup_openclash_core() {
    log_step "步驟 4: 從指定源為 OpenClash 下載並放置 Mihomo 核心"
    
    local url="https://raw.githubusercontent.com/fgbfg5676/1/main/mihomo-linux-armv7-v1.19.13.gz"
    local temp_gz="/tmp/mihomo.gz"
    local temp_bin="/tmp/mihomo_core_unzipped"
    
    log_info "嘗試從您的指定源下載: $url"
    if ! wget --timeout="$DOWNLOAD_TIMEOUT" -O "$temp_gz" "$url"; then
        log_error "Mihomo 核心下載失敗 ，請檢查您的倉庫鏈接和文件是否存在。"
    fi
    
    log_info "下載成功，正在解壓核心文件..."
    if ! gzip -dc "$temp_gz" > "$temp_bin"; then
        log_error "核心文件解壓失敗。"
    fi
    rm -f "$temp_gz"
    
    if [ ! -s "$temp_bin" ]; then
        log_error "解壓後的核心文件為空或不存在。"
    fi

    local OPENCLASH_CORE_DIR="$CUSTOM_PLUGINS_DIR/luci-app-openclash/root/etc/openclash/core"
    mkdir -p "$OPENCLASH_CORE_DIR"
    
    # --- 最終正確的操作順序 ---
    
    # 1. 移動文件到目標位置
    log_info "正在放置核心文件到 $OPENCLASH_CORE_DIR"
    mv "$temp_bin" "$OPENCLASH_CORE_DIR/clash_meta"
    
    # 2. 創建指向已存在文件的軟鏈接
    log_info "創建軟鏈接 clash -> clash_meta..."
    ln -sf "$OPENCLASH_CORE_DIR/clash_meta" "$OPENCLASH_CORE_DIR/clash"

    # 3. 在文件和鏈接都存在後，一次性賦予權限
    log_info "正在為核心文件和鏈接設置執行權限..."
    chmod +x "$OPENCLASH_CORE_DIR/clash_meta" "$OPENCLASH_CORE_DIR/clash"

    # 4. 恢復您指定的權限檢查提示
    # --- 权限检查提示 ---
    if [ -x "$OPENCLASH_CORE_DIR/clash_meta" ] && [ -x "$OPENCLASH_CORE_DIR/clash" ]; then
        log_success "核心文件和软链接执行权限验证通过 ✅"
    else
        log_warning "⚠️ 核心文件或软链接权限验证失败，请手动检查！"
    fi

    log_success "OpenClash 的 Mihomo 核心已成功配置！"
}

# =================================================================
# 步驟 5: 生成最終 .config 文件
# =================================================================
generate_final_config() {
    log_step "步驟 5: 生成最終 .config 配置文件"
    
    rm -f .config .config.old
    
    cat > .config <<EOF
#
# Target
#
CONFIG_TARGET_ipq40xx=y
CONFIG_TARGET_ipq40xx_generic=y
CONFIG_TARGET_DEVICE_ipq40xx_generic_DEVICE_mobipromo_cm520-79f=y
CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y

#
# Base system
#
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_wget=y
CONFIG_PACKAGE_unzip=y
CONFIG_PACKAGE_coreutils=y
CONFIG_PACKAGE_coreutils-nohup=y
CONFIG_PACKAGE_ca-certificates=y
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ipset=y
CONFIG_PACKAGE_iptables-nft=y
CONFIG_PACKAGE_jsonfilter=y
CONFIG_PACKAGE_ruby=y
CONFIG_PACKAGE_ruby-yaml=y

#
# Kernel modules
#
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_kmod-ipt-nat=y
CONFIG_PACKAGE_kmod-ipt-core=y
CONFIG_PACKAGE_kmod-ipt-conntrack=y
CONFIG_PACKAGE_kmod-ipt-socket=y
CONFIG_PACKAGE_kmod-ipt-tproxy=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-nft-socket=y
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-scsi-generic=y
CONFIG_PACKAGE_kmod-fs-ext4=y

#
# LuCI
#
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_luci-compat=y

#
# LuCI Applications (The Trio)
#
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-i18n-openclash-zh-cn=y
CONFIG_PACKAGE_luci-app-passwall2=y
CONFIG_PACKAGE_luci-i18n-passwall2-zh-cn=y
CONFIG_PACKAGE_luci-app-partexp=y

#
# Passwall2 Dependencies
#
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_haproxy=y
CONFIG_PACKAGE_hysteria=y
CONFIG_PACKAGE_v2ray-geoip=y
CONFIG_PACKAGE_v2ray-geosite=y
CONFIG_PACKAGE_tcping=y

#
# Partexp Dependencies
#
CONFIG_PACKAGE_parted=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_fdisk=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_e2fsprogs=y

#
# WiFi Drivers (Standard, not CT)
#
CONFIG_PACKAGE_kmod-ath10k=y
CONFIG_PACKAGE_ath10k-firmware-qca4019=y
EOF

    log_info "正在更新和安裝 feeds..."
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    
    log_info "正在生成最終 defconfig..."
    make defconfig
    
    log_success ".config 文件已生成！"
}

# =================================================================
# 主執行函數
# =================================================================
main() {
    log_step "Manus-V1.9 編譯準備腳本啟動"
    
    check_environment_and_deps
    setup_device_config
    setup_plugins
    setup_openclash_core
    generate_final_config
    
    log_step "🎉 全部準備工作已成功完成！"
    log_info "現在您可以運行 'make -j\$(nproc)' 來開始編譯固件了。"
    log_info "如果需要自定義更多選項，請運行 'make menuconfig'。"
}

# --- 執行主函數 ---
main "$@"
