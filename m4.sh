#!/bin/bash

# RL Swarm 自动重启脚本（Mac M系列优化版）
# 使用方法: ./screen_auto_restart.sh

set -euo pipefail

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Screen会话名称
SCREEN_NAME="gensyn"

# PID文件路径
PID_FILE="/tmp/rl_swarm_daemon.pid"

# 检查是否已有实例运行
check_existing_instance() {
    if [ -f "$PID_FILE" ]; then
        local existing_pid=$(cat "$PID_FILE")
        if ps -p "$existing_pid" > /dev/null; then
            log_warn "检测到已有实例运行 (PID: $existing_pid)"
            log_info "如需启动新实例，请先停止旧实例：$0 --stop"
            return 1
        else
            log_info "清理过期的PID文件"
            rm -f "$PID_FILE"
        fi
    fi
    return 0
}

# 创建PID文件
create_pid_file() {
    echo $$ > "$PID_FILE"
    log_info "创建PID文件: $PID_FILE (PID: $$)"
}

# 清理PID文件
cleanup_pid_file() {
    if [ -f "$PID_FILE" ]; then
        rm -f "$PID_FILE"
        log_info "清理PID文件: $PID_FILE"
    fi
}

# 检查screen是否安装
check_screen() {
    if ! command -v screen &> /dev/null; then
        log_error "screen未安装，请使用以下命令安装："
        log_error "brew install screen"
        exit 1
    fi
}

# 创建或连接到screen会话
setup_screen() {
    log_info "设置Screen会话: $SCREEN_NAME"
    
    # 修复Mac兼容性问题：检查会话数量
    local session_count=$(screen -list 2>/dev/null | grep -c "$SCREEN_NAME" || echo "0")
    session_count=$(echo "$session_count" | tr -d '[:space:]')  # 移除空格
    
    if ! [[ "$session_count" =~ ^[0-9]+$ ]]; then
        log_warn "检测会话数量失败，重置为0"
        session_count=0
    fi
    
    log_debug "检测到 $session_count 个screen会话"
    
    if [ "$session_count" -gt 1 ]; then
        log_warn "检测到多个screen会话，清理重复会话..."
        screen -ls | grep "$SCREEN_NAME" | awk '{print $1}' | while read session; do
            log_info "删除重复的screen会话: $session"
            screen -S "$session" -X quit 2>/dev/null || true
        done
        sleep 2
    fi
}

# 备份认证文件
backup_auth_files() {
    log_info "备份认证文件..."
    mkdir -p "$HOME/backup"
    
    local auth_path="$HOME/rl-swarm/modal-login/temp-data"
    
    if [ -f "$auth_path/userApiKey.json" ]; then
        cp "$auth_path/userApiKey.json" "$HOME/backup/"
        log_info "已备份 userApiKey.json"
    else
        log_warn "userApiKey.json 不存在，跳过备份"
    fi
    
    if [ -f "$auth_path/userData.json" ]; then
        cp "$auth_path/userData.json" "$HOME/backup/"
        log_info "已备份 userData.json"
    else
        log_warn "userData.json 不存在，跳过备份"
    fi
}

# 恢复认证文件
restore_auth_files() {
    log_info "恢复认证文件..."
    local auth_path="$HOME/rl-swarm/modal-login/temp-data"
    mkdir -p "$auth_path"
    
    if [ -f "$HOME/backup/userApiKey.json" ]; then
        cp "$HOME/backup/userApiKey.json" "$auth_path/"
        log_info "已恢复 userApiKey.json"
    fi
    
    if [ -f "$HOME/backup/userData.json" ]; then
        cp "$HOME/backup/userData.json" "$auth_path/"
        log_info "已恢复 userData.json"
    fi
}

# 启动或重启RL Swarm
start_or_restart_rl_swarm() {
    local is_restart=${1:-false}
    
    if [ "$is_restart" = true ]; then
        log_info "重启RL Swarm..."
        
        # 删除所有旧的screen会话
        log_info "删除所有旧的screen会话..."
        screen -ls | grep "$SCREEN_NAME" | awk '{print $1}' | while read session; do
            log_info "删除screen会话: $session"
            screen -S "$session" -X quit 2>/dev/null || true
        done
        sleep 3
    else
        log_info "启动RL Swarm..."
    fi
    
    # 恢复认证文件
    restore_auth_files
    
    # 创建新的screen会话
    log_info "创建新的screen会话..."
    screen -dmS "$SCREEN_NAME" bash -c "cd $HOME && exec bash"
    sleep 2
    
    # 在screen会话中启动RL Swarm
    log_info "在screen会话中启动RL Swarm..."
    screen -S "$SCREEN_NAME" -X stuff "cd $HOME/rl-swarm$(printf '\r')"
    sleep 1
    screen -S "$SCREEN_NAME" -X stuff "source .venv/bin/activate$(printf '\r')"
    sleep 1
    screen -S "$SCREEN_NAME" -X stuff "./run_rl_swarm.sh$(printf '\r')"
    
    log_info "RL Swarm已在screen会话中启动"
    
    # 启动日志捕获
    log_info "启动日志捕获..."
    LOG_FILE="/tmp/rl_swarm_screen.log"
    screen -S "$SCREEN_NAME" -X logfile "$LOG_FILE"
    screen -S "$SCREEN_NAME" -X log on
    sleep 2
    
    # 开始监控
    monitor_rl_swarm
}

