#!/bin/bash
# ==========================================
# Fastfetch 自动安装脚本
# ==========================================
# 功能：自动下载并安装最新版本的 fastfetch
# 用法：bash install_fastfetch.sh
# 降级策略：apt默认仓库 → PPA → GitHub二进制
# ==========================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

echo "=========================================="
echo "  Fastfetch 自动安装脚本"
echo "=========================================="
echo ""

# 检查是否已安装
if command -v fastfetch &> /dev/null; then
    log_info "fastfetch 已安装: $(fastfetch --version)"
    read -p "是否重新安装? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "已取消安装"
        exit 0
    fi
fi

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "此脚本需要 root 权限运行"
    log_info "请使用 sudo 或以 root 用户运行"
    exit 1
fi

# 检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_SUFFIX="amd64"
        ;;
    aarch64|arm64)
        ARCH_SUFFIX="aarch64"
        ;;
    armv7l|armv6l)
        ARCH_SUFFIX="armv7l"
        ;;
    *)
        log_error "不支持的架构: $ARCH"
        exit 1
        ;;
esac
log_info "系统架构: $ARCH ($ARCH_SUFFIX)"

# 创建临时目录
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT
log_info "临时目录: $TMP_DIR"

# 验证安装结果
verify_install() {
    if command -v fastfetch &> /dev/null; then
        echo ""
        log_ok "安装成功!"
        fastfetch --version
        echo ""
        log_info "运行 'fastfetch' 查看系统信息"
        echo ""
        echo "=========================================="
        echo "  安装完成!"
        echo "=========================================="
        exit 0
    fi
    return 1
}

# ==========================================
# 方法1: 直接通过 apt 默认仓库安装
# ==========================================
log_step "方法1: apt 默认仓库"
log_info "尝试通过默认仓库安装..."

if apt update -y 2>/dev/null && apt install -y fastfetch 2>/dev/null; then
    if command -v fastfetch &> /dev/null; then
        log_ok "通过默认仓库安装成功"
        verify_install
    fi
fi
log_info "默认仓库无 fastfetch，尝试下一种方法..."

# ==========================================
# 方法2: 添加 PPA 后 apt 安装
# ==========================================
log_step "方法2: PPA 仓库"
log_info "尝试添加 fastfetch 官方 PPA..."

# 检查是否已添加 PPA
if ! grep -r "zhangsongcui3371.*fastfetch" /etc/apt/sources.list.d/ 2>/dev/null; then
    # 安装 software-properties-common（如果没有）
    if ! command -v add-apt-repository &> /dev/null; then
        log_info "安装 software-properties-common..."
        if ! apt install -y software-properties-common 2>/dev/null; then
            log_info "无法安装 software-properties-common，跳过 PPA 方法"
        fi
    fi
    
    # 添加 PPA
    if command -v add-apt-repository &> /dev/null; then
        log_info "添加 PPA: ppa:zhangsongcui3371/fastfetch"
        if add-apt-repository -y ppa:zhangsongcui3371/fastfetch 2>/dev/null; then
            log_ok "PPA 添加成功"
            apt update -y 2>/dev/null || true
        else
            log_info "PPA 添加失败，跳过"
        fi
    fi
else
    log_info "PPA 已存在"
fi

# 尝试通过 PPA 安装
if apt install -y fastfetch 2>/dev/null; then
    if command -v fastfetch &> /dev/null; then
        log_ok "通过 PPA 安装成功"
        verify_install
    fi
fi
log_info "PPA 安装失败，尝试下一种方法..."

# ==========================================
# 方法3: 从 GitHub 下载二进制（最终降级方案）
# ==========================================
log_step "方法3: GitHub 二进制下载"
log_info "从 GitHub 下载最新版本..."

# 获取最新版本号
log_info "获取最新版本号..."
LATEST_VERSION=$(curl -sL "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" 2>/dev/null | grep -o '"tag_name": "[^"]*"' | head -1 | sed 's/"tag_name": "//;s/"//')

if [ -z "$LATEST_VERSION" ]; then
    log_error "无法获取最新版本号"
    log_info "请检查网络连接"
    exit 1
fi
log_info "最新版本: $LATEST_VERSION"

# 构建下载链接
DOWNLOAD_URL="https://github.com/fastfetch-cli/fastfetch/releases/download/${LATEST_VERSION}/fastfetch-linux-${ARCH_SUFFIX}.tar.gz"
log_info "下载链接: $DOWNLOAD_URL"

# 下载
log_info "正在下载 (这可能需要几分钟)..."
cd "$TMP_DIR"
if ! curl -L -o fastfetch.tar.gz "$DOWNLOAD_URL" 2>&1 | tail -3; then
    log_error "下载失败"
    exit 1
fi

# 验证文件
FILE_SIZE=$(stat -c%s fastfetch.tar.gz 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 1000000 ]; then
    log_error "下载文件过小 ($FILE_SIZE bytes)，可能下载失败"
    exit 1
fi
log_ok "下载完成 ($((FILE_SIZE / 1024)) KB)"

# 解压
log_info "正在解压..."
if ! tar -xzf fastfetch.tar.gz; then
    log_error "解压失败"
    exit 1
fi

# 查找二进制文件
FASTFETCH_BIN=$(find "$TMP_DIR" -name "fastfetch" -type f -path "*/bin/*" | head -1)
if [ -z "$FASTFETCH_BIN" ]; then
    FASTFETCH_BIN=$(find "$TMP_DIR" -name "fastfetch" -type f | head -1)
fi

if [ -z "$FASTFETCH_BIN" ] || [ ! -f "$FASTFETCH_BIN" ]; then
    log_error "未找到 fastfetch 二进制文件"
    log_info "解压后的目录结构:"
    find "$TMP_DIR" -type f | head -20
    exit 1
fi
log_info "找到二进制文件: $FASTFETCH_BIN"

# 安装到 /usr/local/bin
INSTALL_DIR="/usr/local/bin"
log_info "安装到 $INSTALL_DIR..."
cp "$FASTFETCH_BIN" "$INSTALL_DIR/fastfetch"
chmod +x "$INSTALL_DIR/fastfetch"

# 验证安装
verify_install

# 如果到这里还没退出，说明所有方法都失败了
log_error "所有安装方法都失败了"
exit 1
