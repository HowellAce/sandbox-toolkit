#!/bin/bash
# 沙箱启动时自动恢复所有服务 v3（supervisor集成版）
# 核心改进：将服务注册到supervisor，实现真正的自动启动和崩溃恢复
LOG_FILE="/workspace/autostart.log"

log() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $1" | tee -a "$LOG_FILE"
}

main() {
    log "=== 沙箱自动启动脚本 v3 (supervisor集成) ==="

    # 0. 恢复 /www 符号链接（沙箱重启后会丢失）
    if [ ! -d "/www/server/panel" ]; then
        log "恢复 /www 符号链接..."
        mkdir -p /workspace/www
        ln -sf /workspace/www /www
    fi

    # 1. 恢复 bt 启动脚本
    if [ ! -f "/etc/init.d/bt" ] && [ -f "/www/server/panel/init.sh" ]; then
        log "恢复 bt 启动脚本..."
        cp /www/server/panel/init.sh /etc/init.d/bt 2>/dev/null
        chmod +x /etc/init.d/bt 2>/dev/null
    fi

    # 2. 确保 debug.pl 存在（让BT-Panel前台运行，适配supervisor）
    touch /www/server/panel/data/debug.pl

    # 3. 确保 BT-Panel 脚本已patch（debug模式跳过daemonize）
    if ! grep -q "if not is_debug" /www/server/panel/BT-Panel 2>/dev/null; then
        log "Patch BT-Panel: debug模式跳过daemonize..."
        /www/server/panel/pyenv/bin/python3 -c "
with open('/www/server/panel/BT-Panel', 'r') as f:
    c = f.read()
old = '        # 守护进程模式\n        daemonize()'
new = '        # 守护进程模式（debug模式下跳过，适配supervisor）\n        if not is_debug:\n            daemonize()'
if old in c:
    with open('/www/server/panel/BT-Panel', 'w') as f:
        f.write(c.replace(old, new, 1))
    print('BT-Panel patched')
" 2>&1
    fi

    # 3.5 重建 agent-tool-host wrapper（开机自动恢复服务）
    if [ ! -f /app/bin/agent-tool-host.orig ]; then
        if file /app/bin/agent-tool-host 2>/dev/null | grep -q "ELF"; then
            log "创建 agent-tool-host wrapper..."
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
            log "agent-tool-host wrapper 已创建"
        fi
    fi

    # 4. 注册服务到supervisor
    if [ -f "/workspace/supervisor-bt.conf" ]; then
        log "注册服务到supervisor..."
        # 添加include指令（如果不存在）
        if ! grep -q "include" /app/supervisord.conf 2>/dev/null; then
            echo "" >> /app/supervisord.conf
            echo "[include]" >> /app/supervisord.conf
            echo "files = /workspace/supervisor-bt.conf" >> /app/supervisord.conf
        fi
        # 重新加载supervisor配置
        supervisorctl reread 2>&1 | tee -a "$LOG_FILE"
        supervisorctl update 2>&1 | tee -a "$LOG_FILE"
    else
        log "ERROR: /workspace/supervisor-bt.conf 不存在，回退到手动启动"
        # 回退方案：手动启动
        if ! pgrep -f "BT-Panel" > /dev/null 2>&1; then
            cd /www/server/panel && setsid bash -c "nohup /www/server/panel/pyenv/bin/python3 /www/server/panel/BT-Panel > /tmp/bt-panel.log 2>&1 &" > /dev/null 2>&1
        fi
        if ! ss -tlnp 2>/dev/null | grep -q ":18099"; then
            setsid bash -c "nohup python3 /workspace/bt-proxy3.py > /tmp/bt-proxy3.log 2>&1 &" > /dev/null 2>&1
        fi
        if ! ss -tlnp 2>/dev/null | grep -q ":7844"; then
            setsid bash -c "nohup python3 /workspace/cf-edge-proxy.py > /tmp/cf-edge-proxy.log 2>&1 &" > /dev/null 2>&1
        fi
        if [ -f "/workspace/cf-tunnel-token.txt" ] && ! pgrep -f "cloudflared" > /dev/null 2>&1; then
            TOKEN=$(cat /workspace/cf-tunnel-token.txt)
            setsid bash -c "TUNNEL_EDGE='127.0.0.1:7844' nohup /workspace/cloudflared tunnel --no-autoupdate --no-prechecks --protocol http2 --metrics 127.0.0.1:20241 run --token '$TOKEN' > /tmp/cf-tunnel.log 2>&1 &" > /dev/null 2>&1
        fi
    fi

    # 5. 启动bt-watchdog（作为额外保障）
    if ! pgrep -f "bt-watchdog.sh" > /dev/null 2>&1; then
        setsid bash -c "nohup bash /workspace/bt-watchdog.sh > /tmp/bt-watchdog.log 2>&1 &" > /dev/null 2>&1
    fi

    # 7. 修复安全风险（非重负载，可安全执行）
    if [ -f "/workspace/fix-security.sh" ]; then
        log "修复安全风险..."
        bash /workspace/fix-security.sh >> "$LOG_FILE" 2>&1
    fi

    log "=== 自动启动完成 ==="
    supervisorctl status 2>&1 | tee -a "$LOG_FILE"
}

main "$@"
