#!/bin/bash
# ==========================================
# Minecraft Server Deployment Script
# Optional Script
# ==========================================
# 功能：自动部署 Minecraft Java 版服务端
# 版本：26.2 (Chaos Cubed) - 2026年6月16日正式版
# 依赖：Java 25+（Minecraft 26.1+ 强制要求）
# ==========================================
# 更新记录：
#   v1.2 - 更新到最新最佳实践（2026年6月）
#        - 添加 Aikar's Flags JVM 优化参数
#        - 添加性能配置选项（view-distance 等）
#        - 确认 Java 25 为最低要求
#        - 添加服务器软件说明（Vanilla/Paper/Purpur）
#   v1.1 - 修复代理导致正版验证失败的问题
#        - 默认启用 RCON 远程管理
#        - 添加初始 OP 玩家配置
#        - 启动脚本防重复启动
#        - 添加安全关闭说明
# ==========================================
set -e

# ==========================================
# 配置项
# ==========================================
# ---- 基础配置 ----
# Minecraft 版本
MC_VERSION="26.2"
# 服务端下载链接（官方 CDN - Vanilla 原版）
SERVER_JAR_URL="https://piston-data.mojang.com/v1/objects/823e2250d24b3ddac457a60c92a6a941943fcd6a/server.jar"
# 安装目录
INSTALL_DIR="/home/user/.super_doubao/super-doubao-runtime/workspace/minecraft-server"
# 服务端类型：vanilla / paper / purpur（当前仅支持 vanilla）
SERVER_TYPE="vanilla"

# ---- 内存配置 ----
# 内存分配（Xms 和 Xmx 建议设为相同值）
MEM_MIN="2G"
MEM_MAX="2G"

# ---- 游戏配置 ----
# 服务端端口
SERVER_PORT="25565"
# 游戏模式 (survival/creative/adventure/spectator)
GAMEMODE="survival"
# 难度 (peaceful/easy/normal/hard)
DIFFICULTY="easy"
# 最大玩家数
MAX_PLAYERS="20"
# 正版验证 (true/false)
ONLINE_MODE="true"
# 是否自动启动服务端 (true/false)
AUTO_START="false"

# ---- 性能配置（v1.2 新增）----
# 视距（chunks）- 最大性能杠杆，建议 6-10
VIEW_DISTANCE="10"
# 模拟距离（chunks）- 实体活动范围，建议 4-6
SIMULATION_DISTANCE="6"
# 视距内怪物生成上限（每玩家）
MONSTER_SPAWN_LIMIT="70"
# 空服务器自动暂停时间（秒），0 表示不暂停
PAUSE_WHEN_EMPTY="60"

# ---- JVM 优化配置（v1.2 新增）----
# JVM 优化模式：aikars / zgc / none
#   aikars - Aikar's Flags (G1GC)，大多数服务器推荐
#   zgc    - ZGC 分代回收，大内存（8GB+）高性能服务器推荐
#   none   - 不使用优化参数
JVM_OPTIMIZATION="aikars"

# ---- RCON 远程管理 ----
# RCON 远程管理 (true/false)
ENABLE_RCON="true"
# RCON 端口
RCON_PORT="25575"
# RCON 密码（留空则自动生成随机密码）
RCON_PASSWORD=""

# ---- 初始 OP 玩家 ----
# 初始 OP 玩家名（留空则不设置，需要手动添加）
INITIAL_OP=""

# ==========================================
# 颜色输出
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}
success() {
    echo -e "${GREEN}[OK]${NC} $1"
}
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}
error() {
    echo -e "${RED}[ERROR]${NC} $1"
}
highlight() {
    echo -e "${CYAN}$1${NC}"
}

# ==========================================
# 检查权限
# ==========================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        warn "当前不是 root 用户，安装 Java 可能需要 sudo 权限"
        SUDO="sudo"
    else
        SUDO=""
    fi
}

# ==========================================
# 检查并安装 Java
# ==========================================
check_java() {
    info "检查 Java 环境..."
    
    if command -v java &> /dev/null; then
        # 从 java -version 输出中提取版本号（跳过警告行）
        JAVA_VERSION=$(java -version 2>&1 | grep -E '^openjdk|^java version' | head -n 1 | awk -F '"' '{print $2}' | cut -d'.' -f1)
        info "当前 Java 版本: $JAVA_VERSION"
        
        if [ "$JAVA_VERSION" -ge 25 ]; then
            success "Java 版本满足要求 (需要 Java 25+，Minecraft 26.1+ 强制要求)"
            return 0
        else
            warn "Java 版本过低，Minecraft $MC_VERSION 需要 Java 25 或更高版本"
            install_java
        fi
    else
        warn "未检测到 Java 环境"
        install_java
    fi
}

