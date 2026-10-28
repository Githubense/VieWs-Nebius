# VieWs — Nebius Serverless Endpoints Proxy

A lightweight, secure inference proxy built with **FastAPI** designed for deployment on **Nebius Serverless Endpoints**.

This proxy shields client devices (iOS, iPadOS, macOS) from exposing your **Nebius Token Factory** API key while generating rich, atmospheric procedural weather parameters and matching colour palettes powered by **NVIDIA Nemotron** open models.

---

## Architecture

```
┌─────────────────────┐
│  VieWs (iOS / Mac)  │  (Zero API keys in binary)
└──────────┬──────────┘
           │ HTTPS POST /v1/scene {"emotion": "melancholy"}
           ▼
┌───────────────────────────────────────────────┐
│  Nebius Serverless Endpoint (FastAPI Proxy)   │
│   • Enforces rate limiting & input bounds     │
│   • Injects server-side atmospheric prompts   │
│   • Authenticates via NEBIUS_API_KEY          │
│   • Strips <think> tags & validates physics   │
└──────────────────────┬────────────────────────┘
                       │ HTTPS POST /chat/completions (Bearer Auth)
                       ▼
┌───────────────────────────────────────────────┐
│  Nebius Token Factory                         │
│  (NVIDIA Nemotron Open Models)                │
└───────────────────────────────────────────────┘
```

---

## Features

- **Key Isolation:** Your `NEBIUS_API_KEY` stays on the serverless backend.
- **Server-Side Prompt Injection:** The client only sends `{ "emotion": "..." }`. The system cannot be repurposed as a generic LLM proxy.
- **Atmospheric Physics Sanitization:** Enforces mutual exclusivity between rain and snow, suppresses clearness under heavy precipitation/fog, and validates contrast between particles and color tone.
- **Reasoning Tag Stripping:** Automatically removes `<think>...</think>` tags and code fences emitted by Nemotron reasoning variants.
- **Abuse Controls:** IP-based rate limiting (default 40 requests/min) and max input length clamping (300 characters).
- **Graceful Fallbacks:** Guaranteed deterministic scene return if network fails or quota is exceeded.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `NEBIUS_API_KEY` | *(Required)* | Your Nebius Token Factory API key (`https://tokenfactory.nebius.com`). |
| `NEBIUS_MODEL` | `nvidia/llama-3.1-nemotron-70b-instruct` | Exact NVIDIA Nemotron model ID on Token Factory. |
| `NEBIUS_BASE_URL` | `https://api.tokenfactory.nebius.com/v1/` | Base URL for Token Factory chat completions. |
| `RATE_LIMIT_PER_MINUTE` | `40` | Maximum requests per IP per minute. |
| `APP_TOKEN` | `""` | Optional shared token required via `X-App-Token` header. |

---

## Local Development & Testing

1. Create a virtual environment and install dependencies:
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   ```

2. Run tests:
   ```bash
   pytest test_proxy.py
   # or with standard library:
   python3 test_logic.py
   ```

3. Start local development server:
   ```bash
   export NEBIUS_API_KEY="your-token-factory-key"
   uvicorn main:app --reload --port 8000
   ```

4. Test endpoint:
   ```bash
   curl -X POST http://localhost:8000/v1/scene \
     -H "Content-Type: application/json" \
     -d '{"emotion": "a quiet sense of wonder"}'
   ```

---

## Deploying to Nebius Serverless Endpoints

### Step 1: Build & Push Container Image

Build the container image and push it to your container registry (such as GitHub Container Registry `ghcr.io` or Docker Hub):

```bash
# Build Docker image
docker build -t ghcr.io/<your-username>/views-nebius-proxy:latest .

# Push image
docker push ghcr.io/<your-username>/views-nebius-proxy:latest
```

### Step 2: Deploy via Nebius Web Console

1. Navigate to [Nebius AI Cloud Console](https://console.nebius.com).
2. In the left navigation, select **Serverless AI** → **Endpoints**.
3. Click **Create endpoint**.
4. Configure settings:
   - **Name:** `views-weather-proxy`
   - **Container Image:** `ghcr.io/<your-username>/views-nebius-proxy:latest`
   - **Platform & Preset:** `cpu-d3` (e.g. `2vcpu-8gb` or `4vcpu-16gb` — proxy is lightweight).
   - **Container Port:** `8000`
   - **Public Access:** Enabled (provides a secure managed HTTPS URL).
   - **Environment Variables:**
     - `NEBIUS_API_KEY`: `<your_token_factory_key>`
     - `NEBIUS_MODEL`: `<your_nemotron_model_id>`
5. Click **Create endpoint** and wait for deployment to complete.
6. Copy the assigned HTTPS Endpoint URL (e.g., `https://<endpoint-id>.nebius.cloud`).

### Step 3: Deploy via Nebius CLI (Alternative)

```bash
nebius ai endpoint create \
  --name views-weather-proxy \
  --image ghcr.io/<your-username>/views-nebius-proxy:latest \
  --platform cpu-d3 \
  --preset 2vcpu-8gb \
  --public \
  --container-port 8000 \
  --env "NEBIUS_API_KEY=<your_key>" \
  --env "NEBIUS_MODEL=nvidia/llama-3.1-nemotron-70b-instruct"
```

---

## Connecting the iOS App

Once deployed, provide the proxy URL to the iOS app:

- In `Secrets.swift`:
  ```swift
  static let nebiusProxyURL = "https://<endpoint-id>.nebius.cloud"
  ```
- Or via environment variable in Xcode Scheme:
  ```
  NEBIUS_PROXY_URL = https://<endpoint-id>.nebius.cloud
  ```

When `nebiusProxyURL` is configured, the app automatically switches to proxy mode and requires no client-side API keys.
