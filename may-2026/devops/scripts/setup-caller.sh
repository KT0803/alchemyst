#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Alchemyst-ai/hiring.git"
APP_DIR="/opt/caller-worker"
ENGINE_WS="ws://10.0.1.10:49134"

# 1. Install Node.js runtime environments
echo "Setting up Node.js runtimes..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl git

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs

# 2. Acquire codebase repository
echo "Cloning codebase repository..."
if [ -d "$APP_DIR" ]; then
    cd "$APP_DIR" && git pull --ff-only || true
else
    git clone --depth=1 "$REPO_URL" "$APP_DIR"
fi

WORKER_DIR="${APP_DIR}/may-2026/devops/quickstart/workers/caller-worker"

# 3. Resolve Node dependency graphs
echo "Resolving node package dependencies..."
cd "$WORKER_DIR"
npm install --legacy-peer-deps --prefer-offline 2>&1 | tail -5

# 4. Write environment details
cat > /opt/caller-worker-env << EOF
III_URL=${ENGINE_WS}
NODE_ENV=production
EOF

# 5. Build systemd services daemon
echo "Registering caller service daemon..."
TSX_BIN="${WORKER_DIR}/node_modules/.bin/tsx"

cat > /etc/systemd/system/caller-worker.service << EOF
[Unit]
Description=iii caller-worker — TypeScript HTTP+RPC bridge for inference
Documentation=https://github.com/Alchemyst-ai/hiring/tree/main/may-2026/devops
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORKER_DIR}
EnvironmentFile=/opt/caller-worker-env
ExecStart=${TSX_BIN} ${WORKER_DIR}/src/worker.ts
Restart=always
RestartSec=5s
TimeoutStartSec=60
StandardOutput=journal
StandardError=journal
SyslogIdentifier=caller-worker
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 6. Initialize service
echo "Executing daemon..."
systemctl daemon-reload
systemctl enable caller-worker
systemctl start caller-worker

echo "Caller Worker VM deployment completed successfully."
