#!/usr/bin/env bash

# RL-Swarm 监控脚本 (适配 ~/rl-swarm 目录)
# 用于监控 rl-swarm 进程状态，自动重启异常退出的进程

set -euo pipefail

# 配置参数
ROOT_DIR="$HOME/rl-swarm"
SCRIPT_NAME="run_rl_swarm.sh"
LOG_DIR="$ROOT_DIR/logs"
MONITOR_LOG="$LOG_DIR/monitor.log"
PID_FILE="$ROOT_DIR/rl_swarm.pid"
CHECK_INTERVAL=30
RESTART_DELAY=10
REAL_TIME_MODE=false

# 颜色输出
GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
YELLOW_TEXT="\033[33m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

echo_yellow() {
    echo -e "$YELLOW_TEXT$1$RESET_TEXT"
}

log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] $message"
    
    echo "$log_entry" >> "$MONITOR_LOG"
    
    if [ "$REAL_TIME_MODE" = true ]; then
        echo_blue "$log_entry"
    fi
}

tail_logs() {
    echo_green ">> 开始实时监控日志输出..."
    echo_yellow ">> 按 Ctrl+C 停止监控"
    echo ""
    
    local temp_log="/tmp/rl_swarm_combined.log"
    
    (
        while true; do
            {
                if [ -f "$LOG_DIR/rl_swarm_output.log" ]; then
                    tail -n 0 -f "$LOG_DIR/rl_swarm_output.log" 2>/dev/null | sed 's/^/[RL-SWARM] /' &
                fi
                
                if [ -f "$LOG_DIR/yarn.log" ]; then
                    tail -n 0 -f "$LOG_DIR/yarn.log" 2>/dev/null | sed 's/^/[YARN] /' &
                fi
                
                if [ -f "$MONITOR_LOG" ]; then
                    tail -n 0 -f "$MONITOR_LOG" 2>/dev/null | sed 's/^/[MONITOR] /' &
                fi
                
                wait
            }
            sleep 1
        done
    ) &
    
    local tail_pid=$!
    trap "kill $tail_pid 2>/dev/null; exit 0" INT TERM
    wait $tail_pid
}

mkdir -p "$LOG_DIR"

cleanup() {
    echo_yellow ">> 监控脚本正在退出..."
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo_yellow ">> 检测到运行中的 rl-swarm 进程 (PID: $pid)"
            read -p "是否要停止该进程? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                stop_rl_swarm
            fi
        fi
    fi
    
    log_message "监控脚本已退出"
    exit 0
}

trap cleanup EXIT INT TERM

stop_rl_swarm() {
    echo_yellow ">> 正在停止 rl-swarm 进程..."
    
    pkill -f "python -m rgym_exp.runner.swarm_launcher" 2>/dev/null || true
    pkill -f "yarn start" 2>/dev/null || true
    pkill -f "node.*modal-login" 2>/dev/null || true
    pkill -f "run_rl_swarm.sh" 2>/dev/null || true
    
    rm -f "$PID_FILE"
    sleep 3
    log_message "rl-swarm 进程已停止"
}

start_rl_swarm() {
    echo_green ">> 正在启动 rl-swarm..."
    
    cd "$ROOT_DIR"
    
    if ! check_and_activate_venv; then
        echo_red ">> 虚拟环境激活失败，但将继续尝试启动"
        log_message "虚拟环境激活失败，继续启动"
    fi
    
    export IDENTITY_PATH
    export GENSYN_RESET_CONFIG
    export CONNECT_TO_TESTNET=true
    export ORG_ID
    export HF_HUB_DOWNLOAD_TIMEOUT=120
    export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
    export HUGGINGFACE_ACCESS_TOKEN="None"
    export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0
    
    DEFAULT_IDENTITY_PATH="$ROOT_DIR/swarm.pem"
    IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}
    
    DOCKER=${DOCKER:-""}
    GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}
    CPU_ONLY=${CPU_ONLY:-""}
    ORG_ID=${ORG_ID:-""}
    
    if [ ! -f "$SCRIPT_NAME" ]; then
        echo_red ">> 错误: 找不到 $SCRIPT_NAME"
        return 1
    fi
    
    echo_blue ">> Python环境信息:"
    echo "   Python路径: $(which python)"
    echo "   Python版本: $(python --version 2>&1)"
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo "   虚拟环境: $VIRTUAL_ENV"
    else
        echo "   虚拟环境: 未激活"
    fi
    echo "   PyTorch MPS设置: PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0"
    
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        bash -c "source '$VIRTUAL_ENV/bin/activate' && export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0 && bash '$SCRIPT_NAME'" > "$LOG_DIR/rl_swarm_output.log" 2>&1 &
    else
        bash -c "export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0 && bash '$SCRIPT_NAME'" > "$LOG_DIR/rl_swarm_output.log" 2>&1 &
    fi
    
    local pid=$!
    echo $pid > "$PID_FILE"
    log_message "rl-swarm 已启动 (PID: $pid)"
    echo_green ">> rl-swarm 已启动 (PID: $pid)"
    
    sleep $RESTART_DELAY
    
    if ! kill -0 "$pid" 2>/dev/null; then
        echo_red ">> 警告: 进程启动后立即退出，请检查日志"
        log_message "警告: 进程启动后立即退出"
        return 1
    fi
    
    return 0
}

