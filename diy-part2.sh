#!/bin/bash
set -euo pipefail
shopt -s extglob

# -------------------- 核心配置 --------------------
FORCE_HOSTNAME="CM520-79F"
FORCE_IP="192.168.5.1"
ADGUARD_PORT="5353"
ADGUARD_BIN="/usr/bin/AdGuardHome"
ADGUARD_CONF_DIR="/etc/AdGuardHome"
ADGUARD_CONF="$ADGUARD_CONF_DIR/AdGuardHome.yaml"
ERROR_LOG="/tmp/diy_error.log"

# AdGuardHome下载地址
ADGUARD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz"

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
log_error() { 
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$ERROR_LOG"
    exit 1
}
log_warn() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$ERROR_LOG"; }

# -------------------- 初始化错误日志 --------------------
echo "===== DIY脚本错误日志 =====" > "$ERROR_LOG"
echo "开始时间: $(date)" >> "$ERROR_LOG"

# -------------------- 1. 创建必要目录 --------------------
log_info "创建必要目录..."
mkdir -p \
    "target/linux/ipq40xx/files/arch/arm/boot/dts" \
    "package/custom" \
    "package/base-files/files$ADGUARD_CONF_DIR" \
    "package/base-files/files/usr/bin" \
    "package/base-files/files/etc/uci-defaults" \
    "package/base-files/files/etc/config"
log_info "必要目录创建完成"

