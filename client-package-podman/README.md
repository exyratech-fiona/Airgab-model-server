# Air-Gapped Local LLM Server — Client Deployment Package (Podman Edition)

A standalone, completely offline OpenAI-compatible Model Server configured specifically for **Podman** and **podman-compose**, running:
- **LLM Chat Completion**: `/v1/chat/completions` (Default port: `8097`)
- **Embeddings**: `/v1/embeddings` (Default port: `8098`)
- **Reranker**: `/v1/rerank` (Default port: `8099`)

---

## 📦 Package Contents

When unzipped (`unzip client-package-podman.zip`), this folder contains:
- `local-llm-latest.tar` (or `local-llm-cuda12.tar` for GPU) — Pre-built offline container image
- `models/` — Directory for your 3 `.gguf` model files
- `setup.sh` — 1-click automated installation & benchmark script for Podman
- `test.sh` — Verification script for health and token generation speeds
- `docker-compose.yml` — Compose orchestration tuned for Podman, SELinux (`:ro,z`), and rootless execution
- `.env.example` — Configuration template with hardware tuning options

---

## 🔑 Podman & SELinux Features in this Package

1. **Rootless Podman Support:** No root or `sudo` required. Configurations that require elevated host privileges (such as raw `oom_score_adj`) are omitted so rootless containers start cleanly.
2. **SELinux Support:** Volumes are mounted with `:ro,z` shared relabeling, preventing "Permission denied" errors on RHEL, CentOS, Rocky Linux, and Fedora.
3. **Flexible Compose Engine:** Automatically detects and works with either `podman compose` (plugin) or `podman-compose` (Python CLI).

---

## 🚀 One-Click Setup (Fully Automated)

Everything is automated — image loading into Podman, hardware detection (CPU cores, NUMA, GPU), `.env` configuration, service startup, and verification.

```bash
# 1. Unzip and enter this directory
unzip client-package-podman.zip
cd client-package-podman

# 2. Make sure your 3 .gguf files are inside ./models/
ls models/

# 3. Run the one-click installer
bash setup.sh
```

`setup.sh` will:
1. Verify Podman and Podman Compose installation.
2. Load `local-llm-latest.tar` (or `local-llm-cuda12.tar`) into Podman.
3. Auto-detect your CPU topology, NUMA nodes, RAM, and NVIDIA GPUs.
4. Automatically match and map your model files from `./models/`.
5. Spin up the containers using `podman compose` / `podman-compose`.
6. Wait for the models to load and run automated smoke tests.
7. Print your **Network API Endpoints** and ready-to-run curl commands!

> **Tip for Rootless Podman:** To keep containers running in the background after you log out of your terminal session, run:
> ```bash
> loginctl enable-linger $USER
> ```

---

## 🧪 Testing Your Endpoints

You can re-test anytime using:
```bash
bash test.sh
```

### Quick Test Commands

#### 1. Chat Completion (Hi Test)
```bash
curl http://localhost:8097/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hi"}],
    "max_tokens": 50
  }'
```

#### 2. Embeddings
```bash
curl http://localhost:8098/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world"}'
```

#### 3. Reranker
```bash
curl http://localhost:8099/v1/rerank \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What is AI?",
    "documents": ["AI is artificial intelligence.", "Today is sunny."]
  }'
```

---

## 🛠️ Management Commands

Using `podman compose` (or replace with `podman-compose`):

- **Stop services**:
  ```bash
  podman compose down
  ```
- **Start services**:
  ```bash
  podman compose up -d
  # Or with GPU profile:
  podman compose --profile gpu up -d
  ```
- **View logs**:
  ```bash
  podman compose logs -f
  ```
- **Check status**:
  ```bash
  podman compose ps
  ```
