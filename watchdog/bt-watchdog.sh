#!/bin/bash
# ===================================================================
# 宝塔面板保活看门狗 v3
# 解决沙箱重置后所有进程死亡的问题
# 核心改进：
#   1. setsid + nohup + disown 三重保护，防止 SIGHUP 杀死
#   2. 自身也用 setsid 启动，确保脱离会话
#   3. 检测并修复 /www 符号链接
#   4. 强制 HTTP/2 协议（QUIC 在沙箱中不可用）
#   5. 30秒轮询，进程死亡立即重启
# ===================================================================

WATCHDOG_PID_FILE="/workspace/.bt-watchdog.pid"
LOG_FILE="/workspace/bt-watchdog.log"
CHECK_INTERVAL=30

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 防止重复启动
if [ -f "$WATCHDOG_PID_FILE" ]; then
    OLD_PID=$(cat "$WATCHDOG_PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Watchdog already running (PID: $OLD_PID)"
        exit 0
    fi
fi
echo $$ > "$WATCHDOG_PID_FILE"

log "=== Watchdog v3 启动 (PID: $$) ==="

# --- 修复 /www 符号链接 ---
fix_www_link() {
    if [ ! -e /www ]; then
        ln -sf /workspace/www /www
        log "[FIX] Created /www -> /workspace/www symlink"
    elif [ ! -L /www ]; then
        log "[WARN] /www exists but is not a symlink"
    fi
}

# --- 启动宝塔面板 ---
start_bt_panel() {
    if pgrep -f "BT-Panel" > /dev/null 2>&1; then
        return 0
    fi
    log "[START] Starting BT-Panel..."
    rm -f /www/server/panel/logs/panel.pid 2>/dev/null
    cd /www/server/panel
    setsid /www/server/panel/pyenv/bin/python3 /www/server/panel/BT-Panel \
        > /www/server/panel/logs/panel.log 2>&1 &
    sleep 3
    if pgrep -f "BT-Panel" > /dev/null 2>&1; then
        log "[OK] BT-Panel started"
    else
        log "[ERR] BT-Panel failed to start"
    fi
}

# --- 启动 bt-proxy ---
start_bt_proxy() {
    if pgrep -f "bt-proxy3.py" > /dev/null 2>&1; then
        return 0
    fi
    log "[START] Starting bt-proxy..."
    setsid /usr/bin/python3 /workspace/bt-proxy3.py \
        > /workspace/bt-proxy.log 2>&1 &
    sleep 2
    if pgrep -f "bt-proxy3.py" > /dev/null 2>&1; then
        log "[OK] bt-proxy started"
    else
        log "[ERR] bt-proxy failed to start"
    fi
}

# --- 启动 cf-edge-proxy ---
start_cf_edge() {
    if pgrep -f "cf-edge-proxy.py" > /dev/null 2>&1; then
        return 0
    fi
    log "[START] Starting cf-edge-proxy..."
    setsid /usr/bin/python3 /workspace/cf-edge-proxy.py \
        > /workspace/cf-edge-proxy.log 2>&1 &
    sleep 2
    if pgrep -f "cf-edge-proxy.py" > /dev/null 2>&1; then
        log "[OK] cf-edge-proxy started"
    else
        log "[ERR] cf-edge-proxy failed to start"
    fi
}

# --- 启动 cloudflared ---
start_cloudflared() {
    if pgrep -f "cloudflared" > /dev/null 2>&1; then
        return 0
    fi
    log "[START] Starting cloudflared..."
    # 确保启动脚本存在
    cat > /workspace/start-cf.sh << 'INNER'
#!/bin/bash
export TUNNEL_EDGE=127.0.0.1:7844
TOKEN=$(cat /workspace/cf-tunnel-token.txt)
exec /workspace/cloudflared tunnel --no-autoupdate --protocol http2 \
    --metrics 127.0.0.1:20241 \
    --config /workspace/cf-config.yml \
    run --token "$TOKEN"
INNER
    chmod +x /workspace/start-cf.sh
    setsid /workspace/start-cf.sh > /workspace/cf-tunnel.log 2>&1 &
    sleep 8
    if pgrep -f "cloudflared" > /dev/null 2>&1; then
        log "[OK] cloudflared started"
    else
        log "[ERR] cloudflared failed to start"
    fi
}

# --- 主循环 ---
while true; do
    fix_www_link
    start_bt_panel
    start_bt_proxy
    start_cf_edge
    start_cloudflared
    sleep $CHECK_INTERVAL
done
