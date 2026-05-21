#!/usr/bin/env bash
set -euo pipefail

# 1. Update package list and install system dependencies
echo "System update and prerequisites installation..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl

# 2. Download and register the global iii engine binary
echo "Installing the iii framework CLI..."
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh

III_BIN="$(find /root/.local /home -name 'iii' -type f 2>/dev/null | head -1 || true)"
if [ -z "$III_BIN" ]; then
    III_BIN="/usr/local/bin/iii"
fi
if [ ! -f "/usr/local/bin/iii" ]; then
    cp "$III_BIN" /usr/local/bin/iii
fi
chmod +x /usr/local/bin/iii

# 3. Create working directories and write the router configuration
echo "Writing engine configuration file..."
mkdir -p /opt/iii/data
cat > /opt/iii/config.yaml << 'EOF'
workers:
  - name: iii-observability
    config:
      enabled: true
      service_name: iii-engine
      exporter: memory
      memory_max_spans: 10000
      metrics_enabled: true
      metrics_exporter: memory
      logs_enabled: true
      logs_exporter: memory
      logs_console_output: true
      sampling_ratio: 1.0
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /opt/iii/data/state_store.db
  - name: iii-http
    config:
      port: ${III_HTTP_PORT:3111}
      host: ${III_HTTP_HOST:0.0.0.0}
      default_timeout: 120000
      concurrency_request_limit: 256
      cors:
        allowed_origins:
          - "*"
        allowed_methods:
          - GET
          - POST
          - PUT
          - DELETE
          - OPTIONS
EOF

# 4. Write systemd unit files to handle daemon lifecycle
echo "Registering daemon process under systemd..."
cat > /etc/systemd/system/iii-engine.service << 'EOF'
[Unit]
Description=iii Engine — RPC router for distributed inference workers
Documentation=https://iii.dev/docs/using-iii/engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii
ExecStart=/usr/local/bin/iii --config /opt/iii/config.yaml
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=iii-engine
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 5. Load and execute the daemon
echo "Initializing and executing service..."
systemctl daemon-reload
systemctl enable iii-engine
systemctl start iii-engine

echo "VPC Node Engine Deployment Completed Successfully."
