```
wget -O deploy.sh https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/deploy.sh && chmod +x deploy.sh && ./deploy.sh

```
Alpine下需修改nginx.conf才能使用nginx ui面板
```
# /etc/nginx/nginx.conf
user nginx;
worker_processes auto;
pcre_jit on;
error_log /var/log/nginx/error.log warn;

# 1. 动态模块包含 (保留)
include /etc/nginx/modules/*.conf;

# 2. 删除外层 context 的 include，防止重复加载

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    server_tokens off;
    client_max_body_size 1m;
    sendfile on;
    tcp_nopush on;
    
    ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:2m;
    ssl_session_timeout 1h;
    ssl_session_tickets off;
    
    gzip_vary on;
    
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
        '$status $body_bytes_sent "$http_referer" '
        '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;

    # 3. 统一在这里加载配置文件
    # Alpine 默认使用 http.d，我们把它和 conf.d 合并管理
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/http.d/*.conf;
}
```
```
   resolver 8.8.8.8 1.1.1.1 valid=300s;
    resolver_timeout 5s;
    # 基础代理优化
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    location /emos/ {
        # 1. 核心：代理到视频服
        proxy_pass https://video.emos.best/;
        # 2. 【关键】强制 TLS 握手域名匹配 (SNI)
        proxy_ssl_server_name on;
        proxy_ssl_name video.emos.best;
        # 3. 欺骗 Host 头，让后端认为直接访问它
        proxy_set_header Host video.emos.best;
        # 4. 注入你要求的 Header
        proxy_set_header EMOS-PROXY-ID "eD3VXZD9Ys";
        proxy_set_header EMOS-PROXY-NAME "@OneQ1st";
        # 5. 路径重写：去掉 /emby 前缀
        rewrite ^/emos/(.*)$ /$1 break;
        # 6. SSL 证书校验 (若对方是合规证书则开启)
        proxy_ssl_verify off;
    }
    location / {
        # 普通访问直接转发，不带上述 EMOS 特有 Header
        proxy_pass http://127.0.0.1:8080;
    }
}
```
‘‘‘
#!/bin/bash

