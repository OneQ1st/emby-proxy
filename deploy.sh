#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\033[0;32m====================================================\033[0m"
echo -e "\033[0;36m  Emby-Proxy + Caddy(含CF插件) 部署脚本 (智能证书版) \033[0m"
echo -e "\033[0;32m====================================================\033[0m"

# ==================== 1. 基础依赖检查与安装 ====================
echo -e "${YELLOW}>>> [步骤 1/5] 正在检查并安装基础依赖...${NC}"

# 检查命令是否存在的函数
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

NEED_INSTALL=()
for cmd in curl tar wget git openssl jq; do
    if ! check_cmd "$cmd"; then
        NEED_INSTALL+=("$cmd")
    fi
done

if [ ${#NEED_INSTALL[@]} -ne 0 ]; then
    echo -e "${YELLOW}检测到缺失依赖: ${NEED_INSTALL[*]}，正在尝试安装...${NC}"
    apt update -y
    apt install -y curl tar wget git openssl jq psmisc || {
        echo -e "${RED}[错误] 依赖安装失败！请检查系统源或网络后重试。${NC}"
        exit 1
    }
else
    echo -e "${GREEN}所有基础依赖检查通过！${NC}"
fi

# 创建标准目录
mkdir -p /etc/caddy
mkdir -p /opt/emby-proxy
mkdir -p /opt/emby-proxy/ssl

# ==================== 2. 架构自动检测与二进制下载 ====================
echo -e "${YELLOW}>>> [步骤 2/5] 正在检测系统架构并下载核心组件...${NC}"
ARCH=$(uname -m)
CADDY_VER="2.7.6"

echo -e "${YELLOW}当前系统架构: $ARCH${NC}"

if [ "$ARCH" = "x86_64" ]; then
    EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-amd64"
    CADDY_URL="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcaddy-dns%2Fcloudflare&idempotency=emby_caddy_amd64"
elif [ "$ARCH" = "aarch64" ]; then
    EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-arm64"
    CADDY_URL="https://caddyserver.com/api/download?os=linux&arch=arm64&p=github.com%2Fcaddy-dns%2Fcloudflare&idempotency=emby_caddy_arm64"
else
    echo -e "${RED}[错误] 暂不支持当前架构: $ARCH${NC}"
    exit 1
fi

echo -e "${YELLOW}正在下载后端 emby-proxy...${NC}"
rm -f /opt/emby-proxy/emby-proxy
wget -O /opt/emby-proxy/emby-proxy "$EMBY_PROXY_URL" && chmod +x /opt/emby-proxy/emby-proxy

echo -e "${YELLOW}正在从 Caddy 官方下载带 Cloudflare 插件的 Caddy 二进制文件...${NC}"
rm -f /usr/bin/caddy
wget -O /usr/bin/caddy "$CADDY_URL" && chmod +x /usr/bin/caddy

if ! /usr/bin/caddy list-modules | grep -q "dns.providers.cloudflare"; then
    echo -e "${RED}[错误] Caddy 环境校验失败，请检查网络或重新运行。${NC}"
    exit 1
fi
echo -e "${GREEN}核心组件下载完成并校验成功。${NC}"

# ==================== 3. 收集参数与智能证书检测 ====================
echo -e "${YELLOW}>>> [步骤 3/5] 配置参数收集与现有证书扫描...${NC}"
read -p "请输入您的域名 (例如: example.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}域名不能为空！${NC}"
    exit 1
fi

# --- 证书自动扫描开始 ---
CERT_FILE="/opt/emby-proxy/ssl/fullchain.pem"
KEY_FILE="/opt/emby-proxy/ssl/privkey.pem"

POSSIBLE_CERTS=(
    "$CERT_FILE"
    "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    "/etc/acme.sh/${DOMAIN}_ecc/fullchain.cer"
    "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    "$HOME/.acme.sh/${DOMAIN}/fullchain.cer"
    "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    "/etc/ssl/$DOMAIN/fullchain.pem"
)

POSSIBLE_KEYS=(
    "$KEY_FILE"
    "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    "/etc/acme.sh/${DOMAIN}_ecc/$DOMAIN.key"
    "$HOME/.acme.sh/${DOMAIN}_ecc/$DOMAIN.key"
    "$HOME/.acme.sh/${DOMAIN}/$DOMAIN.key"
    "/root/.acme.sh/${DOMAIN}_ecc/$DOMAIN.key"
    "/etc/ssl/$DOMAIN/privkey.pem"
)

USE_EXISTING_CERT=false

echo -e "${YELLOW}正在扫描 VPS 常见标准路径，寻找匹配 [$DOMAIN] 的证书...${NC}"
for idx in "${!POSSIBLE_CERTS[@]}"; do
    cert_path="${POSSIBLE_CERTS[$idx]}"
    key_path="${POSSIBLE_KEYS[$idx]}"
    
    if [ -s "$cert_path" ] && [ -s "$key_path" ]; then
        # 校验证书是否包含当前域名
        if openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -q "$DOMAIN"; then
            echo -e "${GREEN}发现匹配域名的有效证书: $cert_path${NC}"
            # 如果不是目标路径，则建立软链接
            if [ "$cert_path" != "$CERT_FILE" ]; then
                ln -sf "$cert_path" "$CERT_FILE"
                ln -sf "$key_path" "$KEY_FILE"
            fi
            USE_EXISTING_CERT=true
            break
        fi
    fi
done

# --- 未检测到证书，提示手动输入 ---
if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "${YELLOW}未在系统标准路径下找到匹配域名 [$DOMAIN] 的有效证书。${NC}"
    read -p "是否需要手动配置自定义证书路径？(y/n, 默认 n): " PROVIDE_CERT
    
    if [[ "$PROVIDE_CERT" =~ ^[Yy](es)?$ ]]; then
        read -p "请输入证书完整路径 (fullchain.pem 或 .crt): " USER_CERT
        read -p "请输入私钥完整路径 (privkey.pem 或 .key): " USER_KEY
        
        if [ -s "$USER_CERT" ] && [ -s "$USER_KEY" ]; then
            ln -sf "$USER_CERT" "$CERT_FILE"
            ln -sf "$USER_KEY" "$KEY_FILE"
            echo -e "${GREEN}>>> 自定义证书路径导入成功！${NC}"
            USE_EXISTING_CERT=true
        else
            echo -e "${RED}>>> 输入的路径无效或文件为空，将切入 Caddy 自动申请流程。${NC}"
        fi
    fi
fi

# 其余端口和邮箱参数收集
read -p "请输入 HTTPS 外部访问端口 (默认 443): " EX_PORT
EX_PORT=${EX_PORT:-443}
read -p "请输入 HTTP 默认端口 (若被占用可修改，默认 80): " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-80}
read -p "请输入邮箱 (用于 ACME 证书申请通知): " MY_EMAIL

if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "\n请选择 Caddy 证书申请验证方式:"
    echo -e "1) Cloudflare DNS 验证 (无需开放 80 端口，支持 CDN/内网)"
    echo -e "2) HTTP 自动挑战验证 (请确保上方的 HTTP 端口在公网可通过 80 端口映射访问)"
    read -p "选择 [1/2]: " AUTH_MODE
fi

# ==================== 4. 动态生成 Caddyfile 配置 ====================
echo -e "${YELLOW}>>> [步骤 4/5] 正在生成标准全局 Caddyfile 配置...${NC}"

# 基础全局块配置
GLOBAL_BLOCK="email $MY_EMAIL
    http_port $HTTP_PORT
    https_port $EX_PORT"

if [ "$USE_EXISTING_CERT" = true ]; then
    # 使用本地已有证书或手动证书
    cat <<CADDY_EOF > /etc/caddy/Caddyfile
{
    $GLOBAL_BLOCK
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

else
    # 走 Caddy 自动申请逻辑
    if [ "$AUTH_MODE" == "1" ]; then
        read -p "请输入 Cloudflare API Token (需具备 DNS:Edit 权限): " CF_TOKEN
        cat <<CADDY_EOF > /etc/caddy/Caddyfile
{
    $GLOBAL_BLOCK
    acme_dns cloudflare $CF_TOKEN
}

$DOMAIN:$EX_PORT {
    reverse_proxy 127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        flush_interval -1
    }
}
CADDY_EOF
    else
        cat <<CADDY_EOF > /etc/caddy/Caddyfile
{
    $GLOBAL_BLOCK
}

$DOMAIN:$EX_PORT {
    tls {
        acme_ca https://acme-v02.api.letsencrypt.org/directory
    }

    reverse_proxy 127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        flush_interval -1
    }
}
CADDY_EOF
    fi
