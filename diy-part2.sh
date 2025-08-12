#!/bin/bash
#
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Target: CM520-79F (IPQ40xx, ARMv7)
#

# -------------------- 基礎配置與變量定義 --------------------
WGET_OPTS="-q --timeout=30 --tries=3 --retry-connrefused --connect-timeout 10"
ARCH="armv7"

ADGUARD_DIR="package/luci-app-adguardhome/root/usr/bin"
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"

# Nikki 源配置
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"

mkdir -p "$ADGUARD_DIR" "$DTS_DIR"

# -------------------- 內核模塊與工具配置 --------------------
echo "CONFIG_PACKAGE_kmod-ubi=y" >> .config
echo "CONFIG_PACKAGE_kmod-ubifs=y" >> .config
echo "CONFIG_PACKAGE_trx=y" >> .config

# -------------------- 集成 Nikki 源 --------------------
echo "集成 Nikki 源..."

# 檢查是否已經添加了Nikki源
if ! grep -q "nikki.*$NIKKI_FEED" feeds.conf.default 2>/dev/null; then
    echo "添加 Nikki 源到 feeds.conf.default"
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default
else
    echo "Nikki 源已存在，跳過添加"
fi

# 更新和安裝Nikki源
echo "更新 Nikki 源..."
if ./scripts/feeds update nikki; then
    echo "Nikki 源更新成功"
else
    echo "警告：Nikki 源更新失敗，但繼續執行"
fi

echo "安裝 Nikki 包..."
if ./scripts/feeds install -a -p nikki; then
    echo "Nikki 包安裝成功"
else
    echo "警告：Nikki 包安裝失敗，但繼續執行"
fi

# 啟用Nikki包
echo "啟用 Nikki 配置..."
if ! grep -q "^CONFIG_PACKAGE_nikki=y" .config; then
    echo "CONFIG_PACKAGE_nikki=y" >> .config
fi
if ! grep -q "^CONFIG_PACKAGE_luci-app-nikki=y" .config; then
    echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
fi

echo "Nikki 集成完成"

# -------------------- DTS補丁處理 (保持原封不動) --------------------
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/qcom-ipq4019-cm520-79f.dts.patch"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"

echo "Downloading DTS patch..."
wget $WGET_OPTS -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL"
if [ ! -f "$TARGET_DTS" ]; then
    echo "Applying DTS patch..."
    patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE"
fi

# -------------------- 設備規則配置 --------------------
if ! grep -q "define Device/mobipromo_cm520-79f" "$GENERIC_MK"; then
    echo "Adding CM520-79F device rule..."
    cat <<EOF >> "$GENERIC_MK"

define Device/mobipromo_cm520-79f
  DEVICE_VENDOR := MobiPromo
  DEVICE_MODEL := CM520-79F
  DEVICE_DTS := qcom-ipq4019-cm520-79f
  KERNEL_SIZE := 4096k
  ROOTFS_SIZE := 16384k
  IMAGE_SIZE := 32768k
  IMAGE/trx := append-kernel | pad-to \$$(KERNEL_SIZE) | append-rootfs | trx -o \$\@
endef
TARGET_DEVICES += mobipromo_cm520-79f
EOF
fi

# -------------------- 集成AdGuardHome核心 --------------------
echo "開始集成AdGuardHome核心..."

# 清理歷史文件
rm -rf "$ADGUARD_DIR/AdGuardHome" "$ADGUARD_DIR/AdGuardHome.tar.gz"

