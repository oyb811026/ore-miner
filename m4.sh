#!/bin/bash

# RL Swarm M4 终极兼容版
# 版本: 4.3
# 特点: 
# - 100% 兼容 macOS 原生 Bash 3.2
# - 完美支持 M4 芯片 Metal 加速
# - 智能资源管理
# - 自动错误恢复

set -eo pipefail

# ================= 基础配置 =================
# 颜色代码 (兼容旧版Bash)
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_MAGENTA="\033[35m"
COLOR_CYAN="\033[36m"
COLOR_RESET="\033[0m"
COLOR_BOLD="\033[1m"

# 日志函数
log() {
    local color="$1"
    local prefix="$2"
    shift 2
    echo -e "${color}${prefix}${COLOR_RESET} $*"
}

log_header() { log "$COLOR_MAGENTA" "==>" "$@"; }
log_success() { log "$COLOR_GREEN" "✓" "$@"; }
log_warning() { log "$COLOR_YELLOW" "⚠" "$@"; }
log_error() { log "$COLOR_RED" "✗" "$@"; }
log_info() { log "$COLOR_BLUE" "ℹ" "$@"; }

# ================= M4 专属配置 =================
# 硬件配置 (使用普通变量替代关联数组)
M4_TOTAL_MEM="16"        # 单位GB
M4_ALLOC_MEM="12"        # 单位GB
M4_CPU_CORES="6"         # 使用核心数
M4_MODEL="Qwen2.5-0.5B"  # 默认模型
M4_CACHE_DIR="/tmp/m4_swarm_cache"

# ================= 环境初始化 =================
init_m4_environment() {
    log_header "正在初始化 M4 环境"
    
    # 验证Apple Silicon
    local cpu_brand=$(sysctl -n machdep.cpu.brand_string)
    if [[ "$cpu_brand" != *"Apple M4"* ]]; then
        log_warning "非M4芯片检测到: $cpu_brand"
    fi

    # Metal加速检测
    if ! system_profiler SPDisplaysDataType | grep -q "Metal Support"; then
        log_warning "Metal加速不可用，将使用CPU模式"
        export PYTORCH_ENABLE_MPS_FALLBACK=0
    else
        log_success "检测到Metal GPU加速支持"
        export PYTORCH_ENABLE_MPS_FALLBACK=1
    fi

    # 内存配置
    local system_mem=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))
    if (( system_mem < M4_TOTAL_MEM )); then
        log_warning "检测到${system_mem}GB内存，低于配置值${M4_TOTAL_MEM}GB"
        M4_ALLOC_MEM=$((system_mem - 4))
    fi
    
    export MPS_GRAPH_CACHE_MEMORY_LIMIT="${M4_ALLOC_MEM}G"
    export OMP_NUM_THREADS="$M4_CPU_CORES"
    
    # 创建缓存目录
    mkdir -p "$M4_CACHE_DIR"
    export HF_HOME="$M4_CACHE_DIR"
    
    log_info "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    log_info "  分配内存: ${M4_ALLOC_MEM}GB"
    log_info "  CPU线程: $M4_CPU_CORES"
    log_info "  使用模型: $M4_MODEL"
    log_info "  缓存目录: $M4_CACHE_DIR"
    log_info "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
}

# ================= 训练管理 =================
start_training() {
    log_header "正在启动训练任务"
    
    # 内存检查
    local free_mem=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
    free_mem=$((free_mem * 4096 / 1024 / 1024))  # 转换为MB
    
    if (( free_mem < 2000 )); then
        log_warning "可用内存不足 (${free_mem}MB)，正在清理..."
        purge
    fi

    # 启动命令序列
    local commands=(
        "source .venv/bin/activate"
        "export PYTHONUNBUFFERED=1"
        "python -c \"import torch; print(f'\\n${COLOR_MAGENTA}PyTorch 后端: {torch.backends.mps.is_available() and 'Metal' or 'CPU'}${COLOR_RESET}\\n')\""
        "./run_rl_swarm.sh"
    )

    # 创建screen会话
    if ! screen -list | grep -q "rl_swarm"; then
        screen -dmS rl_swarm
        sleep 1
    fi

    # 发送命令
    for cmd in "${commands[@]}"; do
        screen -S rl_swarm -X stuff "$cmd$(printf '\r')"
        sleep 1
    done

    log_success "训练任务已成功启动"
}

