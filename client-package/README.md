# Air-Gapped Local LLM Server — Client Deployment Package

A standalone, completely offline OpenAI-compatible Model Server running:
- **LLM Chat Completion**: `/v1/chat/completions` (Default port: `8097`)
- **Embeddings**: `/v1/embeddings` (Default port: `8098`)
- **Reranker**: `/v1/rerank` (Default port: `8099`)

---

## 📦 Package Contents

When unzipped (`unzip client-package.zip`), this folder contains:
- `local-llm-latest.tar` (or `local-llm-cuda12.tar` for GPU) — Pre-built offline Docker image
- `models/` — Directory for your 3 `.gguf` model files
- `setup.sh` — 1-click automated installation & benchmark script
- `test.sh` — Verification script for health and token speeds
- `docker-compose.yml` — Service orchestration with NUMA & GPU support
- `.env.example` — Configuration template with hardware tuning options

---

## 🚀 One-Click Setup (Fully Automated)

Everything is automated — image loading, hardware detection (CPU cores, NUMA, GPU), `.env` configuration, service startup, and verification.

```bash
# 1. Unzip and enter this directory
unzip client-package.zip
cd client-package

# 2. Make sure your 3 .gguf files are inside ./models/
ls models/

# 3. Run the one-click installer
bash setup.sh
```

`setup.sh` will:
1. Load `local-llm-latest.tar` (or `local-llm-cuda12.tar`) into Docker.
2. Auto-detect your CPU topology, NUMA nodes, RAM, and NVIDIA GPUs.
3. Automatically match and map your model files from `./models/`.
4. Spin up the containers using Docker Compose.
5. Wait for the models to load and run automated smoke tests.
6. Print your **Network API Endpoints** and ready-to-run curl commands!

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

- **Stop services**: `docker compose down`
- **Start services**: `docker compose up -d` (or `docker compose --profile gpu up -d` if using GPU)
- **View logs**: `docker compose logs -f`
- **Check status**: `docker compose ps`