# 下載AdGuardHome核心
ADGUARD_URL=$(curl -s --retry 3 --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest |\
              grep "browser_download_url.*linux_armv7" |\
              cut -d \"\" -f 4)

if [ -n "$ADGUARD_URL" ]; then
    echo "下載AdGuardHome: $ADGUARD_URL"
    if wget $WGET_OPTS -O "$ADGUARD_DIR/AdGuardHome.tar.gz" "$ADGUARD_URL"; then
        # 解壓到臨時目錄，查看實際目錄結構
        TMP_DIR=$(mktemp -d)
        tar -zxf "$ADGUARD_DIR/AdGuardHome.tar.gz" -C "$TMP_DIR" --warning=no-unknown-keyword
        
        # 查找解壓後的AdGuardHome可執行文件路徑（兼容不同目錄結構）
        ADG_EXE=$(find "$TMP_DIR" -name "AdGuardHome" -type f | head -n 1)
        if [ -n "$ADG_EXE" ]; then
            # 複製可執行文件到目標目錄
            cp "$ADG_EXE" "$ADGUARD_DIR/"
            chmod +x "$ADGUARD_DIR/AdGuardHome"
            echo "AdGuardHome核心複製成功"
        else
            echo "警告：未找到AdGuardHome可執行文件"
        fi
        
        # 清理臨時文件
        rm -rf "$TMP_DIR" "$ADGUARD_DIR/AdGuardHome.tar.gz"
    else
        echo "警告：AdGuardHome下載失敗"
    fi
else
    echo "警告：未找到AdGuardHome核心地址"
fi

echo "AdGuardHome核心集成完成"

# -------------------- AdGuardHome LuCI 識別與配置 --------------------
# 創建 /etc/config/adguardhome，用於 LuCI 識別 (用戶要求保留)
mkdir -p "package/base-files/files/etc/config"
cat > "package/base-files/files/etc/config/adguardhome" <<EOF
config adguardhome 'main'
    option enabled '0'
    option binpath '/usr/bin/AdGuardHome'
    option configpath '/etc/AdGuardHome/AdGuardHome.yaml'
    option workdir '/etc/AdGuardHome'
EOF

# 創建 AdGuardHome 工作目錄，用於存放 AdGuardHome.yaml
mkdir -p "package/base-files/files/etc/AdGuardHome"

# 確保 luci-app-adguardhome 被啟用 (如果它沒有被設置的話)
if ! grep -q "^CONFIG_PACKAGE_luci-app-adguardhome=y" .config; then
    echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> .config
fi

# -------------------- dnsmasq 配置 (禁用 DNS 功能，保留 DHCP) --------------------
# 創建或修改 /etc/config/dhcp 文件
mkdir -p "package/base-files/files/etc/config"
cat > "package/base-files/files/etc/config/dhcp" <<EOF
config dnsmasq 'main'
    option domainneeded '1'
    option boguspriv '1'
    option filterwin2k '0'
    option localise_queries '1'
    option rebind_protection '1'
    option rebind_localhost '1'
    option local '/lan/'
    option domain 'lan'
    option expandhosts '1'
    option authoritative '1'
    option readethers '1'
    option leasefile '/tmp/dhcp.leases'
    option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
    option nonwildcard '1'
    option localservice '1'
    option noresolv '1'
    list server '127.0.0.1#5353'

config dhcp 'lan'
    option interface 'lan'
    option start '100'
    option limit '150'
    option leasetime '12h'
    option dhcpv4 'server'
    option dhcpv6 'server'
    option ra 'server'
    option ra_management '1'
    list dns '192.168.1.1' # 請替換為你的路由器實際的 LAN IP 地址

config dhcp 'wan'
    option interface 'wan'
    option ignore '1'

config odhcpd 'main'
    option maindhcp '0'
    option leasefile '/tmp/hosts/odhcpd'
    option leasetrigger '/usr/sbin/odhcpd-update'
    option loglevel '4'
EOF

# -------------------- firewall4/nftables 適配 --------------------
# 創建 /etc/firewall.user 文件，添加 DNS 重定向規則
mkdir -p "package/base-files/files/etc"
cat > "package/base-files/files/etc/firewall.user" <<EOF
# AdGuardHome DNS Redirect (LAN)
nft add rule ip nat prerouting iifname lan tcp dport 53 dnat to 127.0.0.1:5353
nft add rule ip nat prerouting iifname lan udp dport 53 dnat to 127.0.0.1:5353

# AdGuardHome DNS Redirect (Router)
nft add rule ip nat prerouting iifname wan tcp dport 53 dnat to 127.0.0.1:5353
nft add rule ip nat prerouting iifname wan udp dport 53 dnat to 127.0.0.1:5353
EOF
chmod +x "package/base-files/files/etc/firewall.user"

# -------------------- 插件集成 --------------------
echo "Integrating sirpdboy plugins..."
mkdir -p package/custom
rm -rf package/custom/luci-app-watchdog package/custom/luci-app-partexp

git clone --depth 1 https://github.com/sirpdboy/luci-app-watchdog.git package/custom/luci-app-watchdog
git clone --depth 1 https://github.com/sirpdboy/luci-app-partexp.git package/custom/luci-app-partexp

./scripts/feeds update -a
./scripts/feeds install -a

echo "CONFIG_PACKAGE_luci-app-watchdog=y" >> .config
echo "CONFIG_PACKAGE_luci-app-partexp=y" >> .config

echo "DIY腳本執行完成（已集成Nikki）"

