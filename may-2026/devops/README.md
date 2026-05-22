# Alchemyst DevOps Assignment — iii Inference Cluster on GCP

Deploy the `quickstart` inference project (Gemma 3 270M via HuggingFace) across
4 GCP VMs wired together over the **iii RPC framework**, exposed through an
OpenAI-compatible JSON HTTP API.

---

## Architecture Diagram

```
                        ┌─────────────────────────────────────────────────────┐
  INTERNET              │  GCP VPC: iii-vpc  (asia-south1)                    │
                        │  Private Subnet: 10.0.1.0/24                        │
  User / curl           │                                                     │
      │                 │  ┌────────────────────┐                             │
      │  port 80 (HTTP) │  │   vm-gateway        │                             │
      └────────────────►│  │   10.0.1.4          │                             │
                        │  │   + public IP       │                             │
                        │  │                     │                             │
                        │  │   nginx             │                             │
                        │  │   (reverse proxy)   │                             │
                        │  └─────────┬───────────┘                             │
                        │            │                                         │
                        │            │ proxy_pass                              │
                        │            │ POST /v1/chat/completions               │
                        │            │ → http://10.0.1.20:3111                 │
                        │            ▼                                         │
                        │  ┌────────────────────┐     WebSocket (RPC calls)   │
                        │  │   vm-caller         │◄──────────────────────────┐ │
                        │  │   10.0.1.20         │                           │ │
                        │  │   (internal only)   │   ws://10.0.1.10:49134    │ │
                        │  │                     │──────────────────────────►│ │
                        │  │   caller-worker.ts  │                           │ │
                        │  │   (TypeScript)      │                           │ │
                        │  └────────────────────┘                           │ │
                        │                                                    │ │
                        │  ┌─────────────────────────────────────────────┐  │ │
                        │  │   vm-engine (10.0.1.10, internal only)      │  │ │
                        │  │                                             │  │ │
                        │  │   iii Engine (WebSocket server :49134)      │◄─┘ │
                        │  │   iii-http  (HTTP trigger server :3111)     │    │
                        │  │   iii-state (SQLite KV store)               │    │
                        │  │   iii-queue (in-memory message queue)       │    │
                        │  └────────────────────┬────────────────────────┘    │
                        │                       │                             │
                        │                       │ WebSocket + RPC             │
                        │                       │ routes inference::run_inference
                        │                       ▼                             │
                        │  ┌────────────────────┐                             │
                        │  │   vm-inference      │                             │
                        │  │   10.0.1.30         │                             │
                        │  │   (internal only)   │                             │
                        │  │                     │                             │
                        │  │   inference_worker.py                            │
                        │  │   (Python + Gemma   │                             │
                        │  │    3 270M GGUF)     │                             │
                        │  └────────────────────┘                             │
                        │                                                     │
                        └─────────────────────────────────────────────────────┘

RPC CALL FLOW (step by step):
  1. Client sends  POST /v1/chat/completions  to gateway public IP
  2. nginx (vm-gateway) proxies it to http://10.0.1.20:3111
  3. iii-http worker (running on vm-engine port 3111) receives the HTTP request
  4. iii Engine routes it to caller-worker's registered HTTP trigger function
  5. caller-worker triggers  inference::get_response  (its own RPC function)
  6. inference::get_response  triggers  inference::run_inference  on vm-inference
  7. Python worker runs Gemma 270M inference, returns text
  8. Result flows back: vm-inference → Engine → vm-caller → nginx → client
```

---

## File Structure

