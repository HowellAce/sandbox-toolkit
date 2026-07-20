#!/bin/bash
# =============================================================================
# trae-fullroot-toolkit.sh
# -----------------------------------------------------------------------------
# TRAE 沙箱满血版 Root 全套流程 - 单文件版
#
# 功能整合：
#   1. 满血 Root    - 通过 unshare 创建持久 namespace daemon，获得全部 41 个 capabilities
#   2. SSH 服务     - 安装配置 sshd，支持 root 登录
#   3. frpc 穿透    - 部署 SakuraFrp 客户端，建立内网穿透隧道
#   4. Nginx 反代   - 安装配置 nginx，代理 VNC/code-server
#   5. 工具安装     - 安装常用工具（htop/tmux/vim 等）
#   6. Reset 追踪   - 沙箱重置检测 daemon
#   7. 健康检查     - 全套状态检查
#
# 用法:
#   bash trae-fullroot-toolkit.sh             # 执行全套部署
#   bash trae-fullroot-toolkit.sh fullroot    # 仅部署满血 root
#   bash trae-fullroot-toolkit.sh ssh         # 仅配置 SSH
#   bash trae-fullroot-toolkit.sh frpc        # 仅配置 frpc
#   bash trae-fullroot-toolkit.sh nginx       # 仅配置 nginx
#   bash trae-fullroot-toolkit.sh tools       # 仅安装工具
#   bash trae-fullroot-toolkit.sh tracker     # 仅启动 reset tracker
#   bash trae-fullroot-toolkit.sh health      # 健康检查
#   bash trae-fullroot-toolkit.sh status      # 查看满血 root 状态
#   bash trae-fullroot-toolkit.sh stop        # 停止所有 daemon
#
# 环境变量:
#   FRPC_TOKEN    SakuraFrp 访问 token
#   FRPC_TUNNEL   SakuraFrp 隧道 ID
#   ROOT_PASSWORD root 密码（默认: trae）
#   SSH_PORT      SSH 端口（默认: 22）
#   NGINX_PORT    Nginx 端口（默认: 8080，80 被 agent-tool-host 占用）
#   TRACKER_INTERVAL  Reset tracker 心跳间隔秒数（默认: 30）
# =============================================================================

set -o pipefail

# =============================================================================
# 配置常量
# =============================================================================
WORK_DIR="/workspace"
LOG_FILE="${WORK_DIR}/recovery.log"
MEMORY_FILE="${WORK_DIR}/trae-toolkit-memory.md"

# 满血 Root
PERMAROOT_PIDFILE="/tmp/permaroot-daemon.pid"
FULLROOT_CMD="/usr/local/bin/fullroot"
CAPBND_FULL="000001ffffffffff"
CAPBND_DEFAULT="00000000a80425fb"

# SSH
SSH_PORT="${SSH_PORT:-22}"
SSHD_CONFIG="/etc/ssh/sshd_config"

# frpc
FRPC_PATH="/root/frpc"
FRPC_CONFIG="/root/frpc.ini"
FRPC_LOG="/root/frpc.log"
FRPC_PERSISTENT="${WORK_DIR}/trae-toolkit-bin/frpc"
FRPC_DOWNLOAD_URL="https://nya.globalslb.net/natfrp/client/frpc/0.51.0-sakura-12.3/frpc_linux_amd64"
FRPC_TOKEN="${FRPC_TOKEN:-}"
FRPC_TUNNEL="${FRPC_TUNNEL:-}"

# Nginx
NGINX_PORT="${NGINX_PORT:-8080}"
NGINX_SITE_CONF="/etc/nginx/sites-available/default"

# Reset tracker
SANDBOX_STATE_FILE="${WORK_DIR}/.sandbox-state"
SANDBOX_TRACKER_PID="${WORK_DIR}/.sandbox-tracker.pid"
TRACKER_INTERVAL="${TRACKER_INTERVAL:-30}"

# Supervisor
SUPERVISOR_CONF="/app/supervisord.conf"
SUPERVISOR_SOCK="unix:///run/supervisor.sock"

# 工具列表
TOOLS_LIST="curl wget vim tmux htop git python3 unzip rsync jq tree less bc net-tools iputils-ping dnsutils"

# =============================================================================
# 日志函数
# =============================================================================
_log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] $*"
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    echo "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    case "${level}" in
        ERROR|WARN) echo "${line}" >&2 ;;
        *)          echo "${line}" ;;
    esac
}
log_info()    { _log INFO  "$@"; }
log_warn()    { _log WARN  "$@"; }
log_error()   { _log ERROR "$@"; }
log_success() { _log INFO  "[OK] $*"; }

print_banner() {
    cat <<'BANNER'

============================================================
  TRAE 沙箱满血版 Root 全套工具包 (单文件版)
  Full Root Capabilities + SSH + frpc + Nginx + Tools
============================================================

BANNER
}

print_separator() {
    echo "------------------------------------------------------------"
}

# =============================================================================
# 通用辅助函数
# =============================================================================
is_root() { [ "$(id -u)" = "0" ]; }

is_running() {
    local pattern="$1"
    [ -z "$pattern" ] && return 1
    pgrep -f "${pattern}" >/dev/null 2>&1
}

get_capbnd() {
    awk '/CapBnd/{print $2}' /proc/self/status 2>/dev/null
}