install_java() {
    info "正在安装 OpenJDK 25..."
    info "  推荐发行版：Eclipse Temurin、Amazon Corretto、GraalVM"
    info "  当前使用：Ubuntu 默认源 OpenJDK"
    
    if $SUDO apt update -qq 2>/dev/null; then
        if $SUDO apt install -y openjdk-25-jre-headless 2>/dev/null; then
            success "Java 25 安装成功"
        else
            error "Java 25 安装失败，请手动安装"
            error "  推荐下载：https://adoptium.net/ (Eclipse Temurin)"
            exit 1
        fi
    else
        error "无法更新软件源，请检查网络连接"
        exit 1
    fi
}

# ==========================================
# 创建目录
# ==========================================
create_directories() {
    info "创建服务端目录..."
    
    if [ -d "$INSTALL_DIR" ]; then
        warn "目录已存在: $INSTALL_DIR"
        read -p "是否覆盖？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "取消安装"
            exit 0
        fi
    fi
    
    mkdir -p "$INSTALL_DIR"
    success "目录创建完成: $INSTALL_DIR"
}

# ==========================================
# 下载服务端
# ==========================================
download_server() {
    info "下载 Minecraft 服务端 (版本: $MC_VERSION)..."
    info "  类型: $SERVER_TYPE (Vanilla 原版)"
    info "  提示: 如需更好性能，可考虑 Paper 或 Purpur 服务端"
    
    cd "$INSTALL_DIR"
    
    if [ -f "server.jar" ]; then
        warn "server.jar 已存在，跳过下载"
        return 0
    fi
    
    if command -v wget &> /dev/null; then
        wget -q "$SERVER_JAR_URL" -O server.jar
    elif command -v curl &> /dev/null; then
        curl -s -L "$SERVER_JAR_URL" -o server.jar
    else
        error "未找到 wget 或 curl，请手动下载服务端"
        exit 1
    fi
    
    if [ -f "server.jar" ]; then
        FILE_SIZE=$(du -h server.jar | cut -f1)
        success "下载完成 (文件大小: $FILE_SIZE)"
    else
        error "下载失败"
        exit 1
    fi
}

# ==========================================
# 生成随机密码（用于 RCON）
# ==========================================
generate_password() {
    # 生成 12 位随机密码
    echo "$(date +%s | sha256sum | base64 | head -c 12)"
}

# ==========================================
# 生成 JVM 优化参数（v1.2 新增）
# ==========================================
generate_jvm_flags() {
    case "$JVM_OPTIMIZATION" in
        aikars)
            # Aikar's Flags - G1GC 优化（大多数服务器推荐）
            # 参考：https://docs.papermc.io/paper/aikars-flags
            echo "-XX:+UseG1GC \\"
            echo "     -XX:+ParallelRefProcEnabled \\"
            echo "     -XX:MaxGCPauseMillis=200 \\"
            echo "     -XX:+UnlockExperimentalVMOptions \\"
            echo "     -XX:+DisableExplicitGC \\"
            echo "     -XX:+AlwaysPreTouch \\"
            echo "     -XX:G1NewSizePercent=30 \\"
            echo "     -XX:G1MaxNewSizePercent=40 \\"
            echo "     -XX:G1HeapRegionSize=8M \\"
            echo "     -XX:G1ReservePercent=20 \\"
            echo "     -XX:G1HeapWastePercent=5 \\"
            echo "     -XX:G1MixedGCCountTarget=4 \\"
            echo "     -XX:InitiatingHeapOccupancyPercent=15 \\"
            echo "     -XX:G1MixedGCLiveThresholdPercent=90 \\"
            echo "     -XX:G1RSetUpdatingPauseTimePercent=5 \\"
            echo "     -XX:SurvivorRatio=32 \\"
            echo "     -XX:+PerfDisableSharedMem \\"
            echo "     -XX:MaxTenuringThreshold=1 \\"
            ;;
        zgc)
            # ZGC 分代回收（大内存、高性能服务器推荐，Java 21+）
            # 注意：需要 8GB 以上内存效果才明显
            echo "-XX:+UseZGC \\"
            echo "     -XX:+ZGenerational \\"
            echo "     -XX:MaxGCPauseMillis=5 \\"
            echo "     -XX:+UnlockDiagnosticVMOptions \\"
            echo "     -XX:+DoEscapeAnalysis \\"
            echo "     -XX:+UseStringDeduplication \\"
            echo "     -XX:+ParallelRefProcEnabled \\"
            echo "     -XX:CICompilerCount=4 \\"
            ;;
        *)
            # 不使用优化参数
            echo ""
            ;;
    esac
}

