#!/bin/bash
# ==========================================
# Configuration for Sandbox Recovery
# ==========================================

# Workspace directory (persistent)
WORK_DIR="/workspace"

# Sakura Frp configuration
# NOTE: Replace with your actual credentials before use
FRPC_TOKEN="YOUR_FRPC_TOKEN"
FRPC_TUNNEL="YOUR_TUNNEL_ID"
FRPC_PUBLIC_ADDR="YOUR_FRP_SERVER:YOUR_REMOTE_PORT"
FRPC_DOWNLOAD_URL="https://nya.globalslb.net/natfrp/client/frpc/0.51.0-sakura-12.3/frpc_linux_amd64"

# Root password for SSH (set your own password)
ROOT_PASSWORD="YOUR_ROOT_PASSWORD"

# Supervisord configuration
SUPERVISOR_SOCK="unix:///run/supervisor.sock"
VM_SERVER_CONF="/opt/gem/supervisord/supervisord.go_vm_server.conf"
VM_SERVER_NAME="vm_server"
NGINX_SERVICE="nginx"

# NC wrapper path
NC_WRAPPER_PATH="/home/user/.local/bin/nc"

# Frpc paths
FRPC_PATH="/home/user/frpc"
FRPC_CONFIG="/home/user/frpc.ini"
FRPC_LOG="/home/user/frpc.log"
# Persistent frpc binary in workspace (survives sandbox reset)
FRPC_PERSISTENT_PATH="$WORK_DIR/doubao_work/bin/frpc"

# Memory file
MEMORY_FILE="$WORK_DIR/doubao_work/memory.md"

# Natfrp Service (Sakura Frp Launcher)
NATFRP_SERVICE_ARCHIVE="$WORK_DIR/doubao_work/source/natfrp-service_linux_amd64.tar.zst"
NATFRP_SERVICE_INSTALL_URL="https://doc.natfrp.com/launcher.sh"
