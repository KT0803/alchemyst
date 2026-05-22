#!/usr/bin/env bash
set -euo pipefail

# 1. Install gateway proxy engines
echo "Setting up reverse proxy tools..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx

# 2. Configure routing parameters
echo "Writing configuration details..."
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/gateway.conf << 'EOF'
server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/gateway-access.log;
    error_log  /var/log/nginx/gateway-error.log;

    client_max_body_size 10m;

    location /health {
        add_header Content-Type text/plain;
        return 200 "gateway-ok\n";
    }

    location /v1/chat/completions {
        limit_except POST {
            deny all;
        }

        proxy_pass http://10.0.1.10:3111;

        proxy_set_header X-Real-IP        $remote_addr;
        proxy_set_header X-Forwarded-For  $proxy_add_x_forwarded_for;
        proxy_set_header Host             $http_host;
        proxy_set_header Connection       "";

        proxy_connect_timeout  10s;
        proxy_send_timeout    180s;
        proxy_read_timeout    180s;

        proxy_http_version 1.1;

        add_header Access-Control-Allow-Origin  "*" always;
        add_header Access-Control-Allow-Methods "POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;

        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin  "*";
            add_header Access-Control-Allow-Methods "POST, OPTIONS";
            add_header Access-Control-Allow-Headers "Content-Type, Authorization";
            return 204;
        }
    }

    location / {
        return 404 '{"error": "not found", "hint": "POST /v1/chat/completions"}\n';
        add_header Content-Type application/json;
    }
}
EOF

ln -sf /etc/nginx/sites-available/gateway.conf /etc/nginx/sites-enabled/gateway.conf

# 3. Test configurations and startup service
echo "Testing configurations and starting proxy..."
nginx -t

mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/restart.conf << 'EOF'
[Service]
Restart=always
RestartSec=5s
EOF

systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

echo "Gateway VM deployment completed successfully."
