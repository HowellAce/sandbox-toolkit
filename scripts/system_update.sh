#!/bin/bash
# ==========================================
# System Update Script (Fully Automatic)
# ==========================================
# This script runs system updates completely automatically.
# No user intervention required - all prompts are answered with yes.
#
# Usage: bash scripts/system_update.sh
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"

# Load config and utilities
if [ -f "$MODULES_DIR/config.sh" ]; then
    source "$MODULES_DIR/config.sh"
fi
if [ -f "$MODULES_DIR/utils.sh" ]; then
    source "$MODULES_DIR/utils.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $1"; }
    log_ok() { echo "[OK] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_warn() { echo "[WARN] $1"; }
fi

echo "=========================================="
echo "  System Update (Fully Automatic)"
echo "=========================================="
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    log_info "Run the recovery script first to get root access"
    exit 1
fi

log_info "Starting system update..."
echo ""

# Step 1: Update package lists
log_info "Updating package lists..."
apt update -y 2>&1 | tail -5
log_ok "Package lists updated"
echo ""

# Step 2: Upgrade all packages
log_info "Upgrading all packages (this may take a while)..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" 2>&1 | tail -10
log_ok "Packages upgraded"
echo ""

# Step 3: Full upgrade (handles dependency changes)
log_info "Performing full upgrade..."
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" 2>&1 | tail -5
log_ok "Full upgrade complete"
echo ""

# Step 4: Remove unused packages
log_info "Removing unused packages..."
apt autoremove -y 2>&1 | tail -3
log_ok "Unused packages removed"
echo ""

# Step 5: Clean up
log_info "Cleaning up package cache..."
apt clean 2>&1
apt autoclean 2>&1
log_ok "Cache cleaned"
echo ""

# Summary
echo "=========================================="
echo "  System Update Complete!"
echo "=========================================="
echo ""
log_ok "All updates applied successfully"
echo ""
echo "Note: Some services may need a restart to use updated versions."
echo "If kernel was updated, a sandbox restart may be needed."