# ==================================================
# 颜色与样式定义
# ==================================================
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[36m'
PURPLE='\e[35m'
BOLD='\e[1m'
NC='\e[0m'

clear
echo -e "${BLUE}${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BLUE}${BOLD}│    Emby-Proxy 双栈(IPv4/IPv6)智能全自检部署脚本    │${NC}"
echo -e "${BLUE}${BOLD}└──────────────────────────────────────────────────┘${NC}"

# ==================================================
# 基础工具函数
# ==================================================
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ==================================================
# 独立执行块：环境依赖库安装 (Debian/Ubuntu)
# ==================================================
install_deps_debian() {
    echo -e "${YELLOW} ℹ 开始独立安装 Debian 系必要工具和依赖库...${NC}"
    apt-get update -y
    apt-get install -y curl tar wget git openssl jq psmisc
    if [ $? -ne 0 ]; then
        echo -e "${RED} ✖ [错误] Debian 基础依赖安装失败！请检查网络或软件源。${NC}"
        exit 1
    fi
    echo -e "${GREEN} ✔ Debian 依赖库安装完毕。${NC}"
}

# ==================================================
# 独立执行块：环境依赖库安装 (Alpine)
# ==================================================
install_deps_alpine() {
    echo -e "${YELLOW} ℹ 开始独立安装 Alpine 系必要工具和依赖库...${NC}"
    apk update
    apk add curl tar wget git openssl jq psmisc bash coreutils libc6-compat
    if [ $? -ne 0 ]; then
        echo -e "${RED} ✖ [错误] Alpine 基础依赖安装失败！请检查网络或软件源。${NC}"
        exit 1
    fi
    echo -e "${GREEN} ✔ Alpine 依赖库安装完毕。${NC}"
}

# ==================================================
# 系统环境智能识别
# ==================================================
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    INIT_SYSTEM="openrc"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS_TYPE="debian"
    INIT_SYSTEM="systemd"
else
    if command -v apk >/dev/null 2>&1; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
    else
        OS_TYPE="debian"
        INIT_SYSTEM="systemd"
    fi
fi

# ==================================================
# 0. 互动式功能选择
# ==================================================
echo -e "\n${BLUE}${BOLD}📊 请选择要执行的操作：${NC}"
echo -e "  ${BOLD}1)${NC} ${GREEN}智能自检部署 / 更新 Emby-Proxy${NC}"
echo -e "  ${BOLD}2)${NC} ${RED}一键完全卸载 (清理服务与程序数据)${NC}"
read -p " 请输入数字 [1/2]: " MAIN_CHOICE

# ----------------- 卸载逻辑分支 -----------------
if [ "$MAIN_CHOICE" == "2" ]; then
    echo -e "\n${YELLOW}${BOLD}⚠️  警告：该操作将停止并删除 Emby-Proxy 服务与程序本体！${NC}"
    read -p " 确认要继续卸载吗？(y/n, 默认 n): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy](es)?$ ]]; then
        echo -e "${GREEN} ℹ 已取消卸载操作。${NC}"
        exit 0
    fi

    echo -e "\n${BLUE}${BOLD}▶ 正在清理系统服务...${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
    
    # 停止并禁用服务
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        if systemctl is-active --quiet emby-backend || systemctl is-enabled --quiet emby-backend 2>/dev/null; then
            echo -e "${YELLOW} ℹ 正在停止并禁用服务: emby-backend...${NC}"
            systemctl stop emby-backend >/dev/null 2>&1
            systemctl disable emby-backend >/dev/null 2>&1
        fi
        rm -f /etc/systemd/system/emby-backend.service
        systemctl daemon-reload
    else
        if rc-service emby-backend status >/dev/null 2>&1; then
            echo -e "${YELLOW} ℹ 正在停止服务: emby-backend...${NC}"
            rc-service emby-backend stop >/dev/null 2>&1
        fi
        if rc-update show default | grep -q "emby-backend"; then
            echo -e "${YELLOW} ℹ 正在移除自启: emby-backend...${NC}"
            rc-update del emby-backend default >/dev/null 2>&1
        fi
        rm -f /etc/init.d/emby-backend
    fi
    echo -e "${GREEN} ✔ 系统服务配置清理完毕。${NC}"

    # 清理程序目录
    echo -e "${YELLOW} ℹ 正在删除程序目录...${NC}"
    rm -rf /opt/emby-proxy
    echo -e "${GREEN} ✔ 部署目录已彻底删除。${NC}"

    echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}${BOLD}│ 🎉 卸载完成！Emby-Proxy 相关服务及文件已清理干净。       │${NC}"
    echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}\n"
    exit 0

elif [ "$MAIN_CHOICE" != "1" ]; then
    echo -e "${RED} ✖ [错误] 输入无效，脚本退出。${NC}"
    exit 1
fi

# ==================================================
# 部署逻辑初始化
# ==================================================
mkdir -p /opt/emby-proxy

# ==================================================
# 1. 执行独立的依赖检查与安装块
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 1/3] 正在检查系统基础依赖环境...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"

NEED_INSTALL=false
for cmd in curl tar wget git openssl jq; do
    if ! check_cmd "$cmd"; then
        NEED_INSTALL=true
        break
    fi
done

if [ "$NEED_INSTALL" = true ]; then
    echo -e "${YELLOW} ℹ 发现系统基础依赖不完整，进入独立安装流程...${NC}"
    if [ "$OS_TYPE" = "debian" ]; then
        install_deps_debian
    else
        install_deps_alpine
    fi
else
    echo -e "${GREEN} ✔ [已通过] 基础系统依赖完整，无需重复安装。${NC}"
fi

# ==================================================
# 2. 后端 Emby-Proxy 状态检查与下载
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 2/3] 正在检查与配置 Emby-Proxy 后端程序...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
ARCH=$(uname -m)
PROXY_EXEC="/opt/emby-proxy/emby-proxy"

if [ -x "$PROXY_EXEC" ]; then
    echo -e "${GREEN} ✔ [已通过] $PROXY_EXEC 已存在且具备执行权限。${NC}"
    read -p " 是否需要重新下载/更新最新二进制文件？(y/n, 默认 n): " REDOWNLOAD
