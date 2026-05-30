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
echo -e "${BLUE}${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BLUE}${BOLD}│  Emby-Proxy + Caddy(含CF插件) 智能全自检部署脚本 │${NC}"
echo -e "${BLUE}${BOLD}└──────────────────────────────────────────────────┘${NC}"

# ==================== 0. 互动式功能选择 ====================
echo -e "\n${BLUE}${BOLD}📊 请选择要执行的操作：${NC}"
echo -e "  ${BOLD}1)${NC} ${GREEN}智能自检部署 / 更新环境${NC}"
echo -e "  ${BOLD}2)${NC} ${RED}一键完全卸载 (清理服务与数据)${NC}"
read -p " 请输入数字 [1/2]: " MAIN_CHOICE

# ----------------- 卸载逻辑分支 -----------------
if [ "$MAIN_CHOICE" == "2" ]; then
    echo -e "\n${YELLOW}${BOLD}⚠️  警告：该操作将停止并删除 Emby-Proxy 与 Caddy 服务，清空所有相关配置与证书！${NC}"
    read -p " 确认要继续卸载吗？(y/n, 默认 n): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy](es)?$ ]]; then
        echo -e "${GREEN} ℹ 已取消卸载操作。${NC}"
        exit 0
    fi

    echo -e "\n${BLUE}${BOLD}▶ 正在清理系统服务...${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
    
    # 1. 停止并禁用 Systemd 服务
    for svc in emby-backend caddy; do
        if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            echo -e "${YELLOW} ℹ 正在停止并禁用服务: $svc...${NC}"
            systemctl stop "$svc" >/dev/null 2>&1
            systemctl disable "$svc" >/dev/null 2>&1
        fi
    done

    # 2. 清除 Systemd 服务文件
    rm -f /etc/systemd/system/emby-backend.service
    rm -f /etc/systemd/system/caddy.service
    systemctl daemon-reload
    echo -e "${GREEN} ✔ Systemd 服务配置清理完毕。${NC}"

    # 3. 清理程序目录与配置文件
    echo -e "${YELLOW} ℹ 正在删除程序目录与配置文件...${NC}"
    rm -rf /opt/emby-proxy
    rm -rf /etc/caddy
    echo -e "${GREEN} ✔ 部署目录（含证书、Caddyfile）已彻底删除。${NC}"

    # 4. 解除 Caddy 官方 APT 软件源（可选，防止影响系统后续更新）
    if [ -f "/etc/apt/sources.list.d/caddy-stable.list" ]; then
        read -p " 是否同步卸载 Caddy 的 APT 软件源与主程序？(y/n, 默认 n): " RM_CADDY_APT
        if [[ "$RM_CADDY_APT" =~ ^[Yy](es)?$ ]]; then
            echo -e "${YELLOW} ℹ 正在卸载 Caddy 软件源及主程序...${NC}"
            apt purge -y caddy >/dev/null 2>&1
            rm -f /etc/apt/sources.list.d/caddy-stable.list
            rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            apt update -y >/dev/null 2>&1
            echo -e "${GREEN} ✔ Caddy APT 源及主程序已卸载。${NC}"
        fi
    fi

    echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}${BOLD}│ 🎉 卸载完成！Emby-Proxy 相关服务及文件已彻底清理干净。 │${NC}"
    echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}\n"
    exit 0

# ----------------- 错误输入防御 -----------------
elif [ "$MAIN_CHOICE" != "1" ]; then
    echo -e "${RED} ✖ [错误] 输入无效，脚本退出。${NC}"
    exit 1
fi


# ==================== 原部署逻辑开始（代码一律未动） ====================

# 创建标准目录（若不存在）
mkdir -p /etc/caddy
mkdir -p /opt/emby-proxy
mkdir -p /opt/emby-proxy/ssl

# 检查命令是否存在的便捷函数
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ==================== 1. 基础依赖检查与环境补全 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 1/5] 正在检查系统基础依赖环境...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"