has_full_caps() {
    local cap
    cap="$(get_capbnd)"
    [ "${cap}" = "${CAPBND_FULL}" ] || [ "${cap}" = "1ffffffffff" ]
}

port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"
    else
        (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1
    fi
}

ensure_dir() {
    local dir="$1"
    [ -n "$dir" ] && [ ! -d "$dir" ] && mkdir -p "$dir" 2>/dev/null || true
}

kill_process() {
    local pattern="$1"
    local pids
    pids="$(pgrep -f "${pattern}" 2>/dev/null)"
    [ -z "$pids" ] && return 0
    # shellcheck disable=SC2086
    kill ${pids} 2>/dev/null
    sleep 2
    pids="$(pgrep -f "${pattern}" 2>/dev/null)"
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -9 ${pids} 2>/dev/null
    fi
}

# =============================================================================
# Phase 1: 满血 Root (permaroot daemon + fullroot command)
# =============================================================================
phase_fullroot() {
    print_separator
    log_info "Phase 1: 满血 Root 部署"

    if ! is_root; then
        log_error "当前不是 root 用户 (uid=$(id -u))，无法部署"
        return 1
    fi
    log_success "当前为 root 用户 (uid=0)"

    local cap_now
    cap_now="$(get_capbnd)"
    log_info "当前 CapBnd: ${cap_now:-unknown}"

    if has_full_caps; then
        log_success "已有完整 capabilities，无需 permaroot"
        return 0
    fi

    log_info "CapBnd 受限 (${cap_now})，启动 permaroot daemon..."

    # 创建 fullroot 命令
    _create_fullroot_command

    # 启动 permaroot daemon
    if [ -f "${PERMAROOT_PIDFILE}" ]; then
        local old_pid
        old_pid="$(cat "${PERMAROOT_PIDFILE}" 2>/dev/null)"
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log_success "permaroot daemon 已在运行 (PID: $old_pid)"
            _verify_fullroot
            return 0
        fi
    fi

    log_info "启动 permaroot daemon..."
    unshare -U -r -m -n bash -c 'echo $$ > /tmp/permaroot-daemon.pid; exec sleep infinity' &
    local daemon_pid=$!
    disown "$daemon_pid" 2>/dev/null || true

    # 等待 daemon 启动
    local retries=0
    while [ ! -f "${PERMAROOT_PIDFILE}" ] && [ $retries -lt 10 ]; do
        sleep 0.3
        retries=$((retries + 1))
    done

    local pid
    pid="$(cat "${PERMAROOT_PIDFILE}" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log_success "permaroot daemon 启动成功 (PID: $pid)"
        _verify_fullroot
    else
        log_error "permaroot daemon 启动失败"
        return 1
    fi
}

_create_fullroot_command() {
    log_info "创建 fullroot 命令..."
    cat > "${FULLROOT_CMD}" <<'FULLROOT_SCRIPT'
#!/bin/bash
# fullroot - 通过 permaroot namespace 执行命令，获得完整 capabilities
PIDFILE="/tmp/permaroot-daemon.pid"

get_pid() {
    if [ -f "$PIDFILE" ]; then
        local pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    return 1
}

ensure_daemon() {
    if ! get_pid > /dev/null; then
        unshare -U -r -m -n bash -c 'echo $$ > /tmp/permaroot-daemon.pid; exec sleep infinity' &
        disown 2>/dev/null || true
        local retries=0
        while [ ! -f "$PIDFILE" ] && [ $retries -lt 10 ]; do
            sleep 0.3
            retries=$((retries + 1))
        done
    fi
    get_pid
}

case "${1:-}" in
    "")
        PID=$(ensure_daemon)
        if [ -z "$PID" ]; then
            echo "[-] 无法启动 daemon" >&2
            exit 1
        fi
        echo "[*] 进入完整权限 shell (daemon PID: $PID)"
        echo "[*] CapEff: $(nsenter -t $PID -U -- cat /proc/self/status | grep CapEff | awk '{print $2}')"
        echo "[*] 输入 exit 退出"
        echo ""
        exec nsenter -t "$PID" -U -m -n -- bash --noprofile --norc
        ;;
    -s|--status)
        PID=$(get_pid)
        if [ -n "$PID" ]; then
            echo "[+] Daemon 运行中 (PID: $PID)"
            echo "    CapEff: $(nsenter -t $PID -U -- cat /proc/self/status 2>/dev/null | grep CapEff)"
        else
            echo "[-] Daemon 未运行"
        fi
        ;;
    -k|--kill|--stop)
        PID=$(get_pid)
        if [ -n "$PID" ]; then
            kill "$PID" 2>/dev/null
            rm -f "$PIDFILE"
            echo "[+] Daemon 已停止 (PID: $PID)"
        else
            echo "[-] Daemon 未运行"
        fi
        ;;
    -h|--help)
        echo "fullroot - 永久完整权限命令"
        echo ""
        echo "用法:"
        echo "  fullroot              进入完整权限交互式 shell"
        echo "  fullroot <command>    在完整权限下执行命令"
        echo "  fullroot -s           查看 daemon 状态"
        echo "  fullroot -k           停止 daemon"
        ;;
    *)
        PID=$(ensure_daemon)
        if [ -z "$PID" ]; then
            echo "[-] 无法启动 daemon" >&2
            exit 1
        fi
        exec nsenter -t "$PID" -U -m -n -- "$@"
        ;;
esac
FULLROOT_SCRIPT
    chmod +x "${FULLROOT_CMD}"
    log_success "fullroot 命令已创建: ${FULLROOT_CMD}"
}

