# Air-Gapped Local LLM Server — Client Deployment Package

A standalone, completely offline OpenAI-compatible Model Server running:
- **LLM Chat Completion**: `/v1/chat/completions` (Default port: `8094`)
- **Embeddings**: `/v1/embeddings` (Default port: `8090`)
- **Reranker**: `/v1/rerank` (Default port: `8092`)

---

## 🚀 One-Click Setup (Fully Automated)

Everything is automated — image loading, hardware detection (CPU cores, NUMA, GPU), `.env` configuration, service startup, and verification.

```bash
# 1. Enter this directory
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
curl http://localhost:8094/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hi"}],
    "max_tokens": 50
  }'
```

#### 2. Embeddings
```bash
curl http://localhost:8090/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world"}'
```

#### 3. Reranker
```bash
curl http://localhost:8092/v1/rerank \
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

