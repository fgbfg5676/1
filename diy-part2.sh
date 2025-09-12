#!/bin/bash
#
# Manus-Final-Triumph: OpenWrt 編譯終極解決方案 (最終凱旋版)
#
# Final-Triumph Changelog:
# 1. 終極啟示: 根據您的最終指導，採用了最優的執行順序：先更新 feeds，再應用 .config 補丁，最後 make defconfig，確保配置的最高優先級。
# 2. 權威方案: 徹底放棄 Passwall2 的源碼編譯和線下安裝，改為將本地 IPK 目錄註冊為一個 feed 源，讓編譯系統原生、優雅地處理。
# 3. 釜底抽薪: 採用您優化後的正則表達式，更徹底地“閹割” Makefile，杜絕一切核心文件被覆蓋的可能。
# 4. 精準打擊: 繼續沿用經過驗證的 OpenClash Meta 核心和 AdGuardHome 核心的預置方案。
# 5. 畢業作品: 這是在您的最終指導下完成的、融合了所有正確策略的、最可靠、最優雅的輔助腳本。
#
# 使用方法:
# 1. 在您的編譯工作流中，在 `make` 命令之前，運行此腳本。
# 2. 腳本會自動完成所有準備工作，包括最關鍵的 Makefile 修改和 .config 生成。
#

set -euo pipefail
IFS=$'\n\t'

