#!/bin/bash
# ==========================================
# 抗停进程 Watchdog - 防止会话暂停导致进程停止
# ==========================================
# 功能：
#   1. 监控关键服务进程，发现停止立即重启
#   2. 用 setsid + nohup + disown 三重保护
#   3. 定时检查（每 30 秒一次）
#   4. 日志记录到 /workspace/watchdog.log
#
# 监控的服务：
#   - 宝塔面板 (BT-Panel, 端口 9999)
#   - BT 代理 (bt-proxy2.py, 端口 18099)
#   - Serveo SSH 隧道 (ssh -R 80:127.0.0.1:18099 serveo.net)
#   - SSH 服务 (sshd, 端口 22)
#   - Frpc (如果配置了 token)
# ==========================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/workspace/watchdog.log"
PID_FILE="/workspace/watchdog.pid"
STATE_FILE="/workspace/watchdog.state"

# 日志函数
log() {
    local level=$1
    local msg=$2
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[$ts]${NC} ${level} ${msg}"
    echo "[$ts] ${level} ${msg}" >> "$LOG_FILE"
}

log_info() { log "[INFO]" "$1"; }
log_ok()   { log "${GREEN}[OK]${NC}"   "$1"; }
log_warn() { log "${YELLOW}[WARN]${NC}" "$1"; }
log_err()  { log "${RED}[ERR]${NC}"  "$1"; }

# ==========================================
# 启动单个服务（三重保护：setsid + nohup + disown）
# ==========================================
start_service() {
    local name=$1
    local check_cmd=$2
    local start_cmd=$3
    local log_file=$4

    # 检查是否在运行
    if eval "$check_cmd" > /dev/null 2>&1; then
        return 0  # 已在运行
    fi

    log_warn "$name 未运行，正在启动..."
    
    # 三重保护启动
    setsid bash -c "nohup $start_cmd > $log_file 2>&1 &" > /dev/null 2>&1
    disown 2>/dev/null
    
    sleep 3
    
    # 验证启动
    if eval "$check_cmd" > /dev/null 2>&1; then
        log_ok "$name 启动成功"
        return 0
    else
        log_err "$name 启动失败"
        return 1
    fi
}

# ==========================================
# 启动宝塔面板
# ==========================================
check_bt_panel() {
    pgrep -f "BT-Panel" > /dev/null 2>&1
}
start_bt_panel() {
    /etc/init.d/bt start > /dev/null 2>&1
}

# ==========================================
# 启动 BT 代理
# ==========================================
check_bt_proxy() {
    ss -tlnp 2>/dev/null | grep -q ":18099"
}
start_bt_proxy() {
    python3 /workspace/bt-proxy2.py
}

# ==========================================
# 启动 Serveo SSH 隧道
# ==========================================
check_serveo() {
    pgrep -f "ssh.*serveo.net" > /dev/null 2>&1
}
start_serveo() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        -o ProxyCommand="nc -X connect -x 127.0.0.1:18080 %h %p" \
        -R 80:127.0.0.1:18099 serveo.net
}

# ==========================================
# 启动 SSH 服务
# ==========================================
check_sshd() {
    ss -tlnp 2>/dev/null | grep -q ":22 "
}
start_sshd() {
    /usr/sbin/sshd > /dev/null 2>&1
}

# ==========================================
# 启动 Frpc（如果配置了 token）
# ==========================================
check_frpc() {
    pgrep -f "frpc" > /dev/null 2>&1
}
start_frpc() {
    # 从 config.sh 读取 token
    source /workspace/doubao_work/scripts/modules/config.sh 2>/dev/null
    if [ -n "$FRPC_TOKEN" ] && [ "$FRPC_TOKEN" != "YOUR_FRPC_TOKEN" ]; then
        /usr/local/bin/frpc -f ${FRPC_TOKEN}:${FRPC_TUNNEL}
    else
        # token 未配置，跳过
        return 99
    fi
}

