#!/bin/bash
# 最终修复版 - 解决 plugin_count 递增导致脚本退出的问题
# 核心改进：使用兼容的数字递增方式，添加变量校验和详细调试

# 启用基础严格模式，保留调试能力
set -eo pipefail  # 保留 errexit 和 pipefail，确保关键错误被捕获
export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '  # 调试输出格式：文件名:行号

# -------------------- 日志函数 --------------------
log_step() { echo -e "\n[$(date +'%H:%M:%S')] \033[1;36m📝 步骤：$*\033[0m"; }  # 步骤标记
log_info() { echo -e "[$(date +'%H:%M:%S')] \033[34mℹ️  $*\033[0m"; }
log_error() { echo -e "[$(date +'%H:%M:%S')] \033[31m❌ $*\033[0m" >&2; }
log_success() { echo -e "[$(date +'%H:%M:%S')] \033[32m✅ $*\033[0m"; }
log_warning() { echo -e "[$(date +'%H:%M:%S')] \033[33m⚠️  $*\033[0m" >&2; }
log_debug() { echo -e "[$(date +'%H:%M:%S')] \033[90m🐛 $*\033[0m"; }  # 调试日志

# -------------------- 全局变量（确保正确初始化） --------------------
validation_passed=true
plugin_count=0  # 明确初始化为数字0
CONFIG_FILE=".config"
CUSTOM_PLUGINS_DIR="package/custom"
DEBUG_MODE=${DEBUG_MODE:-"true"}  # 默认启用调试模式

# -------------------- 验证变量是否为有效数字 --------------------
is_number() {
    local var="$1"
    if [[ "$var" =~ ^[0-9]+$ ]]; then
        return 0  # 是有效数字
    else
        return 1  # 不是有效数字
    fi
}

# -------------------- 安全递增插件计数 --------------------
increment_plugin_count() {
    # 检查当前值是否为有效数字
    if ! is_number "$plugin_count"; then
        log_error "plugin_count 不是有效数字（当前值: '$plugin_count'），将重置为0"
        plugin_count=0
    fi
    
    # 使用兼容的算术扩展递增（替代可能有问题的 ++）
    local new_count=$((plugin_count + 1))
    log_debug "plugin_count 从 $plugin_count 递增到 $new_count"
    plugin_count="$new_count"
}

# -------------------- 插件集成函数 --------------------
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
            rm -rf "$path" || log_warning "无法删除 $path（可能无权限）"
        fi
    done
    
    # 验证仓库可访问性
    log_info "检查仓库连接性..."
    if ! timeout 10 git ls-remote --heads "$repo" >/dev/null 2>&1; then
        log_error "无法访问仓库！可能原因："
        log_error "1. 网络问题（GitHub访问不稳定）"
        log_error "2. 仓库地址错误（$repo）"
        log_error "3. 防火墙/代理限制"
        flock -u 200
        return 1
    fi
    
    # 克隆重试逻辑
    while [ $retry_count -lt $max_retries ]; do
        ((retry_count++))
        log_info "克隆尝试 $retry_count/$max_retries..."
        
        # 清理临时目录
        [ -d "$temp_dir" ] && rm -rf "$temp_dir"
        
        # 执行克隆（带详细日志）
        if timeout 300 git clone --depth 1 --single-branch \
            --progress "$repo" "$temp_dir" 2>&1; then
            
            if [ -d "$temp_dir" ] && [ "$(ls -A "$temp_dir" 2>/dev/null)" != "" ]; then
                log_success "克隆成功！临时目录: $temp_dir"
                success=1
                break
            else
                log_warning "克隆命令成功，但临时目录为空"
            fi
        else
            log_error "克隆失败（尝试 $retry_count），错误信息："
            git clone --depth 1 --single-branch "$repo" "$temp_dir" 2>&1 | head -10  # 显示部分错误
            if [ $retry_count -lt $max_retries ]; then
                local wait_time=$((retry_count * 5))
                log_info "等待 $wait_time 秒后重试..."
                sleep $wait_time
            fi
        fi
    done
    
    if [ $success -eq 0 ]; then
        log_error "$plugin_name 克隆失败（已重试 $max_retries 次）"
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
        log_info "目标目录权限："
        ls -ld "package/" 2>/dev/null || true
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
                    echo "$dep" >> "$CONFIG_FILE" 2>/dev/null || \
                        log_warning "无法添加依赖: $dep（可能权限不足）"
                fi
            done
        fi
        return 0
    else
        log_error "$plugin_name 集成验证失败"
        return 1
    fi
}

# -------------------- 验证文件系统函数（使用安全递增） --------------------
verify_filesystem() {
    local plugin=$1
    log_step "验证 $plugin 文件系统"
    
    # 调试：输出当前 plugin_count 状态
    log_debug "进入 verify_filesystem，当前 plugin_count: '$plugin_count'（类型: $(declare -p plugin_count 2>/dev/null)）"
    
    if [ -d "package/$plugin" ]; then
        log_debug "目录存在: package/$plugin"
        if [ -f "package/$plugin/Makefile" ]; then
            log_debug "Makefile存在: package/$plugin/Makefile"
            log_success "$plugin 目录和Makefile均存在"
            
            # 使用安全递增函数替代直接 ++
            increment_plugin_count
            
            # 验证递增结果
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
    
    return 0  # 即使失败也继续执行
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
    
    # 临时关闭errexit，确保完整遍历
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
        
        # 检查.config是否可写
        if [ ! -w "$CONFIG_FILE" ]; then
            log_warning "$CONFIG_FILE 不可写，无法添加配置项"
        fi
        
        # 执行grep并显式捕获退出码
        if grep -q "^${config}$" "$CONFIG_FILE" 2>/dev/null; then
            log_info "第 $item_num 项: ✅ $config"
            ((found++))
        else
            log_warning "第 $item_num 项: ❌ $config（.config中未找到）"
            ((missing++))
        fi
    done
    set -e  # 恢复errexit
    
    # 输出汇总
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
)

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
        log_info "建议执行: make menuconfig 确认配置，然后 make -j\$(nproc) V=s 编译"
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
        log_info "4. 清理后重试：rm -rf package/luci-app-* && ./脚本名"
        exit 1
    fi
}

# 启动主流程
main
