#!/bin/bash
set -e

# === 终端颜色设置 ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'
BLUE_LINE="\e[38;5;220m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"

# === 显示标题头 ===
function show_header() {
    clear
    echo -e "\e[38;5;220m"
    echo " ██████╗  ██████╗ ██╗     ██████╗ ██╗   ██╗██████╗ ███████╗"
    echo "██╔════╝ ██╔═══██╗██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝"
    echo "██║  ███╗██║   ██║██║     ██║  ██║██║   ██║██████╔╝███████╗"
    echo "██║   ██║██║   ██║██║     ██║  ██║╚██╗ ██╔╝██╔═══╝ ╚════██║"
    echo "╚██████╔╝╚██████╔╝███████╗██████╔╝ ╚████╔╝ ██║     ███████║"
    echo " ╚═════╝  ╚═════╝ ╚══════╝╚═════╝   ╚═══╝  ╚═╝     ╚══════╝"
    echo -e "\e[0m"
    echo -e "🚀 \e[1;33mMultisynq 自动安装程序\e[0m - 由 \e[1;33mGoldVPS 团队\e[0m 提供支持 🚀"
    echo -e "🌐 \e[4;33mhttps://goldvps.net\e[0m"
    echo ""
}

# === 确保UFW已安装并激活 ===
function ensure_ufw_ready() {
    # 检查UFW是否安装
    if ! command -v ufw &>/dev/null; then
        echo -e "${YELLOW}⚙️ UFW 未安装，正在安装...${RESET}"
        apt-get install -y ufw
    fi

    # 检查UFW是否激活
    if ! ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}🚀 正在启用UFW防火墙...${RESET}"
        ufw --force enable
    fi
}

# === 安装功能 ===
function install_and_run() {
    echo -e "${CYAN}步骤 1: 安装与配置...${RESET}"
    
    # 安装Node.js v18 LTS
    echo -e "${YELLOW}✔ 正在安装 Node.js (v18 LTS)...${RESET}"
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs

    # 安装Docker
    echo -e "${YELLOW}✔ 正在安装 Docker...${RESET}"
    apt-get install -y docker.io

    # 安装screen工具
    echo -e "${YELLOW}✔ 正在安装 screen...${RESET}"
    apt-get install -y screen

    # 安装synchronizer-cli
    echo -e "${YELLOW}✔ 正在安装 synchronizer-cli...${RESET}"
    npm install -g synchronizer-cli

    # 初始化同步器
    echo -e "${YELLOW}✔ 正在运行 synchronize init...${RESET}"
    synchronize init

    echo -e "${CYAN}步骤 2: 在screen中启动同步器...${RESET}"
    # 在screen会话中启动同步器
    screen -dmS multisynq bash -c "synchronize start"
    echo -e "${GREEN}✔ 节点已在screen会话中运行，名称: ${YELLOW}multisynq${RESET}"
    echo -e "${CYAN}查看日志请运行: ${GREEN}screen -r multisynq${RESET}"

    # 打开必要的防火墙端口
    echo -e "${YELLOW}✔ 正在通过UFW开放必要端口...${RESET}"
    ensure_ufw_ready
    ufw allow 22/tcp > /dev/null 2>&1 || true
    ufw allow 3333/tcp > /dev/null 2>&1 || true
    echo -e "${GREEN}✔ 端口 22 和 3333 已成功开放。${RESET}"

    echo ""
    read -p "🔙 按Enter键返回主菜单..."
}

# === 检查并开放所需端口 ===
function check_and_open_ports() {
    for port in 3000 3001; do
        if ! ufw status | grep -q "$port/tcp"; then
            echo -e "${YELLOW}🔓 端口 $port 未开放，正在开放...${RESET}"
            ufw allow "$port"/tcp > /dev/null 2>&1 || true
        else
            echo -e "${GREEN}✅ 端口 $port 已开放。${RESET}"
        fi
    done
}

# === 性能检查功能 ===
function check_performance() {
    # 检查同步器容器是否运行
    if ! docker ps | grep -q "synchronizer"; then
        echo -e "${RED}❌ 没有运行中的同步器容器。请先运行选项1。${RESET}"
        read -p "🔙 按Enter键返回主菜单..."
        return
    fi

    # 获取公网IP
    PUBLIC_IP=$(curl -s ipv4.icanhazip.com || echo "<你的VPS_IP>")

    echo -e "${CYAN}正在启动Web仪表板...${RESET}"
    # 在后台启动仪表板
    synchronize web > /dev/null 2>&1 &

    # 确保仪表板端口已开放
    check_and_open_ports

    sleep 2

    # 显示访问信息
    echo -e "${GREEN}✔ Web仪表板已启动。${RESET}"
    echo -e "${YELLOW}🌐 仪表板: ${CYAN}http://$PUBLIC_IP:3000${RESET}"
    echo -e "${YELLOW}📊 指标:   ${CYAN}http://$PUBLIC_IP:3001/metrics${RESET}"
    echo -e "${YELLOW}❤️  健康检查: ${CYAN}http://$PUBLIC_IP:3001/health${RESET}"
    echo ""
    echo -e "${GREEN}✔ 您的节点在screen会话中运行: ${YELLOW}multisynq${RESET}"
    echo -e "${CYAN}查看日志请运行: ${GREEN}screen -r multisynq${RESET}"
    echo ""
    echo -e "${YELLOW}ℹ️  注意: 关闭终端后仪表板将停止。${RESET}"
    echo -e "${YELLOW}👉 使用选项3设置开机自动启动。${RESET}"
    echo ""
    read -p "🔙 按Enter键返回主菜单..."
}

# === 启用Web仪表板服务 ===
function enable_web_service() {
    echo -e "${CYAN}正在将Web仪表板设置为systemd服务...${RESET}"

    # 服务文件路径
    SERVICE_PATH="/etc/systemd/system/synchronizer-cli-web.service"

    # 创建systemd服务文件
    cat <<EOF > $SERVICE_PATH
[Unit]
Description=Synchronizer Web Dashboard
After=network.target docker.service
Requires=docker.service

[Service]
User=root
ExecStart=$(which synchronize) web
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    # 重载并启用服务
    sudo systemctl daemon-reload
    sudo systemctl enable synchronizer-cli-web
    sudo systemctl start synchronizer-cli-web

    echo -e "${GREEN}✔ Web仪表板服务已安装并成功启动！${RESET}"
    echo -e "${YELLOW}🌐 访问地址: ${CYAN}http://$(curl -s ipv4.icanhazip.com):3000${RESET}"
    echo ""
    read -p "🔙 按Enter键返回主菜单..."
}

# === 主菜单 ===
while true; do
    show_header
    echo -e "${BLUE_LINE}"
    echo -e "  ${GREEN}1.${RESET} 安装并启动节点"
    echo -e "  ${GREEN}2.${RESET} 打开Web仪表板 ${YELLOW}(手动启动)${RESET}"
    echo -e "  ${GREEN}3.${RESET} 启用仪表板开机自启 ${YELLOW}(systemd服务)${RESET}"
    echo -e "  ${GREEN}4.${RESET} 退出"
    echo -e "${BLUE_LINE}"
    read -p "请选择操作 (1–4): " choice

    case $choice in
        1)
            install_and_run
            ;;
        2)
            check_performance
            ;;
        3)
            enable_web_service
            ;;
        4)
            echo -e "${RED}正在退出...${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入。${RESET}"
            sleep 1
            ;;
    esac
done
