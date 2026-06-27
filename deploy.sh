#!/bin/bash

# 配置
INSTALL_DIR="/opt/emby-proxy"
SERVICE_NAME="emby-proxy"

# 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 权限运行此脚本"
   exit 1
fi

# 自动检测初始化系统
if command -v systemctl >/dev/null 2>&1; then
    INIT_SYS="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
else
    echo "不支持的系统：未找到 systemd 或 OpenRC"
    exit 1
fi

install_emby_proxy() {
    echo "正在环境适配 (当前系统: $INIT_SYS)..."
    
    # 针对 Alpine 安装 glibc 兼容层
    if [ "$INIT_SYS" = "openrc" ]; then
        apk add --no-cache libc6-compat
    fi

    mkdir -p "$INSTALL_DIR"
    
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-arm64"
    else
        echo "不支持的架构: $ARCH"
        exit 1
    fi

    curl -L "$URL" -o "$INSTALL_DIR/emby-proxy"
    chmod +x "$INSTALL_DIR/emby-proxy"

    # 根据系统创建服务
    if [ "$INIT_SYS" = "systemd" ]; then
        cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Emby Proxy Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/emby-proxy
WorkingDirectory=$INSTALL_DIR
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now $SERVICE_NAME
    else
        cat <<EOF > /etc/init.d/$SERVICE_NAME
#!/sbin/openrc-run
name="$SERVICE_NAME"
command="$INSTALL_DIR/emby-proxy"
command_background=true
pidfile="/run/$SERVICE_NAME.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/$SERVICE_NAME
        rc-update add $SERVICE_NAME default
        rc-service $SERVICE_NAME start
    fi
    echo "安装完成，服务已启动。"
}

uninstall_emby_proxy() {
    echo "正在卸载..."
    if [ "$INIT_SYS" = "systemd" ]; then
        systemctl stop $SERVICE_NAME
        systemctl disable $SERVICE_NAME
        rm -f /etc/systemd/system/$SERVICE_NAME.service
        systemctl daemon-reload
    else
        rc-service $SERVICE_NAME stop
        rc-update del $SERVICE_NAME default
        rm -f /etc/init.d/$SERVICE_NAME
    fi
    rm -rf "$INSTALL_DIR"
    echo "卸载完成。"
}

# 菜单
echo "检测到环境: $INIT_SYS"
echo "1) 安装/更新 Emby-Proxy"
echo "2) 卸载 Emby-Proxy"
read -p "选择 [1/2]: " CHOICE

case $CHOICE in
    1) install_emby_proxy ;;
    2) uninstall_emby_proxy ;;
    *) echo "无效选项" ;;
esac
