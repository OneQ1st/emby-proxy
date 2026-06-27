```
wget -O deploy.sh https://raw.githubusercontent.com/OneQ1st/emby-proxy/main/deploy.sh && chmod +x deploy.sh && ./deploy.sh

```
Alpine下需修改nginx.conf才能使用nginx ui面板
```
# /etc/nginx/nginx.conf
user nginx;
worker_processes auto;
pcre_jit on;
error_log /var/log/nginx/error.log warn;

# 1. 动态模块包含 (保留)
include /etc/nginx/modules/*.conf;

# 2. 删除外层 context 的 include，防止重复加载

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    server_tokens off;
    client_max_body_size 1m;
    sendfile on;
    tcp_nopush on;
    
    ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:2m;
    ssl_session_timeout 1h;
    ssl_session_tickets off;
    
    gzip_vary on;
    
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
        '$status $body_bytes_sent "$http_referer" '
        '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;

    # 3. 统一在这里加载配置文件
    # Alpine 默认使用 http.d，我们把它和 conf.d 合并管理
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/http.d/*.conf;
}
```