fi

# ==================== 5. 配置 Systemd 服务并启动 ====================
echo -e "${YELLOW}>>> [步骤 5/5] 正在配置系统守护进程并启动...${NC}"

# 后端代理服务
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

# 前端标准 Caddy 服务
cat <<SVC_EOF > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SVC_EOF

# 启动服务
systemctl daemon-reload
systemctl enable --now emby-backend caddy

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}部署完成！系统已恢复运行。${NC}"
echo -e "访问地址: ${YELLOW}https://$DOMAIN:$EX_PORT${NC}"
if [ "$USE_EXISTING_CERT" = true ]; then
    echo -e "证书状态: ${GREEN}已成功复用本地证书进行配置${NC}"
else
    echo -e "证书状态: ${YELLOW}正在通过 Caddy 进行后台托管申请...${NC}"
fi
echo -e "----------------------------------------------------"
echo -e "Caddy 配置文件路径:  /etc/caddy/Caddyfile"
echo -e "管理命令:"
echo -e "  查看前端日志:  journalctl -u caddy --no-pager -n 30"
echo -e "  查看后端日志:  journalctl -u emby-backend --no-pager -n 30"
echo -e "  重启所有服务:  systemctl restart emby-backend caddy"
echo -e "${GREEN}====================================================${NC}"