is_process_running() {
    if [ ! -f "$PID_FILE" ]; then
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        return 1
    fi
    
    if ! pgrep -f "run_rl_swarm.sh" > /dev/null && ! pgrep -f "python -m rgym_exp.runner.swarm_launcher" > /dev/null; then
        rm -f "$PID_FILE"
        return 1
    fi
    
    return 0
}

check_for_errors() {
    local error_patterns=(
        "killed"
        "An error was detected while running rl-swarm"
        "Traceback"
        "Error:"
        "Exception:"
        "SIGKILL"
        "SIGTERM"
    )
    
    local log_files=(
        "$LOG_DIR/rl_swarm_output.log"
        "$LOG_DIR/yarn.log"
    )
    
    for log_file in "${log_files[@]}"; do
        if [ -f "$log_file" ]; then
            local recent_logs=$(tail -n 50 "$log_file" 2>/dev/null || echo "")
            
            for pattern in "${error_patterns[@]}"; do
                if echo "$recent_logs" | grep -qi "$pattern"; then
                    log_message "在 $log_file 中检测到错误模式: $pattern"
                    return 0
                fi
            done
        fi
    done
    
    return 1
}

check_and_activate_venv() {
    local venv_path="$ROOT_DIR/.venv"
    
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo_green ">> 已在虚拟环境中: $VIRTUAL_ENV"
        log_message "已在虚拟环境中: $VIRTUAL_ENV"
        return 0
    fi
    
    if [ ! -d "$venv_path" ]; then
        echo_yellow ">> 虚拟环境不存在，将在系统Python环境中运行"
        log_message "虚拟环境不存在: $venv_path"
        return 0
    fi
    
    local activate_script="$venv_path/bin/activate"
    if [ ! -f "$activate_script" ]; then
        activate_script="$venv_path/Scripts/activate"
        if [ ! -f "$activate_script" ]; then
            echo_yellow ">> 虚拟环境激活脚本不存在，将在系统Python环境中运行"
            log_message "虚拟环境激活脚本不存在"
            return 0
        fi
    fi
    
    echo_green ">> 检测到虚拟环境，正在激活: $venv_path"
    log_message "激活虚拟环境: $venv_path"
    
    source "$activate_script"
    
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo_green ">> 虚拟环境激活成功: $VIRTUAL_ENV"
        log_message "虚拟环境激活成功: $VIRTUAL_ENV"
        return 0
    else
        echo_red ">> 虚拟环境激活失败"
        log_message "虚拟环境激活失败"
        return 1
    fi
}

