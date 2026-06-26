#!/bin/bash

# 颜色定义
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[36m'
PURPLE='\e[35m'
BOLD='\e[1m'
NC='\e[0m'

clear
echo -e "${BLUE}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${BLUE}${BOLD}│  Emby-Proxy + Nginx 智能多轨部署脚本 (核心纯净版)       │${NC}"
echo -e "${BLUE}${BOLD}└────────────────────────────────────────────────────────┘${NC}"

# ==================== 系统环境智能识别 ====================
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    INIT_SYSTEM="openrc"
    NGINX_CONF_DIR="/etc/nginx/http.d"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS_TYPE="debian"
    INIT_SYSTEM="systemd"
    NGINX_CONF_DIR="/etc/nginx/conf.d"
else
    if command -v apk >/dev/null 2>&1; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
        NGINX_CONF_DIR="/etc/nginx/http.d"
    else
        OS_TYPE="debian"
        INIT_SYSTEM="systemd"
        NGINX_CONF_DIR="/etc/nginx/conf.d"
    fi
fi

# ==================== 0. 互动式功能选择 ====================
echo -e "\n${BLUE}${BOLD}📊 请选择要执行的操作：${NC}"
echo -e "  ${BOLD}1)${NC} ${GREEN}智能双配置自检部署 / 更新环境${NC}"
echo -e "  ${BOLD}2)${NC} ${RED}一键完全卸载 (清理服务与双配置数据)${NC}"
read -p " 请输入数字 [1/2]: " MAIN_CHOICE

# ----------------- 卸载逻辑分支 -----------------
if [ "$MAIN_CHOICE" == "2" ]; then
    echo -e "\n${YELLOW}${BOLD}⚠️  警告：该操作将停止并删除 Emby-Proxy 与 Nginx 服务，清空所有相关配置与证书！${NC}"
    read -p " 确认要继续卸载吗？(y/n, 默认 n): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy](es)?$ ]]; then
        echo -e "${GREEN} ℹ 已取消卸载操作。${NC}"
        exit 0
    fi

    echo -e "\n${BLUE}${BOLD}▶ 正在清理系统服务...${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
    
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        for svc in emby-backend nginx; do
            if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                echo -e "${YELLOW} ℹ 正在停止并禁用服务: $svc...${NC}"
                systemctl stop "$svc" >/dev/null 2>&1
                systemctl disable "$svc" >/dev/null 2>&1
            fi
        done
        rm -f /etc/systemd/system/emby-backend.service
        systemctl daemon-reload
    else
        for svc in emby-backend nginx; do
            if rc-service "$svc" status >/dev/null 2>&1; then
                echo -e "${YELLOW} ℹ 正在停止服务: $svc...${NC}"
                rc-service "$svc" stop >/dev/null 2>&1
            fi
            if rc-update show default | grep -q "$svc"; then
                echo -e "${YELLOW} ℹ 正在移除自启: $svc...${NC}"
                rc-update del "$svc" default >/dev/null 2>&1
            fi
            rm -f /etc/init.d/$svc
        done
    fi
    echo -e "${GREEN} ✔ 系统服务配置清理完毕。${NC}"

    echo -e "${YELLOW} ℹ 正在删除程序目录与双重配置文件 (标准路径)...${NC}"
    rm -f /usr/local/bin/emby-proxy
    rm -rf /etc/ssl/emby-proxy
    rm -f "$NGINX_CONF_DIR/nginx-emby.conf"
    rm -f "$NGINX_CONF_DIR/nginx-emos.conf"
    $HOME/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
    rm -rf $HOME/.acme.sh
    echo -e "${GREEN} ✔ 部署双目录（含证书、双Nginx配置、二进制文件）已彻底删除。${NC}"

    if [ "$OS_TYPE" = "debian" ]; then
        read -p " 是否同步卸载 Nginx 主程序？(y/n, 默认 n): " RM_NGINX_APT
        if [[ "$RM_NGINX_APT" =~ ^[Yy](es)?$ ]]; then
            echo -e "${YELLOW} ℹ 正在卸载 Nginx 主程序...${NC}"
            apt purge -y nginx nginx-common >/dev/null 2>&1
            apt autoremove -y >/dev/null 2>&1
            echo -e "${GREEN} ✔ Nginx 主程序已卸载。${NC}"
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        read -p " 是否同步卸载 Nginx 主程序？(y/n, 默认 n): " RM_NGINX_APK
        if [[ "$RM_NGINX_APK" =~ ^[Yy](es)?$ ]]; then
            echo -e "${YELLOW} ℹ 正在卸载 Nginx 主程序...${NC}"
            apk del nginx >/dev/null 2>&1
            echo -e "${GREEN} ✔ Nginx 主程序已卸载。${NC}"
        fi
    fi

    echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}${BOLD}│ 🎉 卸载完成！所有相关服务及配置已彻底清理干净。         │${NC}"
    echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}\n"
    exit 0