# ==========================================
# 创建启动脚本（增强版 v1.2）
# ==========================================
create_start_script() {
    info "创建启动脚本..."
    
    # 生成 RCON 密码（如果未设置）
    if [ "$ENABLE_RCON" = "true" ] && [ -z "$RCON_PASSWORD" ]; then
        RCON_PASSWORD=$(generate_password)
        info "自动生成 RCON 密码: $RCON_PASSWORD"
    fi
    
    # 生成 JVM 优化参数
    JVM_FLAGS=$(generate_jvm_flags)
    
    cat > start.sh << EOF
#!/bin/bash
# ==========================================
# Minecraft Server Startup Script
# Version: $MC_VERSION (deploy script v1.2)
# Server Type: $SERVER_TYPE
# JVM Optimization: $JVM_OPTIMIZATION
# ==========================================
cd "\$(dirname "\$0")"

# ---- 防重复启动 ----
if pgrep -f "server.jar nogui" > /dev/null 2>&1; then
    echo "[ERROR] Minecraft 服务器已经在运行中！"
    echo "  请先停止现有服务器再启动"
    echo "  查看进程: ps aux | grep server.jar"
    exit 1
fi

# ---- 代理绕过配置（关键！修复正版验证失败）----
# 系统默认 HTTP 代理会导致无法连接 Mojang 验证服务器
export no_proxy="localhost,127.0.0.1,::1,*.mojang.com,*.minecraft.net,*.minecraftservices.com,*.mojangstudio.com,sessionserver.mojang.com,authserver.mojang.com,api.mojang.com,api.minecraftservices.com,libraries.minecraft.net,resources.download.minecraft.net,piston-data.mojang.com"
export NO_PROXY="\$no_proxy"

# ---- 内存分配 ----
MEM_MIN="$MEM_MIN"
MEM_MAX="$MEM_MAX"

# ---- 启动服务器 ----
# -Djava.net.useSystemProxies=false  禁止 Java 使用系统代理（关键）
java -Xms\${MEM_MIN} -Xmx\${MEM_MAX} \\
     -Djava.net.useSystemProxies=false \\
     $JVM_FLAGS
     -jar server.jar nogui
EOF
    
    chmod +x start.sh
    success "启动脚本创建完成: start.sh"
    info "  JVM 优化: $JVM_OPTIMIZATION"
    
    # 保存 RCON 密码到单独的文件，方便查看
    if [ "$ENABLE_RCON" = "true" ]; then
        echo "$RCON_PASSWORD" > .rcon_password
        chmod 600 .rcon_password
        info "RCON 密码已保存到 .rcon_password 文件"
    fi
}

# ==========================================
# 首次运行生成配置
# ==========================================
generate_config() {
    info "首次运行生成配置文件..."
    
    # 临时运行服务端生成配置文件（会因为 EULA 未同意而退出）
    # 使用代理绕过配置，避免网络问题
    export no_proxy="localhost,127.0.0.1,::1,*.mojang.com,*.minecraft.net,*.minecraftservices.com"
    timeout 30 java -Xms1G -Xmx1G -Djava.net.useSystemProxies=false -jar server.jar nogui 2>/dev/null || true
    
    # 检查配置文件是否生成
    if [ -f "server.properties" ] && [ -f "eula.txt" ]; then
        success "配置文件生成完成"
    else
        warn "配置文件可能未完全生成，请检查"
    fi
}

# ==========================================
# 同意 EULA
# ==========================================
agree_eula() {
    info "同意 Minecraft EULA 协议..."
    
    if [ -f "eula.txt" ]; then
        sed -i 's/eula=false/eula=true/' eula.txt
        success "EULA 已同意"
    else
        error "未找到 eula.txt 文件"
        exit 1
    fi
}