_verify_fullroot() {
    local pid
    pid="$(cat "${PERMAROOT_PIDFILE}" 2>/dev/null)"
    if [ -z "$pid" ]; then
        log_warn "无法读取 permaroot daemon PID"
        return 1
    fi
    local caps
    caps=$(nsenter -t "$pid" -U -- cat /proc/self/status 2>/dev/null | grep CapEff | awk '{print $2}')
    if [ "$caps" = "${CAPBND_FULL}" ] || [ "$caps" = "000001ffffffffff" ]; then
        log_success "验证成功: 新 namespace 中所有 41 个 capabilities 已激活"
        return 0
    fi
    log_warn "capabilities 异常: $caps"
    return 1
}

# =============================================================================
# Phase 2: SSH 服务
# =============================================================================
phase_ssh() {
    print_separator
    log_info "Phase 2: SSH 服务配置"

    # 安装 openssh-server
    if ! command -v sshd >/dev/null 2>&1; then
        log_info "安装 openssh-server..."
        apt-get update -y >>"${LOG_FILE}" 2>&1 || log_warn "apt-get update 失败"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server >>"${LOG_FILE}" 2>&1; then
            log_error "openssh-server 安装失败"
            return 1
        fi
        log_success "openssh-server 已安装"
    else
        log_info "openssh-server 已安装"
    fi

    # 配置 sshd
    log_info "配置 sshd..."
    ensure_dir /run/sshd
    ensure_dir /root/.ssh

    [ ! -f "${SSHD_CONFIG}.bak" ] && cp -n "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak" 2>/dev/null || true

    set_sshd_option() {
        local key="$1" val="$2"
        if grep -qE "^\s*${key}\s+" "${SSHD_CONFIG}" 2>/dev/null; then
            sed -i -E "s|^\s*${key}\s+.*|${key} ${val}|" "${SSHD_CONFIG}"
        else
            echo "${key} ${val}" >> "${SSHD_CONFIG}"
        fi
    }

    set_sshd_option "PermitRootLogin" "yes"
    set_sshd_option "PasswordAuthentication" "yes"
    set_sshd_option "PubkeyAuthentication" "yes"
    set_sshd_option "Port" "${SSH_PORT}"
    log_success "sshd 配置完成 (Port=${SSH_PORT}, PermitRootLogin=yes)"

    # 生成 host keys
    [ ! -f /etc/ssh/ssh_host_rsa_key ] && ssh-keygen -A >>"${LOG_FILE}" 2>&1 || true

    # 设置 root 密码
    local pw="${ROOT_PASSWORD:-trae}"
    echo "root:${pw}" | chpasswd 2>>"${LOG_FILE}" && log_success "root 密码已设置 (默认: ${pw})" || log_warn "root 密码设置失败"

    # 启动 sshd
    if is_running "/usr/sbin/sshd"; then
        log_info "sshd 已在运行"
    else
        log_info "启动 sshd (端口 ${SSH_PORT})..."
        /usr/sbin/sshd -t >>"${LOG_FILE}" 2>&1 || { log_error "sshd 配置测试失败"; return 1; }
        nohup /usr/sbin/sshd -D >>"${LOG_FILE}" 2>&1 &
        disown 2>/dev/null || true
        sleep 1
        if is_running "/usr/sbin/sshd"; then
            log_success "sshd 已启动"
        else
            log_error "sshd 启动失败"
            return 1
        fi
    fi

    log_success "SSH 配置完成 (端口 ${SSH_PORT})"
}

# =============================================================================
# Phase 3: frpc 内网穿透
# =============================================================================
phase_frpc() {
    print_separator
    log_info "Phase 3: frpc 内网穿透配置"

    # 部署 frpc 二进制
    if [ -x "${FRPC_PATH}" ]; then
        log_info "frpc 二进制已存在: ${FRPC_PATH}"
    else
        # 尝试从持久化目录复制
        if [ -f "${FRPC_PERSISTENT}" ]; then
            log_info "从持久化目录复制 frpc..."
            cp -f "${FRPC_PERSISTENT}" "${FRPC_PATH}"
            chmod +x "${FRPC_PATH}"
            log_success "frpc 二进制已部署"
        else
            # 下载 frpc
            log_info "下载 frpc..."
            if curl -L -o "${FRPC_PATH}" "${FRPC_DOWNLOAD_URL}" >>"${LOG_FILE}" 2>&1; then
                chmod +x "${FRPC_PATH}"
                log_success "frpc 下载完成: $(${FRPC_PATH} -v 2>&1)"

                # 持久化保存
                ensure_dir "$(dirname "${FRPC_PERSISTENT}")"
                cp -f "${FRPC_PATH}" "${FRPC_PERSISTENT}"
                log_info "frpc 已持久化到 ${FRPC_PERSISTENT}"
            else
                log_error "frpc 下载失败"
                return 1
            fi
        fi
    fi

    # 创建配置文件
    cat > "${FRPC_CONFIG}" <<EOF
# frpc configuration for TRAE sandbox
# Token and tunnel are supplied on the command line via -f <token>:<tunnel>.
[common]
EOF
    log_success "frpc 配置文件已创建: ${FRPC_CONFIG}"

    # 创建 frpc-ctl 管理脚本
    _create_frpc_ctl

    # 启动 frpc（如果有 token）
    if [ -n "${FRPC_TOKEN}" ] && [ -n "${FRPC_TUNNEL}" ]; then
        if is_running "${FRPC_PATH} -f "; then
            log_info "frpc 已在运行"
        else
            log_info "启动 frpc (tunnel: ${FRPC_TUNNEL})..."
            : > "${FRPC_LOG}" 2>/dev/null || true
            nohup "${FRPC_PATH}" -f "${FRPC_TOKEN}:${FRPC_TUNNEL}" >>"${FRPC_LOG}" 2>&1 &
            disown 2>/dev/null || true
            sleep 2
            if is_running "${FRPC_PATH} -f "; then
                log_success "frpc 已启动 (tunnel ${FRPC_TUNNEL})"
            else
                log_error "frpc 启动失败，查看日志: ${FRPC_LOG}"
                tail -5 "${FRPC_LOG}" 2>/dev/null | while read -r line; do log_error "  ${line}"; done
                return 1
            fi
        fi
    else
        log_warn "FRPC_TOKEN 或 FRPC_TUNNEL 未设置，frpc 二进制已部署但未启动"
        log_warn "使用方式: FRPC_TOKEN=xxx FRPC_TUNNEL=xxx bash $0 frpc"
        log_warn "或: frpc-ctl start TOKEN:TUNNEL"
    fi

    log_success "frpc 配置完成"
}