elif [ "$MAIN_CHOICE" != "1" ]; then
    echo -e "${RED} ✖ [错误] 输入无效，脚本退出。${NC}"
    exit 1
fi

# ==================== 原部署逻辑开始 ====================

# 创建完全符合 Linux FHS 规范的标准目录
mkdir -p "$NGINX_CONF_DIR"
mkdir -p /etc/ssl/emby-proxy
mkdir -p /usr/local/bin

# 检查命令是否存在的便捷函数
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}


# ==================== 1. 环境依赖独立安装区 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 1/5] 正在检查并独立安装系统基础依赖环境...${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"

NEED_INSTALL=()
for cmd in curl tar wget git openssl jq socat; do
    if ! check_cmd "$cmd"; then
        NEED_INSTALL+=("$cmd")
    fi
done

if [ ${#NEED_INSTALL[@]} -ne 0 ]; then
    echo -e "${YELLOW} ℹ 发现缺失基础依赖: ${NEED_INSTALL[*]}，正在独立执行补充安装...${NC}"
    if [ "$OS_TYPE" = "debian" ]; then
        apt update -y
        apt install -y curl tar wget git openssl jq psmisc socat || {
            echo -e "${RED} ✖ [错误] 基础依赖安装失败！请检查系统网络或软件源。${NC}"
            exit 1
        }
    else
        apk update
        apk add curl tar wget git openssl jq psmisc bash coreutils libc6-compat socat || {
            echo -e "${RED} ✖ [错误] Alpine 基础依赖安装失败！请检查系统网络或软件源。${NC}"
            exit 1
        }
    fi
else
    echo -e "${GREEN} ✔ [已通过] 基础系统依赖完整，无需重复安装。${NC}"
fi


# ==================== 2. Nginx 就绪状态检查 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 2/5] 正在检查 Nginx 服务状态...${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"

if ! check_cmd "nginx"; then
    echo -e "${YELLOW} ℹ 未检测到 Nginx，正在自动安装...${NC}"
    if [ "$OS_TYPE" = "debian" ]; then
        apt update -y && apt install -y nginx || { echo -e "${RED} ✖ [错误] Nginx 安装失败！${NC}"; exit 1; }
    else
        apk add nginx || { echo -e "${RED} ✖ [错误] Nginx 安装失败！${NC}"; exit 1; }
    fi
    echo -e "${GREEN} ✔ Nginx 安装成功！${NC}"
else
    echo -e "${GREEN} ✔ [已通过] 检测到已安装 Nginx。${NC}"
fi

[ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
[ -f /etc/nginx/http.d/default.conf ] && rm -f /etc/nginx/http.d/default.conf


# ==================== 3. 后端 Emby-Proxy 状态检查 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 3/5] 正在检查 Emby-Proxy 后端程序...${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
ARCH=$(uname -m)
BIN_FILE="/usr/local/bin/emby-proxy"

if [ -x "$BIN_FILE" ]; then
    echo -e "${GREEN} ✔ [已通过] 检测到 $BIN_FILE 已存在且具备执行权限，跳过下载。${NC}"
else
    echo -e "${YELLOW} ℹ 未检测到后端程序，正在识别架构并下载...${NC}"
    if [ "$ARCH" = "x86_64" ]; then
        EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        EMBY_PROXY_URL="https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/emby-proxy-arm64"
    else
        echo -e "${RED} ✖ [错误] 暂不支持当前架构: $ARCH${NC}"
        exit 1
    fi

    rm -f "$BIN_FILE"
    wget -O "$BIN_FILE" "$EMBY_PROXY_URL" && chmod +x "$BIN_FILE"
    echo -e "${GREEN} ✔ 后端 emby-proxy 下载并授权成功。${NC}"
fi


# ==================== 4. 域名输入与证书智能扫描 / 申请 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 4/5] 配置参数收集与证书检查...${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"
read -p " 请输入您的域名 (例如: example.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED} ✖ [错误] 域名不能为空！${NC}"
    exit 1
fi

CERT_FILE="/etc/ssl/emby-proxy/fullchain.pem"
KEY_FILE="/etc/ssl/emby-proxy/privkey.pem"

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

echo -e "${YELLOW} ℹ 正在扫描本地常见路径，寻找匹配 [$DOMAIN] 的有效证书...${NC}"
for idx in "${!POSSIBLE_CERTS[@]}"; do
    cert_path="${POSSIBLE_CERTS[$idx]}"
    key_path="${POSSIBLE_KEYS[$idx]}"
    
    if [ -s "$cert_path" ] && [ -s "$key_path" ]; then
        if openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -q "$DOMAIN"; then
            echo -e "${GREEN} ✔ [匹配成功] 发现匹配域名的本地有效证书: $cert_path${NC}"
            if [ "$cert_path" != "$CERT_FILE" ]; then
                cp -f "$cert_path" "$CERT_FILE"
                cp -f "$key_path" "$KEY_FILE"
            fi
            USE_EXISTING_CERT=true
            break
        fi
    fi
done

if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "${YELLOW} ℹ 提示：未自动发现本地证书。${NC}"
    read -p " 是否需要手动配置/粘贴 Cloudflare 源服务器证书？(y/n, 默认 n): " PROVIDE_CERT
    
    if [[ "$PROVIDE_CERT" =~ ^[Yy](es)?$ ]]; then
        echo -e "\n 请选择提供证书的方式:"
        echo -e "  ${BOLD}1)${NC} 输入绝对文件路径"
        echo -e "  ${BOLD}2)${NC} 手动粘贴文本内容"
        read -p " 请选择 [1/2]: " CERT_INPUT_MODE
        
        if [ "$CERT_INPUT_MODE" == "1" ]; then
            read -p " 请输入证书完整路径 (fullchain.pem 或 .crt): " USER_CERT
            read -p " 请输入私钥完整路径 (privkey.pem 或 .key): " USER_KEY
            
            if [ -s "$USER_CERT" ] && [ -s "$USER_KEY" ]; then
                cp -f "$USER_CERT" "$CERT_FILE"
                cp -f "$USER_KEY" "$KEY_FILE"
                echo -e "${GREEN} ✔ 自定义本地证书导入成功！${NC}"
                USE_EXISTING_CERT=true
            else
                echo -e "${RED} ✖ 文件不存在或不可读，系统将退回到 acme.sh 自动申请。${NC}"
            fi
            
        elif [ "$CERT_INPUT_MODE" == "2" ]; then
            echo -e "\n${YELLOW}┌─────────────────── 证书粘贴引导框 ───────────────────┐${NC}"
            echo -e "${YELLOW}│ 请右键粘贴您的证书内容 (以 -----BEGIN CERTIFICATE----- 开头)  │${NC}"
            echo -e "${YELLOW}│ 粘贴完成后，另起新的一行，输入大写 ${BOLD}EOF${NC}${YELLOW} 并回车确认：         │${NC}"
            echo -e "${YELLOW}└──────────────────────────────────────────────────────┘${NC}"
            rm -f "$CERT_FILE"
            while IFS= read -r line; do
                [[ "$line" == "EOF" ]] && break
                echo "$line" >> "$CERT_FILE"
            done
            
            echo -e "\n${YELLOW}┌─────────────────── 私钥粘贴引导框 ───────────────────┐${NC}"
            echo -e "${YELLOW}│ 请右键粘贴您的私钥内容 (以 -----BEGIN PRIVATE KEY----- 开头)  │${NC}"
            echo -e "${YELLOW}│ 粘贴完成后，另起新的一行，输入大写 ${BOLD}EOF${NC}${YELLOW} 并回车确认：         │${NC}"
            echo -e "${YELLOW}└──────────────────────────────────────────────────────┘${NC}"
            rm -f "$KEY_FILE"
            while IFS= read -r line; do
                [[ "$line" == "EOF" ]] && break
                echo "$line" >> "$KEY_FILE"
            done
            
            if [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] && openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
                echo -e "${GREEN} ✔ 粘贴证书保存成功！${NC}"
                USE_EXISTING_CERT=true
            else
                echo -e "${RED} ✖ 证书解析失败，系统将退回到 acme.sh 自动申请。${NC}"
                rm -f "$CERT_FILE" "$KEY_FILE"
            fi
        fi
    fi
fi

# 记录用户自定义端口
read -p " 请输入域名(example.com)访问端口 (默认 443): " DOMAIN_PORT
DOMAIN_PORT=${DOMAIN_PORT:-443}
read -p " 请输入 HTTPS 监听端口 (默认 443): " HTTPS_PORT
HTTPS_PORT=${HTTPS_PORT:-443}
read -p " 请输入 HTTP 默认端口 (默认 80): " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-80}

if [ "$USE_EXISTING_CERT" = false ]; then
    read -p " 请输入邮箱 (用于自动证书申请注册): " MY_EMAIL
    echo -e "\n 请选择自动证书申请验证方式:"
    echo -e "  ${BOLD}1)${NC} Cloudflare DNS 挑战 (${PURPLE}推荐，无需开放 80 端口${NC})"
    echo -e "  ${BOLD}2)${NC} HTTP 独立挑战 (请确保 80 端口空闲且对外开放)"
    read -p " 选择 [1/2]: " AUTH_MODE

    if [ ! -d "$HOME/.acme.sh" ]; then
        echo -e "${YELLOW} ℹ 正在安装 acme.sh...${NC}"
        curl -s https://get.acme.sh | sh -s email="$MY_EMAIL" >/dev/null 2>&1
    fi
    
    ACME_BIN="$HOME/.acme.sh/acme.sh"
    $ACME_BIN --set-default-ca --server letsencrypt >/dev/null 2>&1

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop nginx >/dev/null 2>&1
    else
        rc-service nginx stop >/dev/null 2>&1
    fi

    if [ "$AUTH_MODE" == "1" ]; then
        read -p " 请输入 Cloudflare API Token (需具备该域名 DNS:Edit 权限): " CF_TOKEN
        export CF_Token="$CF_TOKEN"
        echo -e "${YELLOW} ℹ 正在通过 DNS API 申请证书...${NC}"
        $ACME_BIN --issue --dns dns_cf -d "$DOMAIN"
    else
        echo -e "${YELLOW} ℹ 正在通过 Standalone HTTP 申请证书...${NC}"
        $ACME_BIN --issue --standalone -d "$DOMAIN" --httpport 80
    fi

    $ACME_BIN --install-cert -d "$DOMAIN" \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE"
    
    if [ -s "$CERT_FILE" ]; then
        echo -e "${GREEN} ✔ 证书自动申请并安装成功！${NC}"
    else
        echo -e "${RED} ✖ 证书申请失败，请检查网络、DNS 解析或 API Token 后重试。${NC}"
        exit 1
    fi
fi


# ==================== 5. 动态生成 Nginx 双独立配置文件 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 5/5] 正在动态生成 Nginx 隔离配置 (nginx-emby.conf & nginx-emos.conf)...${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────${NC}"

# 📦 配置 1：通用纯净反代配置 (nginx-emby.conf)
cat <<NGINX_EOF1 > "$NGINX_CONF_DIR/nginx-emby.conf"
# 通用后端代理映射
upstream emby-proxy {
    server 127.0.0.1:8080;
}

# HTTP 重定向到 HTTPS
server {
    listen $HTTP_PORT;
    server_name $DOMAIN;
    return 301 https://\$host:$DOMAIN_PORT\$request_uri;
}

# HTTPS 主服务配置
server {
    listen $HTTPS_PORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # 干净的通用根访问控制，无缓存、无节流限制
    location / {
        proxy_pass http://127.0.0.1:8080;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # websocket支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX_EOF1

echo -e "${GREEN} ✔ [1/2] 通用配置 nginx-emby.conf 创建成功。${NC}"


# 📦 配置 2：专属于 emos 的纯净反代配置 (nginx-emos.conf)
cat <<NGINX_EOF2 > "$NGINX_CONF_DIR/nginx-emos.conf"
server {
    # 共享 HTTPS 端口与外部域名
    listen $HTTPS_PORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # =============== 核心路由规则: emos 特殊路由处理 ================
    location ^~ /emos {
        rewrite ^/emos(.*)$ /https/video.emos.best/443\$1 break;
        proxy_pass http://127.0.0.1:8080;
        
        # 处理视频流状态码，透传 Range 头部
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        # 增加核心头部 EMOS-PROXY-ID 和 NAME
        proxy_set_header EMOS-PROXY-ID "eD3VXZD9Ys";
        proxy_set_header EMOS-PROXY-NAME "@OneQ1st";
        
        # 传递头部 X-FORWARDED-FOR 及其余常规头部
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
    }
}
NGINX_EOF2

echo -e "${GREEN} ✔ [2/2] 纯净版特殊配置 nginx-emos.conf 创建完成。${NC}"


# ==================== 6. 服务配置与最终检查 ====================
if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat <<SVC_EOF > /etc/systemd/system/emby-backend.service
[Unit]
Description=Emby Proxy Backend
After=network.target

[Service]
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/emby-proxy
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

    systemctl daemon-reload
    systemctl enable --now emby-backend >/dev/null 2>&1
    systemctl enable --now nginx >/dev/null 2>&1
    systemctl restart emby-backend nginx >/dev/null 2>&1

else
    cat <<'OPENRC_EOF' > /etc/init.d/emby-backend
#!/sbin/openrc-run
description="Emby Proxy Backend"
supervisor="supervise-daemon"
command="/usr/local/bin/emby-proxy"
directory="/usr/local/bin"
respawn_delay=5
respawn_max=0

depend() {
    need net
    after firewall
}
OPENRC_EOF
    chmod +x /etc/init.d/emby-backend

    rc-update add emby-backend default >/dev/null 2>&1
    rc-update add nginx default >/dev/null 2>&1
    rc-service emby-backend restart >/dev/null 2>&1
    rc-service nginx restart >/dev/null 2>&1
fi

sleep 1.5

# ==================== 7. 看板信息输出 ====================
echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│ 🎉 恭喜！双配置文件彻底解耦部署完成。                  │${NC}"
echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}"

echo -e " ${BOLD}📊 [多轨服务运行状态看板]${NC}"
echo -e " ────────────────────────────────────────────────────────"
echo -e "  🌐 统一访问域名:  ${GREEN}${BOLD}https://$DOMAIN:$DOMAIN_PORT${NC}"
echo -e "  📄 纯净反代配置:  ${BLUE}$NGINX_CONF_DIR/nginx-emby.conf${NC}"
echo -e "  📄 特殊配置路径:  ${PURPLE}$NGINX_CONF_DIR/nginx-emos.conf${NC}"
echo -e "  📂 后端执行路径:  ${BLUE}$BIN_FILE${NC}"
echo -e "  🔐 SSL证书存放处: ${BLUE}/etc/ssl/emby-proxy${NC}"

STATUS_NGINX=false
STATUS_BACKEND=false

if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl is-active --quiet nginx && STATUS_NGINX=true
    systemctl is-active --quiet emby-backend && STATUS_BACKEND=true
else
    rc-service nginx status >/dev/null 2>&1 && STATUS_NGINX=true
    rc-service emby-backend status >/dev/null 2>&1 && STATUS_BACKEND=true
fi

if [ "$STATUS_NGINX" = true ]; then
    echo -e "  ⚡ Nginx 前端状态: ${GREEN}${BOLD}● Running (双配置已安全载入并正常运行)${NC}"
else
    DIAG_CMD=$([ "$INIT_SYSTEM" = "systemd" ] && echo "journalctl -u nginx -n 20 --no-pager" || echo "rc-service nginx status")
    echo -e "  ⚡ Nginx 前端状态: ${RED}${BOLD}● Failed (启动异常，输入 '$DIAG_CMD' 诊断)${NC}"
fi

if [ "$STATUS_BACKEND" = true ]; then
    echo -e "  ⚡ Proxy 后端状态: ${GREEN}${BOLD}● Running (正常运行)${NC}"
else
    echo -e "  ⚡ Proxy 后端状态: ${RED}${BOLD}● Failed (启动异常)${NC}"
fi
echo -e " ────────────────────────────────────────────────────────\n"
