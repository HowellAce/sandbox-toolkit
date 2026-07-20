#!/bin/bash
# ==========================================
# Frp Tunnel Manager
# Optional Script - Sakura Frp 隧道快速管理工具
# ==========================================
# 功能：快速开启、关闭、重启、查看 frp 隧道状态
# 注意：已处理所有已知坑点，可安全使用
# ==========================================

set -e

# ==========================================
# 配置项
# ==========================================

# Frpc 二进制路径（运行时位置）
FRPC_BIN="/home/user/frpc"

# Frpc 日志路径
FRPC_LOG="/home/user/frpc.log"

# Frpc 持久化缓存（workspace 中，沙箱重置后保留）
FRPC_PERSISTENT="/home/user/.super_doubao/super-doubao-runtime/workspace/doubao_work/bin/frpc"

# 配置文件路径（可选，从中读取默认 token 和 tunnel）
CONFIG_FILE="/home/user/.super_doubao/super-doubao-runtime/workspace/doubao_work/scripts/modules/config.sh"

# 默认值（如果配置文件中没有）
DEFAULT_TOKEN=""
DEFAULT_TUNNEL=""

# ==========================================
# 颜色输出
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ==========================================
# 加载配置
# ==========================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # 从配置文件中读取 token 和 tunnel
        FRPC_TOKEN=$(grep '^FRPC_TOKEN=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'"' -f2)
        FRPC_TUNNEL=$(grep '^FRPC_TUNNEL=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'"' -f2)
        
        # 过滤掉占位符
        if [[ "$FRPC_TOKEN" == YOUR_* ]]; then
            FRPC_TOKEN=""
        fi
        if [[ "$FRPC_TUNNEL" == YOUR_* ]]; then
            FRPC_TUNNEL=""
        fi
    fi
    
    # 使用默认值
    if [ -z "$FRPC_TOKEN" ]; then
        FRPC_TOKEN="$DEFAULT_TOKEN"
    fi
    if [ -z "$FRPC_TUNNEL" ]; then
        FRPC_TUNNEL="$DEFAULT_TUNNEL"
    fi
}

# ==========================================
# 检查 frpc 二进制
# ==========================================

check_frpc_binary() {
    if [ ! -f "$FRPC_BIN" ]; then
        warn "frpc 二进制不存在: $FRPC_BIN"
        
        # 尝试从持久化缓存复制
        if [ -f "$FRPC_PERSISTENT" ]; then
            info "从持久化缓存复制 frpc..."
            cp "$FRPC_PERSISTENT" "$FRPC_BIN"
            chmod +x "$FRPC_BIN"
            success "frpc 已从缓存恢复"
        else
            error "未找到 frpc 二进制，也没有持久化缓存"
            info "请先下载 frpc 到: $FRPC_PERSISTENT"
            return 1
        fi
    fi
    
    if [ ! -x "$FRPC_BIN" ]; then
        chmod +x "$FRPC_BIN"
    fi
    
    return 0
}

# ==========================================
# 获取 frpc 进程 PID
# ==========================================
# 【重要坑点】必须使用完整路径匹配，不能用简单的 "frpc" 或 "frpc -f "
# 否则会匹配到 Bash 工具自身的 shell 进程，导致误杀和错误码 -1

get_frpc_pid() {
    # 【重要坑点】不能简单匹配 "frpc" 或 "frpc -f "，因为会匹配到 Bash 工具
    # 自身的 shell 进程（命令行包含这些字符串），导致误杀和错误码 -1
    #
    # 解决方案：
    # 1. 匹配包含 "frpc -f " 的进程
    # 2. 排除掉 bash -c 启动的进程（它们是包装进程，不是真正的 frpc）
    # 3. 排除掉 grep 进程
    # 4. 只提取真正的 frpc 可执行文件进程
    
    ps aux 2>/dev/null \
        | grep "frpc -f " \
        | grep -v grep \
        | grep -v "bash -c" \
        | awk '{print $2}'
}

is_frpc_running() {
    if [ -n "$(get_frpc_pid)" ]; then
        return 0
    else
        return 1
    fi
}

# ==========================================
# 停止 frpc
# ==========================================

stop_frpc() {
    info "正在停止 frp 隧道..."
    
    if ! is_frpc_running; then
        warn "frpc 未在运行"
        return 0
    fi
    
    local PID=$(get_frpc_pid)
    info "找到 frpc 进程 (PID: $PID)"
    
    # 优雅停止
    kill "$PID" 2>/dev/null || true
    
    # 等待进程结束
    local count=0
    while is_frpc_running && [ $count -lt 10 ]; do
        sleep 0.5
        count=$((count + 1))
    done
    
    # 如果还没停止，强制杀死
    if is_frpc_running; then
        warn "进程未响应，强制终止..."
        kill -9 "$(get_frpc_pid)" 2>/dev/null || true
        sleep 0.5
    fi
    
    if is_frpc_running; then
        error "无法停止 frpc 进程"
        return 1
    else
        success "frp 隧道已停止"
        return 0
    fi
}

# ==========================================
# 启动 frpc
# ==========================================
# 【重要坑点】不能 cd 到 /home/user 目录，否则 Bash 工具会检测到
# 工作目录变化并返回错误码 -1。必须始终使用绝对路径。

start_frpc() {
    local tunnel_args="$1"
    
    # 检查参数
    if [ -z "$tunnel_args" ]; then
        # 从配置加载
        load_config
        
        if [ -n "$FRPC_TOKEN" ] && [ -n "$FRPC_TUNNEL" ]; then
            tunnel_args="${FRPC_TOKEN}:${FRPC_TUNNEL}"
        else
            error "未指定隧道参数，且配置文件中未设置"
            echo ""
            echo "用法: $0 start <token:tunnel>"
            echo "示例: $0 start YOUR_FRPC_TOKEN:YOUR_TUNNEL_ID"
            return 1
        fi
    fi
    
    info "正在启动 frp 隧道..."
    info "隧道参数: $tunnel_args"
    
    # 检查是否已在运行
    if is_frpc_running; then
        warn "frpc 已在运行中"
        local PID=$(get_frpc_pid)
        info "当前 PID: $PID"
        echo ""
        echo "如需切换隧道，请先执行: $0 stop"
        return 0
    fi
    
    # 检查二进制
    check_frpc_binary || return 1
    
    # 【重要】使用子shell + 绝对路径启动，避免 cd 和工作目录问题
    # 重定向所有输入输出，确保完全脱离终端
    (
        "$FRPC_BIN" -f "$tunnel_args" < /dev/null > "$FRPC_LOG" 2>&1 &
    )
    
    # 等待一下让进程启动
    sleep 1
    
    # 检查是否启动成功
    if is_frpc_running; then
        local PID=$(get_frpc_pid)
        success "frp 隧道已启动 (PID: $PID)"
        echo ""
        
        # 尝试从日志中提取连接信息
        if [ -f "$FRPC_LOG" ]; then
            sleep 1
            local conn_info=$(grep -E "连接你的隧道|frp-.*:[0-9]+" "$FRPC_LOG" 2>/dev/null | tail -1 | sed 's/.*使用 //' | sed 's/ 连接你的隧道.*//')
            if [ -n "$conn_info" ]; then
                info "公网地址: $conn_info"
            fi
        fi
        
        info "日志文件: $FRPC_LOG"
        info "查看日志: $0 log"
        info "查看状态: $0 status"
        return 0
    else
        error "frpc 启动失败"
        if [ -f "$FRPC_LOG" ]; then
            echo ""
            error "日志内容:"
            tail -10 "$FRPC_LOG"
        fi
        return 1
    fi
}

# ==========================================
# 重启 frpc
# ==========================================

restart_frpc() {
    local tunnel_args="$1"
    
    info "正在重启 frp 隧道..."
    echo ""
    
    stop_frpc
    echo ""
    start_frpc "$tunnel_args"
}

# ==========================================
# 查看状态
# ==========================================

show_status() {
    echo "=========================================="
    echo "  Frp Tunnel Status"
    echo "=========================================="
    echo ""
    
    if is_frpc_running; then
        local PID=$(get_frpc_pid)
        echo -e "  状态: ${GREEN}运行中${NC}"
        echo "  PID:  $PID"
        
        # 显示进程信息
        local proc_info=$(ps -p "$PID" -o etime=,pcpu=,pmem= 2>/dev/null | xargs)
        if [ -n "$proc_info" ]; then
            echo "  运行时间/CPU/内存: $proc_info"
        fi
        
        echo ""
        
        # 从日志中提取隧道信息
        if [ -f "$FRPC_LOG" ]; then
            # 提取隧道名称（格式：[token.tunnel_name] 隧道启动成功）
            local tunnel_name=$(grep "隧道启动成功" "$FRPC_LOG" 2>/dev/null | tail -1 | grep -o '\[[^]]*\] 隧道启动成功' | tail -1 | sed 's/^\[//' | sed 's/\] 隧道启动成功$//')
            # 提取公网地址
            local public_addr=$(grep -E "使用.*连接你的隧道" "$FRPC_LOG" 2>/dev/null | tail -1 | grep -oE 'frp[-a-zA-Z0-9.]*:[0-9]+' | head -1)
            
            if [ -n "$tunnel_name" ]; then
                echo "  隧道: $tunnel_name"
            fi
            if [ -n "$public_addr" ]; then
                echo "  公网地址: $public_addr"
            fi
        fi
    else
        echo -e "  状态: ${RED}未运行${NC}"
    fi
    
    echo ""
    echo "=========================================="
}

# ==========================================
# 查看日志
# ==========================================

show_log() {
    local lines="${1:-20}"
    
    if [ ! -f "$FRPC_LOG" ]; then
        error "日志文件不存在: $FRPC_LOG"
        return 1
    fi
    
    info "最近 $lines 行日志:"
    echo ""
    tail -n "$lines" "$FRPC_LOG"
    echo ""
    info "日志文件: $FRPC_LOG"
}

# ==========================================
# 显示帮助
# ==========================================

show_help() {
    echo "=========================================="
    echo "  Frp Tunnel Manager"
    echo "  Sakura Frp 隧道快速管理工具"
    echo "=========================================="
    echo ""
    echo "用法:"
    echo "  $0 <命令> [参数]"
    echo ""
    echo "命令:"
    echo "  start [token:tunnel]    启动 frp 隧道"
    echo "  stop                     停止 frp 隧道"
    echo "  restart [token:tunnel]   重启 frp 隧道"
    echo "  status                   查看隧道状态"
    echo "  log [行数]               查看日志（默认20行）"
    echo "  help                     显示帮助"
    echo ""
    echo "示例:"
    echo "  $0 start YOUR_FRPC_TOKEN:YOUR_TUNNEL_ID"
    echo "  $0 stop"
    echo "  $0 restart YOUR_FRPC_TOKEN:YOUR_TUNNEL_ID"
    echo "  $0 status"
    echo "  $0 log 30"
    echo ""
    echo "说明:"
    echo "  - 如果配置文件中已设置 token 和 tunnel，start 可省略参数"
    echo "  - 配置文件: scripts/modules/config.sh"
    echo ""
    echo "=========================================="
}

# ==========================================
# 主函数
# ==========================================

main() {
    local command="$1"
    shift || true
    
    case "$command" in
        start)
            start_frpc "$1"
            ;;
        stop)
            stop_frpc
            ;;
        restart)
            restart_frpc "$1"
            ;;
        status)
            show_status
            ;;
        log)
            show_log "$1"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            if [ -z "$command" ]; then
                show_help
            else
                error "未知命令: $command"
                echo ""
                show_help
                exit 1
            fi
            ;;
    esac
}

# 运行主函数
main "$@"