```
devops/
├── terraform/
│   ├── main.tf          ← VPC, subnet, 4 VMs, firewall rules, Cloud NAT
│   ├── variables.tf     ← project_id, region, zone, machine_type
│   └── outputs.tf       ← gateway public IP + curl command
│
├── scripts/
│   ├── setup-gateway.sh   ← installs nginx + writes proxy config
│   ├── setup-engine.sh    ← installs iii binary + writes config.yaml
│   ├── setup-caller.sh    ← installs Node.js 20 + npm deps
│   └── setup-inference.sh ← installs Python 3.11 + downloads Gemma model
│
├── systemd/
│   ├── iii-engine.service        ← systemd unit for iii Engine
│   ├── caller-worker.service     ← systemd unit for TypeScript worker
│   └── inference-worker.service  ← systemd unit for Python worker
│
├── nginx/
│   └── gateway.conf   ← nginx reverse proxy config (reference copy)
│
└── README.md          ← this file
```

---

## Prerequisites

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.6+ | Provision GCP infrastructure |
| [gcloud CLI](https://cloud.google.com/sdk/docs/install) | Any | Authenticate to GCP |
| A GCP Project | — | Where everything is deployed |

---

## Step-by-Step Redeploy Instructions (from a fresh GCP account)

### 1. Create a GCP Project and enable billing

1. Go to https://console.cloud.google.com
2. Click **Select a project → New Project**
3. Give it a name (e.g., `iii-inference-cluster`) — copy the **Project ID** (looks like `iii-inference-cluster-abc123`)
4. Go to **Billing** and attach a billing account (free-tier eligible; $300 credit for new accounts)

### 2. Install and authenticate gcloud

```bash
# macOS
brew install --cask google-cloud-sdk

# Linux
curl https://sdk.cloud.google.com | bash

# Login and set default project
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# Create Application Default Credentials (Terraform uses these)
gcloud auth application-default login
```

### 3. Clone this repository

```bash
git clone https://github.com/KT0803/alchemyst.git
cd alchemyst/may-2026/devops
```

### 4. Configure Terraform variables

Create a `terraform/terraform.tfvars` file:

```hcl
# terraform/terraform.tfvars
project_id   = "YOUR_GCP_PROJECT_ID"   # ← replace this
region       = "asia-south1"
zone         = "asia-south1-a"
machine_type = "e2-medium"
```

> **Never commit terraform.tfvars to git** — it contains your project ID.
> Add it to `.gitignore`.

### 5. Apply the Terraform configuration

```bash
cd terraform/

# Download the Google provider plugin
terraform init

# Preview what will be created (no changes yet)
terraform plan

# Create everything: VPC, subnet, 4 VMs, firewall rules, Cloud NAT
# Type "yes" when prompted
terraform apply
```

Expected output after `apply` completes (~3-5 minutes):

```
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Outputs:

gateway_public_ip    = "34.93.XXX.XXX"
engine_internal_ip   = "10.0.1.10"
caller_internal_ip   = "10.0.1.20"
inference_internal_ip = "10.0.1.30"
curl_test_command = <<EOT
  curl -X POST http://34.93.XXX.XXX/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"messages": [{"role": "user", "content": "What is 2 + 2?"}]}'
EOT
```

### 6. Wait for startup scripts to complete

GCP runs the startup scripts in the background after the VMs boot. The VMs
show as "RUNNING" in Terraform before the scripts finish.

| VM | Typical setup time | What takes the longest |
|----|------------------|-----------------------|
| vm-gateway | ~1 minute | nginx install |
| vm-engine | ~2 minutes | iii install |
| vm-caller | ~3 minutes | npm install |
| vm-inference | **~10-15 minutes** | downloading Gemma 270M (~270MB) + PyTorch |

**Monitor startup progress via SSH:**

```bash
# SSH to any VM through the gateway
gcloud compute ssh vm-gateway --zone=asia-south1-a
gcloud compute ssh vm-engine  --zone=asia-south1-a -- \
    "sudo journalctl -u google-startup-scripts -f"
gcloud compute ssh vm-inference --zone=asia-south1-a -- \
    "sudo journalctl -u inference-worker -f"
```

### 7. Test the API

Replace `GATEWAY_IP` with the IP from `terraform output gateway_public_ip`:

```bash
GATEWAY_IP=$(cd terraform && terraform output -raw gateway_public_ip)

curl -X POST http://${GATEWAY_IP}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "user", "content": "What is 2 + 2? Answer briefly."}
    ]
  }'
```

### 8. Tear down (destroy all resources)

```bash
cd terraform/
terraform destroy
# Type "yes" when prompted
```

This deletes every resource Terraform created — VMs, VPC, firewall rules, NAT.
Nothing is left running (and no costs continue).

---

## API Reference

### `POST /v1/chat/completions`

**Request:**

```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user",   "content": "Explain what a VPC is in one sentence."}
  ]
}
```

**Success Response (200 OK):**

```json
{
  "result": {
    "text": "A VPC, or Virtual Private Cloud, is an isolated virtual network within a public cloud that allows you to define and control your own IP address space, subnets, and routing rules.",
    "success": "You've connected two workers and they're interoperating seamlessly, now let's add a few more workers to expand this project's functionality."
  }
}
```

**Error Responses:**

| Status | Cause | Action |
|--------|-------|--------|
| `502 Bad Gateway` | vm-caller is still starting up | Wait 2-3 min and retry |
| `504 Gateway Timeout` | inference took > 180s | Prompt is too long; reduce `messages` length |
| `404 Not Found` | Wrong path | Use exactly `/v1/chat/completions` |

---

## Sample curl + Response

```bash
$ curl -X POST http://34.93.155.42/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"messages": [{"role": "user", "content": "What is 2 + 2?"}]}'
```

```json
{
  "result": {
    "text": "2 + 2 = 4",
    "success": "You've connected two workers and they're interoperating seamlessly, now let's add a few more workers to expand this project's functionality."
  }
}
```

*(Response time on e2-medium CPU: ~15-45 seconds depending on prompt length)*

---

## Debugging Runbook

### Check all service statuses at once

```bash
# On vm-engine
gcloud compute ssh vm-engine --zone=asia-south1-a -- \
    "sudo systemctl status iii-engine"

# On vm-caller
gcloud compute ssh vm-caller --zone=asia-south1-a -- \
    "sudo systemctl status caller-worker"

# On vm-inference
gcloud compute ssh vm-inference --zone=asia-south1-a -- \
    "sudo systemctl status inference-worker"

# On vm-gateway
gcloud compute ssh vm-gateway --zone=asia-south1-a -- \
    "sudo systemctl status nginx"
```

### Common issues and fixes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `502 Bad Gateway` from nginx | caller-worker not running | `sudo systemctl restart caller-worker` on vm-caller |
| `504 Gateway Timeout` | inference-worker not running or model still loading | Check `journalctl -u inference-worker` on vm-inference |
| Worker can't connect to engine | Engine not running | `sudo systemctl restart iii-engine` on vm-engine |
| Model download failed | Network issue during startup | Re-run `setup-inference.sh` manually |
| `curl: (7) Failed to connect` | Gateway public IP changed | Run `terraform output gateway_public_ip` again |

---

## Production Hardening

*If this were going to production, here's what I'd change and why:*

**1. Tighten SSH access.**
The current `fw-allow-ssh-all` rule allows SSH from `0.0.0.0/0` (the entire
internet). In production, replace this with your office/VPN CIDR range, or
remove it entirely and use GCP's **Identity-Aware Proxy (IAP) tunnelling**,
which lets you SSH without opening port 22 to the internet at all.

**2. Enable HTTPS on the gateway.**
HTTP sends data in plaintext — anyone on the network between the user and GCP
can read the request body. Use **Let's Encrypt + Certbot** (or GCP's managed
SSL certificates) to add TLS on port 443 and redirect port 80 to 443.

