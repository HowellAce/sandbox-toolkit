#!/bin/bash
# ==========================================
# Natfrp Service Installer
# Priority: local archive first, download only if missing/corrupted
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"

# Load config
source "$MODULES_DIR/config.sh"
source "$MODULES_DIR/utils.sh"

print_section "Natfrp Service Installer"

# Check if archive is valid
is_archive_valid() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    if ! file "$file" 2>/dev/null | grep -q "Zstandard"; then
        return 1
    fi
    local size=$(stat -c%s "$file" 2>/dev/null)
    if [ "$size" -lt 5000000 ]; then
        return 1
    fi
    return 0
}

# Download official installer
download_installer() {
    log_info "Downloading official installer..."
    local tmp_script="/tmp/natfrp-launcher.sh"
    
    if command -v curl &>/dev/null; then
        curl -sSL "$NATFRP_SERVICE_INSTALL_URL" -o "$tmp_script" 2>/dev/null || return 1
    elif command -v wget &>/dev/null; then
        wget -q "$NATFRP_SERVICE_INSTALL_URL" -O "$tmp_script" 2>/dev/null || return 1
    else
        return 1
    fi
    
    if [ -s "$tmp_script" ]; then
        echo "$tmp_script"
        return 0
    fi
    return 1
}

# Install from local archive
install_from_archive() {
    log_info "Installing from local archive..."
    
    # Ensure zstd is available
    if ! command -v zstd &>/dev/null; then
        log_info "Installing zstd..."
        apt install -y zstd >/dev/null 2>&1 || return 1
    fi
    
    # Extract to temp dir
    local tmp_dir="/tmp/natfrp-install"
    mkdir -p "$tmp_dir"
    tar -xf "$NATFRP_SERVICE_ARCHIVE" -C "$tmp_dir" 2>/dev/null || return 1
    
    # Install binaries
    if [ -f "$tmp_dir/natfrp-service" ]; then
        cp "$tmp_dir/natfrp-service" /usr/local/bin/natfrp-service
        chmod +x /usr/local/bin/natfrp-service
        log_ok "natfrp-service installed"
    fi
    
    if [ -f "$tmp_dir/frpc" ]; then
        cp "$tmp_dir/frpc" /usr/local/bin/frpc
        chmod +x /usr/local/bin/frpc
        log_ok "frpc installed"
    fi
    
    # Cleanup
    rm -rf "$tmp_dir"
    return 0
}

# Main install logic
main() {
    # Check root
    if [ "$(id -u)" != "0" ]; then
        log_error "Root required"
        return 1
    fi
    
    # Try local archive first
    if is_archive_valid "$NATFRP_SERVICE_ARCHIVE"; then
        log_info "Using local archive"
        if install_from_archive; then
            log_ok "Install complete (from local archive)"
            return 0
        fi
        log_warn "Local archive install failed, trying download"
    else
        log_info "Local archive missing/corrupted"
    fi
    
    # Fallback: download official installer
    local installer_script
    if installer_script=$(download_installer); then
        log_info "Running official installer..."
        bash "$installer_script" direct 2>&1 || return 1
        log_ok "Install complete (from official installer)"
        return 0
    fi
    
    log_error "All methods failed"
    return 1
}

main "$@"