# ==========================================
# 配置服务端（增强版 v1.2）
# ==========================================
configure_server() {
    info "配置服务端参数..."
    
    if [ ! -f "server.properties" ]; then
        error "未找到 server.properties 文件"
        return 1
    fi
    
    # ---- 基础配置 ----
    sed -i "s/^server-port=.*/server-port=$SERVER_PORT/" server.properties
    sed -i "s/^gamemode=.*/gamemode=$GAMEMODE/" server.properties
    sed -i "s/^difficulty=.*/difficulty=$DIFFICULTY/" server.properties
    sed -i "s/^max-players=.*/max-players=$MAX_PLAYERS/" server.properties
    sed -i "s/^online-mode=.*/online-mode=$ONLINE_MODE/" server.properties
    
    # ---- 性能配置（v1.2 新增）----
    # 视距 - 最大性能杠杆
    if grep -q "^view-distance=" server.properties; then
        sed -i "s/^view-distance=.*/view-distance=$VIEW_DISTANCE/" server.properties
    else
        echo "view-distance=$VIEW_DISTANCE" >> server.properties
    fi
    
    # 模拟距离 - 实体活动范围
    if grep -q "^simulation-distance=" server.properties; then
        sed -i "s/^simulation-distance=.*/simulation-distance=$SIMULATION_DISTANCE/" server.properties
    else
        echo "simulation-distance=$SIMULATION_DISTANCE" >> server.properties
    fi
    
    # 怪物生成上限
    if grep -q "^spawn-monsters=" server.properties; then
        sed -i "s/^spawn-monsters=.*/spawn-monsters=true/" server.properties
    fi
    
    # 空服务器自动暂停
    if grep -q "^pause-when-empty-seconds=" server.properties; then
        sed -i "s/^pause-when-empty-seconds=.*/pause-when-empty-seconds=$PAUSE_WHEN_EMPTY/" server.properties
    else
        echo "pause-when-empty-seconds=$PAUSE_WHEN_EMPTY" >> server.properties
    fi
    
    # ---- RCON 配置 ----
    if [ "$ENABLE_RCON" = "true" ]; then
        if grep -q "^enable-rcon=" server.properties; then
            sed -i "s/^enable-rcon=.*/enable-rcon=true/" server.properties
        else
            echo "enable-rcon=true" >> server.properties
        fi
        
        if grep -q "^rcon.port=" server.properties; then
            sed -i "s/^rcon.port=.*/rcon.port=$RCON_PORT/" server.properties
        else
            echo "rcon.port=$RCON_PORT" >> server.properties
        fi
        
        if grep -q "^rcon.password=" server.properties; then
            sed -i "s/^rcon.password=.*/rcon.password=$RCON_PASSWORD/" server.properties
        else
            echo "rcon.password=$RCON_PASSWORD" >> server.properties
        fi
        
        info "  RCON: 已启用 (端口: $RCON_PORT)"
    else
        if grep -q "^enable-rcon=" server.properties; then
            sed -i "s/^enable-rcon=.*/enable-rcon=false/" server.properties
        fi
        info "  RCON: 已禁用"
    fi
    
    success "服务端配置完成"
    info "  端口: $SERVER_PORT"
    info "  游戏模式: $GAMEMODE"
    info "  难度: $DIFFICULTY"
    info "  最大玩家: $MAX_PLAYERS"
    info "  正版验证: $ONLINE_MODE"
    info "  视距: $VIEW_DISTANCE"
    info "  模拟距离: $SIMULATION_DISTANCE"
}

