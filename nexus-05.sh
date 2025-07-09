#!/bin/bash

# Nexus节点管理脚本 - 适用于Mac和Linux

# 定义节点ID数组 - 请替换为您的实际节点ID
NODE_IDS=(
    "6723995"
    "6514134"
    "8131274"
    "6209171"
    "6267696"
    "7789177"
    "7729181"
    "7611541"
    "8081729"
    "7789183"
)

# 函数: 启动所有节点
start_nodes() {
    echo "正在启动Nexus节点..."
    for node_id in "${NODE_IDS[@]}"; do
        echo "启动节点: $node_id"
        # 使用MALLOC_ARENA_MAX=2减少内存占用，--max-threads 1提高效率
        # --headless参数让节点在后台运行
        MALLOC_ARENA_MAX=2 nohup nexus-network start --node-id "$node_id" --max-threads 1 --headless > /dev/null 2>&1 &
    done
    echo "所有节点已启动！"
}

# 函数: 查看节点状态
check_status() {
    echo "Nexus节点运行状态:"
    ps aux | grep nexus-network | grep -v grep
    
    echo "----------------------------------------"
    echo "各节点内存占用明细:"
    ps aux | grep nexus-network | grep -v grep | awk '{printf "进程ID: %5s | 内存: %.2f MB | 命令: %s\n", $2, $6/1024, $11}'
    echo "----------------------------------------"
    
    # 计算总内存占用
    MEM_USAGE=$(ps aux | grep nexus-network | grep -v grep | awk '{sum += $6} END {print sum/1024 " MB"}')
    echo "所有节点总内存占用: $MEM_USAGE"
}

# 函数: 停止所有节点
stop_nodes() {
    echo "正在停止所有Nexus节点..."
    pkill -f nexus-network
    echo "所有节点已停止！"
}

# 主菜单
show_menu() {
    echo "====== Nexus节点管理工具 ======"
    echo "1. 启动所有节点"
    echo "2. 查看节点状态"
    echo "3. 停止所有节点"
    echo "4. 重启所有节点"
    echo "0. 退出"
    echo "============================"
    
    read -p "请选择操作 [0-4]: " choice
    
    case $choice in
        1) start_nodes ;;
        2) check_status ;;
        3) stop_nodes ;;
        4) stop_nodes && sleep 2 && start_nodes ;;
        0) exit 0 ;;
        *) echo "无效选择，请重试" && show_menu ;;
    esac
    
    # 操作完成后显示菜单
    echo ""
    show_menu
}

# 检查命令行参数
if [ "$#" -gt 0 ]; then
    case $1 in
        "start") start_nodes ;;
        "status") check_status ;;
        "stop") stop_nodes ;;
        "restart") stop_nodes && sleep 2 && start_nodes ;;
        *) echo "用法: $0 [start|status|stop|restart]" ;;
    esac
else
    # 无参数时显示交互式菜单
    show_menu
fi
