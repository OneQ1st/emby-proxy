#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\033[0;32m====================================================\033[0m"
echo -e "\033[0;36m    Emby-Proxy + Caddy 部署脚本 (证书整合版)    \033[0m"
echo -e "\033[0;32m====================================================\033[0m"

# 1. 基础依赖与环境
echo -e "\033[0;33m>>> 正在安装基础依赖...\033[0m"
apt update -y

apt install -y curl socat net-tools tar wget git ca-certificates psmisc || {
    echo -e "\033[0;31m依赖安装失败！请检查网络或手动执行以下命令：\033[0m"
    echo -e "apt install -y curl socat net-tools tar wget git ca-certificates psmisc"
    exit 1
}

mkdir -p /opt/emby-proxy/ssl

# 2. 自动赋权
echo -e "\033[0;33m>>> 正在给上传的文件赋权...\033[0m"
chmod +x /opt/emby-proxy/emby-proxy 2>/dev/null || true
chmod +x /opt/emby-proxy/caddy 2>/dev/null || true

# 3. 安装/升级 acme.sh
ACME_DIR="$HOME/.acme.sh"
ACME_BIN="$ACME_DIR/acme.sh"

if [ ! -f "$ACME_BIN" ] || [ ! -x "$ACME_BIN" ]; then
    echo -e "\033[0;33m>>> 正在安装 acme.sh...\033[0m"
    rm -rf "$ACME_DIR" /tmp/acme.sh 2>/dev/null
    
    if ! git clone https://github.com/acmesh-official/acme.sh.git /tmp/acme.sh; then
        echo -e "\033[0;31mgit clone 失败！请检查网络连接后重试\033[0m"
        exit 1
    fi
    
    cd /tmp/acme.sh || exit 1
    ./acme.sh --install --nocron
    cd /root || exit 1
    rm -rf /tmp/acme.sh
    echo -e "\033[0;32m>>> acme.sh 安装完成\033[0m"
fi

export PATH="$ACME_DIR:$PATH"
"$ACME_BIN" --upgrade 2>/dev/null || true

# 4. 收集参数
read -p "请输入域名 (例如: example.com): " DOMAIN
read -p "请输入外部端口 (默认 443): " EX_PORT
EX_PORT=${EX_PORT:-443}
read -p "请输入邮箱 (用于 Let's Encrypt 通知): " MY_EMAIL

echo -e "\n请选择证书申请方式:"
echo -e "1) Cloudflare DNS (推荐)"
echo -e "2) HTTP Standalone（推荐，如果 80 端口可用）"
read -p "选择 [1/2]: " AUTH_MODE

# === 证书检测部分（最终稳定版）===
CERT_FILE="/opt/emby-proxy/ssl/fullchain.pem"
KEY_FILE="/opt/emby-proxy/ssl/privkey.pem"

POSSIBLE_CERTS=(
    "$CERT_FILE"
    "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    "\( HOME/.acme.sh/ \){DOMAIN}_ecc/fullchain.cer"
    "\( HOME/.acme.sh/ \){DOMAIN}/fullchain.cer"
    "$HOME/$DOMAIN/$DOMAIN.crt"
    "$HOME/$DOMAIN/fullchain.cer"
    "/etc/ssl/$DOMAIN/fullchain.pem"
    "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
)

POSSIBLE_KEYS=(
    "$KEY_FILE"
    "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    "\( HOME/.acme.sh/ \){DOMAIN}_ecc/$DOMAIN.key"
    "\( HOME/.acme.sh/ \){DOMAIN}/$DOMAIN.key"
    "$HOME/$DOMAIN/$DOMAIN.key"
    "$HOME/$DOMAIN/privkey.key"
    "/etc/ssl/$DOMAIN/privkey.pem"
    "/root/.acme.sh/${DOMAIN}_ecc/$DOMAIN.key"
)

SKIP_CERT=false

echo -e "\033[0;33m>>> 正在检测现有证书...\033[0m"

for idx in "${!POSSIBLE_CERTS[@]}"; do
    cert_path="${POSSIBLE_CERTS[$idx]}"
    key_path="${POSSIBLE_KEYS[$idx]}"
    
    if [ -s "$cert_path" ] && [ -s "$key_path" ]; then
        # 简单校验域名是否匹配（避免复杂正则报错）
        if openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -q "$DOMAIN"; then
            echo -e "\033[0;32m>>> 发现匹配当前域名($DOMAIN)的证书: $cert_path\033[0m"
            if [ "$cert_path" != "$CERT_FILE" ]; then
                ln -sf "$cert_path" "$CERT_FILE"
                ln -sf "$key_path" "$KEY_FILE"
            fi
            SKIP_CERT=true
            break
        else
            echo -e "\033[0;33m>>> 找到证书 $cert_path，但不匹配域名 $DOMAIN，跳过...\033[0m"
        fi
    fi
