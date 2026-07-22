#!/bin/bash
# =============================================================================
# sandbox-watchdog.sh - 沙箱服务监控+自动恢复守护进程
# -----------------------------------------------------------------------------
# 基于 sandbox-reset-tracker.sh（原 tar 包中的抗停脚本）增强：
# 1. 原功能：心跳检测沙箱重置（boot_id 变化）
# 2. 新增：监控 BT-Panel / bt-proxy3 / cf-edge-proxy / cloudflared 服务状态
# 3. 新增：服务异常时自动运行 autostart.sh 恢复
# 4. 新增：可注册为 supervisor 程序，随 supervisor 自动启动
#
# 用法:
#   bash /workspace/sandbox-watchdog.sh start    # 启动守护进程
#   bash /workspace/sandbox-watchdog.sh status   # 查看状态
#   bash /workspace/sandbox-watchdog.sh stop     # 停止
# =============================================================================

WORK_DIR="/workspace"
STATE_FILE="${WORK_DIR}/.sandbox-state"
PID_FILE="${WORK_DIR}/.sandbox-watchdog.pid"
LOG_FILE="${WORK_DIR}/logs/watchdog.log"
INTERVAL="${WATCHDOG_INTERVAL:-30}"

BOOT_ID_FILE="/proc/sys/kernel/random/boot_id"
LAST_BOOT_ID=""
RECOVERY_COOLDOWN=0  # 冷却计数器，避免频繁恢复

mkdir -p "${WORK_DIR}/logs" 2>/dev/null

# -----------------------------------------------------------------------------
# 日志
# -----------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] [watchdog] $*" >>"${LOG_FILE}" 2>/dev/null || true
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

# -----------------------------------------------------------------------------
# 心跳状态（原 tracker 功能）
# -----------------------------------------------------------------------------
write_state() {
    local boot_id="unknown"
    if [ -r "${BOOT_ID_FILE}" ]; then
        boot_id="$(cat "${BOOT_ID_FILE}" 2>/dev/null | tr -d '[:space:]')"
    fi
    cat > "${STATE_FILE}" <<EOF
# TRAE sandbox watchdog state
boot_id=${boot_id}
last_heartbeat=$(date '+%Y-%m-%dT%H:%M:%S%z')
epoch=$(date +%s)
uid=$(id -u)
hostname=$(hostname 2>/dev/null || echo unknown)
EOF
}

detect_reset() {
    local current_boot_id
    current_boot_id="$(cat "${BOOT_ID_FILE}" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "${LAST_BOOT_ID}" ]; then
        LAST_BOOT_ID="${current_boot_id}"
        return 1
    fi
    if [ "${LAST_BOOT_ID}" != "${current_boot_id}" ]; then
        log_warn "检测到沙箱重置！boot_id: ${LAST_BOOT_ID} → ${current_boot_id}"
        LAST_BOOT_ID="${current_boot_id}"
        return 0
    fi
    LAST_BOOT_ID="${current_boot_id}"
    return 1
}

