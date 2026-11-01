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
echo -e "${BLUE}${BOLD}│       Emby-Proxy 后端智能全自检部署脚本          │${NC}"
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
echo -e "\n${BLUE}${BOLD}▶ [步骤 1/2] 正在检查系统基础依赖环境...${NC}"
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
echo -e "\n${BLUE}${BOLD}▶ [步骤 2/2] 正在检查与配置 Emby-Proxy 后端程序...${NC}"
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
# 3. 服务配置与重启 (Systemd / OpenRC)
# ==================================================
if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat <<EOF > /etc/systemd/system/emby-backend.service
[Unit]
Description=Emby Proxy Backend
After=network.target

[Service]
WorkingDirectory=/opt/emby-proxy
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
# 4. 看板信息输出
# ==================================================
echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│ 🎉 部署完毕！Emby-Proxy 二进制及自启动服务已构建完成。 │${NC}"
echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}"

echo -e " ${BOLD}📊 [配置服务运行看板]${NC}"
echo -e " ────────────────────────────────────────────────────────"
echo -e "  📂 程序安装路径:  ${BLUE}/opt/emby-proxy/emby-proxy${NC}"

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
