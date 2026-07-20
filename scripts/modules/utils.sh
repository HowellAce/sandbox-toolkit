#!/bin/bash
# ==========================================
# Utility Functions Module (Improved)
# Added: logging functions, error handling helpers
# ==========================================

# Log file (default path)
LOG_FILE="/workspace/recovery.log"

# Check if config is loaded (warn but don't fail - allow degraded mode)
if [ -z "$WORK_DIR" ]; then
    echo "[WARN] Config not loaded. Running in degraded mode. Source config.sh first for full functionality."
    # Set default values for critical variables
    WORK_DIR="/home/user/.super_doubao/super-doubao-runtime/workspace"
    NC_WRAPPER_PATH="/home/user/.local/bin/nc"
    VM_SERVER_CONF="/opt/gem/supervisord/supervisord.go_vm_server.conf"
    SUPERVISOR_SOCK="unix:///run/supervisor.sock"
fi

# Logging functions
log_info() {
    echo "[INFO] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"
}

log_warn() {
    echo "[WARN] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$LOG_FILE"
}

log_error() {
    echo "[ERROR] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"
}

log_ok() {
    echo "[OK] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1" >> "$LOG_FILE"
}

log_skip() {
    echo "[SKIP] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SKIP] $1" >> "$LOG_FILE"
}

# Print header
print_header() {
    echo "=========================================="
    echo "  Sandbox Recovery Script (v3)"
    echo "=========================================="
    echo ""
    echo "Log file: $LOG_FILE"
    echo ""
}

# Show summary after recovery
show_summary() {
    echo ""
    echo "=========================================="
    echo "  Recovery Complete!"
    echo "=========================================="
    echo ""
    echo "SSH Info:"
    echo "  Port: 22 (system-level)"
    echo "  User: root"
    echo "  Pass: ${ROOT_PASSWORD}"
    echo ""
    echo "Recovery log: $LOG_FILE"
    echo ""
    echo "Tip: Save important files to workspace/"
    echo ""
    echo "Health check: bash doubao_work/scripts/health_check.sh"
    echo ""
}

# Print section header
print_section() {
    echo ""
    echo "--- $1 ---"
    echo ""
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/config.sh"
    echo "Utility module loaded successfully."
    echo "Log file: $LOG_FILE"
fi
