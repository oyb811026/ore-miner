#!/bin/bash

# M4芯片专用监控脚本（Apple Silicon优化版）
# 动态资源分配｜自动模型选择｜智能重启监控
# 最后更新: 2025年7月

set -euo pipefail

# 配置参数
RESTART_DELAY=30
CHECK_INTERVAL=10
LOG_FILE="$PWD/m4_monitor.log"
PID_FILE="$PWD/training.pid"

# 默认参数
DEFAULT_HF_PUSH="N"
DEFAULT_MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"

# 颜色输出
GREEN="\033[32m"
BLUE="\033[34m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 日志系统
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

echo_green() {
    echo -e "${GREEN}$1${RESET}" | tee -a "$LOG_FILE"
}

echo_blue() {
    echo -e "${BLUE}$1${RESET}" | tee -a "$LOG_FILE"
}

echo_red() {
    echo -e "${RED}$1${RESET}" | tee -a "$LOG_FILE"
}

echo_yellow() {
    echo -e "${YELLOW}$1${RESET}" | tee -a "$LOG_FILE"
}

# 清理函数
cleanup() {
    echo_yellow "🛑 停止监控中..."
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo_yellow "终止训练进程 PID: $pid"
            kill -TERM "$pid" 2>/dev/null || true
            sleep 3
            if ps -p "$pid" > /dev/null 2>&1; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    fi
    
    pkill -f "swarm_launcher.py" 2>/dev/null || true
    pkill -f "run_rl_swarm.sh" 2>/dev/null || true
    
    echo_green "✅ 监控已停止"
    exit 0
}

# 进程检查
is_process_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        ps -p "$pid" > /dev/null 2>&1 && return 0
    fi
    
    pgrep -f "swarm_launcher.py" > /dev/null 2>&1 && return 0
    return 1
}

# 启动训练
start_training() {
    # ================= 动态资源优化 =================
    # 内存配置
    TOTAL_MEM=$(($(sysctl -n hw.memsize) / 1024 / 1024))  # MB
    USABLE_MEM=$((TOTAL_MEM * 75 / 100))
    export MPS_GRAPH_CACHE_MEMORY_LIMIT="${USABLE_MEM}M"
    
    # CPU线程优化
    CPU_CORES=$(sysctl -n hw.ncpu)
    OPTIMAL_THREADS=$((CPU_CORES > 8 ? 8 : CPU_CORES - 1))
    [ $OPTIMAL_THREADS -lt 1 ] && OPTIMAL_THREADS=1
    export OMP_NUM_THREADS=$OPTIMAL_THREADS
    export MKL_NUM_THREADS=$OPTIMAL_THREADS
    
    # GPU加速配置
    if [ "$(uname -m)" = "arm64" ]; then
        echo_blue "✅ Apple Silicon芯片：启用GPU加速"
        unset CPU_ONLY
        export PYTORCH_ENABLE_MPS_FALLBACK=0
        
        # 智能模型选择
        if [ $TOTAL_MEM -ge 32000 ]; then  # 32GB+
            DEFAULT_MODEL_NAME="Gensyn/Qwen2.5-1.5B-Instruct"
            echo_blue "💾 检测到大内存(>32GB)，自动升级到1.5B模型"
        elif [ $TOTAL_MEM -ge 16000 ]; then  # 16GB
            DEFAULT_MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"
        else
            echo_yellow "⚠️  内存不足16GB，建议升级硬件"
        fi
    else
        echo_yellow "⚠️  非Apple Silicon芯片，使用CPU模式"
        export CPU_ONLY=1
    fi
    # ================= 优化结束 =================
    
    echo_blue "🚀 启动RL Swarm训练..."
    echo_blue "🧠 内存: ${TOTAL_MEM}MB (分配${USABLE_MEM}MB)"
    echo_blue "⚙️  线程: ${OPTIMAL_THREADS}核"
    echo_blue "🤖 模型: ${DEFAULT_MODEL_NAME}"
    
    # 环境变量
    export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0
    export HF_HUB_DOWNLOAD_TIMEOUT=300
    export CONNECT_TO_TESTNET=true
    export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
    export HUGGINGFACE_ACCESS_TOKEN="None"
    export HF_TOKEN=""
    
    # 缓存目录
    export HF_DATASETS_CACHE="$HOME/.cache/huggingface/datasets"
    export HF_MODELS_CACHE="$HOME/.cache/huggingface/transformers"
    mkdir -p "$HF_DATASETS_CACHE"
    mkdir -p "$HF_MODELS_CACHE"
    
    # 激活虚拟环境
    if [ -f ".venv/bin/activate" ]; then
        source .venv/bin/activate
    else
        echo_red "❌ 虚拟环境不存在"
        return 1
    fi
    
    # 自动启动训练
    {
        echo "$DEFAULT_HF_PUSH"
        echo "$DEFAULT_MODEL_NAME"
    } | ./run_rl_swarm.sh >> "$LOG_FILE" 2>&1 &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo_green "✅ 训练已启动 PID: $pid"
    
    # 启动健康检查
    sleep 25
    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo_red "❌ 进程启动失败"
        rm -f "$PID_FILE"
        return 1
    fi
    
    if ! grep -q "Training started" "$LOG_FILE"; then
        echo_red "❌ 训练初始化失败，请检查日志"
        return 1
    fi
    
    return 0
}

# 信号处理
trap cleanup SIGINT SIGTERM

# 主循环
main() {
    local restart_count=0
    
    echo_green "🎯 M4监控脚本启动"
    echo_blue "🖥️  设备: $(sysctl -n hw.model)"
    echo_blue "💾 内存: $(sysctl -n hw.memsize | awk '{printf "%dGB", $0/1024/1024/1024}')"
    echo_blue "🧠 CPU: $(sysctl -n hw.ncpu)核"
    echo_blue "📝 日志: $LOG_FILE"
    echo_blue "🔄 重启延迟: ${RESTART_DELAY}秒"
    echo ""
    
    if ! start_training; then
        echo_red "❌ 启动失败"
        exit 1
    fi
    
    while true; do
        sleep "$CHECK_INTERVAL"
        
        if ! is_process_running; then
            echo_yellow "⚠️  进程已停止"
            
            restart_count=$((restart_count + 1))
            echo_yellow "🔄 重启 #${restart_count}"
            echo_yellow "⏳ ${RESTART_DELAY}秒后重启..."
            
            sleep "$RESTART_DELAY"
            
            if start_training; then
                echo_green "✅ 重启成功"
            else
                echo_red "❌ 重启失败"
            fi
        fi
    done
}

# 环境检查
if [ ! -f "run_rl_swarm.sh" ]; then
    echo_red "❌ 错误: 请在项目目录运行"
    exit 1
fi

if [ ! -d ".venv" ]; then
    echo_red "❌ 错误: 虚拟环境不存在"
    exit 1
fi

echo_blue "🎮 使用命令:"
echo_blue "   启动: ./m4.sh"
echo_blue "   停止: Ctrl+C"
echo_blue "   日志: tail -f m4_monitor.log"
echo ""
echo_blue "💡 优化特性:"
echo_blue "   • 自动硬件检测"
echo_blue "   • 动态模型选择"
echo_blue "   • GPU加速支持"

# 启动主程序
main
