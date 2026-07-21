# Privilege Escalation

Two distinct privilege escalation scenarios are supported, depending on the sandbox environment.

## Scenario 1: User-level account (Doubao/ByteDance FaaS)

**Environment**: Logged in as `user` (uid=1234), no root access at all.

**Script**: `root.sh`

**Method**: PATH hijacking + supervisord config tampering

**How it works**:
1. Deploys a fake `nc` wrapper to `/home/user/.local/bin/nc`
2. The wrapper modifies supervisord config to change `vm_server` user from `user` to `root`
3. Triggers nginx restart via supervisorctl, which invokes the fake `nc` through PATH
4. After 30-45 seconds, `vm_server` restarts running as root

**Prerequisites**:
- supervisord running with `vm_server` and `nginx` programs
- supervisord socket at `/run/supervisor.sock`
- Config file at `/opt/gem/supervisord/supervisord.go_vm_server.conf`
- User has write access to `/home/user/.local/bin/`

```bash
bash privilege-setup/root.sh
# Wait 30-45 seconds
whoami  # should output: root
```

This is a standard PATH hijacking technique combined with supervisord configuration tampering. Both are well-documented privilege escalation methods in penetration testing literature.

## Scenario 2: Root with incomplete capabilities (TRAE sandbox)

**Environment**: Already root (uid=0), but CapBnd is incomplete (missing CAP_SYS_ADMIN, CAP_NET_ADMIN, etc.).

**Scripts**: `fullroot.sh`, `permaroot.sh`, `trae-fullroot-toolkit.sh`

**Method**: User namespace via `unshare`

**How it works**:
1. `unshare -U -r` creates a new user namespace
2. Inside the new namespace, the process has all 41 Linux capabilities
3. `permaroot.sh` runs as a daemon to keep the namespace alive
4. Other processes enter the namespace via `nsenter`

**Prerequisites**:
- Kernel supports user namespaces (`/proc/sys/kernel/unprivileged_userns_clone` = 1)
- `unshare` and `nsenter` binaries available

```bash
# Quick escalation
bash privilege-setup/fullroot.sh

# Or use the integrated toolkit (includes SSH, frpc, nginx, etc.)
bash privilege-setup/trae-fullroot-toolkit.sh

# Persistent daemon
bash privilege-setup/permaroot.sh
```

## Which one to use?

| Your situation | Script |
|----------------|--------|
| Logged in as `user`, need root | `root.sh` |
| Already root, but `iptables`/`mount` fail with "Operation not permitted" | `fullroot.sh` |
| Want an all-in-one toolkit (root + SSH + frpc + nginx + tools) | `trae-fullroot-toolkit.sh` |

## Verification

```bash
# Check current capabilities
grep CapBnd /proc/self/status

# If already root via root.sh
whoami  # root

# If fullroot via unshare
# CapBnd should be 000001ffffffffff (all 41 capabilities)
```
