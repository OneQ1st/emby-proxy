#!/bin/bash

# 仅保留 Emby-Proxy 的安装、卸载与自启动管理
INSTALL_DIR="/opt/emby-proxy"
SERVICE_FILE="/etc/systemd/system/emby-proxy.service"

# 检查权限
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 权限运行此脚本"
   exit 1
fi

install_emby_proxy() {
    echo "正在安装 Emby-Proxy..."
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

    # 创建 Systemd 服务
    cat <<EOF > "$SERVICE_FILE"
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
    systemctl enable --now emby-proxy
    echo "安装完成，服务已启动。"
}

uninstall_emby_proxy() {
    echo "正在卸载..."
    systemctl stop emby-proxy
    systemctl disable emby-proxy
    rm -f "$SERVICE_FILE"
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reload
    echo "卸载完成。"
}

# 菜单
echo "1) 安装/更新 Emby-Proxy"
echo "2) 卸载 Emby-Proxy"
read -p "选择 [1/2]: " CHOICE

case $CHOICE in
    1) install_emby_proxy ;;
    2) uninstall_emby_proxy ;;
    *) echo "无效选项" ;;
esac
