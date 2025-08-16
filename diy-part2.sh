#!/bin/bash
# 最終解決方案腳本 v3：基於Lean DTS並動態打補丁

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }

# -------------------- 基础配置与变量定义 --------------------
# (基础配置保持不變)
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout=10 -L"
ARCH="armv7"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
CUSTOM_PLUGINS_DIR="package/custom"

# -------------------- 關鍵步驟 1：定義Lean的DTS為模板 --------------------
read -r -d '' LEAN_DTS_TEMPLATE <<'EOF'
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
		tcsr@1949000 { compatible = "qcom,tcsr"; reg = <0x1949000 0x100>; qcom,wifi_glb_cfg = <TCSR_WIFI_GLB_CFG>; };
		tcsr@194b000 { compatible = "qcom,tcsr"; reg = <0x194b000 0x100>; qcom,usb-hsphy-mode-select = <TCSR_USB_HSPHY_HOST_MODE>; };
		ess_tcsr@1953000 { compatible = "qcom,tcsr"; reg = <0x1953000 0x1000>; qcom,ess-interface-select = <TCSR_ESS_PSGMII>; };
		tcsr@1957000 { compatible = "qcom,tcsr"; reg = <0x1957000 0x100>; qcom,wifi_noc_memtype_m0_m2 = <TCSR_WIFI_NOC_MEMTYPE_M0_M2>; };
		usb2@60f8800 {
			status = "okay";
			dwc3@6000000 { #address-cells = <1>; #size-cells = <0>; usb2_port1: port@1 { reg = <1>; #trigger-source-cells = <0; }; };
		};
		usb3@8af8800 {
			status = "okay";
			dwc3@8a00000 { #address-cells = <1>; #size-cells = <0>; usb3_port1: port@1 { reg = <1>; #trigger-source-cells = <0; }; usb3_port2: port@2 { reg = <2>; #trigger-source-cells = <0; }; };
		};
		crypto@8e3a000 { status = "okay"; };
		watchdog@b017000 { status = "okay"; };
		ess-switch@c000000 { status = "okay"; };
		edma@c080000 { status = "okay"; };
	};

	led_spi {
		compatible = "spi-gpio"; #address-cells = <1>; #size-cells = <0>;
		sck-gpios = <&tlmm 40 GPIO_ACTIVE_HIGH>; mosi-gpios = <&tlmm 36 GPIO_ACTIVE_HIGH>; num-chipselects = <0>;
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

	keys {
		compatible = "gpio-keys";
		reset { label = "reset"; gpios = <&tlmm 18 GPIO_ACTIVE_LOW>; linux,code = <KEY_RESTART>; };
	};
};

&blsp_dma { status = "okay"; };
&blsp1_uart1 { status = "okay"; };
&blsp1_uart2 { status = "okay"; };
&cryptobam { status = "okay"; };

&gmac0 {
	nvmem-cells = <&macaddr_art_1006>;
	nvmem-cell-names = "mac-address";
};

&gmac1 {
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

			partition@0 { label = "SBL1"; reg = <0x0 0x100000>; read-only; };
			partition@100000 { label = "MIBIB"; reg = <0x100000 0x100000>; read-only; };
			partition@200000 { label = "BOOTCONFIG"; reg = <0x200000 0x100000>; };
			partition@300000 { label = "QSEE"; reg = <0x300000 0x100000>; read-only; };
			partition@400000 { label = "QSEE_1"; reg = <0x400000 0x100000>; read-only; };
			partition@500000 { label = "CDT"; reg = <0x500000 0x80000>; read-only; };
			partition@580000 { label = "CDT_1"; reg = <0x580000 0x80000>; read-only; };
			partition@600000 { label = "BOOTCONFIG1"; reg = <0x600000 0x80000>; };
			partition@680000 { label = "APPSBLENV"; reg = <0x680000 0x80000>; };
			partition@700000 { label = "APPSBL"; reg = <0x700000 0x200000>; read-only; };
			partition@900000 { label = "APPSBL_1"; reg = <0x900000 0x200000>; read-only; };
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

# -------------------- 關鍵步驟 2：動態打補丁 --------------------
log_info "正在基於Lean的DTS模板進行動態修補..."

# 補丁1：替換為適用於OPBoot的簡潔分區表
# 我們先定義好OPBoot的分區表內容
read -r -d '' OPBOOT_PARTITIONS <<'EOF'
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

				precal_art_1000: precal@1000 {
					reg = <0x1000 0x2f20>;
				};

				macaddr_art_1006: macaddr@1006 {
					reg = <0x1006 0x6>;
				};

				precal_art_5000: precal@5000 {
					reg = <0x5000 0x2f20>;
				};

				macaddr_art_5006: macaddr@5006 {
					reg = <0x5006 0x6>;
				};
			};

			partition@b80000 {
				label = "rootfs";
				reg = <0xb80000 0x7480000>;
			};
		};
