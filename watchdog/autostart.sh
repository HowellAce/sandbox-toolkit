#!/bin/bash
# 沙箱启动时自动恢复所有服务（持久化版）
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
    log "=== 沙箱自动启动脚本开始 ==="
    
    # 0. 恢复 /www 符号链接（沙箱重启后会丢失）
    if [ ! -d "/www/server/panel" ]; then
        log "恢复 /www 符号链接..."
        mkdir -p /workspace/www
        ln -sf /workspace/www /www
    fi
    
    # 1. 恢复 bt 命令（如果丢失）
    if [ ! -f "/etc/init.d/bt" ] && [ -f "/workspace/www/server/panel/init.sh" ]; then
        log "恢复 bt 启动脚本..."
        cp /workspace/www/server/panel/init.sh /etc/init.d/bt 2>/dev/null
        chmod +x /etc/init.d/bt 2>/dev/null
        ln -sf /www/server/panel/bt /usr/bin/bt 2>/dev/null
    fi
    
    # 2. 启动宝塔面板
    if ! pgrep -f "BT-Panel" > /dev/null 2>&1; then
        if [ -f "/etc/init.d/bt" ]; then
            start_protected "BT-Panel" "/etc/init.d/bt start" "/tmp/bt-autostart.log"
        elif [ -f "/workspace/www/server/panel/BT-Panel" ]; then
            start_protected "BT-Panel" "cd /workspace/www/server/panel && python3 BT-Panel" "/tmp/bt-autostart.log"
        fi
    fi
    
    # 3. 启动 BT-Proxy
    if ! ss -tlnp 2>/dev/null | grep -q ":18099"; then
        start_protected "BT-Proxy" "python3 /workspace/bt-proxy2.py" "/tmp/btproxy-autostart.log"
    fi
    
    # 4. 启动 Serveo 隧道
    if ! pgrep -f "ssh.*serveo" > /dev/null 2>&1; then
        start_protected "Serveo" "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ProxyCommand='nc -X connect -x 127.0.0.1:18080 %h %p' -R 80:127.0.0.1:18099 serveo.net" "/tmp/serveo-autostart.log"
    fi
    
    # 5. 启动 SSH
    if ! ss -tlnp 2>/dev/null | grep -q ":22 "; then
        start_protected "SSH" "/usr/sbin/sshd" "/tmp/sshd-autostart.log"
    fi
    
    # 6. 启动 Cloudflare Tunnel（如果配置了 token）
    if [ -f "/workspace/cf-tunnel-token.txt" ]; then
        TOKEN=$(cat /workspace/cf-tunnel-token.txt)
        if ! pgrep -f "cloudflared" > /dev/null 2>&1; then
            start_protected "Cloudflare Tunnel" "/workspace/cloudflared tunnel --no-autoupdate run --token $TOKEN" "/tmp/cf-tunnel.log"
        fi
    fi
    
    # 7. 启动 Watchdog
    if ! pgrep -f "watchdog.sh _run" > /dev/null 2>&1; then
        start_protected "Watchdog" "bash /workspace/watchdog.sh _run" "/tmp/watchdog-autostart.log"
    fi
    
    log "=== 自动启动完成 ==="
}

main "$@"