# ==========================================
# 启动 Fullroot daemon（提权保持）
# ==========================================
check_fullroot() {
    # 检查 permaroot daemon
    if [ -f /tmp/permaroot-daemon.pid ]; then
        local pid=$(cat /tmp/permaroot-daemon.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    # 或者检查 CapBnd 是否完整
    local cap=$(grep CapBnd /proc/self/status 2>/dev/null | awk '{print $2}')
    if [ "$cap" = "000001ffffffffff" ]; then
        return 0
    fi
    # 或者检查 unshare 进程
    pgrep -f "unshare.*sleep" > /dev/null 2>&1
}
start_fullroot() {
    # 使用 trae-fullroot-toolkit.sh 的 daemon 模式
    if [ -f /workspace/trae-fullroot-toolkit.sh ]; then
        setsid bash -c 'nohup bash /workspace/trae-fullroot-toolkit.sh --daemon > /tmp/fullroot-daemon.log 2>&1 &' > /dev/null 2>&1
        disown 2>/dev/null
    fi
}

# ==========================================
# 主循环
# ==========================================
main_loop() {
    log_info "Watchdog 主循环启动（间隔 30 秒）"
    
    while true; do
        # 记录心跳
        echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE"
        
        # 检查并启动各服务
        start_service "BT-Panel"  "check_bt_panel"  "start_bt_panel"  "/tmp/bt-panel.log"
        start_service "BT-Proxy"  "check_bt_proxy"  "start_bt_proxy"  "/tmp/bt-proxy-watchdog.log"
        start_service "Serveo"    "check_serveo"    "start_serveo"    "/tmp/serveo-watchdog.log"
        start_service "SSHD"      "check_sshd"      "start_sshd"      "/tmp/sshd-watchdog.log"
        start_service "Fullroot"  "check_fullroot"  "start_fullroot"  "/tmp/fullroot-watchdog.log"
        
        # Frpc 只在配置了 token 时启动
        source /workspace/doubao_work/scripts/modules/config.sh 2>/dev/null
        if [ -n "$FRPC_TOKEN" ] && [ "$FRPC_TOKEN" != "YOUR_FRPC_TOKEN" ]; then
            start_service "Frpc" "check_frpc" "start_frpc" "/tmp/frpc-watchdog.log"
        fi
        
        sleep 30
    done
}

# ==========================================
# 启动控制
# ==========================================
case "$1" in
    start)
        # 检查是否已在运行（用 pgrep 而不是 PID 文件）
        RUNNING_PID=$(pgrep -f "watchdog.sh _run" | head -1)
        if [ -n "$RUNNING_PID" ]; then
            log_warn "Watchdog 已在运行 (PID: $RUNNING_PID)"
            exit 0
        fi
        
        # 用三重保护启动 watchdog 自身
        setsid bash -c "nohup $0 _run > /tmp/watchdog-stdout.log 2>&1 &" > /dev/null 2>&1
        disown 2>/dev/null
        
        sleep 3
        NEW_PID=$(pgrep -f "watchdog.sh _run" | head -1)
        echo "$NEW_PID" > "$PID_FILE"
        log_ok "Watchdog 已启动 (PID: $NEW_PID)"
        ;;
    
    _run)
        # 内部运行模式
        echo $$ > "$PID_FILE"
        log_info "Watchdog 启动 (PID: $$)"
        log_info "监控的服务: BT-Panel, BT-Proxy, Serveo, SSHD, Fullroot, Frpc"
        
        # 捕获信号，优雅退出
        trap 'log_info "收到终止信号，退出"; rm -f "$PID_FILE"; exit 0' TERM INT
        
        main_loop
        ;;
    
    stop)
        RUNNING_PID=$(pgrep -f "watchdog.sh _run" | head -1)
        if [ -n "$RUNNING_PID" ]; then
            kill -TERM "$RUNNING_PID"
            log_ok "Watchdog 已停止 (PID: $RUNNING_PID)"
        else
            log_warn "Watchdog 未运行"
        fi
        rm -f "$PID_FILE"
        ;;
    
    status)
        echo "=========================================="
        echo "  Watchdog 状态"
        echo "=========================================="
        echo ""
        
        RUNNING_PID=$(pgrep -f "watchdog.sh _run" | head -1)
        if [ -n "$RUNNING_PID" ]; then
            echo "  Watchdog:  ✅ 运行中 (PID: $RUNNING_PID)"
        else
            echo "  Watchdog:  ❌ 未运行"
        fi
        echo ""
        echo "  服务状态:"
        check_bt_panel && echo "    BT-Panel:  ✅ 运行中" || echo "    BT-Panel:  ❌ 未运行"
        check_bt_proxy && echo "    BT-Proxy:  ✅ 运行中" || echo "    BT-Proxy:  ❌ 未运行"
        check_serveo   && echo "    Serveo:    ✅ 运行中" || echo "    Serveo:    ❌ 未运行"
        check_sshd     && echo "    SSHD:      ✅ 运行中" || echo "    SSHD:      ❌ 未运行"
        check_fullroot && echo "    Fullroot:  ✅ 运行中" || echo "    Fullroot:  ❌ 未运行"
        check_frpc     && echo "    Frpc:      ✅ 运行中" || echo "    Frpc:      ❌ 未运行"
        echo ""
        
        if [ -f "$STATE_FILE" ]; then
            echo "  最后心跳: $(cat $STATE_FILE)"
        fi
        if [ -f "$LOG_FILE" ]; then
            echo "  日志文件: $LOG_FILE ($(wc -l < $LOG_FILE) 行)"
        fi
        ;;
    
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    
    log)
        if [ -f "$LOG_FILE" ]; then
            tail -f "$LOG_FILE"
        else
            echo "日志文件不存在"
        fi
        ;;
    
    *)
        echo "用法: $0 {start|stop|status|restart|log}"
        echo ""
        echo "命令:"
        echo "  start    启动 watchdog（抗停模式）"
        echo "  stop     停止 watchdog"
        echo "  status   查看状态"
        echo "  restart  重启 watchdog"
        echo "  log      查看实时日志"
        exit 1
        ;;
esac

exit 0