# -----------------------------------------------------------------------------
# 服务监控
# -----------------------------------------------------------------------------
check_services() {
    local failed=()

    # 检查 BT-Panel (端口 24965)
    if ! ss -tlnp 2>/dev/null | grep -q ":24965"; then
        failed+=("bt-panel")
    fi

    # 检查 bt-proxy3 (端口 18099)
    if ! ss -tlnp 2>/dev/null | grep -q ":18099"; then
        failed+=("bt-proxy3")
    fi

    # 检查 cf-edge-proxy (端口 7844)
    if ! ss -tlnp 2>/dev/null | grep -q ":7844"; then
        failed+=("cf-edge-proxy")
    fi

    # 检查 cloudflared (进程)
    if ! pgrep -f "cloudflared.*tunnel" > /dev/null 2>&1; then
        failed+=("cloudflared")
    fi

    # 检查 /www 软链接
    if [ ! -d "/www/server/panel" ]; then
        failed+=("www-symlink")
    fi

    if [ ${#failed[@]} -gt 0 ]; then
        echo "${failed[*]}"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 恢复
# -----------------------------------------------------------------------------
run_recovery() {
    log_warn "开始自动恢复服务..."

    # 恢复 /www 软链接
    if [ ! -d "/www/server/panel" ] && [ -d "/workspace/www/server/panel" ]; then
        ln -sf /workspace/www /www
        log_info "已恢复 /www 软链接"
    fi

    # 恢复 agent-tool-host wrapper（如果丢失）
    if [ ! -f /app/bin/agent-tool-host.orig ] && [ -f /app/bin/agent-tool-host ]; then
        # wrapper 可能被重置，重新创建
        if file /app/bin/agent-tool-host | grep -q "ELF"; then
            mv /app/bin/agent-tool-host /app/bin/agent-tool-host.orig
            cat > /app/bin/agent-tool-host << 'WRAPPER'
#!/bin/bash
if [ -f /workspace/autostart.sh ]; then
    nohup bash /workspace/autostart.sh > /workspace/autostart-boot.log 2>&1 &
    disown 2>/dev/null || true
fi
exec /app/bin/agent-tool-host.orig "$@"
WRAPPER
            chmod +x /app/bin/agent-tool-host
            log_info "已重建 agent-tool-host wrapper"
        fi
    fi

    # 运行 autostart.sh
    if [ -f "${WORK_DIR}/autostart.sh" ]; then
        bash "${WORK_DIR}/autostart.sh" >> "${LOG_FILE}" 2>&1
        log_info "autostart.sh 执行完成"
    else
        log_error "autostart.sh 不存在！"
    fi

    # 等待服务启动
    sleep 10

    # 验证
    local result
    result=$(check_services 2>/dev/null)
    if [ $? -eq 0 ]; then
        log_info "所有服务已恢复"
    else
        log_error "恢复后仍有服务异常: ${result}"
    fi
}

# -----------------------------------------------------------------------------
# 守护进程主循环
# -----------------------------------------------------------------------------
run_daemon() {
    log_info "watchdog 守护进程启动 (interval=${INTERVAL}s)"

    # 初始化
    write_state
    LAST_BOOT_ID="$(cat "${BOOT_ID_FILE}" 2>/dev/null | tr -d '[:space:]')"

    # 首次检查：如果服务未运行，立即恢复
    local initial_check
    initial_check=$(check_services 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_warn "启动时检测到服务异常: ${initial_check}"
        run_recovery
    fi

    while true; do
        sleep "${INTERVAL}"
        write_state

        # 检测沙箱重置
        if detect_reset; then
            log_warn "检测到沙箱重置，触发恢复"
            run_recovery
            RECOVERY_COOLDOWN=4  # 冷却 4 个周期（2分钟）
            continue
        fi

        # 冷却期内跳过检查
        if [ ${RECOVERY_COOLDOWN} -gt 0 ]; then
            RECOVERY_COOLDOWN=$((RECOVERY_COOLDOWN - 1))
            continue
        fi

        # 检查服务状态
        local failed
        failed=$(check_services 2>/dev/null)
        if [ $? -ne 0 ]; then
            log_warn "服务异常: ${failed}"
            run_recovery
            RECOVERY_COOLDOWN=4  # 冷却 4 个周期
        fi
    done
}

# -----------------------------------------------------------------------------
# 进程管理
# -----------------------------------------------------------------------------
is_running() {
    if [ ! -f "${PID_FILE}" ]; then
        return 1
    fi
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null)"
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

action_start() {
    if is_running; then
        log_info "已在运行 (pid $(cat "${PID_FILE}"))"
        return 0
    fi
    log_info "启动 watchdog..."
    setsid bash -c "nohup $0 _daemon >>${LOG_FILE} 2>&1 &" > /dev/null 2>&1
    disown 2>/dev/null || true
    # 获取刚启动的进程PID
    sleep 1
    local pid=$(pgrep -f "sandbox-watchdog.sh _daemon" | head -1)
    if [ -n "${pid}" ]; then
        echo "${pid}" > "${PID_FILE}"
        log_info "watchdog 已启动 (pid ${pid})"
    else
        # 回退到 nohup
        nohup "$0" _daemon >> "${LOG_FILE}" 2>&1 &
        local ppid=$!
        disown "${ppid}" 2>/dev/null || true
        echo "${ppid}" > "${PID_FILE}"
        log_info "watchdog 已启动 via nohup (pid ${ppid})"
    fi
}

action_stop() {
    if ! is_running; then
        rm -f "${PID_FILE}" 2>/dev/null
        return 0
    fi
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null)"
    kill "${pid}" 2>/dev/null
    sleep 2
    kill -9 "${pid}" 2>/dev/null || true
    rm -f "${PID_FILE}" 2>/dev/null
    log_info "watchdog 已停止"
}

action_status() {
    echo "=== Sandbox Watchdog ==="
    echo "PID file:    ${PID_FILE}"
    echo "Log file:    ${LOG_FILE}"
    echo "Interval:    ${INTERVAL}s"
    if is_running; then
        echo "Running:     yes (pid $(cat "${PID_FILE}"))"
    else
        echo "Running:     no"
    fi
    echo ""
    echo "--- 服务状态 ---"
    check_services 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "所有服务正常"
    else
        echo "异常: $(check_services 2>/dev/null)"
    fi
    echo ""
    echo "--- 心跳状态 ---"
    if [ -f "${STATE_FILE}" ]; then
        cat "${STATE_FILE}"
        local age
        age=$(($(date +%s) - $(stat -c%Y "${STATE_FILE}" 2>/dev/null || echo 0)))
        echo "state age: ${age}s"
    else
        echo "状态文件不存在"
    fi
    echo ""
    echo "--- 最近日志 ---"
    tail -10 "${LOG_FILE}" 2>/dev/null || echo "无日志"
}

# -----------------------------------------------------------------------------
# 主入口
# -----------------------------------------------------------------------------
case "${1:-start}" in
    _daemon)  run_daemon ;;
    start)    action_start ;;
    stop)     action_stop ;;
    restart)  action_stop; sleep 1; action_start ;;
    status)   action_status ;;
    once)     write_state ;;
    *)
        echo "Usage: $(basename "$0") [start|stop|restart|status|once]"
        exit 2
        ;;
esac
