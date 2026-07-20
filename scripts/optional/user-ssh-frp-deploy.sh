#!/bin/bash
# SSH + Sakura Intranet Penetration One-Click Deployment Script
# For: Ubuntu 22.04 sandbox environment without root privileges

set -e

echo "========================================="
echo "  SSH + Sakura Frp One-Click Deploy Tool"
echo "========================================="
echo ""

# Get user home directory
HOME_DIR=$(eval echo ~$USER)
echo "Home directory: $HOME_DIR"
echo ""

# Step 1: Environment check
echo "📋 Step 1/8: Environment check..."
echo "-------------------------"

# Check system version
if lsb_release -a 2>/dev/null | grep -q "Ubuntu 22.04"; then
    echo "✅ System: Ubuntu 22.04"
else
    echo "⚠️  Warning: Not Ubuntu 22.04, may not be compatible"
    lsb_release -a 2>/dev/null || cat /etc/os-release
fi

# Check if root
if [ "$(id -u)" = "0" ]; then
    echo "⚠️  Warning: Running as root, this script is designed for non-root environments"
else
    echo "✅ Current user: $USER (non-root, as expected)"
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    echo "✅ Architecture: x86_64"
else
    echo "❌ Error: Unsupported architecture $ARCH, this script only supports x86_64"
    exit 1
fi

echo ""

# Step 2: Create directory structure
echo "📁 Step 2/8: Creating directory structure..."
echo "-------------------------"

mkdir -p $HOME_DIR/bin
mkdir -p $HOME_DIR/etc/ssh
mkdir -p $HOME_DIR/lib
mkdir -p $HOME_DIR/tmp
mkdir -p $HOME_DIR/.ssh

echo "✅ Directories created"
echo ""

# Step 3: Download openssh-server
echo "📥 Step 3/8: Downloading openssh-server..."
echo "-------------------------"

cd $HOME_DIR/tmp

# Bypass proxy for download
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

# Try apt-get download first
if apt-get download openssh-server 2>/dev/null; then
    echo "✅ Download via apt-get successful"
else
    echo "⚠️  apt-get download failed, trying direct download..."
    # Direct download deb package
    curl -L -o openssh-server.deb "http://archive.ubuntu.com/ubuntu/pool/main/o/openssh/openssh-server_8.9p1-3ubuntu0.15_amd64.deb"
    if [ -f openssh-server.deb ]; then
        echo "✅ Direct download successful"
    else
        echo "❌ Download failed"
        exit 1
    fi
fi

echo ""

# Step 4: Extract and configure sshd
echo "🔧 Step 4/8: Extracting and configuring sshd..."
echo "-------------------------"

cd $HOME_DIR/tmp
mkdir -p openssh-server
dpkg-deb -x openssh-server_*.deb openssh-server/ 2>/dev/null || dpkg-deb -x openssh-server.deb openssh-server/

# Copy sshd binary
cp openssh-server/usr/sbin/sshd $HOME_DIR/bin/sshd
chmod +x $HOME_DIR/bin/sshd
echo "✅ sshd binary copied"

# Check dependencies
echo "Checking dependencies..."
MISSING_LIBS=$(ldd $HOME_DIR/bin/sshd 2>/dev/null | grep "not found" || true)

if [ -n "$MISSING_LIBS" ]; then
    echo "⚠️  Missing dependencies, resolving..."
    echo "$MISSING_LIBS"
    
    # Download libwrap0
    echo "Downloading libwrap0..."
    cd $HOME_DIR/tmp
    curl -L -o libwrap0.deb "http://archive.ubuntu.com/ubuntu/pool/main/t/tcp-wrappers/libwrap0_7.6.q-31build2_amd64.deb"
    mkdir -p libwrap0
    dpkg-deb -x libwrap0.deb libwrap0/
    
    # Copy library files
    cp libwrap0/usr/lib/x86_64-linux-gnu/libwrap.so.0.7.6 $HOME_DIR/lib/
    
    # Create symlink
    cd $HOME_DIR/lib
    ln -sf libwrap.so.0.7.6 libwrap.so.0
    cd $HOME_DIR/tmp
    
    echo "✅ Dependencies resolved"
else
    echo "✅ All dependencies satisfied"
fi

echo ""

# Step 5: Generate host keys
echo "🔐 Step 5/8: Generating host keys..."
echo "-------------------------"

# Check if keys already exist
if [ -f "$HOME_DIR/etc/ssh/ssh_host_rsa_key" ]; then
    echo "⚠️  Host keys already exist, skipping generation"
else
    ssh-keygen -t rsa -b 4096 -f $HOME_DIR/etc/ssh/ssh_host_rsa_key -N "" -q
    echo "✅ RSA host key generated"
    
    ssh-keygen -t ecdsa -b 521 -f $HOME_DIR/etc/ssh/ssh_host_ecdsa_key -N "" -q
    echo "✅ ECDSA host key generated"
    
    ssh-keygen -t ed25519 -f $HOME_DIR/etc/ssh/ssh_host_ed25519_key -N "" -q
    echo "✅ Ed25519 host key generated"
fi

echo ""