# 监控RL Swarm输出
monitor_rl_swarm() {
    log_info "开始监控RL Swarm输出..."
    
    # 初始化状态变量
    startup_complete=false
    auth_handled=false
    startup_start_time=$(date +%s)
    
    while true; do
        # 日志文件路径
        LOG_FILE="/tmp/rl_swarm_screen.log"
        
        # 检查日志文件大小（Mac兼容方式）
        if [ -f "$LOG_FILE" ]; then
            log_size=$(wc -c < "$LOG_FILE" | awk '{print $1}')
            if [ $log_size -gt 10485760 ]; then  # 10MB
                log_info "清理过大的日志文件..."
                echo "" > "$LOG_FILE"
            fi
            
            # 监控日志文件
            tail -n 50 "$LOG_FILE" | while read line; do
                # 简化日志处理（移除颜色代码处理）
                clean_line=$(echo "$line" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g')
                
                if [ -n "$clean_line" ]; then
                    # 检测启动完成标志
                    if echo "$clean_line" | grep -q "Good luck in the swarm!"; then
                        startup_complete=true
                        log_info "RL Swarm启动完成"
                    fi
                    
                    # 检测异常错误
                    if echo "$clean_line" | grep -E "(ERROR: Exception occurred during game run\.|Traceback \(most recent call last\):|Segmentation fault)"; then
                        log_warn "检测到严重错误，准备重启..."
                        sleep 10
                        start_or_restart_rl_swarm true
                        return
                    fi
                    
                    # 检测认证提示
                    if [ "$auth_handled" = false ]; then
                        if echo "$clean_line" | grep -q "Waiting for modal userData.json to be created"; then
                            log_info "检测到认证提示，恢复备份文件..."
                            restore_auth_files
                            auth_handled=true
                            sleep 2
                            screen -S "$SCREEN_NAME" -X stuff "N$(printf '\r')"
                            sleep 1
                            screen -S "$SCREEN_NAME" -X stuff "Gensyn/Qwen2.5-0.5B-Instruct$(printf '\r')"
                        fi
                    fi
                fi
            done
        fi
        
        # 检查进程状态
        if ! pgrep -f "run_rl_swarm.sh" > /dev/null; then
            log_warn "RL Swarm进程已停止，准备重启..."
            start_or_restart_rl_swarm true
            sleep 10
            continue
        fi
        
        # 检查screen会话状态
        if ! screen -list | grep -q "$SCREEN_NAME"; then
            log_warn "Screen会话丢失，准备重启..."
            start_or_restart_rl_swarm true
            sleep 10
            continue
        fi
        
        # 简单心跳检测
        sleep 30
        log_info "监控运行中..."
    done
}

# 清理临时文件
cleanup() {
    log_info "清理临时文件..."
    rm -f /tmp/rl_swarm_screen.log
    rm -f /tmp/rl_swarm_daemon.log
    cleanup_pid_file
}

# 显示帮助信息
show_help() {
    echo "RL Swarm 自动重启脚本（Mac优化版）"
    echo ""
    echo "使用方法:"
    echo "  $0                    # 前台启动"
    echo "  $0 --daemon          # 后台启动"
    echo "  $0 --help            # 显示帮助"
    echo "  $0 --status          # 显示状态"
    echo "  $0 --stop            # 停止脚本"
    echo ""
    echo "Screen管理命令:"
    echo "  screen -r $SCREEN_NAME    # 连接会话"
    echo "  screen -list              # 查看会话"
}

# 显示状态
show_status() {
    echo "=== RL Swarm 状态 ==="
    
    # 后台进程状态
    if [ -f "$PID_FILE" ]; then
        local daemon_pid=$(cat "$PID_FILE")
        if ps -p "$daemon_pid" > /dev/null; then
            echo "监控进程: 运行中 (PID: $daemon_pid)"
        else
            echo "监控进程: 未运行"
        fi
    else
        echo "监控进程: 未运行"
    fi
    
    # Screen会话状态
    echo -n "Screen会话: "
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo "运行中"
    else
        echo "未运行"
    fi
    
    # RL Swarm进程状态
    echo -n "RL Swarm进程: "
    if pgrep -f "run_rl_swarm.sh" > /dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

# 主函数
main() {
    case "${1:-}" in
        --help)
            show_help
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --stop)
            log_info "停止RL Swarm..."
            # 停止监控进程
            if [ -f "$PID_FILE" ]; then
                local daemon_pid=$(cat "$PID_FILE")
                if ps -p "$daemon_pid" > /dev/null; then
                    kill "$daemon_pid" 2>/dev/null && log_info "监控进程已停止"
                fi
            fi
            
            # 停止screen会话
            screen -ls | grep "$SCREEN_NAME" | awk '{print $1}' | while read session; do
                screen -S "$session" -X quit 2>/dev/null && log_info "Screen会话已停止"
            done
            
            cleanup_pid_file
            exit 0
            ;;
        --daemon)
            log_info "启动后台监控模式..."
            nohup "$0" > /tmp/rl_swarm_daemon.log 2>&1 &
            log_info "后台进程PID: $!"
            exit 0
            ;;
    esac
    
    log_info "启动RL Swarm自动重启脚本（Mac优化版）..."
    
    # 检查现有实例
    if ! check_existing_instance; then
        exit 1
    fi
    
    # 创建PID文件
    create_pid_file
    
    # 检查依赖
    check_screen
    
    # 备份文件
    backup_auth_files
    
    # 设置screen
    setup_screen
    
    # 设置退出清理
    trap 'log_info "退出清理..."; cleanup; exit 0' SIGTERM SIGINT
    
    # 启动RL Swarm
    start_or_restart_rl_swarm
}

# 运行主函数
main "$@"
