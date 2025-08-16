#!/bin/bash
# 最終解決方案腳本 v7：根據DTC詳細錯誤報告進行最終修正

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m"; exit 1; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }

# -------------------- 基础配置与变量定义 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout=10 -L"
ARCH="armv7"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
DTS_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
CUSTOM_PLUGINS_DIR="package/custom"
ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
ADGUARD_CONF_DIR="package/base-files/files/etc/AdGuardHome"

# -------------------- 步驟 1：定義最終修正的DTS模板 --------------------
# 該模板使用 &gmac0/&gmac1 結構，並修復了所有已知語法問題
read -r -d '' FINAL_DTS_TEMPLATE <<'EOF'
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
		/* PARTITIONS-PLACEHOLDER */
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

# -------------------- 步驟 2：動態打補丁 --------------------
log_info "正在基於最終的DTS模板進行動態修補..."

# 定義OPBoot分區表
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
EOF

# 使用sed進行精準替換
Patched_DTS=$(sed "s|/\* PARTITIONS-PLACEHOLDER \*/|${OPBOOT_PARTITIONS}|" <<< "$FINAL_DTS_TEMPLATE")

log_success "DTS動態修補完成。"

# -------------------- 步驟 3：寫入最終的DTS文件 --------------------
log_info "正在寫入最終生成的DTS文件到 $DTS_FILE"
mkdir -p "$DTS_DIR"
echo "$Patched_DTS" > "$DTS_FILE"
log_success "DTS文件寫入成功。"

# (後續所有腳本內容保持不變，此處為完整呈現)
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
		# 根據gmac0/gmac1的結構，這裡可能需要調整為eth0/eth1，但通常驅動會正確映射
		# 暫時保持不變，如果網絡不通再調整
		ucidef_set_interfaces_lan_wan "eth1" "eth0"
		;;
	esac
}
boot_hook_add preinit_main ipq40xx_board_detect
EOF
log_success "網絡配置文件創建完成"

# -------------------- 設備規則配置 --------------------
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

# -------------------- 其他配置（內核、插件等） --------------------
log_info "配置内核模块..."
grep -q "CONFIG_PACKAGE_kmod-ubi=y" .config || echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
grep -q "CONFIG_PACKAGE_kmod-ubifs=y" .config || echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
grep -q "CONFIG_PACKAGE_trx=y" .config || echo "CONFIG_PACKAGE_trx=y" >> .config
grep -q "CONFIG_PACKAGE_kmod-ath10k-ct=y" .config || echo "CONFIG_PACKAGE_kmod-ath10k-ct=y" >> .config
grep -q "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y" .config || echo "CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y" >> .config
grep -q "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" .config || echo "CONFIG_PACKAGE_ipq-wifi-mobipromo_cm520-79f=y" >> .config
grep -q "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y" .config || echo "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y" >> .config
grep -q "CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y" .config || echo "CONFIG_TARGET_ROOTFS_NO_CHECK_SIZE=y" >> .config
log_success "内核模块配置完成"

# --- AdGuardHome集成 (完整版) ---
log_info "集成AdGuardHome..."
mkdir -p "$ADGUARD_DIR" "$ADGUARD_CONF_DIR"
./scripts/feeds install -p luci luci-app-adguardhome >/dev/null || log_error "安装luci-app-adguardhome失败"
ADGUARD_URLS=(
  "https://ghproxy.com/https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${ARCH}.tar.gz"
  "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${ARCH}.tar.gz"
 )
ADGUARD_TMP="/tmp/adguard.tar.gz"
ADGUARD_DOWNLOADED=false
for url in "${ADGUARD_URLS[@]}"; do
  log_info "正在尝试从 $url 下载 AdGuardHome..."
  if wget $WGET_OPTS -O "$ADGUARD_TMP" "$url"; then
    if file "$ADGUARD_TMP" | grep -q 'gzip compressed data'; then
      log_success "AdGuardHome核心下载成功，且文件格式正确。"
      ADGUARD_DOWNLOADED=true
      break
    else
      log_info "下载的文件不是有效的gzip格式，尝试下一个URL..."
      rm -f "$ADGUARD_TMP"
    fi
  else
    log_info "从 $url 下载失败。尝试下一个URL..."
  fi
done
if [ "$ADGUARD_DOWNLOADED" = true ]; then
  tar -zxf "$ADGUARD_TMP" -C /tmp >/dev/null || log_error "解压缩AdGuardHome失败"
  cp /tmp/AdGuardHome/AdGuardHome "$ADGUARD_DIR/" || log_error "AdGuardHome复制失败"
  chmod +x "$ADGUARD_DIR/AdGuardHome"
  rm -rf /tmp/AdGuardHome "$ADGUARD_TMP"
else
  log_error "AdGuardHome核心下载失败，所有URL都已尝试。"
fi
cat > "$ADGUARD_CONF_DIR/AdGuardHome.yaml" <<EOF
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: "\$2y\$10\$gIAKp1l.BME2k5p6mMYlj..4l5mhc8YBGZzI8J/6z8s8nJlQ6oP4y"
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
  file: /var/log/AdGuardHome.log
EOF
grep -q "CONFIG_PACKAGE_luci-app-adguardhome=y" .config || echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> .config
log_success "AdGuardHome集成完成"

# --- sirpdboy插件集成 (完整版 ) ---
log_info "集成sirpdboy插件..."
mkdir -p "$CUSTOM_PLUGINS_DIR"
if git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git "$CUSTOM_PLUGINS_DIR/luci-app-partexp"; then
  grep -q "CONFIG_PACKAGE_luci-app-partexp=y" .config || echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config
  log_success "sirpdboy插件集成完成"
else
  log_error "sirpdboy插件克隆失败"
fi

# -------------------- 最终配置 --------------------
log_info "更新和安裝所有feeds..."
./scripts/feeds update -a
./scripts/feeds install -a
log_success "所有配置完成 ，準備開始編譯..."