else
    REDOWNLOAD="y"
fi

if [[ "$REDOWNLOAD" =~ ^[Yy](es)?$ ]]; then
    echo -e "${YELLOW} ℹ 正在识别架构并下载后端程序...${NC}"
    if [ "$ARCH" = "x86_64" ]; then
        EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-arm64"
    else
        echo -e "${RED} ✖ [错误] 暂不支持当前架构: $ARCH${NC}"
        exit 1
    fi

    rm -f "$PROXY_EXEC"
    wget -O "$PROXY_EXEC" "$EMBY_PROXY_URL"
    if [ $? -eq 0 ]; then
        chmod +x "$PROXY_EXEC"
        echo -e "${GREEN} ✔ 后端 emby-proxy 下载并授权成功。${NC}"
    else
        echo -e "${RED} ✖ [错误] 后端程序下载失败，请检查网络。${NC}"
        exit 1
    fi
fi

# ==================================================
# 3. 自定义监听端口交互配置 (双栈适配)
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 3/3] 配置服务监听端口 (IPv4 & IPv6 双栈)${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
read -p " 请输入服务监听端口 [直接回车默认 7080]: " INPUT_PORT
if [ -z "$INPUT_PORT" ]; then
    INPUT_PORT="7080"
fi
echo -e "${GREEN} ✔ 已设定监听端口为: ${BOLD}$INPUT_PORT${NC}"

# ==================================================
# 4. 服务配置与重启 (Systemd / OpenRC) - 双栈绑定
# ==================================================
if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat <<EOF > /etc/systemd/system/emby-backend.service
[Unit]
Description=Emby Proxy Backend
After=network.target

[Service]
WorkingDirectory=/opt/emby-proxy
Environment="LISTEN_ADDR=:$INPUT_PORT"
# 针对部分 Go 程序需要显式开启 IPv6 双栈支持，可确保内核不单绑 IPv4
Environment="GODEBUG=netdns=go"
ExecStart=$PROXY_EXEC
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now emby-backend >/dev/null 2>&1
    systemctl restart emby-backend >/dev/null 2>&1

else
    cat <<EOF > /etc/init.d/emby-backend
#!/sbin/openrc-run
description="Emby Proxy Backend"
supervisor="supervise-daemon"
command="$PROXY_EXEC"
directory="/opt/emby-proxy"
command_args=""
export LISTEN_ADDR=":$INPUT_PORT"
export GODEBUG="netdns=go"
respawn_delay=5
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/emby-backend

    rc-update add emby-backend default >/dev/null 2>&1
    rc-service emby-backend restart >/dev/null 2>&1
fi

sleep 2

# ==================================================
# 5. 看板信息输出
# ==================================================
echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│ 🎉 部署完毕！双栈监听服务及环境变量已构建完成。        │${NC}"
echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}"

echo -e " ${BOLD}📊 [配置服务运行看板]${NC}"
echo -e " ────────────────────────────────────────────────────────"
echo -e "  📂 程序安装路径:  ${BLUE}/opt/emby-proxy/emby-proxy${NC}"
echo -e "  🌐 监听端口(双栈): ${BLUE}:$INPUT_PORT (IPv4 & IPv6)${NC}"

STATUS_BACKEND=false

if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl is-active --quiet emby-backend && STATUS_BACKEND=true
    DIAG_CMD="journalctl -u emby-backend -n 20"
else
    rc-service emby-backend status >/dev/null 2>&1 && STATUS_BACKEND=true
    DIAG_CMD="rc-service emby-backend status"
fi

if [ "$STATUS_BACKEND" = true ]; then
    echo -e "  ⚡ Proxy 后端状态: ${GREEN}${BOLD}● Running (正常运行)${NC}"
else
    echo -e "  ⚡ Proxy 后端状态: ${RED}${BOLD}● Failed (启动异常，请用 '$DIAG_CMD' 诊断)${NC}"
fi
echo -e " ────────────────────────────────────────────────────────\n"
’’’
