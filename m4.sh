#!/bin/bash

# RL Swarm M4 专属管理脚本
# 版本: 4.1
# 适配硬件: Apple M4芯片 + 16GB内存
# 功能: 自动重启 | Metal加速 | 智能资源管理

set -eo pipefail

# ██████╗ ██████╗  █████╗ ███████╗
# ██╔══██╗██╔══██╗██╔══██╗██╔════╝
# ██████╔╝██████╔╝███████║███████╗
# ██╔═══╝ ██╔══██╗██╔══██║╚════██║
# ██║     ██║  ██║██║  ██║███████║
# ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝

# 颜色定义
BOLD="\033[1m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
RESET="\033[0m"

# 日志函数
log_header() { echo -e "${BOLD}${MAGENTA}==>${RESET} ${BOLD}$1${RESET}"; }
log_success() { echo -e "${GREEN}✓${RESET} $1"; }
log_warning() { echo -e "${YELLOW}⚠${RESET} $1"; }
log_error() { echo -e "${RED}✗${RESET} $1"; }
log_info() { echo -e "${BLUE}ℹ${RESET} $1"; }
log_debug() { echo -e "${CYAN}⚙${RESET} $1"; }

# ███╗   ███╗ █████╗  ██████╗██████╗  ██████╗
# ████╗ ████║██╔══██╗██╔════╝██╔══██╗██╔═══██╗
# ██╔████╔██║███████║██║     ██████╔╝██║   ██║
# ██║╚██╔╝██║██╔══██║██║     ██╔══██╗██║   ██║
# ██║ ╚═╝ ██║██║  ██║╚██████╗██║  ██║╚██████╔╝
# ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝

# M4 硬件配置
declare -A M4_CONFIG=(
    [TOTAL_MEM]="16G"            # 物理内存
    [ALLOC_MEM]="12G"            # 分配给训练任务
    [CPU_CORES]="6"              # 使用核心数 (4性能+2能效)
    [GPU_BACKEND]="metal"        # 加速后端
    [MODEL]="Qwen2.5-0.5B"       # 默认模型
    [CACHE_DIR]="/tmp/m4_cache"  # 缓存位置
)

# ███████╗██╗   ██╗███╗   ██╗ ██████╗████████╗██╗ ██████╗ ███╗   ██╗
# ██╔════╝██║   ██║████╗  ██║██╔════╝╚══██╔══╝██║██╔═══██╗████╗  ██║
# █████╗  ██║   ██║██╔██╗ ██║██║        ██║   ██║██║   ██║██╔██╗ ██║
# ██╔══╝  ██║   ██║██║╚██╗██║██║        ██║   ██║██║   ██║██║╚██╗██║
# ██║     ╚██████╔╝██║ ╚████║╚██████╗   ██║   ██║╚██████╔╝██║ ╚████║
# ╚═╝      ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

init_m4_environment() {
    log_header "初始化 M4 环境"
    
    # 验证硬件
    local cpu_family=$(sysctl -n machdep.cpu.family)
    if [[ "$cpu_family" != "ARM64" ]]; then
        log_error "非Apple Silicon架构"
        exit 1
    fi

    # 检测Metal支持
    if ! system_profiler SPDisplaysDataType | grep -q "Metal Support"; then
        log_warning "Metal加速不可用，性能将受限"
        M4_CONFIG[GPU_BACKEND]="cpu"
    fi

    # 创建缓存目录
    mkdir -p "${M4_CONFIG[CACHE_DIR]}"
    chmod 777 "${M4_CONFIG[CACHE_DIR]}"

    # 设置环境变量
    export PYTORCH_ENABLE_MPS_FALLBACK=1
    export MPS_GRAPH_CACHE_MEMORY_LIMIT="${M4_CONFIG[ALLOC_MEM]}"
    export OMP_NUM_THREADS="${M4_CONFIG[CPU_CORES]}"
    export HF_HOME="${M4_CONFIG[CACHE_DIR]}"
    export TORCH_USE_METAL=1
    
    log_debug "内存分配: ${M4_CONFIG[ALLOC_MEM]}"
    log_debug "CPU核心: ${M4_CONFIG[CPU_CORES]}"
    log_debug "加速后端: ${M4_CONFIG[GPU_BACKEND]}"
    log_debug "缓存目录: ${M4_CONFIG[CACHE_DIR]}"
}

# ████████╗██████╗  █████╗ ██╗███╗   ██╗██╗███╗   ██╗ ██████╗ 
# ╚══██╔══╝██╔══██╗██╔══██╗██║████╗  ██║██║████╗  ██║██╔════╝ 
#    ██║   ██████╔╝███████║██║██╔██╗ ██║██║██╔██╗ ██║██║  ███╗
#    ██║   ██╔══██╗██╔══██║██║██║╚██╗██║██║██║╚██╗██║██║   ██║
#    ██║   ██║  ██║██║  ██║██║██║ ╚████║██║██║ ╚████║╚██████╔╝
#    ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝ 