monitor_loop() {
    local restart_count=0
    local real_time_flag="${1:-false}"
    
    if [ "$real_time_flag" = "--real-time" ] || [ "$real_time_flag" = "-r" ]; then
        REAL_TIME_MODE=true
        echo_green ">> 实时监控模式已启用"
    fi
    
    echo_blue ">> RL-Swarm 监控脚本已启动"
    echo_blue ">> 检查间隔: ${CHECK_INTERVAL}秒"
    echo_blue ">> 无限重启模式: 启用"
    echo_blue ">> 日志文件: $MONITOR_LOG"
    
    if [ "$REAL_TIME_MODE" = true ]; then
        echo_green ">> 实时日志输出已启用"
    fi
    
    log_message "监控脚本已启动 (实时模式: $REAL_TIME_MODE, 无限重启模式: 启用)"
    
    if [ "$REAL_TIME_MODE" = true ]; then
        tail_logs &
        local tail_pid=$!
        trap "kill $tail_pid 2>/dev/null; cleanup" EXIT INT TERM
    fi
    
    while true; do
        if ! is_process_running; then
            echo_red ">> 检测到 rl-swarm 进程未运行"
            log_message "检测到 rl-swarm 进程未运行"
            
            restart_count=$((restart_count + 1))
            echo_yellow ">> 尝试重启 (第 $restart_count 次)"
            log_message "尝试重启 rl-swarm (第 $restart_count 次)"
            
            stop_rl_swarm
            sleep 5
            
            if start_rl_swarm; then
                echo_green ">> 重启成功"
                log_message "重启成功"
            else
                echo_red ">> 重启失败，将在下次检查时重试"
                log_message "重启失败"
            fi
        elif check_for_errors; then
            echo_red ">> 检测到错误，准备重启进程"
            log_message "检测到错误，准备重启进程"
            
            restart_count=$((restart_count + 1))
            echo_yellow ">> 由于错误重启 (第 $restart_count 次)"
            log_message "由于错误重启 rl-swarm (第 $restart_count 次)"
            
            stop_rl_swarm
            start_rl_swarm
        else
            if [ "$REAL_TIME_MODE" = true ]; then
                local current_time=$(date '+%H:%M:%S')
                echo_green "[$current_time] >> rl-swarm 运行正常 (已重启 $restart_count 次)"
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
}

show_help() {
    echo "RL-Swarm 监控脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  start           启动监控"
    echo "  start --real-time 启动实时监控（直接输出日志）"
    echo "  start -r        启动实时监控（简写）"
    echo "  stop            停止 rl-swarm 进程"
    echo "  status          查看状态"
    echo "  restart         重启 rl-swarm 进程"
    echo "  logs            查看监控日志"
    echo "  tail            实时跟踪所有日志"
    echo "  help            显示此帮助信息"
    echo ""
}

show_status() {
    echo_blue ">> RL-Swarm 状态检查"
    
    echo ">> Python环境状态:"
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo_green "   虚拟环境: 已激活 ($VIRTUAL_ENV)"
    else
        if [ -d "$ROOT_DIR/.venv" ]; then
            echo_yellow "   虚拟环境: 存在但未激活 ($ROOT_DIR/.venv)"
        else
            echo_yellow "   虚拟环境: 不存在"
        fi
    fi
    echo "   Python路径: $(which python 2>/dev/null || echo '未找到')"
    echo "   Python版本: $(python --version 2>&1 || echo '无法获取版本')"
    echo ""
    
    if is_process_running; then
        local pid=$(cat "$PID_FILE")
        echo_green ">> rl-swarm 正在运行 (PID: $pid)"
        
        echo ">> 相关进程:"
        pgrep -f "python -m rgym_exp.runner.swarm_launcher" | while read p; do
            echo "   Python进程: $p"
        done
        
        pgrep -f "yarn start" | while read p; do
            echo "   Yarn进程: $p"
        done
    else
        echo_red ">> rl-swarm 未运行"
    fi
    
    if [ -f "$MONITOR_LOG" ]; then
        echo ""
        echo ">> 最近的监控日志:"
        tail -n 5 "$MONITOR_LOG"
    fi
}

show_logs() {
    if [ -f "$MONITOR_LOG" ]; then
        echo_blue ">> 监控日志 ($MONITOR_LOG):"
        tail -n 20 "$MONITOR_LOG"
    else
        echo_yellow ">> 监控日志文件不存在"
    fi
    
    echo ""
    
    if [ -f "$LOG_DIR/rl_swarm_output.log" ]; then
        echo_blue ">> RL-Swarm 输出日志:"
        tail -n 20 "$LOG_DIR/rl_swarm_output.log"
    else
        echo_yellow ">> RL-Swarm 输出日志文件不存在"
    fi
}

main() {
    case "${1:-start}" in
        "start")
            if [ "${2:-}" = "--real-time" ] || [ "${2:-}" = "-r" ]; then
                monitor_loop "--real-time"
            else
                monitor_loop
            fi
            ;;
        "stop")
            stop_rl_swarm
            ;;
        "status")
            show_status
            ;;
        "restart")
            stop_rl_swarm
            start_rl_swarm
            ;;
        "logs")
            show_logs
            ;;
        "tail")
            tail_logs
            ;;
        "help")
            show_help
            ;;
        *)
            echo_red ">> 未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

if [ ! -f "$ROOT_DIR/$SCRIPT_NAME" ]; then
    echo_red ">> 错误: 在当前目录找不到 $SCRIPT_NAME"
    echo_red ">> 请确保在 rl-swarm 项目根目录运行此脚本"
    exit 1
fi

main "$@"