# ==========================================
# 设置初始 OP 玩家
# ==========================================
setup_initial_op() {
    if [ -z "$INITIAL_OP" ]; then
        info "未设置初始 OP 玩家，跳过"
        return 0
    fi
    
    info "设置初始 OP 玩家: $INITIAL_OP"
    
    # 尝试通过 Mojang API 获取 UUID
    UUID=""
    if command -v curl &> /dev/null; then
        # 使用代理绕过
        UUID=$(curl -s --noproxy '*' "https://api.mojang.com/users/profiles/minecraft/$INITIAL_OP" 2>/dev/null | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
    fi
    
    if [ -n "$UUID" ]; then
        # 格式化 UUID（添加横线）
        FORMATTED_UUID="${UUID:0:8}-${UUID:8:4}-${UUID:12:4}-${UUID:16:4}-${UUID:20:12}"
        info "获取到 UUID: $FORMATTED_UUID"
        
        # 创建 ops.json
        cat > ops.json << EOF
[
  {
    "uuid": "$FORMATTED_UUID",
    "name": "$INITIAL_OP",
    "level": 4,
    "bypassesPlayerLimit": false
  }
]
EOF
        success "初始 OP 设置成功: $INITIAL_OP (权限等级 4)"
    else
        warn "无法从 Mojang API 获取 UUID，跳过初始 OP 设置"
        warn "你可以手动设置，方法："
        warn "  1. 启动服务器后，让玩家进入一次"
        warn "  2. 从 logs/latest.log 中找到玩家的 UUID"
        warn "  3. 修改 ops.json 文件添加玩家"
    fi
}

# ==========================================
# 启动服务端
# ==========================================
start_server() {
    if [ "$AUTO_START" != "true" ]; then
        return 0
    fi
    
    info "启动 Minecraft 服务端..."
    
    # 检查是否已在运行
    if pgrep -f "server.jar nogui" > /dev/null; then
        warn "服务端似乎已经在运行中"
        return 0
    fi
    
    # 后台启动服务端（使用 start.sh 确保代理配置和 JVM 优化生效）
    nohup bash start.sh > server.out 2>&1 &
    SERVER_PID=$!
    
    success "服务端已启动 (PID: $SERVER_PID)"
    info "日志目录: $INSTALL_DIR/logs/"
    info "查看日志: tail -f $INSTALL_DIR/logs/latest.log"
}

# ==========================================
# 显示摘要（增强版 v1.2）
# ==========================================
show_summary() {
    echo ""
    echo "=========================================="
    echo "  Minecraft Server Deployment Complete!"
    echo "=========================================="
    echo ""
    echo "  版本:        $MC_VERSION (Chaos Cubed)"
    echo "  类型:        $SERVER_TYPE (Vanilla 原版)"
    echo "  安装目录:    $INSTALL_DIR"
    echo "  端口:        $SERVER_PORT"
    echo "  内存分配:    $MEM_MIN ~ $MEM_MAX"
    echo "  游戏模式:    $GAMEMODE"
    echo "  难度:        $DIFFICULTY"
    echo "  最大玩家:    $MAX_PLAYERS"
    
    echo ""
    highlight "  性能配置:"
    echo "    视距:      $VIEW_DISTANCE"
    echo "    模拟距离:  $SIMULATION_DISTANCE"
    echo "    JVM 优化:  $JVM_OPTIMIZATION"
    
    if [ "$ENABLE_RCON" = "true" ]; then
        echo ""
        highlight "  RCON 远程管理:"
        echo "    状态:      ✅ 已启用"
        echo "    端口:      $RCON_PORT"
        echo "    密码:      $RCON_PASSWORD"
        echo "    密码文件:  $INSTALL_DIR/.rcon_password"
    fi
    
    if [ -n "$INITIAL_OP" ]; then
        echo ""
        highlight "  初始 OP 玩家:"
        echo "    玩家:      $INITIAL_OP"
        echo "    权限:      等级 4（最高）"
    fi
    
    echo ""
    highlight "  常用命令:"
    echo "    启动:      cd $INSTALL_DIR && bash start.sh"
    echo "    查看日志:  tail -f $INSTALL_DIR/logs/latest.log"
    echo ""
    highlight "  安全关闭服务器（推荐）:"
    echo "    方法 1: 游戏内 OP 玩家输入 /stop"
    echo "    方法 2: 使用 RCON 发送 stop 命令"
    echo "    方法 3: kill -15 \$(pgrep -f 'server.jar nogui')"
    echo "    ❌ 不要使用 kill -9，会导致世界损坏！"
    
    echo ""
    highlight "  注意事项:"
    echo "    • 启动脚本已自动绕过系统代理，确保正版验证正常"
    echo "    • 空服务器 ${PAUSE_WHEN_EMPTY} 秒后会自动暂停（节省资源）"
    echo "    • 有玩家进入时会自动恢复"
    echo "    • Java 25+ 是 Minecraft 26.1+ 的最低要求"
    echo ""
    highlight "  性能优化建议:"
    echo "    • 如需更好性能，可考虑 Paper 或 Purpur 服务端"
    echo "    • 大内存服务器（8GB+）可尝试 ZGC 垃圾回收器"
    echo "    • 玩家多的时候可适当降低 view-distance"
    
    echo ""
    echo "=========================================="
}

# ==========================================
# 主函数
# ==========================================
main() {
    echo "=========================================="
    echo "  Minecraft Server Deployer"
    echo "  Version: $MC_VERSION (Chaos Cubed)"
    echo "  Deploy Script: v1.2"
    echo "=========================================="
    echo ""
    
    check_root
    check_java
    create_directories
    download_server
    create_start_script
    generate_config
    agree_eula
    configure_server
    setup_initial_op
    start_server
    show_summary
}

# 运行主函数
main "$@"