start_training() {
    log_header "启动训练任务"
    
    # 资源预检查
    local free_mem=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.' | awk '{print $1*4096/1024/1024}')
    if (( $(echo "$free_mem < 2000" | bc -l) )); then
        log_warning "可用内存不足 (${free_mem}MB)，正在清理..."
        purge
    fi

    # 启动命令
    local cmd=(
        "source .venv/bin/activate"
        "export PYTHONUNBUFFERED=1"
        "python -c 'import torch; print(f\"\n{MAGENTA}PyTorch 使用 {torch.backends.mps.is_available() and \"Metal\" or \"CPU\"} 加速{RESET}\n\")'"
        "./run_rl_swarm.sh"
    )

    # 创建screen会话
    if ! screen -list | grep -q "rl_train"; then
        screen -dmS rl_train -t "RL Swarm"
        sleep 1
    fi

    # 发送命令
    for instruction in "${cmd[@]}"; do
        screen -S rl_train -X stuff "${instruction}$(printf '\r')"
        sleep 1
    done

    log_success "训练任务已启动"
}

# ███╗   ███╗ ██████╗ ███╗   ██╗██╗████████╗ ██████╗ ██████╗ 
# ████╗ ████║██╔═══██╗████╗  ██║██║╚══██╔══╝██╔═══██╗██╔══██╗
# ██╔████╔██║██║   ██║██╔██╗ ██║██║   ██║   ██║   ██║██████╔╝
# ██║╚██╔╝██║██║   ██║██║╚██╗██║██║   ██║   ██║   ██║██╔══██╗
# ██║ ╚═╝ ██║╚██████╔╝██║ ╚████║██║   ██║   ╚██████╔╝██║  ██║
# ╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝

monitor_training() {
    log_header "启动监控系统"
    local log_file="/tmp/rl_swarm.log"
    local last_round=0
    local error_count=0
    
    # 开始日志跟踪
    screen -S rl_train -X logfile "$log_file"
    screen -S rl_train -X log on

    tail -Fn0 "$log_file" | while read -r line; do
        # 检测关键事件
        case "$line" in
            *"Starting round:"*)
                current_round=$(echo "$line" | grep -oE '[0-9]+')
                if (( current_round > last_round + 1 )); then
                    log_warning "Round跳跃检测: $last_round → $current_round"
                fi
                last_round=$current_round
                error_count=0
                ;;
                
            *"MPS backend out of memory"*)
                log_warning "GPU内存不足，自动清理缓存..."
                python -c "import torch; torch.mps.empty_cache()"
                ;;
                
            *"ERROR"*|*"Exception"*)
                ((error_count++))
                if (( error_count > 3 )); then
                    log_error "检测到连续错误，准备重启..."
                    return 1
                fi
                ;;
                
            *"Good luck in the swarm!"*)
                log_success "训练正常启动"
                ;;
        esac
    done
}

# ██████╗ ███████╗██████╗ ██╗   ██╗
# ██╔══██╗██╔════╝██╔══██╗╚██╗ ██╔╝
# ██████╔╝█████╗  ██████╔╝ ╚████╔╝ 
# ██╔══██╗██╔══╝  ██╔══██╗  ╚██╔╝  
# ██║  ██║███████╗██║  ██║   ██║   
# ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝   ╚═╝   

restart_service() {
    log_header "执行重启操作"
    
    # 清理进程
    pkill -f "run_rl_swarm.sh" || true
    screen -S rl_train -X quit || true
    
    # 清理GPU缓存
    python -c "import torch; torch.mps.empty_cache()" 2>/dev/null || true
    
    # 等待资源释放
    sleep 5
    
    # 重新启动
    init_m4_environment
    start_training
}

# ██╗      ██████╗  ██████╗ █████╗ 
# ██║     ██╔═══██╗██╔════╝██╔══██╗
# ██║     ██║   ██║██║     ███████║
# ██║     ██║   ██║██║     ██╔══██║
# ███████╗╚██████╔╝╚██████╗██║  ██║
# ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝

main_loop() {
    while true; do
        start_training
        
        if ! monitor_training; then
            log_warning "训练异常，10秒后重启..."
            sleep 10
            restart_service
        fi
        
        sleep 5
    done
}

# ██████╗ ███████╗███╗   ██╗██████╗ ███████╗██████╗ 
# ██╔══██╗██╔════╝████╗  ██║██╔══██╗██╔════╝██╔══██╗
# ██████╔╝█████╗  ██╔██╗ ██║██║  ██║█████╗  ██████╔╝
# ██╔══██╗██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██╔══██╗
# ██║  ██║███████╗██║ ╚████║██████╔╝███████╗██║  ██║
# ╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝  ╚═╝

case "${1:-}" in
    --start)
        init_m4_environment
        main_loop
        ;;
    --stop)
        pkill -f "run_rl_swarm.sh"
        screen -S rl_train -X quit
        log_success "已停止所有服务"
        ;;
    --status)
        echo -e "${BOLD}${CYAN}RL Swarm 服务状态${RESET}"
        echo "--------------------------------"
        screen -list | grep "rl_train" || echo "训练会话: 未运行"
        pgrep -fl "run_rl_swarm.sh" || echo "训练进程: 未运行"
        echo "--------------------------------"
        python -c "import torch; print(f'PyTorch 后端: {torch.backends.mps.is_available() and \"Metal\" or \"CPU\"}')"
        ;;
    --clean)
        rm -rf "${M4_CONFIG[CACHE_DIR]}"
        python -c "import torch; torch.mps.empty_cache()"
        log_success "已清理所有缓存"
        ;;
    *)
        echo -e "${BOLD}Usage:${RESET}"
        echo "  $0 --start   启动训练服务"
        echo "  $0 --stop    停止服务"
        echo "  $0 --status  查看状态"
        echo "  $0 --clean   清理缓存"
        exit 1
        ;;
esac
