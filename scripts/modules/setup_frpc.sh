#!/bin/bash
# ==========================================
# Sakura Frp Setup Module (v5 - File Integrity Check)
# Download and start Sakura frp client
# Improvements:
#   - Detect placeholder configuration
#   - Proper logging
#   - Clear setup instructions
#   - Persistent frpc binary in workspace (faster recovery)
#   - Copy from workspace first, download only if missing or corrupted
#   - File integrity check (ELF validation, size check, execution test)
# ==========================================

# Check if config is loaded
if [ -z "$WORK_DIR" ]; then
    echo "[ERROR] Config not loaded. Source config.sh first."
    return 1 2>/dev/null || exit 1
fi

# Check if config is placeholder (not configured)
is_frpc_configured() {
    if [[ "$FRPC_TOKEN" == *"YOUR_"* ]] || [[ "$FRPC_TUNNEL" == *"YOUR_"* ]]; then
        return 1  # Not configured
    fi
    return 0  # Configured
}

# Check if frpc binary is valid (not corrupted)
is_frpc_valid() {
    local file_path="$1"
    
    # Must exist and be executable
    if [ ! -f "$file_path" ] || [ ! -x "$file_path" ]; then
        return 1
    fi
    
    # Must be a valid ELF binary
    if ! file "$file_path" 2>/dev/null | grep -q "ELF.*executable"; then
        return 1
    fi
    
    # Must have reasonable size (at least 1MB)
    local size=$(stat -c%s "$file_path" 2>/dev/null)
    if [ -z "$size" ] || [ "$size" -lt 1000000 ]; then
        return 1
    fi
    
    # Try to run version check (quick sanity test)
    if "$file_path" --version >/dev/null 2>&1; then
        return 0
    fi
    
    # Even if --version fails, it might still work (different frpc versions)
    # As long as it's a valid ELF with reasonable size, consider it valid
    return 0
}

# Get frpc binary - copy from workspace first, download only if missing or corrupted
get_frpc_binary() {
    # Already exists at target path and is valid
    if is_frpc_valid "$FRPC_PATH"; then
        return 0
    fi
    
    # Try copy from persistent workspace location (fast path)
    if is_frpc_valid "$FRPC_PERSISTENT_PATH"; then
        log_info "Copying frpc from workspace cache..."
        cp "$FRPC_PERSISTENT_PATH" "$FRPC_PATH"
        chmod +x "$FRPC_PATH"
        if is_frpc_valid "$FRPC_PATH"; then
            log_ok "Copied from workspace cache"
            return 0
        fi
    fi
    
    # Fallback: download from network
    log_info "Downloading frpc from network..."
    curl -fsSL "$FRPC_DOWNLOAD_URL" -o "$FRPC_PATH" 2>/dev/null
    if [ $? -eq 0 ] && is_frpc_valid "$FRPC_PATH"; then
        chmod +x "$FRPC_PATH"
        log_ok "Downloaded"
        # Save to workspace for future use (persistent cache)
        mkdir -p "$(dirname "$FRPC_PERSISTENT_PATH")"
        cp "$FRPC_PATH" "$FRPC_PERSISTENT_PATH" 2>/dev/null
        if is_frpc_valid "$FRPC_PERSISTENT_PATH"; then
            log_info "Cached to workspace for next time"
        fi
        return 0
    fi
    
    log_error "Download failed"
    return 1
}

# Start frpc - fully background, returns immediately
start_frpc() {
    print_section "Sakura Frp"
    
    # Check if already running (use full path to avoid matching Bash tool's shell process)
    # IMPORTANT: Do NOT use simple pattern like "frpc" or "frpc -f " - they match the
    # Bash tool's command line and cause pkill to kill the shell process (error code -1)
    if pgrep -f "/home/user/frpc -f " > /dev/null 2>&1; then
        log_ok "Already running"
        return 0
    fi
    
    # Check if config is placeholder
    if ! is_frpc_configured; then
        log_skip "Not configured (using placeholders)"
        log_info "Binary path: $FRPC_PATH"
        log_info "Workspace cache: $FRPC_PERSISTENT_PATH"
        log_info "To configure: edit scripts/modules/config.sh"
        log_info "Get config from: https://www.natfrp.com/"
        return 0
    fi
    
    # Get frpc binary (copy from cache or download)
    get_frpc_binary || return 1
    
    # Start frpc in fully detached background mode
    log_info "Starting frpc (background)..."
    
    # IMPORTANT: Use absolute path, do NOT cd to /home/user - it causes Bash tool
    # to detect workspace directory change and return error code -1
    # Use subshell + background to ensure immediate return
    # This prevents Bash tool from hanging waiting for process
    (
        /home/user/frpc -f ${FRPC_TOKEN}:${FRPC_TUNNEL} < /dev/null > "$FRPC_LOG" 2>&1 &
    )
    
    # Quick check (non-blocking, just check if process exists)
    # Use full path to avoid matching Bash tool's command line
    if pgrep -f "/home/user/frpc -f " > /dev/null 2>&1; then
        log_ok "Started (background)"
    else
        log_info "Starting... (check log for status)"
    fi
    
    log_info "Log: $FRPC_LOG"
    log_info "Address: ${FRPC_PUBLIC_ADDR}"
    log_info "Tunnel usually connects within 2-5 seconds"
    return 0
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/config.sh"
    source "$SCRIPT_DIR/utils.sh"
    start_frpc
fi
