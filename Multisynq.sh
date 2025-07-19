#!/usr/bin/env bash
set -e

### =============== 全局配置 ===============
# 基础端口配置
BASE_HTTP_PORT=7000
BASE_METRICS_PORT=7100
LOG_DIR="$HOME/synq_logs"  # 专用日志目录

### =============== 菜单函数 ===============
menu() {
  clear
  echo "======= Multisynq CLI ======="
  echo "  Synchronizer 安装与启动脚本"
  echo "  作者：@ferdie_jhovie"
  echo "  注意：这是一个免费脚本！"
  echo "========================================"
  echo "1) 部署节点（安装依赖、生成配置、启动节点）"
  echo "2) 查看节点状态 (pm2 ls)"
  echo "3) 查看节点日志（选择节点）"
  echo "4) 停止所有节点并清理容器"
  echo "0) 退出"
  echo "========================================"
  read -rp "请输入选项: " opt
  case $opt in
    1) deploy_nodes ;;
    2) pm2 ls; read -rp "按回车继续..." ;;
    3) show_logs ;;
    4) stop_all ;;
    0) exit 0 ;;
    *) echo "❌ 无效选项"; sleep 1 ;;
  esac
}

### =============== 端口检查函数 ===============
check_port() {
  local port=$1
  if lsof -i :"$port" >/dev/null 2>&1; then
    echo "❌ 端口 $port 已被占用"
    return 1
  fi
  return 0
}

### =============== 部署节点 ===============
deploy_nodes() {
  # 安装依赖
  echo "📦 安装依赖（Node·Docker·CLI）..."
  if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt install -y nodejs
  fi
  
  docker_installed=false
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER
    docker_installed=true
  fi
  
  sudo npm i -g pm2 synchronizer-cli
  synchronize install-docker
  echo "✅ 依赖安装完成"
  
  if $docker_installed; then
    echo "⚠️ 注意：已将当前用户加入docker组，需要重新登录或重启系统才能使权限生效"
    echo "如果立即运行脚本时出现权限错误，请尝试重新登录后再运行"
  fi

  # 生成单一 .env.m1 文件
  echo "📝 生成 .env.m1 文件..."
  echo "请逐行输入账户信息："
  echo "----------------------------------------"

  # 逐行提示用户输入
  read -rp "请输入 WALLET（如 0x123abc）: " WAL
  if [[ -z $WAL ]]; then
    echo "❌ WALLET 不能为空"
    read -rp "按回车继续..."
    return
  fi

  read -rp "请输入 synqKey（如 ae1c98c9-xxxx-xxxx-xxxx）: " KEY
  if [[ -z $KEY ]]; then
    echo "❌ synqKey 不能为空"
    read -rp "按回车继续..."
    return
  fi

  read -rp "请输入 PROXY（可选，如 http://user:pass@ip:port，按回车跳过）: " PROXY

  # 生成 .env.m1 文件
  f=".env.m1"
  if [[ -n $PROXY ]]; then
    cat > "$f" <<EOF
WALLET=$WAL
KEY=$KEY
PROXY=$PROXY
EOF
    echo "✔️ 已写入 $f ($WAL) - 使用代理"
  else
    cat > "$f" <<EOF
WALLET=$WAL
KEY=$KEY
EOF
    echo "✔️ 已写入 $f ($WAL) - 不使用代理"
  fi
  echo "✅ 已生成单一配置文件 .env.m1"

  # 启动节点
  echo "🔄 清空旧 pm2 记录..."
  pm2 delete all &>/dev/null || true
  echo "🧹 清理所有旧 Docker 容器..."
  docker ps -aq --filter "name=synchronizer-" | xargs -r docker rm -f

  # 仅处理 .env.m1 文件
  if [[ -f ".env.m1" ]]; then
    source ".env.m1"
    
    # 使用唯一节点名（添加时间戳）
    timestamp=$(date +%s)
    name="m1_$timestamp"
    http_port=$BASE_HTTP_PORT
    metrics_port=$BASE_METRICS_PORT
    sync_name="synq-${name}"
    
    # 检查端口是否可用
    if ! check_port $http_port || ! check_port $metrics_port; then
      echo "❌ 端口冲突，无法启动节点"
      read -rp "按回车继续..."
      return
    fi
    
    echo "🚀 启动 $name (HTTP端口: $http_port, Metrics端口: $metrics_port)..."
    if [[ -n $PROXY ]]; then
      echo "  使用代理: $PROXY"
      pm2 start bash --name "$name" -- -c \
        "http_proxy=$PROXY HTTPS_PROXY=$PROXY \
        docker run --rm --name synchronizer-$name \
        -p $http_port:8080 \
        -p $metrics_port:9090 \
        -e SYNC_HTTP_PORT=$http_port \
        -e SYNC_METRICS_PORT=$metrics_port \
        cdrakep/synqchronizer:latest \
        --depin wss://api.multisynq.io/depin \
        --sync-name $sync_name \
        --launcher cli \
        --key $KEY \
        --wallet $WALLET \
        --time-stabilized"
    else
      echo "  不使用代理"
      pm2 start bash --name "$name" -- -c \
        "docker run --rm --name synchronizer-$name \
        -p $http_port:8080 \
        -p $metrics_port:9090 \
        -e SYNC_HTTP_PORT=$http_port \
        -e SYNC_METRICS_PORT=$metrics_port \
        cdrakep/synqchronizer:latest \
        --depin wss://api.multisynq.io/depin \
        --sync-name $sync_name \
        --launcher cli \
        --key $KEY \
        --wallet $WALLET \
        --time-stabilized"
    fi
  else
    echo "❌ 未找到 .env.m1 文件，节点启动失败"
    read -rp "按回车继续..."
    return
  fi
  
  echo "✅ 节点已启动"
  echo "📊 节点状态页面可通过以下地址访问:"
  echo "  - $name: http://localhost:$http_port"
  
  read -rp "按回车继续..."
}

