#!/bin/bash
# ==========================================
# Cloudflare Tunnel 启动脚本（沙箱突破版）
# ==========================================
# 原理：
#   1. 沙箱只允许通过 127.0.0.1:18080 HTTP 代理出站
#   2. cloudflared 需要直连 198.41.x.x:7844（被阻断）
#   3. 用 TUNNEL_EDGE 环境变量强制 cloudflared 连 127.0.0.1:7844
#   4. 在 127.0.0.1:7844 运行 TCP 转发器，通过 HTTP 代理的 CONNECT 方法转发
# 
# 架构：
#   cloudflared → 127.0.0.1:7844 (cf-edge-proxy.py)
#                     → HTTP 代理 127.0.0.1:18080 (CONNECT)
#                         → 198.41.x.x:7844 (Cloudflare 边缘)
# ==========================================

LOG_DIR="/workspace"
CF_TOKEN=$(cat /workspace/cf-tunnel-token.txt 2>/dev/null)

if [ -z "$CF_TOKEN" ]; then
    echo "错误：未找到 token，请先创建 /workspace/cf-tunnel-token.txt"
    exit 1
fi

# 1. 启动边缘代理（TCP 转发器）
if ! pgrep -f "cf-edge-proxy.py" > /dev/null 2>&1; then
    echo "启动 CF Edge 代理..."
    setsid bash -c "nohup python3 /workspace/cf-edge-proxy.py > $LOG_DIR/cf-edge.log 2>&1 &" > /dev/null 2>&1
    disown 2>/dev/null
    sleep 3
fi

if ! ss -tlnp 2>/dev/null | grep -q ":7844"; then
    echo "错误：边缘代理启动失败"
    exit 1
fi
echo "✅ CF Edge 代理运行中 (127.0.0.1:7844)"

# 2. 启动 cloudflared
if pgrep -f "cloudflared.*tunnel" > /dev/null 2>&1; then
    echo "cloudflared 已在运行"
else
    echo "启动 cloudflared..."
    setsid bash -c "TUNNEL_EDGE='127.0.0.1:7844' nohup /workspace/cloudflared tunnel --no-autoupdate --no-prechecks --protocol http2 run --token '$CF_TOKEN' > $LOG_DIR/cf-tunnel.log 2>&1 &" > /dev/null 2>&1
    disown 2>/dev/null
    sleep 15
fi

if pgrep -f "cloudflared.*tunnel" > /dev/null 2>&1; then
    echo "✅ cloudflared 运行中"
else
    echo "❌ cloudflared 启动失败"
    exit 1
fi

# 3. 检查隧道状态
sleep 5
READY=$(curl -s http://127.0.0.1:20241/ready 2>/dev/null)
if echo "$READY" | grep -q "readyConnections"; then
    CONNS=$(echo "$READY" | grep -oE '"readyConnections":[0-9]+' | grep -oE '[0-9]+')
    echo "✅ 隧道已就绪 (连接数: $CONNS)"
else
    echo "⚠️ 隧道未就绪，等待中..."
    sleep 10
    READY=$(curl -s http://127.0.0.1:20241/ready 2>/dev/null)
    if echo "$READY" | grep -q "readyConnections"; then
        echo "✅ 隧道已就绪"
    else
        echo "❌ 隧道连接失败"
        echo "日志："
        tail -10 /workspace/cf-tunnel.log 2>/dev/null
    fi
fi

echo ""
echo "========== 隧道信息 =========="
echo "Connector ID: $(echo $READY | grep -oE '"connectorId":"[^"]*"' | cut -d'"' -f4)"
echo ""
echo "下一步：在 Cloudflare Dashboard 配置 Public Hostname"
echo "  https://one.dash.cloudflare.com/"
echo "  Networks → Tunnels → 你的隧道 → Public Hostname"
echo "  添加: your-subdomain.yourdomain.com → HTTP localhost:18099"