**3. Add authentication to the API.**
Right now anyone who knows the IP can call the inference API. Add an API key
check in nginx (`ngx_http_auth_request_module`) or inside the caller-worker.
For production, use **GCP API Gateway** or **Cloud Run** with OAuth.

**4. Replace ephemeral public IP with a static reserved IP + Cloud DNS.**
Ephemeral IPs change when the VM restarts. Reserve a **Static External IP**
in GCP and point a domain name at it (via Cloud DNS or any DNS provider).

**5. Add a load balancer in front of the gateway.**
A single nginx VM is a single point of failure. In production, place a **GCP
HTTP(S) Load Balancer** in front of multiple gateway VMs, with a managed SSL
certificate, for zero-downtime failover.

**6. Separate secrets from startup scripts.**
Right now the `III_URL` is hardcoded in the setup scripts. Store secrets in
**GCP Secret Manager** and have the startup script fetch them at boot time with
`gcloud secrets versions access`.

**7. Add monitoring and alerting.**
Install the **GCP Ops Agent** on all VMs so metrics (CPU, memory, disk) and
logs appear in Cloud Monitoring. Set alerts for: worker service crashed,
inference latency > 60s, disk usage > 80% (the Gemma model takes significant space).

**8. Restrict internal firewall rules.**
Currently `fw-allow-internal` allows all TCP/UDP between the VMs. In a
zero-trust production environment you'd define granular rules: vm-caller may
only connect to vm-engine on port 49134; vm-gateway may only connect to vm-caller
on port 3111; vm-inference cannot initiate any connections at all.