done

# 手动提供证书逻辑
if [ "$SKIP_CERT" = false ]; then
    echo -e "\033[0;33m>>> 未检测到匹配域名 $DOMAIN 的有效证书。\033[0m"
    read -p "是否手动提供证书路径？(y/n，默认 n): " PROVIDE_CERT
    
    # 使用最安全的判断方式
    if [ "$PROVIDE_CERT" = "y" ] || [ "$PROVIDE_CERT" = "Y" ] || [ "$PROVIDE_CERT" = "yes" ]; then
        echo -e "\033[0;36m请输入证书文件完整路径 (fullchain.pem 或 .crt)：\033[0m"
        read -p "证书路径: " USER_CERT
        
        echo -e "\033[0;36m请输入私钥文件完整路径 (privkey.pem 或 .key)：\033[0m"
        read -p "私钥路径: " USER_KEY

        if [ -s "$USER_CERT" ] && [ -s "$USER_KEY" ]; then
            ln -sf "$USER_CERT" "$CERT_FILE"
            ln -sf "$USER_KEY" "$KEY_FILE"
            echo -e "\033[0;32m>>> 手动证书已设置成功！\033[0m"
            SKIP_CERT=true
        else
            echo -e "\033[0;31m>>> 输入路径无效或文件不存在，将继续自动申请证书...\033[0m"
        fi
    fi
fi

# 如果仍然没有证书，则自动申请
if [ "$SKIP_CERT" = false ]; then
    echo -e "\033[0;33m>>> 将使用 acme.sh 自动申请新证书...\033[0m"
    echo -e "\033[0;33m>>> 注册 Let's Encrypt 账号...\033[0m"
    "$ACME_BIN" --register-account -m "$MY_EMAIL" --server letsencrypt --force
    "$ACME_BIN" --set-default-ca --server letsencrypt

    echo -e "\033[0;33m>>> 开始申请证书...\033[0m"
    "$ACME_BIN" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1

    if [ "$AUTH_MODE" == "1" ]; then
        echo -e "\033[0;33m>>> 模式: Cloudflare DNS\033[0m"
        read -p "请输入 Cloudflare Token: " CF_Key
        export CF_Token="$CF_Key"

        "$ACME_BIN" --issue --dns dns_cf -d "$DOMAIN" --force --ecc
    else
        echo -e "\033[0;33m>>> 模式: HTTP Standalone\033[0m"
        fuser -k 80/tcp 2>/dev/null || true
        "$ACME_BIN" --issue -d "$DOMAIN" --standalone --httpport 80 --force --ecc
    fi

    "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_FILE" \
        --key-file "$KEY_FILE" \
        --reloadcmd "systemctl reload caddy-proxy 2>/dev/null || true"

    if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
        echo -e "\033[0;31m[错误] 证书申请失败！\033[0m"
        exit 1
    fi

    echo -e "\033[0;32m>>> 证书申请并安装成功！\033[0m"
fi

# 6. 生成 Caddyfile
cat <<CADDY_EOF > /opt/emby-proxy/Caddyfile
{
    # 避免自动监听80端口
    http_port 40890 
}
$DOMAIN:$EX_PORT {
    tls $CERT_FILE $KEY_FILE
    reverse_proxy 127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        flush_interval -1
    }
}
CADDY_EOF

# 7. Systemd 服务
cat <<SVC_EOF > /etc/systemd/system/emby-backend.service
[Unit]
Description=Emby Proxy Backend
After=network.target

[Service]
WorkingDirectory=/opt/emby-proxy
ExecStart=/opt/emby-proxy/emby-proxy
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

cat <<SVC_EOF > /etc/systemd/system/caddy-proxy.service
[Unit]
Description=Caddy SSL Frontend
After=network.target

[Service]
WorkingDirectory=/opt/emby-proxy
ExecStart=/opt/emby-proxy/caddy run --config /opt/emby-proxy/Caddyfile --adapter caddyfile
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

# 启动服务
chmod +x /opt/emby-proxy/emby-proxy 2>/dev/null || true
chmod +x /opt/emby-proxy/caddy 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now emby-backend caddy-proxy

echo -e "\033[0;32m部署完成！\033[0m"
echo -e "访问地址: https://$DOMAIN:$EX_PORT"
echo -e "万能反代示例: https://$DOMAIN:$EX_PORT/https/目标域名/443/..."
echo -e "重启命令: systemctl restart emby-backend caddy-proxy"