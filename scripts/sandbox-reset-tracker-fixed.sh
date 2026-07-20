#!/bin/bash
# 修复版 sandbox reset tracker - 使用 nohup 替代 setsid

WORK_DIR="/workspace"
STATE_FILE="$WORK_DIR/.sandbox-state"
RESET_LOG="$WORK_DIR/sandbox-reset-log.csv"
HEARTBEAT_LOG="$WORK_DIR/sandbox-tracker-heartbeat.log"
PID_FILE="$WORK_DIR/.sandbox-tracker.pid"
INTERVAL=${HEARTBEAT_INTERVAL:-60}

get_boot_time() { grep '^btime' /proc/stat | awk '{print $2}'; }
log_heartbeat() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$HEARTBEAT_LOG"; }
log_reset() { echo "$(date '+%Y-%m-%d %H:%M:%S'),$1,$2" >> "$RESET_LOG"; }
get_last_boot() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "0"; }
set_boot_time() { echo "$1" > "$STATE_FILE"; }

do_check() {
    current=$(get_boot_time)
    last=$(get_last_boot)
    if [ "$last" = "0" ]; then
        set_boot_time "$current"
        log_heartbeat "First run - boot time: $current"
        echo "Initialized (boot time: $current)"
        return 2
    fi
    if [ "$current" != "$last" ]; then
        log_reset "$last" "$current"
        set_boot_time "$current"
        log_heartbeat "RESET DETECTED! Old: $last, New: $current"
        echo "RESET DETECTED"
        echo "Old boot time: $last"
        echo "New boot time: $current"
        return 1
    fi
    log_heartbeat "Heartbeat OK (boot: $current)"
    echo "No reset (boot time: $current)"
    return 0
}

run_daemon() {
    log_heartbeat "Daemon started (PID: $$, interval: ${INTERVAL}s)"
    while true; do
        do_check > /dev/null 2>&1
        sleep "$INTERVAL"
    done
}

cmd_start() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Already running (PID: $(cat "$PID_FILE"))"
        return 1
    fi
    nohup bash "$0" daemon > /dev/null 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Started (PID: $(cat "$PID_FILE"))"
    else
        echo "Failed to start"
        rm -f "$PID_FILE"
        return 1
    fi
}

cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then echo "Not running"; return 1; fi
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    echo "Stopped (PID: $pid)"
}

cmd_status() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Running (PID: $(cat "$PID_FILE"))"
    else
        echo "Not running"
    fi
    echo "Last recorded boot: $(get_last_boot)"
    echo "Current boot time: $(get_boot_time)"
}

cmd_log() {
    echo "=== Reset Log ==="; [ -f "$RESET_LOG" ] && cat "$RESET_LOG" || echo "(none)"
    echo ""; echo "=== Recent Heartbeats ==="
    [ -f "$HEARTBEAT_LOG" ] && tail -10 "$HEARTBEAT_LOG" || echo "(none)"
}

cmd_stats() {
    if [ -f "$RESET_LOG" ]; then
        echo "Total resets: $(wc -l < "$RESET_LOG")"
        echo "Last reset: $(tail -1 "$RESET_LOG")"
    else
        echo "Total resets: 0"
    fi
    echo "Current boot: $(get_boot_time)"
}

case "${1:-help}" in
    check)  do_check ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    log)    cmd_log ;;
    stats)  cmd_stats ;;
    reset)  rm -f "$STATE_FILE"; echo "State cleared" ;;
    daemon) run_daemon ;;
    *)      echo "Usage: $0 {check|start|stop|status|log|stats|reset|daemon}" ;;
esac
