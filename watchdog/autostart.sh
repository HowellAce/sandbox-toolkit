#!/bin/bash
# 沙箱启动时自动恢复所有服务 v2（持久化版）
# 更新：bt-proxy3 + cloudflared(edge proxy) + bt-watchdog
LOG_FILE="/workspace/autostart.log"

log() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $1" | tee -a "$LOG_FILE"
}

start_protected() {
    local name=$1
    local start_cmd=$2
    local log_file=$3
    log "启动 $name ..."
    setsid bash -c "nohup $start_cmd > $log_file 2>&1 &" > /dev/null 2>&1
    disown 2>/dev/null
    sleep 2
}

main() {
    log "=== 沙箱自动启动脚本 v2 开始 ==="

    # 0. 恢复 /www 符号链接（沙箱重启后会丢失）
    if [ ! -d "/www/server/panel" ]; then
        log "恢复 /www 符号链接..."
        mkdir -p /workspace/www
        ln -sf /workspace/www /www
    fi

    # 1. 恢复 bt 命令（如果丢失）
    if [ ! -f "/etc/init.d/bt" ] && [ -f "/www/server/panel/init.sh" ]; then
        log "恢复 bt 启动脚本..."
        cp /www/server/panel/init.sh /etc/init.d/bt 2>/dev/null
        chmod +x /etc/init.d/bt 2>/dev/null
    fi

    # 2. 启动宝塔面板
    if ! pgrep -f "BT-Panel" > /dev/null 2>&1; then
        start_protected "BT-Panel" "cd /www/server/panel && /www/server/panel/pyenv/bin/python3 /www/server/panel/BT-Panel" "/tmp/bt-panel.log"
    fi

    # 3. 启动 BT-Proxy3（多线程版）
    if ! ss -tlnp 2>/dev/null | grep -q ":18099"; then
        start_protected "BT-Proxy3" "python3 /workspace/bt-proxy3.py" "/tmp/bt-proxy3.log"
    fi

    # 4. 启动 CF Edge Proxy（TCP 转发器）
    if ! ss -tlnp 2>/dev/null | grep -q ":7844"; then
        start_protected "CF-Edge-Proxy" "python3 /workspace/cf-edge-proxy.py" "/tmp/cf-edge-proxy.log"
    fi

    # 5. 启动 Cloudflare Tunnel
    if [ -f "/workspace/cf-tunnel-token.txt" ]; then
        TOKEN=$(cat /workspace/cf-tunnel-token.txt)
        if ! pgrep -f "cloudflared" > /dev/null 2>&1; then
            start_protected "Cloudflare Tunnel" "TUNNEL_EDGE='127.0.0.1:7844' /workspace/cloudflared tunnel --no-autoupdate --no-prechecks --protocol http2 --metrics 127.0.0.1:20241 run --token '$TOKEN'" "/tmp/cf-tunnel.log"
        fi
    fi

    # 6. 启动 BT Watchdog v3
    if ! pgrep -f "bt-watchdog.sh" > /dev/null 2>&1; then
        start_protected "BT-Watchdog" "bash /workspace/bt-watchdog.sh" "/tmp/bt-watchdog.log"
    fi

    log "=== 自动启动完成 ==="
}

main "$@"