_create_frpc_ctl() {
    log_info "创建 frpc-ctl 管理脚本..."
    cat > /usr/local/bin/frpc-ctl <<'FRPC_CTL'
#!/bin/bash
# frpc-ctl - frpc 管理脚本
FRPC_BIN="/root/frpc"
FRPC_LOG="/root/frpc.log"
PID_FILE="/root/frpc.pid"

case "$1" in
    start)
        if [ -z "$2" ]; then
            if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE" 2>/dev/null) 2>/dev/null; then
                echo "frpc 已在运行 (PID: $(cat $PID_FILE))"
                exit 0
            fi
            echo "用法: frpc-ctl start <token:tunnel>"
            echo "或设置 FRPC_TOKEN 和 FRPC_TUNNEL 环境变量后: frpc-ctl start env"
            exit 1
        fi
        if [ "$2" = "env" ]; then
            [ -z "$FRPC_TOKEN" ] || [ -z "$FRPC_TUNNEL" ] && { echo "FRPC_TOKEN 或 FRPC_TUNNEL 未设置"; exit 1; }
            ARGS="${FRPC_TOKEN}:${FRPC_TUNNEL}"
        else
            ARGS="$2"
        fi
        if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE" 2>/dev/null) 2>/dev/null; then
            echo "frpc 已在运行 (PID: $(cat $PID_FILE))"
            exit 0
        fi
        nohup $FRPC_BIN -f "$ARGS" > "$FRPC_LOG" 2>&1 &
        echo $! > "$PID_FILE"
        sleep 2
        if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
            echo "[OK] frpc 已启动 (PID: $(cat $PID_FILE))"
        else
            echo "[FAIL] frpc 启动失败"
            tail -5 "$FRPC_LOG" 2>/dev/null
            rm -f "$PID_FILE"
            exit 1
        fi
        ;;
    stop)
        if [ -f "$PID_FILE" ]; then
            kill $(cat "$PID_FILE") 2>/dev/null
            rm -f "$PID_FILE"
            echo "[OK] frpc 已停止"
        else
            pkill -f "${FRPC_BIN} -f" 2>/dev/null
            echo "frpc 未运行"
        fi
        ;;
    status)
        if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
            echo "frpc 运行中 (PID: $(cat $PID_FILE))"
        else
            echo "frpc 未运行"
        fi
        echo "二进制: $([ -x "$FRPC_BIN" ] && echo "存在" || echo "缺失") ($FRPC_BIN)"
        echo "日志: $FRPC_LOG"
        ;;
    log)
        tail -n "${2:-20}" "$FRPC_LOG" 2>/dev/null || echo "无日志"
        ;;
    *)
        echo "用法: frpc-ctl {start <token:tunnel>|start env|stop|status|log [行数]}"
        ;;
esac
FRPC_CTL
    chmod +x /usr/local/bin/frpc-ctl
    log_success "frpc-ctl 已创建: /usr/local/bin/frpc-ctl"
}

