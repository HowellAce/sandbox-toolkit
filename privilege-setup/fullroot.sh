#!/bin/bash
# ==========================================
# Full Root Capability Wrapper
# Uses user namespace to gain all 41 capabilities
# ==========================================

FULLROOT_DIR="/data/user/work/fullroot"
mkdir -p "$FULLROOT_DIR"

# Create the main wrapper script
cat > "$FULLROOT_DIR/run" << 'WRAPPER'
#!/bin/bash
# Execute a command with full capabilities in a new user namespace
# Usage: run <command> [args...]
# Or:    run -i  (interactive shell with full caps)

if [ "$1" = "-i" ] || [ "$1" = "--interactive" ]; then
    # Interactive shell with full capabilities
    exec unshare -U -r -m -n bash -c '
        export PS1="fullroot@$(hostname):\w# "
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "[*] Full root shell - all 41 capabilities active"
        echo "[*] CapEff: $(cat /proc/self/status | grep CapEff | awk "{print \$2}")"
        echo "[*] Network: separate namespace (use iptables freely)"
        echo "[*] Mount: separate namespace (use mount freely)"
        echo ""
        exec bash --noprofile --norc
    '
else
    # Execute single command
    exec unshare -U -r -m -n bash -c '"$@"' -- "$@"
fi
WRAPPER

chmod +x "$FULLROOT_DIR/run"

# Create network-only wrapper (preserves original network but gains net_admin)
cat > "$FULLROOT_DIR/net" << 'NETWRAPPER'
#!/bin/bash
# Execute network commands with cap_net_admin in new namespace
# WARNING: This creates a NEW network namespace, so iptables rules
# only affect the new namespace, not the original one.
# For original namespace network ops, we need a different approach.

exec unshare -U -r -n bash -c '"$@"' -- "$@"
NETWRAPPER

chmod +x "$FULLROOT_DIR/net"

# Create mount wrapper
cat > "$FULLROOT_DIR/mnt" << 'MNTWRAPPER'
#!/bin/bash
# Execute mount operations in new mount namespace
exec unshare -U -r -m bash -c '"$@"' -- "$@"
MNTWRAPPER

chmod +x "$FULLROOT_DIR/mnt"

# Create info script
cat > "$FULLROOT_DIR/info" << 'INFO'
#!/bin/bash
echo "=== Original Environment ==="
echo "User: $(whoami) (uid=$(id -u))"
echo "Caps: $(cat /proc/self/status | grep CapEff | awk '{print $2}')"
echo ""
echo "=== Full Root Environment (via unshare) ==="
unshare -U -r bash -c '
    echo "User: $(whoami) (uid=$(id -u))"
    echo "Caps: $(cat /proc/self/status | grep CapEff | awk "{print \$2}")"
    echo ""
    echo "Available capabilities:"
    capsh --decode=$(cat /proc/self/status | grep CapEff | awk "{print \$2}") 2>/dev/null || \
    python3 -c "
cap = int(open(\"/proc/self/status\").read().split(\"CapEff:\")[1].split(\"\n\")[0].strip(), 16)
names = {0:\"chown\",1:\"dac_override\",2:\"dac_read_search\",3:\"fowner\",4:\"fsetid\",5:\"kill\",6:\"setgid\",7:\"setuid\",8:\"setpcap\",9:\"linux_immutable\",10:\"net_bind_service\",11:\"net_broadcast\",12:\"net_admin\",13:\"net_raw\",14:\"ipc_lock\",15:\"ipc_owner\",16:\"sys_module\",17:\"sys_rawio\",18:\"sys_chroot\",19:\"sys_ptrace\",20:\"sys_pacct\",21:\"sys_admin\",22:\"sys_boot\",23:\"sys_nice\",24:\"sys_resource\",25:\"sys_time\",26:\"sys_tty_config\",27:\"mknod\",28:\"lease\",29:\"audit_write\",30:\"audit_control\",31:\"setfcap\",32:\"mac_override\",33:\"mac_admin\",34:\"syslog\",35:\"wake_alarm\",36:\"block_suspend\",37:\"audit_read\",38:\"perfmon\",39:\"bpf\",40:\"checkpoint_restore\"}
[print(f\"  + cap_{names[b]}\") for b in range(41) if cap & (1<<b)]
"
'
INFO

chmod +x "$FULLROOT_DIR/info"

echo "[+] Full root toolkit installed to $FULLROOT_DIR/"
echo "[+] Available commands:"
echo "    $FULLROOT_DIR/run -i        # Interactive full-root shell"
echo "    $FULLROOT_DIR/run <cmd>     # Run command with full caps"
echo "    $FULLROOT_DIR/net <cmd>     # Run in new network namespace"
echo "    $FULLROOT_DIR/mnt <cmd>     # Run in new mount namespace"
echo "    $FULLROOT_DIR/info          # Show capability info"
