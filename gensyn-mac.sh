#!/bin/bash
set -euo pipefail

log_file="$HOME/deploy_rl_swarm_0.5.log"

info() {
    echo -e "[INFO] $*" | tee -a "$log_file"
}

error() {
    echo -e "[ERROR] $*" >&2 | tee -a "$log_file"
    exit 1
}

echo "🧹 检查 Homebrew..." | tee -a "$log_file"

if ! command -v brew &> /dev/null; then
    info "Homebrew 未安装，正在安装..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || error "Homebrew 安装失败"

    if [[ $(uname -m) == "arm64" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/usr/local/bin/brew shellenv)"
    fi
else
    info "Homebrew 已安装，版本：$(brew --version | head -n 1)"
fi

echo "安装python3.11" | tee -a "$log_file"
if ! command -v python3.11 &> /dev/null; then
    brew install python@3.11 || error "Python 3.11 安装失败"
else
    info "Python 3.11 已安装，版本：$(python3.11 --version 2>&1)"
fi

if [ ! -d ~/rl-swarm ]; then
    echo "Cloning repository..." | tee -a "$log_file"
    git clone https://github.com/gensyn-ai/rl-swarm.git ~/rl-swarm || error "仓库克隆失败"
else
    info "仓库已存在，跳过克隆步骤"
fi

cd ~/rl-swarm || error "无法进入仓库目录"

if [ ! -d .venv ]; then
    echo "Setting up Python virtual environment..." | tee -a "$log_file"
    python3.11 -m venv .venv || error "虚拟环境创建失败"
else
    info "虚拟环境已存在，跳过创建步骤"
fi

info "创建自动监控脚本: auto.sh"
cat << 'EOF' > "auto.sh"
#!/bin/bash

# Mac 自动监控重启脚本
# 适配 ~/rl-swarm 目录结构

set -euo pipefail

ROOT_DIR="$HOME/rl-swarm"
RESTART_DELAY=30
CHECK_INTERVAL=10
LOG_FILE="$ROOT_DIR/auto_monitor.log"
PID_FILE="$ROOT_DIR/training.pid"

DEFAULT_HF_PUSH="N"
DEFAULT_MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"

GREEN="\033[32m"
BLUE="\033[34m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

log_important() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

echo_green() {
    echo -e "${GREEN}$1${RESET}"
}

echo_blue() {
    echo -e "${BLUE}$1${RESET}"
}

echo_red() {
    echo -e "${RED}$1${RESET}"
    log_important "$1"
}

echo_yellow() {
    echo -e "${YELLOW}$1${RESET}"
    log_important "$1"
}

cleanup() {
    echo_yellow "🛑 正在停止监控..."
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo_yellow "终止训练进程 PID: $pid"
            kill -TERM "$pid" 2>/dev/null || true
            sleep 5
            if ps -p "$pid" > /dev/null 2>&1; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    fi
    
    pkill -f "swarm_launcher.py" 2>/dev/null || true
    pkill -f "run_rl_swarm.sh" 2>/dev/null || true
    pkill -f "yarn start" 2>/dev/null || true
    
    echo_green "✅ 监控已停止"
    exit 0
}

is_process_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        fi
    fi
    
    if pgrep -f "swarm_launcher.py" > /dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

start_training() {
    echo_blue "🚀 启动 Mac 优化版 RL Swarm 训练..."
    
    export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0
    export OMP_NUM_THREADS=8
    export MKL_NUM_THREADS=8
    export PYTORCH_ENABLE_MPS_FALLBACK=1
    export CPU_ONLY=1
    export HF_HUB_DOWNLOAD_TIMEOUT=300
    export HF_DATASETS_CACHE="$HOME/.cache/huggingface/datasets"
    export HF_MODELS_CACHE="$HOME/.cache/huggingface/transformers"
    
    export CONNECT_TO_TESTNET=true
    export HUGGINGFACE_ACCESS_TOKEN="None"
    export HF_TOKEN=""
    
    mkdir -p "$HF_DATASETS_CACHE"
    mkdir -p "$HF_MODELS_CACHE"
    
    if [ -f "$ROOT_DIR/.venv/bin/activate" ]; then
        source "$ROOT_DIR/.venv/bin/activate"
    else
        echo_red "❌ 虚拟环境不存在，请先运行部署脚本"
        return 1
    fi
    
    {
        echo "$DEFAULT_HF_PUSH"
        echo "$DEFAULT_MODEL_NAME"
    } | ./run_rl_swarm.sh > "$LOG_FILE" 2>&1 &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo_green "✅ 训练进程已启动，PID: $pid"
    
    sleep 15
    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo_red "❌ 训练进程启动失败"
        rm -f "$PID_FILE"
        return 1
    fi
    
    return 0
}

trap cleanup SIGINT SIGTERM

main() {
    local restart_count=0
    
    echo_green "🎯 RL Swarm 自动监控启动"
    echo_blue "📊 配置: Mac mini"
    echo_blue "📝 日志文件: $LOG_FILE"
    echo_blue "🔄 无限重启模式: 7*24小时持续运行"
    echo_blue "⏱️  检查间隔: ${CHECK_INTERVAL}秒"
    echo_blue "⏰ 重启延迟: ${RESTART_DELAY}秒"
    echo ""
    
    if ! start_training; then
        echo_red "❌ 初始启动失败"
        exit 1
    fi
    
    while true; do
        sleep "$CHECK_INTERVAL"
        
        if ! is_process_running; then
            echo_yellow "⚠️  检测到训练进程已结束"
            
            restart_count=$((restart_count + 1))
            echo_yellow "🔄 准备第 $restart_count 次重启 (无限重启模式)"
            echo_yellow "⏰ 等待 $RESTART_DELAY 秒后重启..."
            
            sleep "$RESTART_DELAY"
            
            if start_training; then
                echo_green "✅ 第 $restart_count 次重启成功"
            else
                echo_red "❌ 第 $restart_count 次重启失败，将继续尝试"
            fi
        fi
    done
    
    cleanup
}

if [ ! -f "run_rl_swarm.sh" ]; then
    echo_red "❌ 错误: 请在 rl-swarm 项目根目录下运行此脚本"
    exit 1
fi

if [ ! -d ".venv" ]; then
    echo_red "❌ 错误: 虚拟环境不存在，请先运行部署脚本创建环境"
    exit 1
fi

echo_blue "🎮 使用方法:"
echo_blue "   启动监控: ./auto.sh"
echo_blue "   停止监控: Ctrl+C"
echo_blue "   查看日志: tail -f $LOG_FILE"
echo ""

main
EOF

chmod +x auto.sh
info "auto.sh 脚本已创建并添加执行权限"

if pgrep -f "swarm_launcher.py" > /dev/null; then
    info "训练进程已在运行，跳过启动步骤"
elif pgrep -f "auto.sh" > /dev/null; then
    info "监控进程已在运行，跳过启动步骤"
else
    info "启动自动监控脚本..."
    cd ~/rl-swarm || error "无法进入工作目录"
    nohup ./auto.sh > auto_monitor.log 2>&1 &
    info "监控进程已启动 (PID: $!)"
fi

info "✅ 部署完成！"
echo "=============================================="
echo "监控日志: ~/rl-swarm/auto_monitor.log"
echo "训练日志: ~/rl-swarm/training.log"
echo "停止训练: kill $(pgrep -f "auto.sh")"
echo "=============================================="