# =============================================================================
# Phase 4: Nginx 反向代理
# =============================================================================
phase_nginx() {
    print_separator
    log_info "Phase 4: Nginx 反向代理配置"

    # 安装 nginx
    if ! command -v nginx >/dev/null 2>&1; then
        log_info "安装 nginx..."
        apt-get update -y >>"${LOG_FILE}" 2>&1 || true
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >>"${LOG_FILE}" 2>&1; then
            log_error "nginx 安装失败"
            return 1
        fi
        log_success "nginx 已安装: $(nginx -v 2>&1)"
    else
        log_info "nginx 已安装: $(nginx -v 2>&1)"
    fi

    # 配置 nginx
    log_info "配置 nginx (端口 ${NGINX_PORT})..."
    ensure_dir /var/www/html
    echo "<html><body><h1>TRAE Sandbox Nginx</h1><p>Running on port ${NGINX_PORT}</p></body></html>" > /var/www/html/index.nginx-debian.html

    cat > "${NGINX_SITE_CONF}" <<EOF
server {
    listen ${NGINX_PORT} default_server;
    listen [::]:${NGINX_PORT} default_server;

    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # WebSocket proxy for VNC/noVNC
    location /websockify {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Proxy for code-server
    location /code/ {
        proxy_pass http://127.0.0.1:8200/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    log_success "nginx 配置已写入 (端口 ${NGINX_PORT})"

    # 测试配置
    if ! nginx -t >>"${LOG_FILE}" 2>&1; then
        log_error "nginx 配置测试失败"
        return 1
    fi
    log_success "nginx 配置测试通过"

    # 停止已有 nginx 实例
    if is_running "nginx: master"; then
        log_info "停止已有 nginx 实例..."
        nginx -s stop >>"${LOG_FILE}" 2>&1 || true
        sleep 1
    fi

    # 加入 supervisord
    if [ -f "${SUPERVISOR_CONF}" ]; then
        if ! grep -q "\[program:nginx\]" "${SUPERVISOR_CONF}" 2>/dev/null; then
            log_info "将 nginx 加入 supervisord..."
            cat >> "${SUPERVISOR_CONF}" <<EOF

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
directory=/workspace
autostart=true
autorestart=true
startretries=3
startsecs=2
stdout_logfile=/var/log/tool/nginx.stdout.log
stderr_logfile=/var/log/tool/nginx.stderr.log
stdout_logfile_maxbytes=50MB
stderr_logfile_maxbytes=50MB
stdout_logfile_backups=3
stderr_logfile_backups=3
EOF
            log_success "nginx 已加入 supervisord"
            if command -v supervisorctl >/dev/null 2>&1; then
                supervisorctl -s "${SUPERVISOR_SOCK}" reread >>"${LOG_FILE}" 2>&1 || true
                supervisorctl -s "${SUPERVISOR_SOCK}" update >>"${LOG_FILE}" 2>&1 || true
                sleep 3
            fi
        else
            log_info "nginx 已在 supervisord 配置中"
        fi
    fi

    # 如果 supervisord 没有管理 nginx，手动启动
    if ! is_running "nginx: master"; then
        log_info "启动 nginx..."
        nginx >>"${LOG_FILE}" 2>&1 || { log_error "nginx 启动失败"; return 1; }
        sleep 1
    fi

    if is_running "nginx: master"; then
        log_success "nginx 已启动 (端口 ${NGINX_PORT})"
    else
        log_error "nginx 未运行"
        return 1
    fi

    # 验证访问
    if curl -s "http://127.0.0.1:${NGINX_PORT}/" >/dev/null 2>&1; then
        log_success "nginx 访问验证通过"
    else
        log_warn "nginx 访问验证失败"
    fi

    log_success "Nginx 配置完成 (端口 ${NGINX_PORT})"
}

# =============================================================================
# Phase 5: 工具安装
# =============================================================================
phase_tools() {
    print_separator
    log_info "Phase 5: 工具安装"

    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "apt-get 不可用，跳过工具安装"
        return 0
    fi

    # apt update（只执行一次）
    if [ ! -f /tmp/.trae-apt-updated ]; then
        log_info "执行 apt-get update..."
        apt-get update -y >>"${LOG_FILE}" 2>&1 || log_warn "apt-get update 失败"
        touch /tmp/.trae-apt-updated 2>/dev/null || true
    fi

    local missing=0
    for pkg in ${TOOLS_LIST}; do
        if command -v "$pkg" >/dev/null 2>&1 || dpkg -s "$pkg" >/dev/null 2>&1; then
            continue
        fi
        log_info "安装 ${pkg}..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >>"${LOG_FILE}" 2>&1; then
            log_success "${pkg} 已安装"
        else
            log_warn "${pkg} 安装失败（网络可能受限）"
            missing=$((missing + 1))
        fi
    done

    if [ $missing -gt 0 ]; then
        log_warn "${missing} 个工具未能安装"
    else
        log_success "所有工具已安装"
    fi

    # 添加 shell aliases
    _install_shell_aliases

    log_success "工具安装完成"
}

_install_shell_aliases() {
    local rc="/root/.bashrc"
    local marker="# >>> TRAE toolkit aliases >>>"
    local ender="# <<< TRAE toolkit aliases <<<"
    if [ -f "$rc" ] && grep -q "$marker" "$rc" 2>/dev/null; then
        return 0
    fi
    {
        echo ""
        echo "$marker"
        echo "alias ll='ls -alF'"
        echo "alias la='ls -A'"
        echo "alias fullroot='/usr/local/bin/fullroot'"
        echo "alias health='bash ${WORK_DIR}/trae-fullroot-toolkit.sh health'"
        echo "alias frpm='frpc-ctl'"
        echo "$ender"
    } >> "$rc" 2>/dev/null || true
    log_success "Shell aliases 已添加到 ${rc}"
}

# =============================================================================
# Phase 6: Reset Tracker
# =============================================================================
phase_tracker() {
    print_separator
    log_info "Phase 6: Reset Tracker 启动"

    # 检查是否已在运行
    if [ -f "${SANDBOX_TRACKER_PID}" ]; then
        local pid
        pid="$(cat "${SANDBOX_TRACKER_PID}" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_success "tracker 已在运行 (PID: $pid)"
            return 0
        fi
    fi

    # 写入初始状态
    _tracker_write_state

    # 启动 daemon
    log_info "启动 reset tracker daemon (间隔 ${TRACKER_INTERVAL}s)..."
    nohup bash -c '
        TRACKER_INTERVAL="'"${TRACKER_INTERVAL}"'"
        SANDBOX_STATE_FILE="'"${SANDBOX_STATE_FILE}"'"
        SANDBOX_TRACKER_PID="'"${SANDBOX_TRACKER_PID}"'"
        LOG_FILE="'"${LOG_FILE}"'"
        echo $$ > "'${SANDBOX_TRACKER_PID}'"
        while true; do
            boot_id="unknown"
            [ -r /proc/sys/kernel/random/boot_id ] && boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d "[:space:]")
            cat > "'${SANDBOX_STATE_FILE}'" <<EOF
# TRAE sandbox reset tracker state
boot_id=${boot_id}
last_heartbeat=$(date "+%Y-%m-%dT%H:%M:%S%z")
epoch=$(date +%s)
uid=$(id -u)
hostname=$(hostname 2>/dev/null || echo unknown)
EOF
            sleep "'${TRACKER_INTERVAL}'"
        done
    ' >> "${LOG_FILE}" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true

    sleep 1
    if [ -f "${SANDBOX_TRACKER_PID}" ] && kill -0 "$(cat "${SANDBOX_TRACKER_PID}" 2>/dev/null)" 2>/dev/null; then
        log_success "tracker 已启动 (PID: $(cat "${SANDBOX_TRACKER_PID}"))"
    else
        log_warn "tracker 启动可能失败"
    fi

    log_success "Reset Tracker 配置完成"
}

_tracker_write_state() {
    local boot_id="unknown"
    [ -r /proc/sys/kernel/random/boot_id ] && boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '[:space:]')
    cat > "${SANDBOX_STATE_FILE}" <<EOF
# TRAE sandbox reset tracker state
boot_id=${boot_id}
last_heartbeat=$(date '+%Y-%m-%dT%H:%M:%S%z')
epoch=$(date +%s)
uid=$(id -u)
hostname=$(hostname 2>/dev/null || echo unknown)
EOF
}

# =============================================================================
# Phase 7: 更新 Memory
# =============================================================================
phase_memory() {
    print_separator
    log_info "Phase 7: 更新 Memory 文件"

    cat > "${MEMORY_FILE}" <<EOF
# TRAE Sandbox 满血版 Root 工具包 - Memory

## 环境信息
- System: TRAE sandbox (Ubuntu 22.04)
- User: root (uid=0)
- Filesystem: virtiofs (不支持 xattr/mknod)
- CapBnd (默认): ${CAPBND_DEFAULT} (14 capabilities, 受限)
- CapBnd (满血): ${CAPBND_FULL} (41 capabilities, 通过 unshare 获得)
- Supervisor: /app/supervisord.conf (服务: agent-tool-host, nginx)

## 满血 Root 方案
- 通过 \`unshare -U -r -m -n\` 创建新 user/mount/network namespace
- 在新 namespace 中拥有所有 41 个 capabilities
- permaroot daemon 持久运行（sleep infinity），通过 nsenter 进入
- \`fullroot\` 命令全局可用（/usr/local/bin/fullroot）

## 服务配置
- SSH: 端口 ${SSH_PORT}, root 登录已启用
- frpc: SakuraFrp 0.51.0-sakura-12.3, 路径 /root/frpc
- Nginx: 端口 ${NGINX_PORT}, 代理 VNC(6080) 和 code-server(8200)
- frpc-ctl: /usr/local/bin/frpc-ctl

## 命令速查
- \`fullroot\`           - 进入完整权限 shell
- \`fullroot <cmd>\`     - 在完整权限下执行命令
- \`fullroot -s\`        - 查看 daemon 状态
- \`frpc-ctl start TOKEN:TUNNEL\` - 启动 frpc
- \`frpc-ctl status\`    - 查看 frpc 状态
- \`bash ${WORK_DIR}/trae-fullroot-toolkit.sh health\` - 健康检查
- \`bash ${WORK_DIR}/trae-fullroot-toolkit.sh\` - 全套部署

## 沙箱重置后恢复
1. \`bash ${WORK_DIR}/trae-fullroot-toolkit.sh\` - 执行全套部署
2. 或分步执行: fullroot -> ssh -> frpc -> nginx -> tools -> tracker

## 动态状态 (last refresh: $(date '+%Y-%m-%d %H:%M:%S'))
- uid: $(id -u)
- CapBnd: $(get_capbnd)
- Full caps: $(has_full_caps && echo yes || echo no)
- sshd: $(is_running "/usr/sbin/sshd" && echo running || echo stopped)
- frpc: $(is_running "${FRPC_PATH} -f " && echo running || echo stopped)
- nginx: $(is_running "nginx: master" && echo running || echo stopped)
- fullroot: $([ -x "${FULLROOT_CMD}" ] && echo available || echo unavailable)
- agent-tool-host: $(is_running "agent-tool-host" && echo running || echo stopped)
EOF

    log_success "Memory 文件已更新: ${MEMORY_FILE}"
}

# =============================================================================
# 健康检查
# =============================================================================
phase_health() {
    print_banner
    echo "TRAE 沙箱健康检查 - $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    local pass=0 fail=0 warn=0
    ok()   { echo "  [OK]   $*"; pass=$((pass + 1)); }
    fail() { echo "  [FAIL] $*"; fail=$((fail + 1)); }
    warn() { echo "  [WARN] $*"; warn=$((warn + 1)); }
    section() { echo ""; echo "=== $* ==="; }

    # Root
    section "Root 权限"
    if is_root; then ok "root 用户 (uid=0)"; else fail "非 root (uid=$(id -u))"; fi

    # CapBnd
    section "Capability Bounding Set"
    local cap
    cap="$(get_capbnd)"
    if has_full_caps; then
        ok "CapBnd 完整 (${cap})"
    else
        warn "CapBnd 受限 (${cap})，使用 fullroot 获得完整权限"
    fi

    # fullroot
    section "满血 Root (fullroot)"
    if [ -x "${FULLROOT_CMD}" ]; then
        ok "fullroot 命令存在"
        if "${FULLROOT_CMD}" -s >/dev/null 2>&1; then
            ok "fullroot daemon 运行中"
        else
            warn "fullroot daemon 未运行"
        fi
    else
        warn "fullroot 命令未安装"
    fi

    # SSH
    section "SSH (端口 ${SSH_PORT})"
    if is_running "/usr/sbin/sshd"; then ok "sshd 运行中"; else fail "sshd 未运行"; fi
    if port_listening "${SSH_PORT}"; then ok "端口 ${SSH_PORT} 监听中"; else fail "端口 ${SSH_PORT} 未监听"; fi

    # frpc
    section "frpc 内网穿透"
    if [ -x "${FRPC_PATH}" ]; then ok "frpc 二进制存在"; else warn "frpc 二进制缺失"; fi
    if is_running "${FRPC_PATH} -f "; then ok "frpc 运行中"; else warn "frpc 未运行（token 可能未设置）"; fi

    # Nginx
    section "Nginx (端口 ${NGINX_PORT})"
    if is_running "nginx: master"; then ok "nginx 运行中"; else warn "nginx 未运行"; fi
    if port_listening "${NGINX_PORT}"; then ok "端口 ${NGINX_PORT} 监听中"; else warn "端口 ${NGINX_PORT} 未监听"; fi

    # agent-tool-host
    section "agent-tool-host (Supervisor)"
    if is_running "agent-tool-host"; then ok "agent-tool-host 运行中"; else fail "agent-tool-host 未运行"; fi

    # Supervisor
    section "Supervisor"
    if [ -S /run/supervisor.sock ]; then ok "supervisor socket 存在"; else warn "supervisor socket 缺失"; fi

    # Chrome Debug
    section "Chrome Debug (端口 9222)"
    if port_listening 9222; then ok "端口 9222 监听中"; else warn "端口 9222 未监听（可选）"; fi

    # Reset Tracker
    section "Reset Tracker"
    if [ -f "${SANDBOX_TRACKER_PID}" ]; then
        local tpid
        tpid="$(cat "${SANDBOX_TRACKER_PID}" 2>/dev/null)"
        if [ -n "$tpid" ] && kill -0 "$tpid" 2>/dev/null; then
            ok "tracker 运行中 (PID: $tpid)"
        else
            warn "tracker PID 文件存在但进程已死"
        fi
    else
        warn "tracker 未运行"
    fi
    if [ -f "${SANDBOX_STATE_FILE}" ]; then ok "状态文件存在"; else warn "状态文件缺失"; fi

    # Workspace
    section "工作区"
    if [ -d "${WORK_DIR}" ]; then ok "工作区存在 (${WORK_DIR})"; else fail "工作区缺失"; fi
    if [ -f "${MEMORY_FILE}" ]; then ok "memory.md 存在"; else warn "memory.md 缺失"; fi

    # Summary
    echo ""
    print_separator
    echo "汇总: ${pass} 通过, ${warn} 警告, ${fail} 失败"
    print_separator

    [ $fail -gt 0 ] && return 1
    return 0
}

# =============================================================================
# 状态查看
# =============================================================================
phase_status() {
    echo "=== TRAE 沙箱满血 Root 状态 ==="
    echo ""
    echo "用户:     $(whoami) (uid=$(id -u))"
    echo "CapBnd:   $(get_capbnd)"
    echo "完整 caps: $(has_full_caps && echo "是" || echo "否（使用 fullroot）")"
    echo ""

    echo "--- 满血 Root Daemon ---"
    if [ -f "${PERMAROOT_PIDFILE}" ]; then
        local pid
        pid="$(cat "${PERMAROOT_PIDFILE}" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "状态: 运行中 (PID: $pid)"
            echo "CapEff: $(nsenter -t $pid -U -- cat /proc/self/status 2>/dev/null | grep CapEff)"
        else
            echo "状态: 未运行（PID 文件过期）"
        fi
    else
        echo "状态: 未运行"
    fi
    echo "fullroot: $([ -x "${FULLROOT_CMD}" ] && echo "可用" || echo "未安装")"
    echo ""

    echo "--- 服务状态 ---"
    echo "sshd:     $(is_running "/usr/sbin/sshd" && echo "运行中" || echo "停止") (端口 ${SSH_PORT})"
    echo "frpc:     $(is_running "${FRPC_PATH} -f " && echo "运行中" || echo "停止")"
    echo "nginx:    $(is_running "nginx: master" && echo "运行中" || echo "停止") (端口 ${NGINX_PORT})"
    echo "tracker:  $([ -f "${SANDBOX_TRACKER_PID}" ] && kill -0 "$(cat "${SANDBOX_TRACKER_PID}" 2>/dev/null)" 2>/dev/null && echo "运行中" || echo "停止")"
    echo "agent:    $(is_running "agent-tool-host" && echo "运行中" || echo "停止")"
    echo ""

    echo "--- 监听端口 ---"
    ss -tlnp 2>/dev/null | awk 'NR>1{print $4}' | sort -t: -k2 -n | uniq | head -20
}

# =============================================================================
# 停止所有 daemon
# =============================================================================
phase_stop() {
    print_separator
    log_info "停止所有 daemon..."

    # permaroot daemon
    if [ -f "${PERMAROOT_PIDFILE}" ]; then
        local pid
        pid="$(cat "${PERMAROOT_PIDFILE}" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_success "permaroot daemon 已停止 (PID: $pid)"
        fi
        rm -f "${PERMAROOT_PIDFILE}"
    fi

    # reset tracker
    if [ -f "${SANDBOX_TRACKER_PID}" ]; then
        local pid
        pid="$(cat "${SANDBOX_TRACKER_PID}" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_success "reset tracker 已停止 (PID: $pid)"
        fi
        rm -f "${SANDBOX_TRACKER_PID}"
    fi

    # frpc
    if is_running "${FRPC_PATH} -f "; then
        kill_process "${FRPC_PATH} -f "
        log_success "frpc 已停止"
    fi

    log_success "所有 daemon 已停止"
}

# =============================================================================
# 全套部署
# =============================================================================
phase_all() {
    print_banner
    log_info "TRAE 沙箱满血版 Root 全套部署开始 - $(date '+%Y-%m-%d %H:%M:%S')"

    phase_fullroot  || log_warn "满血 Root 部署有问题（继续）"
    phase_ssh       || log_warn "SSH 配置有问题（继续）"
    phase_frpc      || log_warn "frpc 配置有问题（继续）"
    phase_nginx     || log_warn "Nginx 配置有问题（继续）"
    phase_tools     || log_warn "工具安装有问题（继续）"
    phase_tracker   || log_warn "Reset tracker 有问题（继续）"
    phase_memory    || log_warn "Memory 更新有问题（继续）"

    print_separator
    echo "==================== 部署总结 ===================="
    echo "时间:     $(date '+%Y-%m-%d %H:%M:%S')"
    echo "uid:      $(id -u)"
    echo "CapBnd:   $(get_capbnd)"
    echo "满血 caps: $(has_full_caps && echo "是" || echo "否")"
    echo "sshd:     $(is_running "/usr/sbin/sshd" && echo "运行中" || echo "停止") (端口 ${SSH_PORT})"
    echo "frpc:     $(is_running "${FRPC_PATH} -f " && echo "运行中" || echo "停止")"
    echo "nginx:    $(is_running "nginx: master" && echo "运行中" || echo "停止") (端口 ${NGINX_PORT})"
    echo "fullroot: $([ -x "${FULLROOT_CMD}" ] && echo "可用" || echo "不可用")"
    echo "tracker:  $([ -f "${SANDBOX_TRACKER_PID}" ] && kill -0 "$(cat "${SANDBOX_TRACKER_PID}" 2>/dev/null)" 2>/dev/null && echo "运行中" || echo "停止")"
    echo "日志:     ${LOG_FILE}"
    echo "memory:   ${MEMORY_FILE}"
    echo "=================================================="
    echo ""
    echo "运行 'bash $0 health' 查看完整健康检查"
    echo "运行 'bash $0 status' 查看状态"
    echo ""

    log_success "全套部署完成"
}

# =============================================================================
# 主入口
# =============================================================================
case "${1:-all}" in
    all)         phase_all ;;
    fullroot)    phase_fullroot ;;
    ssh)         phase_ssh ;;
    frpc)        phase_frpc ;;
    nginx)       phase_nginx ;;
    tools)       phase_tools ;;
    tracker)     phase_tracker ;;
    memory)      phase_memory ;;
    health)      phase_health ;;
    status)      phase_status ;;
    stop)        phase_stop ;;
    -h|--help|help)
        cat <<EOF
TRAE 沙箱满血版 Root 全套工具包 (单文件版)

用法: bash $0 [命令]

命令:
  (无) / all     执行全套部署
  fullroot       仅部署满血 Root (permaroot daemon + fullroot)
  ssh            仅配置 SSH 服务
  frpc           仅配置 frpc 内网穿透
  nginx          仅配置 Nginx 反向代理
  tools          仅安装常用工具
  tracker        仅启动 Reset Tracker
  memory         仅更新 Memory 文件
  health         健康检查
  status         查看状态
  stop           停止所有 daemon

环境变量:
  FRPC_TOKEN        SakuraFrp 访问 token
  FRPC_TUNNEL       SakuraFrp 隧道 ID
  ROOT_PASSWORD     root 密码（默认: trae）
  SSH_PORT          SSH 端口（默认: 22）
  NGINX_PORT        Nginx 端口（默认: 8080）
  TRACKER_INTERVAL  Tracker 心跳间隔秒数（默认: 30）

示例:
  bash $0                                    # 全套部署
  FRPC_TOKEN=xxx FRPC_TUNNEL=123 bash $0     # 全套部署 + 启动 frpc
  bash $0 fullroot                           # 仅部署满血 Root
  bash $0 health                             # 健康检查
  bash $0 status                             # 查看状态
EOF
        ;;
    *)
        echo "未知命令: $1" >&2
        echo "使用 'bash $0 help' 查看帮助" >&2
        exit 2
        ;;
esac