monitor_training() {
    log_header "正在启动监控系统"
    local log_file="/tmp/rl_swarm_$(date +%Y%m%d).log"
    local last_round=0
    local error_count=0
    
    # 设置日志记录
    screen -S rl_swarm -X logfile "$log_file"
    screen -S rl_swarm -X log on

    # 日志跟踪 (兼容旧版tail)
    tail -F "$log_file" | while read -r line; do
        # Round进度检测
        if [[ "$line" =~ "Starting round: "([0-9]+) ]]; then
            local current_round="${BASH_REMATCH[1]}"
            if (( current_round > last_round + 1 )); then
                log_warning "检测到Round跳跃: $last_round → $current_round"
            fi
            last_round="$current_round"
            error_count=0
        
        # GPU内存处理
        elif [[ "$line" == *"MPS backend out of memory"* ]]; then
            log_warning "GPU内存不足，正在清理缓存..."
            python -c "import torch; torch.mps.empty_cache()"
        
        # 错误处理
        elif [[ "$line" == *"ERROR"* || "$line" == *"Exception"* ]]; then
            ((error_count++))
            if (( error_count > 3 )); then
                log_error "检测到连续错误，需要重启"
                return 1
            fi
        
        # 启动成功检测
        elif [[ "$line" == *"Good luck in the swarm!"* ]]; then
            log_success "训练正常初始化完成"
        fi
    done
}

restart_training() {
    log_header "正在重启训练服务"
    
    # 清理现有进程
    pkill -f "run_rl_swarm.sh" || true
    screen -S rl_swarm -X quit || true
    python -c "import torch; torch.mps.empty_cache()" 2>/dev/null || true
    
    # 等待资源释放
    sleep 5
    
    # 重新启动
    init_m4_environment
    start_training
}

# ================= 主控制流 =================
main_loop() {
    while true; do
        start_training
        
        if ! monitor_training; then
            log_warning "训练异常，将在10秒后重启..."
            sleep 10
            restart_training
        fi
        
        sleep 5
    done
}

# ================= 命令行接口 =================
case "$1" in
    start|--start)
        init_m4_environment
        main_loop
        ;;
    stop|--stop)
        pkill -f "run_rl_swarm.sh"
        screen -S rl_swarm -X quit
        log_success "已停止所有训练服务"
        ;;
    status|--status)
        echo -e "${COLOR_CYAN}=== 训练服务状态 ===${COLOR_RESET}"
        echo -e "${COLOR_BOLD}Screen会话:${COLOR_RESET}"
        screen -list | grep "rl_swarm" || echo "未运行"
        echo -e "\n${COLOR_BOLD}训练进程:${COLOR_RESET}"
        pgrep -fl "run_rl_swarm.sh" || echo "未运行"
        echo -e "\n${COLOR_BOLD}PyTorch后端:${COLOR_RESET}"
        python -c "import torch; print('Metal' if torch.backends.mps.is_available() else 'CPU')"
        ;;
    clean|--clean)
        rm -rf "$M4_CACHE_DIR"
        python -c "import torch; torch.mps.empty_cache()"
        log_success "已清理所有缓存"
        ;;
    *)
        echo -e "${COLOR_BOLD}使用方法:${COLOR_RESET}"
        echo "  $0 start    启动训练服务"
        echo "  $0 stop     停止服务"
        echo "  $0 status   查看状态"
        echo "  $0 clean    清理缓存"
        exit 1
        ;;
esac