# -------------------- 2. 清理并备份现有配置 --------------------
log_info "清理构建环境..."
# 备份当前配置
cp .config .config.backup_$(date +%s) 2>/dev/null || true
# 清理临时文件，避免缓存问题
rm -rf tmp/.* tmp/* 2>/dev/null || true
log_info "环境清理完成"

# -------------------- 3. 配置内核模块（基础配置） --------------------
log_info "配置基础内核模块..."
# 先创建一个干净的基础配置
cat > .config << 'EOF'
# 目标平台
CONFIG_TARGET_ipq40xx=y
CONFIG_TARGET_ipq40xx_generic=y
CONFIG_TARGET_ipq40xx_generic_DEVICE_mobipromo_cm520-79f=y

# 基础内核模块
CONFIG_PACKAGE_kmod-ubi=y
CONFIG_PACKAGE_kmod-ubifs=y
CONFIG_PACKAGE_trx=y

# 基础防火墙（避免复杂依赖）
CONFIG_PACKAGE_firewall3=y
CONFIG_PACKAGE_iptables=y
CONFIG_PACKAGE_ip6tables=y

# 基础LuCI
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_luci-theme-bootstrap=y

# 必要的网络工具
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_wget-ssl=y
CONFIG_PACKAGE_ca-certificates=y
EOF
log_info "基础配置创建完成"

# -------------------- 4. 渐进式添加Nikki（分步验证） --------------------
log_info "开始渐进式集成Nikki..."

# 添加nikki源
NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
if ! grep -q "nikki.*nikkinikki-org" feeds.conf.default; then
    echo "src-git nikki $NIKKI_FEED" >> feeds.conf.default || log_error "添加Nikki源失败"
fi

# 更新feeds（分步进行）
log_info "更新基础feeds..."
if ! ./scripts/feeds update -a 2>&1 | tee feeds_update.log; then
    log_warn "基础feeds更新有警告，继续..."
fi

# 单独更新nikki并处理可能的网络问题
log_info "更新nikki源..."
retry_count=0
max_retries=3
while [ $retry_count -lt $max_retries ]; do
    if timeout 120 ./scripts/feeds update nikki 2>&1 | tee nikki_update_$retry_count.log; then
        log_info "nikki源更新成功"
        NIKKI_AVAILABLE=1
        break
    else
        retry_count=$((retry_count + 1))
        log_warn "nikki源更新失败，尝试 $retry_count/$max_retries"
        sleep 10
        if [ $retry_count -eq $max_retries ]; then
            log_warn "nikki源更新最终失败，将跳过nikki集成"
            NIKKI_AVAILABLE=0
            break
        fi
    fi
done

# 验证基础配置可用性
log_info "验证基础配置..."
if ! timeout 120 make defconfig 2>&1 | tee make_defconfig_base.log; then
    log_error "基础配置验证失败，请检查OpenWrt源码完整性"
fi
log_info "基础配置验证通过"

# 如果nikki可用，谨慎添加
if [ "${NIKKI_AVAILABLE:-0}" = "1" ]; then
    log_info "安装nikki核心包..."
    
    # 只安装核心包，避免复杂依赖
    if ./scripts/feeds install nikki 2>&1 | tee install_nikki_core.log; then
        echo "CONFIG_PACKAGE_nikki=y" >> .config
        log_info "nikki核心包添加成功"
        
        # 验证配置
        if timeout 120 make defconfig 2>&1 | tee make_defconfig_nikki.log; then
            log_info "nikki核心配置验证通过"
            
            # 尝试添加LuCI界面
            if ./scripts/feeds install luci-app-nikki 2>&1 | tee install_nikki_luci.log; then
                echo "CONFIG_PACKAGE_luci-app-nikki=y" >> .config
                log_info "luci-app-nikki添加成功"
                
                # 再次验证
                if ! timeout 120 make defconfig 2>&1 | tee make_defconfig_final.log; then
                    log_warn "添加LuCI界面后配置失败，回滚到核心包"
                    sed -i '/CONFIG_PACKAGE_luci-app-nikki/d' .config
                    make defconfig > /dev/null 2>&1
                fi
            else
                log_warn "luci-app-nikki安装失败，仅使用核心包"
            fi
        else
            log_warn "nikki配置验证失败，移除nikki包"
            sed -i '/CONFIG_PACKAGE_nikki/d' .config
            make defconfig > /dev/null 2>&1
        fi
    else
        log_warn "nikki核心包安装失败，跳过nikki集成"
    fi
else
    log_info "跳过nikki集成（源不可用）"
fi

# -------------------- 5. DTS补丁处理 --------------------
log_info "处理DTS补丁..."
DTS_DIR="target/linux/ipq40xx/files/arch/arm/boot/dts"
TARGET_DTS="$DTS_DIR/qcom-ipq4019-cm520-79f.dts"
BACKUP_DTS="$TARGET_DTS.backup"
DTS_PATCH_URL="https://git.ix.gs/mptcp/openmptcprouter/commit/a66353a01576c5146ae0d72ee1f8b24ba33cb88e.patch"
DTS_PATCH_FILE="$DTS_DIR/cm520-79f.patch"

if [ -f "$TARGET_DTS" ]; then
    cp "$TARGET_DTS" "$BACKUP_DTS" || log_error "DTS备份失败"
    
    if wget -q --timeout=30 -O "$DTS_PATCH_FILE" "$DTS_PATCH_URL"; then
        if [ -s "$DTS_PATCH_FILE" ]; then
            if patch --dry-run -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" >/dev/null 2>&1; then
                patch -d "$DTS_DIR" -p2 < "$DTS_PATCH_FILE" || log_error "DTS补丁应用失败"
                rm -f "$DTS_PATCH_FILE"
                log_info "DTS补丁处理完成"
            else
                log_warn "DTS补丁不兼容，跳过"
                rm -f "$DTS_PATCH_FILE"
            fi
        else
            log_warn "DTS补丁下载为空，跳过"
        fi
    else
        log_warn "DTS补丁下载失败，跳过"
    fi
else
    log_warn "目标DTS文件不存在，跳过补丁：$TARGET_DTS"
fi

# -------------------- 6. 配置设备规则 --------------------
log_info "配置设备规则..."
GENERIC_MK="target/linux/ipq40xx/image/generic.mk"
if [ -f "$GENERIC_MK" ] && ! grep -q "mobipromo_cm520-79f" "$GENERIC_MK"; then
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
    log_info "设备规则添加完成"
else
    log_info "设备规则已存在或文件不存在，跳过"
fi

# -------------------- 7. 主机名和IP配置 --------------------
log_info "配置主机名和IP..."
HOSTNAME_FILE="package/base-files/files/etc/hostname"
echo "$FORCE_HOSTNAME" > "$HOSTNAME_FILE" || log_error "写入hostname文件失败"

SYSTEM_CONF="package/base-files/files/etc/config/system"
cat <<EOF > "$SYSTEM_CONF"
config system
    option hostname '$FORCE_HOSTNAME'
    option timezone 'UTC'
EOF

NETWORK_CONF="package/base-files/files/etc/config/network"
cat <<EOF > "$NETWORK_CONF"
config interface 'lan'
    option type 'bridge'
    option ifname 'eth0'
    option ipaddr '$FORCE_IP'
    option netmask '255.255.255.0'
    option proto 'static'
EOF

UCI_SCRIPT="package/base-files/files/etc/uci-defaults/99-force-ip-hostname"
cat <<EOF > "$UCI_SCRIPT"
#!/bin/sh
uci set network.lan.ipaddr='$FORCE_IP'
uci set system.@system[0].hostname='$FORCE_HOSTNAME'
uci commit network
uci commit system
/etc/init.d/network reload
exit 0
EOF
chmod +x "$UCI_SCRIPT" || log_error "设置uci脚本权限失败"
log_info "主机名和IP配置完成"

# -------------------- 8. AdGuardHome集成 --------------------
log_info "集成AdGuardHome..."
ADGUARD_TMP_DIR="/tmp/adguard"
ADGUARD_ARCHIVE="/tmp/adguard.tar.gz"

rm -rf "$ADGUARD_TMP_DIR" "$ADGUARD_ARCHIVE"

if wget -q --timeout=120 -O "$ADGUARD_ARCHIVE" "$ADGUARD_URL"; then
    if [ $(stat -c "%s" "$ADGUARD_ARCHIVE") -gt 102400 ]; then
        mkdir -p "$ADGUARD_TMP_DIR"
        if tar -xzf "$ADGUARD_ARCHIVE" -C "$ADGUARD_TMP_DIR" 2>/dev/null; then
            ADGUARD_BIN_SRC=$(find "$ADGUARD_TMP_DIR" -type f -name "AdGuardHome" | head -n 1)
            
            if [ -n "$ADGUARD_BIN_SRC" ] && [ -f "$ADGUARD_BIN_SRC" ]; then
                cp "$ADGUARD_BIN_SRC" "package/base-files/files$ADGUARD_BIN"
                chmod +x "package/base-files/files$ADGUARD_BIN"
                
                # 创建配置文件
                cat <<EOF > "package/base-files/files$ADGUARD_CONF"
bind_host: 0.0.0.0
bind_port: $ADGUARD_PORT
users:
  - name: admin
    password: \$2y\$10\$FoyiYiwQKRoJl9zzG7u0yeFpb4B8jVH4VkgrKauQuOV0WRnLNPXXi
language: zh-cn
upstream_dns:
  - 223.5.5.5
  - 114.114.114.114
EOF

                # 创建服务脚本
                SERVICE_SCRIPT="package/base-files/files/etc/init.d/adguardhome"
                cat <<EOF > "$SERVICE_SCRIPT"
#!/bin/sh /etc/rc.common
START=95
STOP=15
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command $ADGUARD_BIN -c $ADGUARD_CONF
    procd_set_param respawn
    procd_close_instance
}
EOF
                chmod +x "$SERVICE_SCRIPT"
                log_info "AdGuardHome集成完成"
            else
                log_warn "AdGuardHome二进制文件未找到"
            fi
        else
            log_warn "AdGuardHome解压失败"
        fi
    else
        log_warn "AdGuardHome下载文件过小"
    fi
else
    log_warn "AdGuardHome下载失败，跳过集成"
fi

# 清理临时文件
rm -rf "$ADGUARD_TMP_DIR" "$ADGUARD_ARCHIVE" 2>/dev/null || true

# -------------------- 9. 最终配置验证 --------------------
log_info "执行最终配置验证..."
if timeout 180 make defconfig 2>&1 | tee make_defconfig_final.log; then
    log_info "最终配置验证成功"
else
    log_error "最终配置验证失败，请检查 make_defconfig_final.log"
fi

# -------------------- 10. 生成构建报告 --------------------
log_info "生成构建报告..."
cat > build_report.txt << EOF
OpenWrt CM520-79F 定制构建报告
生成时间: $(date)
构建目录: $(pwd)

=== 配置摘要 ===
主机名: $FORCE_HOSTNAME
默认IP: $FORCE_IP
AdGuardHome端口: $ADGUARD_PORT

=== 包配置统计 ===
总包数: $(grep -c "CONFIG_PACKAGE.*=y" .config)
Nikki状态: $(grep -q "CONFIG_PACKAGE_nikki=y" .config && echo "已启用" || echo "未启用")
AdGuardHome: $([ -f "package/base-files/files$ADGUARD_BIN" ] && echo "已集成" || echo "未集成")

=== 构建建议 ===
1. 执行: make download 下载源码包
2. 执行: make -j\$(nproc) V=s 开始编译
3. 镜像位置: bin/targets/ipq40xx/generic/

=== 问题排查 ===
如遇到问题，请检查以下日志文件：
- $ERROR_LOG (错误日志)
- make_defconfig_*.log (配置生成日志)
- feeds_update.log (源更新日志)
EOF

log_info "构建报告已生成: build_report.txt"
log_info "DIY脚本执行完成，现在可以执行 make download && make -j\$(nproc) V=s 开始编译"
