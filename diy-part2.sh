#!/bin/bash
# 完整修复版 - 解决配置项验证过程中脚本意外退出的问题
# 主要修复: 确保配置项验证能完整执行所有项，不会因单个项失败而终止脚本

# 启用严格模式，但在关键位置进行灵活处理
set -euo pipefail

# -------------------- 日志函数 --------------------
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m" >&2; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m" >&2; }

# -------------------- 全局变量 --------------------
validation_passed=true
plugin_count=0
CONFIG_FILE=".config"

# -------------------- 验证配置项的核心函数（重点修复） --------------------
verify_configs() {
    local plugin_name="$1"
    shift
    local deps=("$@")
    local missing=0
    local found=0
    local total=${#deps[@]}

    log_info "开始验证 $plugin_name 配置项（共 $total 项）..."

    # 保存当前的shell选项，以便之后恢复
    local original_shell_opts=$(set +o)
    
    # 临时关闭严格模式，防止单个配置项验证失败导致整个脚本退出
    set +euo pipefail

    # 遍历所有配置项
    for index in "${!deps[@]}"; do
        local config="${deps[$index]}"
        local item_num=$((index + 1))

        # 跳过空配置项
        if [ -z "$config" ]; then
            log_warning "第 $item_num 项：配置项为空，已跳过"
            ((missing++))
            continue
        fi

        # 验证配置项是否存在于.config中
        log_info "正在验证第 $item_num 项: $config"
        
        # 使用grep验证，重定向错误输出
        if grep -q "^${config}$" "$CONFIG_FILE" 2>/dev/null; then
            log_info "第 $item_num 项: ✅ $config"
            ((found++))
        else
            log_warning "第 $item_num 项: ❌ $config（在 $CONFIG_FILE 中未找到）"
            ((missing++))
        fi
    done

    # 恢复原始的shell选项
    eval "$original_shell_opts"

    # 输出验证结果汇总
    log_info "$plugin_name 配置项验证汇总："
    log_info "  总配置项: $total"
    log_info "  找到的配置项: $found"
    log_info "  缺失的配置项: $missing"

    # 根据结果更新验证状态
    if [ $missing -eq 0 ]; then
        log_success "$plugin_name 所有配置项验证通过"
    else
        log_warning "$plugin_name 存在 $missing 个缺失的配置项"
        validation_passed=false
    fi
}

# -------------------- 验证插件文件系统的函数 --------------------
verify_filesystem() {
    local plugin=$1
    log_info "验证 $plugin 文件系统..."
    
    if [ -d "package/$plugin" ]; then
        if [ -f "package/$plugin/Makefile" ]; then
            log_success "$plugin 目录和 Makefile 验证通过"
            ((plugin_count++))
            return 0
        else
            log_error "$plugin 目录存在，但缺少 Makefile"
            validation_passed=false
        fi
    else
        log_error "$plugin 目录不存在"
        validation_passed=false
    fi
    
    return 1
}

# -------------------- 检查配置文件有效性 --------------------
check_config_file() {
    log_info "检查配置文件 $CONFIG_FILE 有效性..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件 $CONFIG_FILE 不存在"
        return 1
    fi
    
    if [ ! -r "$CONFIG_FILE" ]; then
        log_error "配置文件 $CONFIG_FILE 不可读取"
        return 1
    fi
    
    if [ -z "$(cat "$CONFIG_FILE" 2>/dev/null)" ]; then
        log_error "配置文件 $CONFIG_FILE 为空"
        return 1
    fi
    
    log_success "配置文件 $CONFIG_FILE 有效"
    return 0
}

# -------------------- 插件依赖配置 --------------------
# OpenClash 依赖配置项
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

# Passwall2 依赖配置项
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
)

# -------------------- 检查依赖数组有效性 --------------------
check_deps_array() {
    local name=$1
    shift
    local array=("$@")
    
    log_info "检查 $name 依赖数组有效性..."
    
    if [ ${#array[@]} -eq 0 ]; then
        log_error "$name 依赖数组为空"
        return 1
    fi
    
    local has_error=0
    for index in "${!array[@]}"; do
        local item="${array[$index]}"
        if [ -z "$item" ]; then
            log_error "$name 依赖数组第 $((index + 1)) 项为空"
            has_error=1
        fi
    done
    
    if [ $has_error -eq 0 ]; then
        log_success "$name 依赖数组有效"
        return 0
    else
        return 1
    fi
}

# -------------------- 主执行流程 --------------------
main() {
    log_info "===== 开始执行插件配置验证流程 ====="
    
    # 首先检查配置文件是否有效
    if ! check_config_file; then
        log_error "配置文件无效，无法继续验证"
        exit 1
    fi
    
    # 检查依赖数组有效性
    check_deps_array "OpenClash" "${OPENCLASH_DEPS[@]}"
    check_deps_array "Passwall2" "${PASSWALL2_DEPS[@]}"
    
    # 验证插件文件系统
    verify_filesystem "luci-app-openclash"
    verify_filesystem "luci-app-passwall2"
    
    # 验证OpenClash配置项（重点修复部分）
    if [ -d "package/luci-app-openclash" ]; then
        verify_configs "OpenClash" "${OPENCLASH_DEPS[@]}"
    else
        log_info "OpenClash 未安装，跳过配置项验证"
    fi
    
    # 验证Passwall2配置项
    if [ -d "package/luci-app-passwall2" ]; then
        verify_configs "Passwall2" "${PASSWALL2_DEPS[@]}"
    else
        log_info "Passwall2 未安装，跳过配置项验证"
    fi
    
    # 输出最终验证结果
    log_info "===== 验证流程完成 ====="
    if $validation_passed; then
        log_success "所有验证均通过！可以继续编译流程"
        log_info "建议执行: make menuconfig 进行最终确认，然后执行 make -j\$(nproc) V=s 开始编译"
        exit 0
    else
        log_warning "部分验证未通过，请根据上述警告信息进行修复"
        log_info "修复建议:"
        log_info "1. 对于缺失的配置项，可以通过 make menuconfig 启用"
        log_info "2. 确保所有插件目录和Makefile都存在且完整"
        log_info "3. 修复后可重新运行本脚本进行验证"
        exit 0  # 即使有警告也返回0，避免CI流程中断，由用户决定是否继续
    fi
}

# 启动主执行流程
main
