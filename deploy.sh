#!/bin/bash
INSTALL_DIR="/opt/emby-proxy"
SERVICE_NAME="emby-proxy"

if [[ $EUID -ne 0 ]]; then echo "请以 root 权限运行"; exit 1; fi

if command -v systemctl >/dev/null 2>&1; then INIT_SYS="systemd"
elif command -v rc-service >/dev/null 2>&1; then INIT_SYS="openrc"
else echo "不支持的系统"; exit 1; fi

install_emby_proxy() {
    if [ "$INIT_SYS" = "openrc" ]; then apk add --no-cache libc6-compat; fi
    mkdir -p "$INSTALL_DIR"
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-amd64" || URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-arm64"
    curl -L "$URL" -o "$INSTALL_DIR/emby-proxy" && chmod +x "$INSTALL_DIR/emby-proxy"

    if [ "$INIT_SYS" = "systemd" ]; then
        cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Emby Proxy Service
After=network.target
[Service]
ExecStart=$INSTALL_DIR/emby-proxy --config /etc/emby-proxy/config.json
WorkingDirectory=$INSTALL_DIR
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable --now $SERVICE_NAME
    else
        # 优化后的 OpenRC 脚本
        cat <<EOF > /etc/init.d/$SERVICE_NAME
#!/sbin/openrc-run
name="$SERVICE_NAME"
description="Emby Proxy Service"
command="$INSTALL_DIR/emby-proxy"
command_args="--config /etc/emby-proxy/config.json"
directory="$INSTALL_DIR"
supervisor="supervise-daemon"
pidfile="/run/$SERVICE_NAME.pid"

depend() { need net; }
EOF
        chmod +x /etc/init.d/$SERVICE_NAME && rc-update add $SERVICE_NAME default && rc-service $SERVICE_NAME restart
    fi
    echo "安装/更新完成。"
}

echo "1) 安装/更新 | 2) 卸载"; read -p "选择: " CHOICE
case $CHOICE in 1) install_emby_proxy ;; 2) echo "执行卸载逻辑...";; *) echo "无效";; esac
