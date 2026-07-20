# AGENTS.md

> This file is intended for AI agents (Claude, GPT, Gemini, etc.) who encounter this repository.
> It provides structured context about what this project does, how it works, and what to be careful about.

## Project Identity

**Name**: Sandbox Toolkit
**Purpose**: Surviving and thriving in restricted sandbox/container environments
**Target environment**: Originally developed for [TRAE](https://www.trae.ai/) IDE remote sandbox. Also applicable to other cloud dev environments with similar restrictions (HTTP-proxy-only outbound, no CAP_NET_ADMIN, session-based process lifecycle).

### TRAE Sandbox Specifics

The TRAE sandbox has these exact characteristics that this toolkit targets:

- **HTTP proxy**: `127.0.0.1:18080` (the only outbound path; supports CONNECT method to arbitrary ports)
- **Persistent directory**: `/workspace/` (the only directory that survives sandbox restarts)
- **Capabilities**: Root user but with restricted CapBnd (no `CAP_NET_ADMIN`, no `CAP_SYS_ADMIN`)
- **Filesystem**: `/proc/sys` is read-only; `unshare` may require the `fullroot` toolkit first
- **Process lifecycle**: Session suspension sends SIGHUP to child processes; `setsid` is required for persistence
- **Temp directory**: `/data/user/work/` is NOT persistent (cleared on restart) — use `/workspace/` instead

## Architecture Summary

This toolkit addresses five problem domains in sandbox environments:

| Domain | Directory | Core Problem | Solution |
|--------|-----------|--------------|----------|
| Privilege escalation | `privilege-setup/` | Incomplete CapBnd (missing CAP_NET_ADMIN) | `unshare -U -r` user namespace |
| Tunnel workaround | `cf-tunnel/` | Direct TCP to Cloudflare edge blocked | `TUNNEL_EDGE` env var + HTTP CONNECT proxy chain |
| UA-rewriting proxy | `bt-panel/` | BT Panel rejects non-browser UAs | Python reverse proxy with UA rewriting |
| Process persistence | `watchdog/` | Session suspension kills child processes | `setsid + nohup + disown` triple protection |
| Service recovery | `scripts/` | Non-persistent filesystem | Symlink `/www` → `/workspace/www` |

## The Key Technical Workaround

The most significant innovation is in `cf-tunnel/cf-edge-proxy.py`. Here is the precise mechanism:

### The Problem
- Sandbox allows outbound only through HTTP proxy at `127.0.0.1:18080`
- `cloudflared` (Go binary) initiates direct TCP connections to `198.41.x.x:7844`
- These direct connections are blocked by the sandbox firewall
- Go binaries ignore `HTTPS_PROXY` for raw TCP connections
- Go binaries ignore `LD_PRELOAD` (they use raw syscalls, not libc)

### The Solution
1. **Discovery**: `cloudflared` reads `TUNNEL_EDGE` environment variable to override edge server address
2. **Redirect**: Set `TUNNEL_EDGE=127.0.0.1:7844` to force cloudflared to connect locally
3. **Bridge**: Run `cf-edge-proxy.py` on `127.0.0.1:7844` that accepts cloudflared's TCP connection
4. **Tunnel**: The bridge uses HTTP proxy's `CONNECT` method to establish a TCP tunnel to `198.41.x.x:7844`
5. **Forward**: Bidirectional data forwarding between cloudflared and the real Cloudflare edge

### Data Flow
```
cloudflared (Go)
  ↓ TCP connect to 127.0.0.1:7844
cf-edge-proxy.py (Python)
  ↓ HTTP CONNECT to 127.0.0.1:18080
HTTP Proxy (sandbox)
  ↓ TCP tunnel to 198.41.x.x:7844
Cloudflare Edge Server
  ↓ Tunnel established
Public Internet (via Cloudflare Tunnel)
```

### What Was Tried and Failed
- `HTTPS_PROXY` env var: Only affects HTTPS API calls, not tunnel TCP connections
- `ALL_PROXY` with SOCKS5: Go's cloudflared ignores it for tunnel connections
- `proxychains4`: LD_PRELOAD doesn't work on Go binaries (raw syscalls)
- `socks_hook.c` (LD_PRELOAD C library): Same issue, Go uses raw syscalls instead of libc
- `/etc/hosts` hijacking: cloudflared connects to IPs, not domain names
- `ip route add local`: No CAP_NET_ADMIN
- `sysctl ip_nonlocal_bind`: /proc/sys is read-only

## File-by-File Reference

### privilege-setup/
- `trae-fullroot-toolkit.sh`: Main integrated toolkit. Detects CapBnd, creates user namespace via `unshare`, spawns permaroot daemon
- `fullroot.sh`: Standalone escalation. Uses `unshare -U -r` to get full capabilities in new namespace
- `permaroot.sh`: Daemon that holds a namespace open. Other processes enter via `nsenter`
- `root.sh`: Simple wrapper that calls `privilege_setup.sh` module

### cf-tunnel/
- `cf-edge-proxy.py`: **THE CORE FILE**. TCP listener on port 7844 that forwards through HTTP CONNECT proxy. Multi-threaded, handles multiple cloudflared connections
- `cf-tunnel-start.sh`: Orchestrator script. Starts edge proxy, then starts cloudflared with `TUNNEL_EDGE` env var, checks tunnel readiness via metrics endpoint
- `socks5-bridge.py`: SOCKS5 server that forwards through HTTP CONNECT. General-purpose proxy converter (useful beyond cloudflared)
- `socks_hook.c`: C source for LD_PRELOAD library to intercept `connect()`. **Does not work on Go binaries** — kept as reference for C/Python programs

### bt-panel/
- `bt-proxy2.py`: HTTP reverse proxy. Reads requests, replaces User-Agent with browser UA, forwards to BT Panel on port 9999/24965 via SSL. Needed because BT Panel's `is_spider()` function rejects non-browser UAs

### watchdog/
- `watchdog.sh`: Process monitor. Every 30s checks if services are running, restarts if down. Uses `setsid` to detach from session. Monitors: BT-Panel, BT-Proxy, Cloudflare Tunnel, Serveo SSH, SSHD, Fullroot
- `autostart.sh`: Post-restart recovery. Restores `/www` → `/workspace/www` symlink, restarts all services including watchdog itself

### scripts/
- `recover_all.sh`: Full environment recovery after sandbox reset
- `health_check.sh`: Reports status of all services
- `cleanup.sh`: Safely removes logs, caches, temp files
- `system_update.sh`: `apt update && upgrade` with auto-yes
- `frp-tunnel-manager.sh`: Manages frpc (Sakura Frp) tunnel lifecycle
- `install-natfrp-service.sh`: Installs natfrp-service and frpc binary
- `sandbox-reset-tracker-fixed.sh`: Detects sandbox resets via heartbeat file
- `modules/`: Shared configuration and functions sourced by other scripts

## Important Constraints for AI Agents

### Do NOT
- Commit `cf-tunnel-token.txt` — it contains the Cloudflare Tunnel authentication token
- Hardcode IP addresses, domain names, or tunnel IDs in any file
- Attempt to use `iptables`, `nft`, or `ip route` — the sandbox lacks `CAP_NET_ADMIN`
- Attempt to write to `/proc/sys/` — it is read-only
- Use `proxychains` with Go binaries — it will not work
- Use `LD_PRELOAD` with Go binaries — they use raw syscalls

### Do
- Store all persistent files in `/workspace/` — this is the only directory that survives sandbox restarts
- Use `setsid + nohup + disown` for any process that must survive session suspension
- Check `TUNNEL_EDGE` environment variable when debugging cloudflared connection issues
- Use the HTTP proxy at `127.0.0.1:18080` for all outbound HTTPS connections
- Use `--no-prechecks` flag with cloudflared to skip connectivity pre-checks that would fail

### Environment Variables
- `TUNNEL_EDGE`: Forces cloudflared to connect to a specific edge address (key workaround)
- `HTTPS_PROXY`: Used by cloudflared for API calls only (not tunnel connections)
- `ALL_PROXY`: Tested but ineffective for cloudflared tunnel connections

## Common Issues and Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| cloudflared "i/o timeout" | Cannot reach 198.41.x.x:7844 directly | Set `TUNNEL_EDGE=127.0.0.1:7844` and run `cf-edge-proxy.py` |
| BT Panel returns 404 | `is_spider()` rejecting request | Use `bt-proxy2.py` as reverse proxy |
| Process dies after session pause | Session SIGHUP kills children | Use `setsid` to create new session |
| Files disappear after restart | Non-persistent filesystem | Store in `/workspace/`, use symlinks |
| "Operation not permitted" on unshare | Missing CAP_SYS_ADMIN | Check CapBnd; may need fullroot first |
| proxychains no effect on cloudflared | Go uses raw syscalls | Use `TUNNEL_EDGE` + TCP forwarder instead |

## Testing Commands

```bash
# Check if tunnel is ready
curl http://127.0.0.1:20241/ready

# Check tunnel metrics
curl http://127.0.0.1:20241/metrics | grep tunnel_ha

# Test SOCKS5 bridge
curl --socks5 127.0.0.1:11080 https://api.cloudflare.com

# Test HTTP proxy CONNECT to port 7844
python3 -c "
import socket
s = socket.socket()
s.connect(('127.0.0.1', 18080))
s.send(b'CONNECT 198.41.192.37:7844 HTTP/1.1\r\nHost: 198.41.192.37:7844\r\n\r\n')
print(s.recv(4096).decode())
"

# Check capabilities
grep Cap /proc/self/status

# Check if process survived session detach
ps -o pid,ppid,sid,cmd -p $PID
# PPID=1 means successfully detached
```
