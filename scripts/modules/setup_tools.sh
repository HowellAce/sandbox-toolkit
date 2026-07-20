#!/bin/bash
# ==========================================
# Tools Installation Module (v3)
# Install common useful tools
# ==========================================

# Check if config is loaded
if [ -z "$WORK_DIR" ]; then
    echo "[ERROR] Config not loaded. Source config.sh first."
    return 1 2>/dev/null || exit 1
fi

# List of tools to install
TOOLS_LIST=(
    "vim"
    "curl"
    "wget"
    "git"
    "htop"
    "tmux"
    "net-tools"
    "iputils-ping"
    "dnsutils"
    "bc"
)

# Install common tools
install_tools() {
    print_section "Common Tools"
    
    # Find missing tools
    MISSING=()
    for tool in "${TOOLS_LIST[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            MISSING+=("$tool")
        fi
    done
    
    # All installed
    if [ ${#MISSING[@]} -eq 0 ]; then
        log_ok "All tools already installed"
        return 0
    fi
    
    # Install missing tools
    log_info "Installing: ${MISSING[*]}"
    DEBIAN_FRONTEND=noninteractive apt install -y "${MISSING[@]}" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_ok "Tools installed successfully"
        return 0
    else
        log_warn "Some tools may have failed to install"
        return 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/config.sh"
    source "$SCRIPT_DIR/utils.sh"
    install_tools
fi