### =============== 查看日志 ===============
show_logs() {
  echo "可用节点："
  pm2 ls | awk 'NR>3 && $2 !~ /-/ {print $2}' | sort | uniq
  read -rp $'\n输入要查看日志的节点名（如 m1），或回车查看全部: ' name
  
  echo "选择操作:"
  echo "1) 查看实时日志"
  echo "2) 保存日志到文件"
  read -rp "请选择 [1]: " log_opt
  log_opt=${log_opt:-1}
  
  # 创建日志目录
  mkdir -p "$LOG_DIR"
  
  if [[ $log_opt == "1" ]]; then
    if [[ -n $name ]]; then
      pm2 logs "$name" --lines 20
    else
      pm2 logs --lines 20
    fi
  else
    timestamp=$(date +"%Y%m%d_%H%M%S")
    if [[ -n $name ]]; then
      log_file="${LOG_DIR}/log_${name}_${timestamp}.txt"
      echo "保存 $name 的日志到 $log_file ..."
      pm2 logs "$name" --lines 100 --nostream > "$log_file"
      echo "✅ 日志已保存到 $log_file"
    else
      log_file="${LOG_DIR}/log_all_${timestamp}.txt"
      echo "保存所有节点日志到 $log_file ..."
      pm2 logs --lines 100 --nostream > "$log_file"
      echo "✅ 日志已保存到 $log_file"
    fi
  fi
  
  read -rp "按回车继续..."
}

### =============== 停止并清理 ===============
stop_all() {
  echo "🛑 停止所有 pm2 节点..."
  pm2 stop all || true
  pm2 delete all || true

  echo "🧹 清理所有 Docker 容器 synchronizer-* ..."
  docker ps -aq --filter "name=synchronizer-" | xargs -r docker rm -f

  echo "✅ 所有节点与容器已清理完毕"
  read -rp "按回车继续..."
}

### =============== 主循环 ===============
while true; do menu; done