EOF

# 使用awk來實現精準替換&nand節點中的partitions內容
Patched_DTS=$(awk -v opboot_part="${OPBOOT_PARTITIONS}" '
  BEGIN {p=1}
  /&nand/,/};/ {
    if (/\&nand/) {
      print;
      next;
    }
    if (/partitions/) {
      if (p) {
        print opboot_part;
        p=0
      }
      next;
    }
    if (p==0 && /};/) {
      p=1
    }
    if (p==0) {
      next;
    }
  }
  {print}
' <<< "$LEAN_DTS_TEMPLATE")

# 補丁2：將gmac0/gmac1的定義方式替換為gmac/switch（如果需要）
# 根據之前的錯誤，我們推斷當前環境可能需要gmac/switch的方式
read -r -d '' GMAC_SWITCH_PATCH <<'EOF'
&gmac {
	status = "okay";
	nvmem-cells = <&macaddr_art_1006>;
	nvmem-cell-names = "mac-address";
};

&switch {
	status = "okay";
};

&swport3 {
	status = "okay";
	label = "lan2";
};

&swport4 {
	status = "okay";
	label = "lan1";
};

&swport5 {
	status = "okay";
	nvmem-cells = <&macaddr_art_5006>;
	nvmem-cell-names = "mac-address";
};
EOF

# 刪除gmac0和gmac1，並插入新的定義
Patched_DTS=$(echo "$Patched_DTS" | sed '/&gmac0 {/,/};/d' | sed '/&gmac1 {/,/};/d')
Patched_DTS=$(echo "$Patched_DTS" | sed '/&cryptobam { status = "okay"; };/a\'$'\n'"${GMAC_SWITCH_PATCH}")

log_success "DTS動態修補完成。"

# -------------------- 關鍵步驟 3：寫入最終的DTS文件 --------------------
log_info "正在寫入最終生成的DTS文件到 $DTS_FILE"
mkdir -p "$DTS_DIR"
echo "$Patched_DTS" > "$DTS_FILE"
log_success "DTS文件寫入成功。"

# -------------------- 創建網絡配置文件 --------------------
log_info "創建針對 CM520-79F 的網絡配置文件..."
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
log_success "網絡配置文件創建完成"

# -------------------- 設備規則配置 --------------------
log_info "配置設備規則..."
# (此部分保持不變)
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

# -------------------- 其他配置（內核、插件等） --------------------
# (此部分保持不變)
log_info "配置内核模块..."
grep -q "CONFIG_PACKAGE_kmod-ubi=y" .config || echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
grep -q "CONFIG_PACKAGE_kmod-ubifs=y" .config || echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
# ... 其他内核配置 ...
log_success "内核模块配置完成"

log_info "集成AdGuardHome..."
# ... AdGuardHome集成代码 ...
log_success "AdGuardHome集成完成"

log_info "集成sirpdboy插件..."
# ... sirpdboy插件集成代码 ...
log_success "sirpdboy插件集成完成"

# -------------------- 最终配置 --------------------
log_info "更新和安裝所有feeds..."
./scripts/feeds update -a
./scripts/feeds install -a
log_success "所有配置完成，準備開始編譯..."
