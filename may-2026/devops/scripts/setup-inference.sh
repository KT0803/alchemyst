#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Alchemyst-ai/hiring.git"
APP_DIR="/opt/inference-worker"
VENV_DIR="${APP_DIR}/venv"
ENGINE_WS="ws://10.0.1.10:49134"

# 1. Update packages and install python dependency environment
echo "Installing dependency compilers and Python 3.11 environment..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3.11 \
    python3.11-venv \
    python3-pip \
    python3.11-dev \
    build-essential \
    git \
    curl \
    wget

# Ensure Python 3.11 targets are absolute defaults
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1

# 2. Clone the core repository
echo "Acquiring project repositories..."
if [ -d "$APP_DIR" ]; then
    cd "$APP_DIR" && git pull --ff-only || true
else
    git clone --depth=1 "$REPO_URL" "$APP_DIR"
fi

WORKER_DIR="${APP_DIR}/may-2026/devops/quickstart/workers/inference-worker"

# 3. Build virtual environment and load PyTorch stack
echo "Provisioning virtual environment sandboxes..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip --quiet

echo "Loading PyTorch ML framework dependencies..."
pip install --quiet -r "$WORKER_DIR/requirements.txt"

# 4. Acquire model parameters
echo "Downloading and caching Gemma 3 270M GGUF parameters..."
mkdir -p /opt/hf-cache
export HF_HOME=/opt/hf-cache
export TRANSFORMERS_CACHE=/opt/hf-cache

python3 - << 'PYEOF'
import os
os.environ["HF_HOME"] = "/opt/hf-cache"
from huggingface_hub import hf_hub_download
hf_hub_download(
    repo_id="ggml-org/gemma-3-270m-GGUF",
    filename="gemma-3-270m-Q8_0.gguf",
    cache_dir="/opt/hf-cache",
)
PYEOF

# 5. Build runtime configuration and systems environment
echo "Writing systems environment bindings..."
cat > /opt/inference-worker-env << EOF
III_URL=${ENGINE_WS}
HF_HOME=/opt/hf-cache
TRANSFORMERS_CACHE=/opt/hf-cache
PYTHONUNBUFFERED=1
EOF

# 6. Build systemd services daemon
echo "Writing daemon services..."
cat > /etc/systemd/system/inference-worker.service << EOF
[Unit]
Description=iii inference-worker — Gemma 3 270M model inference via RPC
Documentation=https://github.com/Alchemyst-ai/hiring/tree/main/may-2026/devops
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORKER_DIR}
EnvironmentFile=/opt/inference-worker-env
ExecStart=${VENV_DIR}/bin/python ${WORKER_DIR}/inference_worker.py
Restart=always
RestartSec=10s
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal
SyslogIdentifier=inference-worker
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 7. Initialize service
echo "Executing daemon..."
systemctl daemon-reload
systemctl enable inference-worker
systemctl start inference-worker

echo "Inference Worker VM deployment completed successfully."
