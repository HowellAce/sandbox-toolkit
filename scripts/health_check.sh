#!/bin/bash
# ==========================================
# Health Check Script (v4)
# Comprehensive status check for all sandbox services
#
# Usage: bash health_check.sh
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"

# Load config and utils
source "$MODULES_DIR/config.sh"
source "$MODULES_DIR/utils.sh"

echo "=========================================="
echo "  Sandbox Health Check (v4)"
echo "=========================================="
echo ""

# Counters
PASS=0
FAIL=0
WARN=0
SKIP=0

check_item() {
    local name="$1"
    local status="$2"
    local detail="$3"
    
    case "$status" in
        ok)
            echo "[OK]   $name"
            [ -n "$detail" ] && echo "       $detail"
            PASS=$((PASS + 1))
            ;;
        fail)
            echo "[FAIL] $name"
            [ -n "$detail" ] && echo "       $detail"
            FAIL=$((FAIL + 1))
            ;;
        warn)
            echo "[WARN] $name"
            [ -n "$detail" ] && echo "       $detail"
            WARN=$((WARN + 1))
            ;;
        skip)
            echo "[SKIP] $name"
            [ -n "$detail" ] && echo "       $detail"
            SKIP=$((SKIP + 1))
            ;;
    esac
}

# ==========================================
# 1. Permissions
# ==========================================
echo "--- Permissions ---"
if [ "$(id -u)" = "0" ]; then
    check_item "Root access" "ok" "Running as root"
else
    check_item "Root access" "warn" "Running as user (exploit may not have triggered yet)"
fi
echo ""

# ==========================================
# 2. Exploit Status
# ==========================================
echo "--- Exploit Status ---"

# VM Server config
if grep -q '^user=root' "$VM_SERVER_CONF" 2>/dev/null; then
    check_item "VM Server config" "ok" "user=root (exploit applied)"
else
    check_item "VM Server config" "warn" "user=user (exploit not applied)"
fi

# NC wrapper existence
if [ -x "$NC_WRAPPER_PATH" ]; then
    # Check wrapper content
    if grep -q 'supervisor.*restart.*vm_server' "$NC_WRAPPER_PATH" 2>/dev/null; then
        check_item "NC wrapper" "ok" "Present and valid"
    else
        check_item "NC wrapper" "warn" "Present but content may be invalid"
    fi
else
    check_item "NC wrapper" "warn" "Not found"
fi

# VM Server process user
VM_SERVER_USER=$(ps aux | grep '[m]cp_vm_server' | awk '{print $1}' | head -1)
if [ -n "$VM_SERVER_USER" ]; then
    if [ "$VM_SERVER_USER" = "root" ]; then
        check_item "VM Server process" "ok" "Running as root"
    else
        check_item "VM Server process" "warn" "Running as $VM_SERVER_USER"
    fi
else
    check_item "VM Server process" "fail" "Not found"
fi
echo ""

# ==========================================
# 3. SSH
# ==========================================
echo "--- SSH ---"
if pgrep -x sshd >/dev/null 2>&1; then
    SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | head -1)
    check_item "SSH server" "ok" "Running on $SSH_PORT"
else
    check_item "SSH server" "fail" "Not running"
fi
echo ""

# ==========================================
# 4. Frp
# ==========================================
echo "--- Frp ---"
if pgrep -f "frpc -f " >/dev/null 2>&1; then
    check_item "Frpc client" "ok" "Running"
else
    # Check if config has placeholders
    if grep -q "YOUR_" "$FRPC_CONFIG" 2>/dev/null; then
        check_item "Frpc client" "skip" "Not configured (token/tunnel ID are placeholders)"
    else
        check_item "Frpc client" "fail" "Not running"
    fi
fi
echo ""

# ==========================================
# 5. Sandbox Reset Tracker
# ==========================================
echo "--- Reset Tracker ---"
TRACKER_SCRIPT="$WORK_DIR/doubao_work/sandbox-reset-tracker.sh"
PID_FILE="$WORK_DIR/.sandbox-tracker.pid"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    check_item "Reset tracker daemon" "ok" "Running (PID: $(cat "$PID_FILE"))"
else
    check_item "Reset tracker daemon" "warn" "Not running"
fi

# Check state file
if [ -f "$WORK_DIR/.sandbox-state" ]; then
    check_item "Reset tracker state" "ok" "State file present"
else
    check_item "Reset tracker state" "warn" "No state file (run 'check' first)"
fi
echo ""

# ==========================================
# 6. Core Services
# ==========================================
echo "--- Core Services ---"

# Nginx
if pgrep -f "nginx: master" >/dev/null 2>&1; then
    check_item "Nginx" "ok" "Running"
else
    check_item "Nginx" "fail" "Not running (critical - exploit depends on this)"
fi

# VM Server
if pgrep -f "mcp_vm_server" >/dev/null 2>&1; then
    check_item "VM Server" "ok" "Running"
else
    check_item "VM Server" "fail" "Not running"
fi

# Supervisor socket
if [ -S "/run/supervisor.sock" ]; then
    check_item "Supervisor socket" "ok" "Present"
else
    check_item "Supervisor socket" "fail" "Not found"
fi
echo ""

# ==========================================
# 7. Ports
# ==========================================
echo "--- Listening Ports ---"

check_port() {
    local port="$1"
    local name="$2"
    if ss -tlnp | grep -q ":$port " 2>/dev/null; then
        check_item "$name (port $port)" "ok" "Listening"
    else
        check_item "$name (port $port)" "warn" "Not listening"
    fi
}

check_port "22" "SSH"
check_port "8080" "Nginx"
check_port "8200" "Code Server"
check_port "9222" "Chrome Debug"
echo ""

# ==========================================
# 8. Workspace & Files
# ==========================================
echo "--- Workspace & Files ---"

if [ -d "$WORK_DIR" ]; then
    check_item "Workspace directory" "ok" "Exists"
else
    check_item "Workspace directory" "fail" "Not found"
fi

if [ -d "$WORK_DIR/doubao_work" ]; then
    check_item "doubao_work directory" "ok" "Exists"
else
    check_item "doubao_work directory" "fail" "Not found"
fi

if [ -f "$MEMORY_FILE" ]; then
    check_item "Memory file" "ok" "Present"
else
    check_item "Memory file" "warn" "Not found"
fi
echo ""

# ==========================================
# Summary
# ==========================================
echo "=========================================="
echo "  Summary"
echo "=========================================="
echo ""
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
echo "  Warn: $WARN"
[ $SKIP -gt 0 ] && echo "  Skip: $SKIP"
echo ""
if [ $FAIL -gt 0 ]; then
    echo "  Status: ISSUES FOUND"
    echo "  Check failed items above"
elif [ $WARN -gt 0 ]; then
    echo "  Status: PARTIAL (warnings only)"
    echo "  Core services are working"
else
    echo "  Status: ALL GOOD"
fi
echo ""