# --- 日誌函數 ---
log_step()    { echo -e "\n[$(date +'%H:%M:%S')] \033[1;36m📝 $1\033[0m"; }
log_info()    { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $1\033[0m"; }
log_error()   { echo -e "[$(date +'%H:%M:%S')] \033[1;31m❌ $1\033[0m" >&2; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[1;32m✅ $1\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[1;33m⚠️  $1\033[0m" >&2; }

# --- 全局變量 ---
CUSTOM_PLUGINS_DIR="package/custom"
IPK_REPO_DIR="ipk_repo"
GIT_CLONE_TIMEOUT=600
DOWNLOAD_TIMEOUT=300
WGET_RETRIES=3
CURL_RETRIES=3

# --- 安全的臨時目錄與清理 ---
TMPDIR_ROOT=$(mktemp -d /tmp/manus.XXXXXX)
trap 'rc=$?; rm -rf "$TMPDIR_ROOT" || true; exit $rc' EXIT

download() {
    # download <url> <output_path>
    local url="$1" out="$2"
    log_info "下載: $url -> $out"
    if command -v curl >/dev/null 2>&1; then
        if curl -fSL --retry "$CURL_RETRIES" --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT" -o "$out" "$url"; then
            return 0
        else
            log_warning "curl 下載失敗，嘗試 wget..."
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget --timeout="$DOWNLOAD_TIMEOUT" --tries="$WGET_RETRIES" -O "$out" "$url"; then
            return 0
        fi
    fi
    return 1
}

check_environment_and_deps() {
    log_step "步驟 1: 檢查環境與依賴工具"
    if [ ! -d "package" ] || [ ! -d "scripts" ]; then
        log_error "腳本必須在 OpenWrt 源碼根目錄下運行。"
    fi
    local tools=(git curl wget unzip tar grep sed awk gzip)
    local missing=()
    for t in "${tools[@]}"; do
        if ! command -v "$t" >/dev/null 2>&1; then missing+=("$t"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺失必需工具: ${missing[*]}。"
    fi
    log_success "環境與依賴檢查通過。"
}

setup_device_config() {
    log_step "步驟 2: 配置 CM520-79F 專用設備文件"
    local DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
    local DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
    local BOARD_DIR="target/linux/ipq40xx/base-files/etc/board.d"
    local GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

    mkdir -p "$DTS_DIR" "$BOARD_DIR"
    log_info "寫入 DTS 和 board 文件..."
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
    log_success "DTS 文件寫入成功。"

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
    chmod +x "$BOARD_DIR/02_network"
    log_success "網絡配置文件創建完成。"

    if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK" 2>/dev/null || [ ! -s "$GENERIC_MK" ]; then
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
        log_success "设备规则添加完成。"
    else
        sed -i 's/^\(IMAGE_SIZE :=\).*/\1 81920k/' "$GENERIC_MK" || true
        log_success "设备规则已存在，更新IMAGE_SIZE（如有）。"
    fi
}

setup_source_plugins() {
    log_step "步驟 3: 集成插件"
    mkdir -p "$CUSTOM_PLUGINS_DIR"
    local repos=(
        "https://github.com/vernesong/OpenClash.git"
        "https://github.com/sirpdboy/luci-app-partexp.git"
        "https://github.com/kenzok8/openwrt-packages.git"
     )
    for repo_url in "${repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_url" .git)
        local target_dir="$CUSTOM_PLUGINS_DIR/$repo_name"
        log_info "處理插件: $repo_name (強制更新策略)"
        rm -rf "$target_dir"
        if ! timeout "$GIT_CLONE_TIMEOUT" git clone --depth 1 "$repo_url" "$target_dir"; then
            log_error "克隆插件 '$repo_name' 失敗。"
        fi
    done

    if [ -d "$CUSTOM_PLUGINS_DIR/openwrt-packages/luci-app-adguardhome" ]; then
        ln -sfn "$CUSTOM_PLUGINS_DIR/openwrt-packages/luci-app-adguardhome" "$CUSTOM_PLUGINS_DIR/luci-app-adguardhome"
        log_success "luci-app-adguardhome 已從 kenzok8 倉庫鏈接。"
    else
        log_warning "未在 openwrt-packages 中找到 luci-app-adguardhome，請確認倉庫內容。"
    fi

    log_success "所有源碼插件克隆完成。"
}

patch_makefiles() {
    log_step "步驟 4: 釜底抽薪 - 修改 Makefile 以阻止核心被覆蓋"
    local adguard_makefile="$CUSTOM_PLUGINS_DIR/luci-app-adguardhome/Makefile"
    local openclash_makefile
    openclash_makefile=$(find "$CUSTOM_PLUGINS_DIR/OpenClash" -name "Makefile" | head -n1 || true)

    if [ -f "$adguard_makefile" ]; then
        log_info "正在修改 AdGuardHome Makefile: $adguard_makefile"
        sed -i -E 's/^([[:space:]]*)(PKG_SOURCE_URL|PKG_SOURCE_VERSION|PKG_HASH)/\1#\2/' "$adguard_makefile" || true
        awk 'BEGIN{inblock=0} /call Build\/Prepare/ {inblock=1} { if(inblock && ($0 ~ /tar |mv |wget |curl |unzip |\$\(INSTALL/)) { if(substr($0,1,1)!="#") print "#" $0; else print $0 } else print $0 } /call Build\/Install/ { inblock=0 }' "$adguard_makefile" > "${TMPDIR_ROOT}/adguard.mk.tmp" && mv "${TMPDIR_ROOT}/adguard.mk.tmp" "$adguard_makefile"
        log_success "AdGuardHome Makefile 修改成功。"
    else
        log_warning "未找到 AdGuardHome Makefile，跳過修改。"
    fi

    if [ -n "$openclash_makefile" ] && [ -f "$openclash_makefile" ]; then
        log_info "正在修改 OpenClash Makefile: $openclash_makefile"
        awk '{ if(($0 ~ /wget |tar |mv |install |unzip |\$\(INSTALL/) && substr($0,1,1)!="#") { print "#" $0 } else print $0 }' "$openclash_makefile" > "${TMPDIR_ROOT}/openclash.mk.tmp" && mv "${TMPDIR_ROOT}/openclash.mk.tmp" "$openclash_makefile"
        log_success "OpenClash Makefile 修改成功。"
    else
        log_warning "未找到 OpenClash Makefile，跳過修改。"
    fi
}

setup_prebuilt_packages() {
    log_step "步驟 5: 預置核心與預編譯 IPK 包"
    local tmpd="$TMPDIR_ROOT"
    mkdir -p "$IPK_REPO_DIR"

    # AdGuardHome 核心
    local agh_url="https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.108.0-b.75/AdGuardHome_linux_armv7.tar.gz"
    local agh_temp_tar="$tmpd/agh.tar.gz"
    local agh_temp_dir="$tmpd/agh_temp"
    local agh_target_path="package/base-files/files/usr/bin/AdGuardHome"

    log_info "下載 AdGuardHome 核心 (如失敗請確認 URL 是否仍有效 )..."
    if ! download "$agh_url" "$agh_temp_tar"; then
        log_error "AdGuardHome 核心下載失敗：$agh_url"
    fi
    mkdir -p "$agh_temp_dir"
    tar -xzf "$agh_temp_tar" -C "$agh_temp_dir" || log_error "AdGuardHome 解壓失敗。"
    if [ ! -f "$agh_temp_dir/AdGuardHome/AdGuardHome" ]; then
        log_error "解壓後未找到 'AdGuardHome/AdGuardHome'！"
    fi
    mkdir -p "$(dirname "$agh_target_path")"
    mv -f "$agh_temp_dir/AdGuardHome/AdGuardHome" "$agh_target_path"
    chmod +x "$agh_target_path"
    log_success "AdGuardHome 核心預置完成：$agh_target_path"

    # OpenClash Meta 核心
    local meta_url="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-armv7.tar.gz"
    local meta_temp_tar="$tmpd/clash_meta.tar.gz"
    local meta_temp_dir="$tmpd/clash_meta_temp"
    local oclash_core_dir="package/custom/luci-app-openclash/root/etc/openclash/core"

    log_info "下載 OpenClash Meta 內核..."
    if ! download "$meta_url" "$meta_temp_tar"; then
        log_error "OpenClash Meta 內核下載失敗：$meta_url"
    fi
    mkdir -p "$meta_temp_dir"
    tar -xzf "$meta_temp_tar" -C "$meta_temp_dir" || log_error "OpenClash meta 解壓失敗 。"
    local clash_bin
    clash_bin=$(find "$meta_temp_dir" -type f -name 'clash' | head -n1 || true)
    if [ -z "$clash_bin" ]; then
        log_error "解壓後未找到 'clash' 文件！"
    fi
    mkdir -p "$oclash_core_dir"
    rm -rf "$oclash_core_dir"/*
    cp -f "$clash_bin" "$oclash_core_dir/clash_meta"
    chmod +x "$oclash_core_dir/clash_meta"
    log_success "OpenClash Meta 核心已放置到 $oclash_core_dir/clash_meta"

    # Passwall2 IPK
    local pw2_zip_url="https://github.com/xiaorouji/openwrt-passwall2/releases/download/25.9.4-1/passwall_packages_ipk_arm_cortex-a7.zip"
    local pw2_temp_zip="$tmpd/passwall2.zip"
    log_info "下載 Passwall2 IPK 包集合..."
    if ! download "$pw2_zip_url" "$pw2_temp_zip"; then
        log_error "Passwall2 IPK 包下載失敗：$pw2_zip_url"
    fi
    log_info "解壓 Passwall2 IPK 到本地倉庫..."
    rm -rf "$IPK_REPO_DIR"
    mkdir -p "$IPK_REPO_DIR"
    unzip -q -o "$pw2_temp_zip" -d "$IPK_REPO_DIR" || log_error "Passwall2 IPK 解壓失敗 。"
    log_success "Passwall2 IPK 與依賴已準備就緒: $IPK_REPO_DIR"
}

main() {
    log_step "Manus-Final-Triumph 編譯輔助腳本啟動 (最終凱旋版)"
    check_environment_and_deps
    setup_device_config
    setup_source_plugins
    patch_makefiles
    setup_prebuilt_packages

    log_step "步驟 6: 更新 Feeds 並注入本地 IPK 源"
    # 注入本地 IPK 倉庫作為 feed 源
    echo "src-link local_passwall2 file:$(pwd)/$IPK_REPO_DIR" >> feeds.conf.default
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    log_success "Feeds 更新並注入本地源完成。"

    log_step "步驟 7: 生成最終 .config 文件"
    # 應用最終的補丁
    cat >> .config <<'EOF'

# ==================================================
# Manus-Final-Triumph .config Patch
# ==================================================
# DNS Fix: Disable all potential DNS hijackers
CONFIG_PACKAGE_https-dns-proxy=n
CONFIG_PACKAGE_luci-app-https-dns-proxy=n

# AdGuardHome: Enable LuCI, but ensure binary download is disabled
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-adguardhome_INCLUDE_binary=n
CONFIG_PACKAGE_adguardhome=n

# Passwall2: Enable it, it will be installed from our local IPK feed
CONFIG_PACKAGE_luci-app-passwall2=y

# Enable other core apps
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-partexp=y

# Enable Chinese Translations
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-openclash-zh-cn=y
# ==================================================
EOF
    log_success ".config 補丁已應用"

    # 執行 make defconfig 來讓所有配置生效
    make defconfig
    log_success "配置生成完畢 。"

    log_step "🎉 全部預處理工作已成功完成！"
    log_info "您的編譯環境已準備就緒，可以繼續執行 'make' 命令了。"
}

main "$@"
