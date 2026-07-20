#!/bin/bash
# ==========================================
# Permanent Full Root Solution
# Uses persistent namespace daemon + nsenter
# ==========================================

PERMAROOT_DIR="/data/user/work/permaroot"
PIDFILE="/tmp/permaroot-daemon.pid"
DAEMON_PID=""

mkdir -p "$PERMAROOT_DIR"

# --- 函数：检查 daemon 是否运行 ---
is_running() {
    if [ -f "$PIDFILE" ]; then
        local pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            DAEMON_PID="$pid"
            return 0
        fi
    fi
    return 1
}

# --- 函数：启动 daemon ---
start_daemon() {
    if is_running; then
        echo "[+] Daemon 已在运行 (PID: $DAEMON_PID)"
        return 0
    fi

    echo "[*] 启动 permanent full-root daemon..."

    # 在新 namespace 中启动持久进程
    unshare -U -r -m -n bash -c '
        # 写入 PID
        echo $$ > /tmp/permaroot-daemon.pid

        # 持久运行
        exec sleep infinity
    ' &

    # 等待 PID 文件
    local retries=0
    while [ ! -f "$PIDFILE" ] && [ $retries -lt 10 ]; do
        sleep 0.2
        retries=$((retries + 1))
    done

    if is_running; then
        echo "[+] Daemon 启动成功 (PID: $DAEMON_PID)"

        # 验证 capabilities
        local caps=$(nsenter -t "$DAEMON_PID" -U -- cat /proc/self/status 2>/dev/null | grep CapEff | awk '{print $2}')
        if [ "$caps" = "000001ffffffffff" ]; then
            echo "[+] 验证成功: 所有 41 个 capabilities 已激活"
        else
            echo "[-] 警告: capabilities 异常: $caps"
        fi
    else
        echo "[-] Daemon 启动失败"
        return 1
    fi
}

# --- 主入口 ---
case "${1:-start}" in
    start)
        start_daemon
        ;;
    stop)
        if is_running; then
            kill "$DAEMON_PID" 2>/dev/null
            rm -f "$PIDFILE"
            echo "[+] Daemon 已停止 (PID: $DAEMON_PID)"
        else
            echo "[-] Daemon 未运行"
        fi
        ;;
    status)
        if is_running; then
            echo "[+] Daemon 运行中 (PID: $DAEMON_PID)"
            echo "    CapEff: $(nsenter -t $DAEMON_PID -U -- cat /proc/self/status 2>/dev/null | grep CapEff)"
        else
            echo "[-] Daemon 未运行"
        fi
        ;;
    *)
        echo "用法: $0 {start|stop|status}"
        exit 1
        ;;
esac