---

## What Changes if the Model is 100x Larger

*Gemma 270M is ~270 MB. A model 100x larger (~27 GB, e.g., Llama 3 70B) changes almost everything:*

**1. You need a GPU VM (mandatory).**
A 27 GB model cannot run at useful speed on CPU. You would switch from `e2-medium`
to an `n1-standard-8` with an **NVIDIA A100 or T4 GPU** attached. Terraform's
`google_compute_instance` supports `guest_accelerator` blocks for GPUs.
Cost goes from ~$30/month to **~$1,500-3,000/month**.

**2. Model loading time balloons.**
Loading 27 GB into GPU VRAM takes 3-10 minutes on a cold start. This makes
VM preemption extremely expensive (GCP preemptible VMs restart frequently).
You'd use **non-preemptible VMs** and keep the model hot at all times.

**3. Storage changes.**
The boot disk would need to be 100-200 GB (SSD) to store the model. Or better:
use a **GCP Filestore (NFS)** mounted on vm-inference, and load the model from
there. This allows switching models without re-downloading.

**4. Model quantization becomes critical.**
A 70B model in FP16 = ~140 GB. In 4-bit GGUF = ~35-40 GB. The difference
determines whether you need 2x A100s or 1x A100. llama.cpp or vLLM with GPTQ
quantization would replace HuggingFace transformers.

**5. Switch to vLLM or TGI.**
HuggingFace `transformers` (used in `inference_worker.py`) is a general-purpose
library and is slow for serving. For a large model, replace it with:
- **vLLM** — optimised for throughput, supports continuous batching
- **Text Generation Inference (TGI)** — HuggingFace's production server

**6. Request batching is necessary.**
At this scale, serving one request at a time wastes GPU compute. vLLM's
continuous batching processes multiple incoming requests simultaneously on the
same GPU pass, dramatically increasing throughput.

**7. The iii worker architecture doesn't change.**
The caller-worker and engine configuration stay identical. Only `inference_worker.py`
changes — replace the `transformers` code with a call to a local vLLM HTTP server
(`localhost:8000`). The RPC layer is language- and model-agnostic.

**8. Cost optimisation: use reserved VMs or spot/preemptible with checkpointing.**
Large GPU VMs are expensive. Options:
- **1-year CUD (Committed Use Discount)**: ~40% cheaper if you know you'll need it
- **Spot VMs**: 60-80% cheaper, but can be preempted any time → requires the worker to reconnect to the engine gracefully (iii's reconnect logic handles this)

---

*Assignment by Krrishh Taneja | Alchemyst DevOps Internship May 2026*