# Step 6: Generate user keys and configure
echo "🔑 Step 6/8: Configuring user keys..."
echo "-------------------------"

# Set .ssh directory permissions
chmod 700 $HOME_DIR/.ssh

# Generate Ed25519 key
if [ -f "$HOME_DIR/.ssh/id_ed25519" ]; then
    echo "⚠️  Ed25519 key already exists, skipping generation"
else
    ssh-keygen -t ed25519 -f $HOME_DIR/.ssh/id_ed25519 -N "" -q
    echo "✅ Ed25519 user key generated"
fi

# Generate RSA key (backup)
if [ -f "$HOME_DIR/.ssh/id_rsa" ]; then
    echo "⚠️  RSA key already exists, skipping generation"
else
    ssh-keygen -t rsa -b 4096 -f $HOME_DIR/.ssh/id_rsa -N "" -q
    echo "✅ RSA user key generated"
fi

# Configure authorized_keys
if [ ! -f "$HOME_DIR/.ssh/authorized_keys" ]; then
    cat $HOME_DIR/.ssh/id_ed25519.pub >> $HOME_DIR/.ssh/authorized_keys
    cat $HOME_DIR/.ssh/id_rsa.pub >> $HOME_DIR/.ssh/authorized_keys
    chmod 600 $HOME_DIR/.ssh/authorized_keys
    echo "✅ authorized_keys configured"
else
    echo "⚠️  authorized_keys already exists, skipping configuration"
fi

echo ""

# Step 7: Write sshd config and start
echo "⚙️  Step 7/8: Configuring and starting sshd..."
echo "-------------------------"

# Generate config file
cat > $HOME_DIR/etc/ssh/sshd_config << EOF
Port 2222
ListenAddress 0.0.0.0
ListenAddress ::
HostKey $HOME_DIR/etc/ssh/ssh_host_rsa_key
HostKey $HOME_DIR/etc/ssh/ssh_host_ecdsa_key
HostKey $HOME_DIR/etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM no
AllowUsers $USER
MaxAuthTries 6
MaxSessions 10
SyslogFacility AUTH
LogLevel INFO
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 3
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SetEnv LD_LIBRARY_PATH=$HOME_DIR/lib
EOF

echo "✅ sshd config file generated"

# Set library path
export LD_LIBRARY_PATH=$HOME_DIR/lib:$LD_LIBRARY_PATH

# Check if sshd is already running
if pgrep -x "sshd" > /dev/null; then
    echo "⚠️  sshd already running, skipping start"
else
    # Start sshd
    $HOME_DIR/bin/sshd -f $HOME_DIR/etc/ssh/sshd_config -E /tmp/sshd.log
    sleep 1
    
    # Check if started successfully
    if pgrep -x "sshd" > /dev/null; then
        echo "✅ sshd started successfully"
    else
        echo "❌ sshd failed to start, check logs:"
        cat /tmp/sshd.log
        exit 1
    fi
fi

# Local connection test
echo "Testing local SSH connection..."
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 -i $HOME_DIR/.ssh/id_ed25519 $USER@localhost echo "Connection test successful" 2>/dev/null; then
    echo "✅ SSH local connection test passed"
else
    echo "⚠️  Local connection test failed (may be first connection issue)"
fi

echo ""

# Step 8: Download Sakura frpc
echo "🌸 Step 8/8: Downloading Sakura frp client..."
echo "-------------------------"

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

if [ -f "$HOME_DIR/frpc" ]; then
    echo "⚠️  frpc already exists, skipping download"
else
    # Download Sakura custom version of frpc
    curl -L -o $HOME_DIR/frpc "https://nya.globalslb.net/natfrp/client/frpc/0.51.0-sakura-12.3/frpc_linux_amd64"
    chmod +x $HOME_DIR/frpc
    
    # Verify version
    FRPC_VERSION=$($HOME_DIR/frpc -v 2>&1 || echo "unknown version")
    echo "✅ Sakura frpc download complete, version: $FRPC_VERSION"
fi

echo ""
echo "========================================="
echo "  🎉 Deployment Complete!"
echo "========================================="
echo ""

echo "📋 Next steps:"
echo ""
echo "1. Start intranet penetration:"
echo "   ~/frpc -f <your_access_token>:<tunnel_id>"
echo ""
echo "   Example:"
echo "   ~/frpc -f YOUR_FRPC_TOKEN:YOUR_TUNNEL_ID"
echo ""
echo "2. Your private key (save to local machine):"
echo ""
echo "--- Ed25519 Private Key (recommended) ---"
cat $HOME_DIR/.ssh/id_ed25519
echo "--- End of Private Key ---"
echo ""

echo "📁 File locations:"
echo "   sshd:     ~/bin/sshd"
echo "   config:   ~/etc/ssh/sshd_config"
echo "   keys:     ~/.ssh/"
echo "   frpc:     ~/frpc"
echo "   logs:     /tmp/sshd.log"
echo ""

echo "🔄 Restart sshd command:"
echo "   export LD_LIBRARY_PATH=\$HOME/lib:\$LD_LIBRARY_PATH"
echo "   ~/bin/sshd -f ~/etc/ssh/sshd_config -E /tmp/sshd.log"
echo ""
