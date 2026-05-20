#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\033[0;32m====================================================\033[0m"
echo -e "\033[0;36m  Emby-Proxy + Caddy(含CF插件) 智能全检查部署脚本   \033[0m"
echo -e "\033[0;32m====================================================\033[0m"

# 创建标准目录（若不存在）
mkdir -p /etc/caddy
mkdir -p /opt/emby-proxy
mkdir -p /opt/emby-proxy/ssl

# 检查命令是否存在的便捷函数
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ==================== 1. 基础依赖检查与环境补全 ====================
echo -e "${YELLOW}>>> [步骤 1/5] 正在检查系统基础依赖环境...${NC}"

NEED_INSTALL=()
for cmd in curl tar wget git openssl jq gpg; do
    if ! check_cmd "$cmd"; then
        NEED_INSTALL+=("$cmd")
    fi
done

if [ ${#NEED_INSTALL[@]} -ne 0 ]; then
    echo -e "${YELLOW}发现缺失基础依赖: ${NEED_INSTALL[*]}，正在补充安装...${NC}"
    apt update -y
    apt install -y curl tar wget git openssl jq psmisc debian-keyring debian-archive-keyring apt-transport-https || {
        echo -e "${RED}[错误] 基础依赖安装失败！请检查系统网络或软件源。${NC}"
        exit 1
    }
else
    echo -e "${GREEN}[已通过] 基础系统依赖完整，无需重复安装。${NC}"
fi


# ==================== 2. Caddy 及其插件就绪状态检查 ====================
echo -e "${YELLOW}>>> [步骤 2/5] 正在检查 Caddy 服务及 Cloudflare 插件状态...${NC}"
CADDY_READY=false

if check_cmd "caddy"; then
    echo -e "${YELLOW}检测到系统已安装 Caddy，正在校验 Cloudflare 插件...${NC}"
    if /usr/bin/caddy list-modules | grep -q "dns.providers.cloudflare"; then
        echo -e "${GREEN}[已通过] 检测到完全符合要求的 Caddy (已集成 Cloudflare 插件)，跳过安装。${NC}"
        CADDY_READY=true
    else
        echo -e "${YELLOW}提示：已安装 Caddy，但未检测到 cloudflare 插件。将为您在线热补丁集成...${NC}"
    fi
fi

if [ "$CADDY_READY" = false ]; then
    if ! check_cmd "caddy"; then
        echo -e "${YELLOW}正在配置 Caddy 官方 APT 存储库...${NC}"
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update -y && apt install -y caddy || { echo -e "${RED}[错误] 标准版 Caddy 安装失败！${NC}"; exit 1; }
    fi

    echo -e "${YELLOW}正在向 Caddy 注入 cloudflare 插件 (进程需要一分钟左右，请稍候)...${NC}"
    /usr/bin/caddy add-package github.com/caddy-dns/cloudflare || {
        echo -e "${RED}[错误] 插件集成失败！请检查您的 VPS 到 github.com 的网络连接。${NC}"
        exit 1
    }
    echo -e "${GREEN}Caddy 及其插件环境配置成功！${NC}"
fi


# ==================== 3. 后端 Emby-Proxy 状态检查 ====================
echo -e "${YELLOW}>>> [步骤 3/5] 正在检查 Emby-Proxy 后端程序...${NC}"
ARCH=$(uname -m)

if [ -x "/opt/emby-proxy/emby-proxy" ]; then
    echo -e "${GREEN}[已通过] 检测到 /opt/emby-proxy/emby-proxy 已存在且具备执行权限，跳过下载。${NC}"
else
    echo -e "${YELLOW}未检测到后端程序，正在识别架构并下载...${NC}"
    if [ "$ARCH" = "x86_64" ]; then
        EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-arm64"
    else
        echo -e "${RED}[错误] 暂不支持当前架构: $ARCH${NC}"
        exit 1
    fi

    rm -f /opt/emby-proxy/emby-proxy
    wget -O /opt/emby-proxy/emby-proxy "$EMBY_PROXY_URL" && chmod +x /opt/emby-proxy/emby-proxy
    echo -e "${GREEN}后端 emby-proxy 下载并授权成功。${NC}"
fi


# ==================== 4. 域名输入与证书智能扫描 ====================
echo -e "${YELLOW}>>> [步骤 4/5] 配置参数收集与现有证书扫描...${NC}"
read -p "请输入您的域名 (例如: example.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[错误] 域名不能为空！${NC}"
    exit 1
fi

# 证书目标路径
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

echo -e "${YELLOW}正在扫描本地常见路径，寻找匹配 [$DOMAIN] 的有效证书...${NC}"
for idx in "${!POSSIBLE_CERTS[@]}"; do
    cert_path="${POSSIBLE_CERTS[$idx]}"
    key_path="${POSSIBLE_KEYS[$idx]}"
    
    if [ -s "$cert_path" ] && [ -s "$key_path" ]; then
        if openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -q "$DOMAIN"; then
            echo -e "${GREEN}[已通过] 发现匹配域名的本地有效证书: $cert_path${NC}"
            if [ "$cert_path" != "$CERT_FILE" ]; then
                ln -sf "$cert_path" "$CERT_FILE"
                ln -sf "$key_path" "$KEY_FILE"
            fi
            USE_EXISTING_CERT=true
            break
        fi
    fi
done

# 未扫描到证书，进入增强回落交互（支持路径指定或纯文本粘贴）
if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "${YELLOW}提示：未在系统常见路径下自动发现匹配域名 [$DOMAIN] 的本地证书。${NC}"
    read -p "是否需要手动配置/粘贴 Cloudflare 源服务器证书？(y/n, 默认 n): " PROVIDE_CERT
    
    if [[ "$PROVIDE_CERT" =~ ^[Yy](es)?$ ]]; then
        echo -e "\n请选择提供证书的方式:"
        echo -e "1) 输入已有证书和私钥的【绝对文件路径】"
        echo -e "2) 直接【手动粘贴】Cloudflare 源服务器证书/私钥文本内容"
        read -p "请选择 [1/2]: " CERT_INPUT_MODE
        
        if [ "$CERT_INPUT_MODE" == "1" ]; then
            read -p "请输入证书完整路径 (fullchain.pem 或 .crt): " USER_CERT
            read -p "请输入私钥完整路径 (privkey.pem 或 .key): " USER_KEY
            
            if [ -s "$USER_CERT" ] && [ -s "$USER_KEY" ]; then
                ln -sf "$USER_CERT" "$CERT_FILE"
                ln -sf "$USER_KEY" "$KEY_FILE"
                echo -e "${GREEN}>>> 自定义本地证书文件导入成功！${NC}"
                USE_EXISTING_CERT=true
            else
                echo -e "${RED}>>> 输入的路径文件不存在或不可读，系统将退回到 Caddy 自动申请方案。${NC}"
            fi
            
        elif [ "$CERT_INPUT_MODE" == "2" ]; then
            echo -e "${YELLOW}\n[提示] 请粘贴您的证书内容 (以 -----BEGIN CERTIFICATE----- 开头)，完成后换行输入 EOF 并回车确认:${NC}"
            rm -f "$CERT_FILE"
            while IFS= read -r line; do
                [[ "$line" == "EOF" ]] && break
                echo "$line" >> "$CERT_FILE"
            done
            
            echo -e "${YELLOW}\n[提示] 请粘贴您的私钥内容 (以 -----BEGIN PRIVATE KEY----- 开头)，完成后换行输入 EOF 并回车确认:${NC}"
            rm -f "$KEY_FILE"
            while IFS= read -r line; do
                [[ "$line" == "EOF" ]] && break
                echo "$line" >> "$KEY_FILE"
            done
            
            # 校验粘贴内容的合法性
            if [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] && openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
                echo -e "${GREEN}>>> 粘贴的 Cloudflare 源服务器证书及私钥解析并保存成功！${NC}"
                USE_EXISTING_CERT=true
            else
                echo -e "${RED}>>> 证书解析失败（可能复制不全或格式错误），系统将退回到 Caddy 自动申请方案。${NC}"
                rm -f "$CERT_FILE" "$KEY_FILE"
            fi
        else
            echo -e "${RED}输入错误，退回到自动申请方案。${NC}"
        fi
    fi
fi

# 其余运行参数收集
read -p "请输入 HTTPS 外部访问端口 (默认 443): " EX_PORT
EX_PORT=${EX_PORT:-443}
read -p "请输入 HTTP 默认端口 (若 80 被占用可自定义修改，默认 80): " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-80}
read -p "请输入邮箱 (用于自动化证书申请/续期通知): " MY_EMAIL

if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "\n请选择 Caddy 证书申请验证方式:"
    echo -e "1) Cloudflare DNS 挑战 (推荐，无需开放 80 端口)"
    echo -e "2) HTTP 自动挑战 (请确保上述指定的 HTTP 端口能接收外部 80 端口的流量)"
    read -p "选择 [1/2]: " AUTH_MODE
fi


# ==================== 5. 动态生成符合规范的 Caddyfile ====================
echo -e "${YELLOW}>>> [步骤 5/5] 正在生成全局标准化 Caddyfile 配置...${NC}"

GLOBAL_BLOCK="email $MY_EMAIL
    http_port $HTTP_PORT
    https_port $EX_PORT"

if [ "$USE_EXISTING_CERT" = true ]; then
    # 场景 A：复用本地已有、手动指定、或刚刚粘贴的证书文件
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
    # 场景 B：完全交给 Caddy 自动托管申请
    if [ "$AUTH_MODE" == "1" ]; then
        read -p "请输入 Cloudflare API Token (需具备该域名 DNS:Edit 权限): " CF_TOKEN
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


# ==================== 6. Systemd 服务配置与最终检查 ====================
# 后端 Systemd
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

# 前端 Systemd
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

# 服务加载与重启
systemctl daemon-reload
systemctl enable --now emby-backend caddy
systemctl restart emby-backend caddy

sleep 1.5

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}【全自检运行成功】标准路径部署完毕。${NC}"
echo -e "访问地址: ${YELLOW}https://$DOMAIN:$EX_PORT${NC}"
echo -e "----------------------------------------------------"
echo -e "Caddy 配置路径:  /etc/caddy/Caddyfile"
echo -e "服务运行状态检测:"
if systemctl is-active --quiet caddy; then
    echo -e "  Caddy 前端状态:   ${GREEN}● Running (正常)${NC}"
else
    echo -e "  Caddy 前端状态:   ${RED}● Failed (异常，请执行 journalctl -u caddy 查看原因)${NC}"
fi

if systemctl is-active --quiet emby-backend; then
    echo -e "  Proxy 后端状态:   ${GREEN}● Running (正常)${NC}"
else
    echo -e "  Proxy 后端状态:   ${RED}● Failed (异常)${NC}"
fi
echo -e "====================================================${NC}"
