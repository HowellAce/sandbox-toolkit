#!/bin/bash
# ==========================================
# SSH Setup Module (v3)
# Install and configure system-level SSH
# ==========================================

# Check if config is loaded
if [ -z "$WORK_DIR" ]; then
    echo "[ERROR] Config not loaded. Source config.sh first."
    return 1 2>/dev/null || exit 1
fi

# Switch to faster apt mirror (Alibaba Cloud)
switch_apt_mirror() {
    # Only switch if using default archive.ubuntu.com
    if grep -q "archive.ubuntu.com" /etc/apt/sources.list 2>/dev/null; then
        log_info "Switching to Alibaba Cloud mirror for faster downloads..."
        sed -i 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' /etc/apt/sources.list
        apt update -qq > /dev/null 2>&1
        log_ok "Mirror switched and apt updated"
    fi
}

# Install and configure SSH server
install_ssh() {
    print_section "SSH Server"
    
    # Check if already installed
    if command -v sshd &> /dev/null; then
        log_ok "Already installed"
    else
        switch_apt_mirror
        log_info "Installing openssh-server..."
        DEBIAN_FRONTEND=noninteractive apt install -y openssh-server > /dev/null 2>&1
        if command -v sshd &> /dev/null; then
            log_ok "Installed"
        else
            log_error "Installation failed"
            return 1
        fi
    fi
    
    # Create runtime directory
    mkdir -p /run/sshd
    chmod 755 /run/sshd
    
    # Configure SSH - allow root login and password auth
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null
    
    # Set root password
    echo "root:${ROOT_PASSWORD}" | chpasswd
    log_info "Root password set"
    
    # Start SSH server
    if pgrep -x "sshd" > /dev/null; then
        log_ok "Already running (port 22)"
    else
        /usr/sbin/sshd
        if pgrep -x "sshd" > /dev/null; then
            log_ok "Started on port 22"
        else
            log_error "Failed to start"
            return 1
        fi
    fi
    
    return 0
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/config.sh"
    source "$SCRIPT_DIR/utils.sh"
    install_ssh
fi
