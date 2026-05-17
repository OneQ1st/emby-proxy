#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\033[0;32m====================================================\033[0m"
echo -e "\033[0;36m    Emby-Proxy + Nginx 部署脚本 (架构自适应终极版)    \033[0m"
echo -e "\033[0;32m====================================================\033[0m"

# 1. 基础环境与 Nginx 本地存在性检查及安装
echo -e "\033[0;33m>>> 正在检查基础环境依赖与 Nginx 状态...\033[0m"

# 待安装的基础依赖列表
INSTALL_PACKAGES="curl socat net-tools tar wget git ca-certificates psmisc"

# 检查 Nginx 是否已存在于系统
if command -v nginx >/dev/null 2>&1; then
    echo -e "${GREEN}>>> 检测到本地已安装 Nginx，将跳过 Nginx 核心安装，仅进行依赖补齐与配置更新。${NC}"
else
    echo -e "${YELLOW}>>> 未检测到 Nginx，已将其加入安装队列...${NC}"
    INSTALL_PACKAGES="$INSTALL_PACKAGES nginx"
fi

apt update -y
apt install -y $INSTALL_PACKAGES || {
    echo -e "\033[0;31m依赖或 Nginx 安装失败！请检查网络或手动执行以下命令：\033[0m"
    echo -e "apt install -y $INSTALL_PACKAGES"
    exit 1
}

# 移除 Nginx 可能自带的默认冲突站点配置
if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# 创建项目及 SSL 证书默认目录
mkdir -p /opt/emby-proxy/ssl
cd /opt/emby-proxy || exit 1

# 2. 架构自动检测与对应后端文件下载
ARCH=$(uname -m)
echo -e "\033[0;33m>>> 检测到系统架构为: $ARCH\033[0m"

if [ "$ARCH" = "x86_64" ]; then
    EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-amd64"
elif [ "$ARCH" = "aarch64" ]; then
    EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-arm64"
else
    echo -e "\033[0;31m暂不支持当前架构: $ARCH，请手动编译或获取对应二进制文件！\033[0m"
    exit 1
fi

echo -e "\033[0;33m>>> 正在从 GitHub 下载对应的 emby-proxy 后端...\033[0m"
rm -f emby-proxy
wget -O emby-proxy "$EMBY_PROXY_URL"
chmod +x emby-proxy

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
    cd /opt/emby-proxy || exit 1
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

# === 证书检测部分 ===
CERT_FILE="/opt/emby-proxy/ssl/fullchain.pem"
KEY_FILE="/opt/emby-proxy/ssl/privkey.pem"

POSSIBLE_CERTS=(
    "$CERT_FILE"
    "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    "$HOME/.acme.sh/${DOMAIN}/fullchain.cer"
    "$HOME/$DOMAIN/$DOMAIN.crt"
    "$HOME/$DOMAIN/fullchain.cer"
    "/etc/ssl/$DOMAIN/fullchain.pem"
    "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
)

POSSIBLE_KEYS=(
    "$KEY_FILE"
    "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    "$HOME/.acme.sh/${DOMAIN}_ecc/$DOMAIN.key"
    "$HOME/.acme.sh/${DOMAIN}/$DOMAIN.key"
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
        # 申请前优雅停止 nginx 以释放 80 端口，双重保险配合 fuser
        systemctl stop nginx 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true
        "$ACME_BIN" --issue -d "$DOMAIN" --standalone --httpport 80 --force --ecc
    fi

    # 证书申请/续期成功后的回调，保证 nginx 能够重新载入新证书
    "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_FILE" \
        --key-file "$KEY_FILE" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true"

    if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
        echo -e "\033[0;31m[错误] 证书申请失败！\033[0m"
        exit 1
    fi

    echo -e "\033[0;32m>>> 证书申请并安装成功！\033[0m"
fi

# 5. 生成 Nginx 配置文件
echo -e "\033[0;33m>>> 正在生成 Nginx 配置文件...\033[0m"

# 根据自定义外部端口动态拼接透传 Header 逻辑
PORT_HEADER=""
if [ "$EX_PORT" != "443" ]; then
    PORT_HEADER="proxy_set_header X-Forwarded-Port \$server_port;"
fi

cat <<NGINX_EOF > /etc/nginx/conf.d/emby-proxy.conf
server {
    listen $EX_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    # SSL 基础安全调优
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;

        # 媒体流特殊优化选项（关闭双向缓冲、限制临时分块临时文件大小，防止流媒体卡顿）
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 非 443 端口自适应透传
        $PORT_HEADER
    }
}
NGINX_EOF

# 6. 配置 Emby 后端 Systemd 服务
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

# 7. 启动与重载服务
echo -e "\033[0;33m>>> 正在启动 Emby 后端并校验 Nginx...\033[0m"
systemctl daemon-reload
systemctl enable --now emby-backend

# 强校验 Nginx 语法
nginx -t >/dev/null 2>&1
if [ $? -eq 0 ]; then
    systemctl enable nginx
    systemctl restart nginx
else
    echo -e "${RED}[错误] Nginx 配置语法校验失败，请检查 /etc/nginx/conf.d/emby-proxy.conf 的合规性！${NC}"
    exit 1
fi

echo -e "\033[0;32m====================================================\033[0m"
echo -e "\033[0;32m部署完成！\033[0m"
echo -e "访问地址: https://$DOMAIN:$EX_PORT"
echo -e "万能反代示例: https://$DOMAIN:$EX_PORT/https/目标域名/443/..."
echo -e "管理后端命令: systemctl restart/status emby-backend"
echo -e "管理前端命令: systemctl restart/reload nginx"
echo -e "\033[0;32m====================================================\033[0m"