NEED_INSTALL=()
for cmd in curl tar wget git openssl jq gpg; do
    if ! check_cmd "$cmd"; then
        NEED_INSTALL+=("$cmd")
    fi
done

if [ ${#NEED_INSTALL[@]} -ne 0 ]; then
    echo -e "${YELLOW} ℹ 发现缺失基础依赖: ${NEED_INSTALL[*]}，正在补充安装...${NC}"
    apt update -y
    apt install -y curl tar wget git openssl jq psmisc debian-keyring debian-archive-keyring apt-transport-https || {
        echo -e "${RED} ✖ [错误] 基础依赖安装失败！请检查系统网络或软件源。${NC}"
        exit 1
    }
else
    echo -e "${GREEN} ✔ [已通过] 基础系统依赖完整，无需重复安装。${NC}"
fi


# ==================== 2. Caddy 及其插件就绪状态检查 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 2/5] 正在检查 Caddy 服务及 Cloudflare 插件状态...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
CADDY_READY=false

if check_cmd "caddy"; then
    echo -e "${YELLOW} ℹ 检测到系统已安装 Caddy，正在校验 Cloudflare 插件...${NC}"
    if /usr/bin/caddy list-modules | grep -q "dns.providers.cloudflare"; then
        echo -e "${GREEN} ✔ [已通过] 检测到完全符合要求的 Caddy (已集成 Cloudflare 插件)，跳过安装。${NC}"
        CADDY_READY=true
    else
        echo -e "${YELLOW} ℹ 提示：已安装 Caddy，但未检测到 cloudflare 插件。将为您在线热补丁集成...${NC}"
    fi
fi

if [ "$CADDY_READY" = false ]; then
    if ! check_cmd "caddy"; then
        echo -e "${YELLOW} ℹ 正在配置 Caddy 官方 APT 存储库...${NC}"
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update -y && apt install -y caddy || { echo -e "${RED} ✖ [错误] 标准版 Caddy 安装失败！${NC}"; exit 1; }
    fi

    echo -e "${YELLOW} ℹ 正在向 Caddy 注入 cloudflare 插件 (进程需要一分钟左右，请稍候)...${NC}"
    /usr/bin/caddy add-package github.com/caddy-dns/cloudflare || {
        echo -e "${RED} ✖ [错误] 插件集成失败！请检查您的 VPS 到 github.com 的 network 状态。${NC}"
        exit 1
    }
    echo -e "${GREEN} ✔ Caddy 及其插件环境配置成功！${NC}"
fi


# ==================== 3. 后端 Emby-Proxy 状态检查 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 3/5] 正在检查 Emby-Proxy 后端程序...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
ARCH=$(uname -m)

if [ -x "/opt/emby-proxy/emby-proxy" ]; then
    echo -e "${GREEN} ✔ [已通过] 检测到 /opt/emby-proxy/emby-proxy 已存在且具备执行权限，跳过下载。${NC}"
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

    rm -f /opt/emby-proxy/emby-proxy
    wget -O /opt/emby-proxy/emby-proxy "$EMBY_PROXY_URL" && chmod +x /opt/emby-proxy/emby-proxy
    echo -e "${GREEN} ✔ 后端 emby-proxy 下载并授权成功。${NC}"
fi


# ==================== 4. 域名输入与证书智能扫描 ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 4/5] 配置参数收集与现有证书扫描...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
read -p " 请输入您的域名 (例如: example.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED} ✖ [错误] 域名不能为空！${NC}"
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

echo -e "${YELLOW} ℹ 正在扫描本地常见路径，寻找匹配 [$DOMAIN] 的有效证书...${NC}"
for idx in "${!POSSIBLE_CERTS[@]}"; do
    cert_path="${POSSIBLE_CERTS[$idx]}"
    key_path="${POSSIBLE_KEYS[$idx]}"
    
    if [ -s "$cert_path" ] && [ -s "$key_path" ]; then
        if openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -q "$DOMAIN"; then
            echo -e "${GREEN} ✔ [匹配成功] 发现匹配域名的本地有效证书: $cert_path${NC}"
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
    echo -e "${YELLOW} ℹ 提示：未在系统常见路径下自动发现匹配域名 [$DOMAIN] 的本地证书。${NC}"
    read -p " 是否需要手动配置/粘贴 Cloudflare 源服务器证书？(y/n, 默认 n): " PROVIDE_CERT
    
    if [[ "$PROVIDE_CERT" =~ ^[Yy](es)?$ ]]; then
        echo -e "\n 请选择提供证书的方式:"
        echo -e "  ${BOLD}1)${NC} 输入已有证书和私钥的【绝对文件路径】"
        echo -e "  ${BOLD}2)${NC} 直接【手动粘贴】Cloudflare 源服务器证书/私钥文本内容"
        read -p " 请选择 [1/2]: " CERT_INPUT_MODE
        
        if [ "$CERT_INPUT_MODE" == "1" ]; then
            read -p " 请输入证书完整路径 (fullchain.pem 或 .crt): " USER_CERT
            read -p " 请输入私钥完整路径 (privkey.pem 或 .key): " USER_KEY
            
            if [ -s "$USER_CERT" ] && [ -s "$USER_KEY" ]; then
                ln -sf "$USER_CERT" "$CERT_FILE"
                ln -sf "$USER_KEY" "$KEY_FILE"
                echo -e "${GREEN} ✔ 自定义本地证书文件导入成功！${NC}"
                USE_EXISTING_CERT=true
            else
                echo -e "${RED} ✖ 输入的路径文件不存在或不可读，系统将退回到 Caddy 自动申请方案。${NC}"
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
            
            # 校验粘贴内容的合法性
            if [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] && openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
                echo -e "${GREEN} ✔ 粘贴的 Cloudflare 源服务器证书及私钥解析并保存成功！${NC}"
                USE_EXISTING_CERT=true
            else
                echo -e "${RED} ✖ 证书解析失败（可能复制不全或格式错误），系统将退回到 Caddy 自动申请方案。${NC}"
                rm -f "$CERT_FILE" "$KEY_FILE"
            fi
        else
            echo -e "${RED} ✖ 输入错误，退回到自动申请方案。${NC}"
        fi
    fi
fi

# 其余运行参数收集
read -p " 请输入域名(example.com)访问端口 (默认 443): " DOMAIN_PORT
DOMAIN_PORT=${DOMAIN_PORT:-443}
read -p " 请输入 HTTPS 监听端口 (默认 443): " HTTPS_PORT
HTTPS_PORT=${HTTPS_PORT:-443}
read -p " 请输入 HTTP 默认端口 (若 80 被占用可自定义修改，默认 80): " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-80}
read -p " 请输入邮箱 (用于自动化证书申请/续期通知): " MY_EMAIL

if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "\n 请选择 Caddy 证书申请验证方式:"
    echo -e "  ${BOLD}1)${NC} Cloudflare DNS 挑战 (${PURPLE}推荐，无需开放 80 端口${NC})"
    echo -e "  ${BOLD}2)${NC} HTTP 自动挑战 (请确保上述指定的 HTTP 端口能接收外部 80 端口的流量)"
    read -p " 选择 [1/2]: " AUTH_MODE
fi


# ==================== 5. 动态生成符合规范的 Caddyfile ====================
echo -e "\n${BLUE}${BOLD}▶ [步骤 5/5] 正在生成全局标准化 Caddyfile 配置...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"

GLOBAL_BLOCK="email $MY_EMAIL
    http_port $HTTP_PORT
    https_port $HTTPS_PORT"

if [ "$USE_EXISTING_CERT" = true ]; then
    cat <<CADDY_EOF > /opt/emby-proxy/Caddyfile
{
    $GLOBAL_BLOCK
}

$DOMAIN:$DOMAIN_PORT {
    tls $CERT_FILE $KEY_FILE

    handle_path /emos* {
        rewrite * /https/video.emos.best/443{path}
        
        reverse_proxy 127.0.0.1:8080 {
            header_up EMOS-PROXY-ID "eD3VXZD9Ys"
            header_up EMOS-PROXY-NAME "@OneQ1st"
            header_up X-Forwarded-For {remote_host}
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }
    # 2. 通用路径：保持简单，不带上述多余限制
    handle {
        reverse_proxy 127.0.0.1:8080 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }
}
CADDY_EOF

else
    if [ "$AUTH_MODE" == "1" ]; then
        read -p " 请输入 Cloudflare API Token (需具备该域名 DNS:Edit 权限): " CF_TOKEN
        cat <<CADDY_EOF > /opt/emby-proxy/Caddyfile
{
    $GLOBAL_BLOCK
    acme_dns cloudflare $CF_TOKEN
}

$DOMAIN:$DOMAIN_PORT {
    handle_path /emos* {
        rewrite * /https/video.emos.best/443{path}
        
        reverse_proxy 127.0.0.1:8080 {
            header_up EMOS-PROXY-ID "eD3VXZD9Ys"
            header_up EMOS-PROXY-NAME "@OneQ1st"
            header_up X-Forwarded-For {remote_host}
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }
    # 2. 通用路径：保持简单，不带上述多余限制
    handle {
        reverse_proxy 127.0.0.1:8080 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }
}
CADDY_EOF
    else
        cat <<CADDY_EOF > /opt/emby-proxy/Caddyfile
{
    $GLOBAL_BLOCK
}

$DOMAIN:$DOMAIN_PORT {
    tls {
        acme_ca https://acme-v02.api.letsencrypt.org/directory
    }

    handle_path /emos* {
        rewrite * /https/video.emos.best/443{path}
        
        reverse_proxy 127.0.0.1:8080 {
            header_up EMOS-PROXY-ID "eD3VXZD9Ys"
            header_up EMOS-PROXY-NAME "@OneQ1st"
            header_up X-Forwarded-For {remote_host}
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }
    # 2. 通用路径：保持简单，不带上述多余限制
    handle {
        reverse_proxy 127.0.0.1:8080 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
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
ExecStart=/usr/bin/caddy run --environ --config /opt/emby-proxy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /opt/emby-proxy/Caddyfile --force
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
systemctl enable --now emby-backend caddy >/dev/null 2>&1
systemctl restart emby-backend caddy >/dev/null 2>&1

sleep 1.5

# ==================== 7. 绚丽看板信息输出 ====================
echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│ 🎉 恭喜！智能全自检运行成功，标准路径部署完毕。        │${NC}"
echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}"

echo -e " ${BOLD}📊 [配置服务运行看板]${NC}"
echo -e " ────────────────────────────────────────────────────────"
echo -e "  🌐 访问入口地址:  ${GREEN}${BOLD}https://$DOMAIN:$DOMAIN_PORT${NC}"
echo -e "  📄 Caddy配置路径:  ${BLUE}/opt/emby-proxy/Caddyfile${NC}"

if systemctl is-active --quiet caddy; then
    echo -e "  ⚡ Caddy 前端状态: ${GREEN}${BOLD}● Running (正常运行)${NC}"
else
    echo -e "  ⚡ Caddy 前端状态: ${RED}${BOLD}● Failed (启动异常，输入 'journalctl -u caddy' 诊断)${NC}"
fi

if systemctl is-active --quiet emby-backend; then
    echo -e "  ⚡ Proxy 后端状态: ${GREEN}${BOLD}● Running (正常运行)${NC}"
else
    echo -e "  ⚡ Proxy 后端状态: ${RED}${BOLD}● Failed (启动异常)${NC}"
fi
echo -e " ────────────────────────────────────────────────────────\n"
