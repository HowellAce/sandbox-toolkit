# Sandbox Toolkit

> Scripts for working efficiently in restricted sandbox environments — privilege escalation, persistent tunnels, session-surviving process management, and Cloudflare Tunnel workaround.

<!-- LANG-TOGGLE -->
<table>
<tr>
<td><a href="#中文文档">中文</a></td>
<td><a href="#english-documentation">English</a></td>
</tr>
</table>

---

## 中文文档

### 项目简介

Sandbox Toolkit 是一套针对受限沙箱环境的综合工具集。

本项目最初为 [TRAE](https://www.trae.ai/) IDE 的远程沙箱环境开发。TRAE 沙箱有以下限制：

- 仅允许通过 HTTP 代理（`127.0.0.1:18080`）出站，直连外部 IP 被阻断
- 没有 `CAP_NET_ADMIN`，无法修改路由表或 iptables
- `/proc/sys` 为只读文件系统，无法修改内核参数
- 会话暂停后子进程会被终止
- 沙箱重启后非 `/workspace` 目录的文件全部丢失

这些限制在其他云端开发环境（如 GitHub Codespaces、Gitpod、CodeSandbox 等）中也部分存在。本项目的核心适配方案——通过 HTTP 代理的 CONNECT 方法建立 TCP 隧道——适用于任何"仅允许 HTTP 代理出站"的受限环境。

> **致 TRAE 团队**：本项目是对沙箱网络限制的技术研究，不涉及任何漏洞利用或安全规避。所有操作在沙箱赋予的权限范围内进行，不突破沙箱本身的隔离边界。如果本项目的内容有任何不妥之处，欢迎通过 GitHub Issues 联系。

### 给 AI 助手使用

如果你正在让 AI 助手（Claude、GPT、Gemini 等）帮你操作沙箱环境，请让 AI 阅读本仓库的 `AGENTS.md` 文件：

```bash
# 克隆仓库
git clone https://github.com/你的用户名/sandbox-toolkit.git

# 让 AI 阅读 AGENTS.md
cat sandbox-toolkit/AGENTS.md
```

`AGENTS.md` 是专门为 AI 编写的结构化文档，包含：
- 技术架构概览（问题域与解决方案对照表）
- 核心适配方案原理（Cloudflare Tunnel 的完整数据流）
- 失败方案记录（哪些方法不工作，避免 AI 重复尝试）
- 文件功能索引（每个文件的作用）
- 操作约束（AI 应做和不应做的事项）
- 常见问题速查表
- 调试命令

**给 AI 的提示词示例**：
> 请阅读 `AGENTS.md` 文件了解这个项目的架构，然后帮我在沙箱里配置 Cloudflare Tunnel。

### 目录结构

```
sandbox-toolkit/
├── privilege-setup/              # 权限提升
│   ├── trae-fullroot-toolkit.sh   # 主工具包（集成版）
│   ├── fullroot.sh                # 提权核心脚本
│   ├── permaroot.sh               # 持久化提权守护
│   └── root.sh                    # 提权入口
├── scripts/                   # 核心运维脚本
│   ├── modules/                   # 模块化配置
│   │   ├── config.sh              # 全局配置
│   │   ├── privilege_setup.sh        # 提权模块
│   │   ├── setup_ssh.sh           # SSH 配置
│   │   ├── setup_frpc.sh          # Frp 配置
│   │   ├── setup_tools.sh         # 工具安装
│   │   ├── update_memory.sh       # 记忆更新
│   │   └── utils.sh               # 工具函数
│   ├── optional/                  # 可选功能
│   │   ├── deploy-minecraft-server.sh  # Minecraft 服务器部署
│   │   ├── install_fastfetch.sh        # 系统信息工具
│   │   └── user-ssh-frp-deploy.sh      # 非 root SSH+Frp 部署
│   ├── recover_all.sh             # 一键恢复所有服务
│   ├── health_check.sh            # 服务健康检查
│   ├── cleanup.sh                 # 安全清理临时文件
│   ├── system_update.sh           # 系统更新
│   ├── frp-tunnel-manager.sh      # Frp 隧道管理
│   ├── install-natfrp-service.sh  # Natfrp 安装
│   ├── sandbox-reset-tracker-fixed.sh  # 沙箱重置追踪
│   ├── downloader.py              # 多线程下载器
│   ├── package_deployment.sh      # 打包脚本
│   └── memory.md                  # 环境记忆
├── cf-tunnel/                 # Cloudflare Tunnel 适配方案
│   ├── cf-edge-proxy.py           # TCP 转发器（核心适配方案）
│   ├── cf-tunnel-start.sh         # 一键启动隧道
│   ├── socks5-bridge.py           # SOCKS5 桥接器
│   └── socks_hook.c               # LD_PRELOAD hook 源码
├── bt-panel/                  # 宝塔面板代理
│   └── bt-proxy2.py               # 反向代理（适配 UA 检查）
├── bt-security/               # 宝塔安全风险修复
│   ├── fix_security_risks.sh      # 一键修复安全风险（无需会员）
│   └── README.md                  # 修复原理文档
└── watchdog/                  # 进程保活
    ├── watchdog.sh                # 持久化看门狗
    └── autostart.sh               # 沙箱重启自动恢复
```

### 核心功能

#### 1. 权限提升 (privilege-setup/)

沙箱环境通常以受限 root 运行（CapBnd 不完整）。这些脚本通过 `unshare` 创建新的用户命名空间，恢复完整的 Linux capabilities。

```bash
# 快速提权
bash privilege-setup/trae-fullroot-toolkit.sh

# 或使用独立脚本
bash privilege-setup/fullroot.sh
```

原理：`unshare -U -r` 创建新命名空间，在新命名空间内进程拥有完整权限。`permaroot.sh` 以 daemon 模式保持命名空间存活。

#### 2. Cloudflare Tunnel 适配方案 (cf-tunnel/)

这是本项目的核心技术适配方案。沙箱只允许通过 HTTP 代理 `127.0.0.1:18080` 出站，但 `cloudflared` 需要直连 `198.41.x.x:7844`。通过三层转发实现隧道连接：

```
cloudflared → 127.0.0.1:7844 (cf-edge-proxy.py)
                 → HTTP 代理 127.0.0.1:18080 (CONNECT 方法)
                     → 198.41.x.x:7844 (Cloudflare 边缘)
```

**关键发现**：`cloudflared` 支持 `TUNNEL_EDGE` 环境变量强制指定边缘服务器地址。利用这个隐藏参数，把 cloudflared 的连接重定向到本地 TCP 转发器，再通过 HTTP 代理的 CONNECT 方法建立到 Cloudflare 的隧道。

```bash
# 1. 保存你的 tunnel token
echo "your-token-here" > /workspace/cf-tunnel-token.txt

# 2. 下载 cloudflared
wget -O /workspace/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /workspace/cloudflared

# 3. 启动隧道
bash cf-tunnel/cf-tunnel-start.sh
```

在 Cloudflare Dashboard 配置 Public Hostname 后，就能通过自定义域名访问沙箱内的服务。

`socks5-bridge.py` 是 SOCKS5 到 HTTP CONNECT 的桥接器，可作为通用代理转换工具。`socks_hook.c` 是尝试用 LD_PRELOAD 拦截 `connect()` 系统调用的方案（对 Go 程序无效，保留作为参考）。

#### 3. 宝塔面板代理 (bt-panel/)

宝塔面板有 `is_spider()` UA 检查，会拒绝非浏览器 UA 的请求。`bt-proxy2.py` 作为反向代理，把所有请求的 User-Agent 替换为浏览器 UA，同时处理 HTTPS 到 HTTP 的转换。

```bash
# 启动代理（默认监听 18099 端口）
python3 bt-panel/bt-proxy2.py
```

配合 Cloudflare Tunnel 使用时，在 Public Hostname 里把 Service 设为 `HTTP localhost:18099`。

#### 4. 宝塔安全风险修复 (bt-security/)

宝塔面板的"安全检测"功能会扫描系统安全风险（典型环境约81项），但"一键修复"需要购买会员。本模块通过分析宝塔检测逻辑，实现无需会员手动修复全部风险。

**修复策略**：

| 类别 | 修复方法 |
|------|----------|
| 配置类（TMOUT、PAM等） | 直接修改系统配置文件 |
| sysctl类（硬链接/软链接保护、禁Ping） | 写入 sysctl.conf + 增强检测脚本回退逻辑 |
| CVE漏洞（ESM包） | 移除有CVE的高风险包（ffmpeg/imagemagick等） |

**核心原理**：
- 容器/沙箱中 `/proc/sys` 通常只读，无法运行时修改内核参数。修改宝塔检测脚本添加 sysctl.conf 回退逻辑：先检查运行时值，不可用时回退检查配置文件
- Ubuntu 22.04 许多 CVE 修复版本带 `+esm` 后缀需 Ubuntu Pro 订阅。分析漏洞数据库发现典型环境的64个CVE全来自4个非必需包（ffmpeg/imagemagick/git-lfs/graphviz），直接移除即可

```bash
# 一键修复所有安全风险
bash bt-security/fix_security_risks.sh
```

修复后风险数从 81 降为 0。详见 [bt-security/README.md](bt-security/README.md)。

#### 5. 进程保活 (watchdog/)

沙箱会话暂停后，子进程会被终止。`watchdog.sh` 通过 `setsid + nohup + disown` 三重保护使进程脱离会话，并每 30 秒检查一次服务状态，发现停止立即重启。

```bash
# 启动看门狗
bash watchdog/watchdog.sh start

# 查看状态
bash watchdog/watchdog.sh status

# 停止
bash watchdog/watchdog.sh stop
```

监控的服务：BT-Panel、BT-Proxy、Cloudflare Tunnel、Serveo SSH、SSHD、Fullroot daemon。

#### 6. 一键恢复 (scripts/)

沙箱重启后所有非 `/workspace` 文件丢失。`autostart.sh` 会恢复符号链接并重新启动所有服务。

```bash
# 沙箱重启后执行
bash watchdog/autostart.sh

# 或使用 recover_all.sh 恢复 doubao_work 环境
bash scripts/recover_all.sh
```

### 快速开始

#### 场景一：在沙箱里部署宝塔面板 + Cloudflare Tunnel

```bash
# 1. 提权
bash privilege-setup/trae-fullroot-toolkit.sh

# 2. 持久化安装宝塔面板
mkdir -p /workspace/www && ln -s /workspace/www /www
wget -O install.sh https://download.bt.cn/install/install-ubuntu_6.0.sh
printf "y\nyes\n" | bash install.sh ed8484bec

# 3. 启动宝塔代理
python3 bt-panel/bt-proxy2.py &

# 4. 配置 Cloudflare Tunnel
echo "your-token" > /workspace/cf-tunnel-token.txt
wget -O /workspace/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /workspace/cloudflared
bash cf-tunnel/cf-tunnel-start.sh

# 5. 启动看门狗
bash watchdog/watchdog.sh start
```

在 Cloudflare Dashboard 配置 Public Hostname：
- Subdomain: `bt`
- Domain: `yourdomain.com`
- Service: `HTTP localhost:18099`

#### 场景二：仅使用 Frp 内网穿透

```bash
# 1. 安装 natfrp
bash scripts/install-natfrp-service.sh

# 2. 配置 token（编辑 scripts/modules/config.sh）
# 3. 启动隧道
bash scripts/frp-tunnel-manager.sh start YOUR_TOKEN:YOUR_TUNNEL_ID
```

### 环境要求

- Linux 沙箱环境（Ubuntu/Debian）
- Python 3.7+
- bash 4+
- 可选：gcc（编译 socks_hook.so）
- 可选：wget/curl（下载 cloudflared）

### 注意事项

1. **`cf-tunnel-token.txt` 不要提交到 GitHub**。该文件包含你的 Cloudflare Tunnel 认证 token，已加入 `.gitignore`。
2. **沙箱重启后**需要重新运行 `bash watchdog/autostart.sh`。
3. **`cloudflared` 二进制不包含在包内**（约 40MB），请自行下载。
4. **权限提升**依赖 `unshare` 系统调用，部分沙箱可能禁用此功能。
5. **Cloudflare Tunnel 适配方案**依赖沙箱 HTTP 代理支持 CONNECT 方法到 7844 端口。

### 许可证

GPL-3.0 License - 衍生作品必须开源，禁止商用。详见 [LICENSE](LICENSE)。

### 致谢

本项目在开发过程中参考了以下资源：

- [doevt.top](https://doevt.top/doubao/) - 沙箱部署脚本和 fullroot 命名空间方案的初始参考
- [Cloudflare](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) - Cloudflare Tunnel 官方文档及 `cloudflared` 工具
- Linux 内核 `unshare`/`nsenter` 用户命名空间机制

---

## English Documentation

### Overview

Sandbox Toolkit is a comprehensive toolkit for restricted sandbox environments.

This project was originally developed for the [TRAE](https://www.trae.ai/) IDE remote sandbox. The TRAE sandbox imposes these constraints:

- Outbound traffic only allowed through an HTTP proxy (`127.0.0.1:18080`); direct IP connections are blocked
- No `CAP_NET_ADMIN`; cannot modify routing tables or iptables
- `/proc/sys` is read-only; kernel parameters cannot be changed
- Child processes are killed when the session is suspended
- All files outside `/workspace` are lost on sandbox restart

These constraints also exist partially in other cloud development environments (GitHub Codespaces, Gitpod, CodeSandbox, etc.). The core workaround — establishing TCP tunnels through an HTTP proxy's CONNECT method — applies to any environment that only allows HTTP proxy outbound traffic.

> **To the TRAE team**: This project is a technical research on sandbox network limitations. It does not involve any vulnerability exploitation or security bypassing. All operations are performed within the permissions granted by the sandbox and do not break the sandbox's own isolation boundary. If any content in this project is inappropriate, please reach out via GitHub Issues.

### For AI Assistants

If you are using an AI assistant (Claude, GPT, Gemini, etc.) to help operate in a sandbox environment, have the AI read the `AGENTS.md` file in this repository:

```bash
# Clone the repository
git clone https://github.com/your-username/sandbox-tunnel-breakout.git

# Have the AI read AGENTS.md
cat sandbox-tunnel-breakout/AGENTS.md
```

`AGENTS.md` is a structured document written specifically for AI, containing:
- Architecture overview (problem domain and solution mapping table)
- Core workaround principle (complete data flow for Cloudflare Tunnel)
- Failed approach records (what doesn't work, to save AI from repeating attempts)
- File function index (purpose of each file)
- Operating constraints (what AI should and should not do)
- Common issues quick reference
- Debugging commands

**Example prompt for AI**:
> Please read the `AGENTS.md` file to understand this project's architecture, then help me configure Cloudflare Tunnel in the sandbox.

### Directory Structure

```
sandbox-toolkit/
├── privilege-setup/              # Privilege escalation
│   ├── trae-fullroot-toolkit.sh   # Main toolkit (integrated)
│   ├── fullroot.sh                # Core escalation script
│   ├── permaroot.sh               # Persistent privilege daemon
│   └── root.sh                    # Entry point
├── scripts/                   # Core operations
│   ├── modules/                   # Modular config
│   │   ├── config.sh              # Global configuration
│   │   ├── privilege_setup.sh        # Escalation module
│   │   ├── setup_ssh.sh           # SSH setup
│   │   ├── setup_frpc.sh          # Frp setup
│   │   ├── setup_tools.sh         # Tools installation
│   │   ├── update_memory.sh       # Memory update
│   │   └── utils.sh               # Utility functions
│   ├── optional/                  # Optional features
│   │   ├── deploy-minecraft-server.sh  # Minecraft server deployment
│   │   ├── install_fastfetch.sh        # System info tool
│   │   └── user-ssh-frp-deploy.sh      # Non-root SSH+Frp deployment
│   ├── recover_all.sh             # One-click service recovery
│   ├── health_check.sh            # Health check
│   ├── cleanup.sh                 # Safe cleanup
│   ├── system_update.sh           # System update
│   ├── frp-tunnel-manager.sh      # Frp tunnel manager
│   ├── install-natfrp-service.sh  # Natfrp installer
│   ├── sandbox-reset-tracker-fixed.sh  # Sandbox reset tracker
│   ├── downloader.py              # Multi-thread downloader
│   ├── package_deployment.sh      # Packaging script
│   └── memory.md                  # Environment memory
├── cf-tunnel/                 # Cloudflare Tunnel workaround
│   ├── cf-edge-proxy.py           # TCP forwarder (core workaround)
│   ├── cf-tunnel-start.sh         # One-click tunnel start
│   ├── socks5-bridge.py           # SOCKS5 bridge
│   └── socks_hook.c               # LD_PRELOAD hook source
├── bt-panel/                  # BT Panel proxy
│   └── bt-proxy2.py               # Reverse proxy (rewrites browser UA)
├── bt-security/               # BT Panel security risk fix
│   ├── fix_security_risks.sh      # Fix all security risks without membership
│   └── README.md                  # Fix principles documentation
└── watchdog/                  # Process persistence
    ├── watchdog.sh                # Session-surviving watchdog
    └── autostart.sh               # Auto-recovery on restart
```

### Key Features

#### 1. Privilege Escalation (privilege-setup/)

Sandbox environments typically run as restricted root (incomplete CapBnd). These scripts use `unshare` to create a new user namespace, restoring full Linux capabilities.

```bash
# Quick escalation
bash privilege-setup/trae-fullroot-toolkit.sh

# Or use standalone script
bash privilege-setup/fullroot.sh
```

Principle: `unshare -U -r` creates a new namespace where the process has full privileges. `permaroot.sh` runs as a daemon to keep the namespace alive.

#### 2. Cloudflare Tunnel Workaround (cf-tunnel/)

This is the core technical workaround of this project. The sandbox only allows outbound traffic through HTTP proxy `127.0.0.1:18080`, but `cloudflared` needs to directly connect to `198.41.x.x:7844`. The tunnel connection is achieved through a three-layer forwarding chain:

```
cloudflared → 127.0.0.1:7844 (cf-edge-proxy.py)
                 → HTTP proxy 127.0.0.1:18080 (CONNECT method)
                     → 198.41.x.x:7844 (Cloudflare edge)
```

**Key discovery**: `cloudflared` supports the `TUNNEL_EDGE` environment variable to force a specific edge server address. Using this hidden parameter, cloudflared's connection is redirected to a local TCP forwarder, which then tunnels to Cloudflare via the HTTP proxy's CONNECT method.

```bash
# 1. Save your tunnel token
echo "your-token-here" > /workspace/cf-tunnel-token.txt

# 2. Download cloudflared
wget -O /workspace/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /workspace/cloudflared

# 3. Start the tunnel
bash cf-tunnel/cf-tunnel-start.sh
```

After configuring a Public Hostname in the Cloudflare Dashboard, you can access services inside the sandbox via your custom domain.

`socks5-bridge.py` is a SOCKS5-to-HTTP-CONNECT bridge that serves as a general-purpose proxy converter. `socks_hook.c` is an attempt to intercept the `connect()` syscall via LD_PRELOAD (ineffective for Go binaries, kept as reference).

#### 3. BT Panel Proxy (bt-panel/)

The BT Panel (aaPanel/BT-Panel) has an `is_spider()` UA-rewriting check that rejects requests with non-browser User-Agents. `bt-proxy2.py` acts as a reverse proxy, replacing all request User-Agents with a browser UA while handling HTTPS-to-HTTP conversion.

```bash
# Start the proxy (listens on port 18099 by default)
python3 bt-panel/bt-proxy2.py
```

When used with Cloudflare Tunnel, set the Service to `HTTP localhost:18099` in the Public Hostname configuration.

#### 4. BT Panel Security Risk Fix (bt-security/)

The BT Panel's "Security Check" feature scans for system security risks (typically ~81 items), but "One-click Fix" requires a paid membership. This module analyzes the BT Panel's detection logic to manually fix all risks without membership.

**Fix Strategies**:

| Category | Fix Method |
|----------|-----------|
| Config (TMOUT, PAM, etc.) | Directly modify system config files |
| sysctl (hardlink/symlink protection, disable Ping) | Write to sysctl.conf + enhance detection scripts with fallback logic |
| CVE vulnerabilities (ESM packages) | Remove high-risk packages with CVEs (ffmpeg/imagemagick, etc.) |

**Core Principles**:
- In containers/sandboxes, `/proc/sys` is usually read-only, preventing runtime kernel parameter changes. Detection scripts are enhanced with sysctl.conf fallback: check runtime value first, fall back to config file if unavailable
- Many Ubuntu 22.04 CVE fix versions have `+esm` suffix requiring Ubuntu Pro subscription. Analysis of the vulnerability database reveals that all 64 CVEs in a typical environment come from 4 non-essential packages (ffmpeg/imagemagick/git-lfs/graphviz), which can be simply removed

```bash
# Fix all security risks in one command
bash bt-security/fix_security_risks.sh
```

After fixing, the risk count drops from 81 to 0. See [bt-security/README.md](bt-security/README.md) for details.

#### 5. Process Persistence (watchdog/)

When a sandbox session is suspended, child processes are killed. `watchdog.sh` uses `setsid + nohup + disown` triple protection to detach processes from the session, and checks service status every 30 seconds, restarting any stopped services immediately.

```bash
# Start the watchdog
bash watchdog/watchdog.sh start

# Check status
bash watchdog/watchdog.sh status

# Stop
bash watchdog/watchdog.sh stop
```

Monitored services: BT-Panel, BT-Proxy, Cloudflare Tunnel, Serveo SSH, SSHD, Fullroot daemon.

#### 6. One-Click Recovery (scripts/)

All files outside `/workspace` are lost on sandbox restart. `autostart.sh` restores symlinks and restarts all services.

```bash
# Run after sandbox restart
bash watchdog/autostart.sh

# Or use recover_all.sh to restore the doubao_work environment
bash scripts/recover_all.sh
```

### Quick Start

#### Scenario 1: Deploy BT Panel + Cloudflare Tunnel in a sandbox

```bash
# 1. Escalate privileges
bash privilege-setup/trae-fullroot-toolkit.sh

# 2. Persistently install BT Panel
mkdir -p /workspace/www && ln -s /workspace/www /www
wget -O install.sh https://download.bt.cn/install/install-ubuntu_6.0.sh
printf "y\nyes\n" | bash install.sh ed8484bec

# 3. Start BT Panel proxy
python3 bt-panel/bt-proxy2.py &

# 4. Configure Cloudflare Tunnel
echo "your-token" > /workspace/cf-tunnel-token.txt
wget -O /workspace/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /workspace/cloudflared
bash cf-tunnel/cf-tunnel-start.sh

# 5. Start watchdog
bash watchdog/watchdog.sh start
```

Configure Public Hostname in Cloudflare Dashboard:
- Subdomain: `bt`
- Domain: `yourdomain.com`
- Service: `HTTP localhost:18099`

#### Scenario 2: Using Frp tunnel only

```bash
# 1. Install natfrp
bash scripts/install-natfrp-service.sh

# 2. Configure token (edit scripts/modules/config.sh)
# 3. Start tunnel
bash scripts/frp-tunnel-manager.sh start YOUR_TOKEN:YOUR_TUNNEL_ID
```

### Requirements

- Linux sandbox environment (Ubuntu/Debian)
- Python 3.7+
- bash 4+
- Optional: gcc (to compile socks_hook.so)
- Optional: wget/curl (to download cloudflared)

### Notes

1. **Never commit `cf-tunnel-token.txt` to GitHub**. This file contains your Cloudflare Tunnel authentication token and is listed in `.gitignore`.
2. **After sandbox restart**, run `bash watchdog/autostart.sh` again.
3. **The `cloudflared` binary is not included** in the package (~40MB). Download it separately.
4. **Privilege escalation** depends on the `unshare` syscall, which some sandboxes may disable.
5. **Cloudflare Tunnel workaround** depends on the sandbox HTTP proxy supporting the CONNECT method to port 7844.

### License

GPL-3.0 License - Derivative works must be open-sourced; commercial use is prohibited. See [LICENSE](LICENSE).

### Acknowledgments

This project referenced the following resources during development:

- [doevt.top](https://doevt.top/doubao/) - Initial reference for sandbox deployment scripts and fullroot namespace approach
- [Cloudflare](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) - Official Cloudflare Tunnel documentation and the `cloudflared` tool
- Linux kernel `unshare`/`nsenter` user namespace mechanism
