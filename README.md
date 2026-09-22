# airgap-local-llm

Three model-serving containers — an LLM, an embedding model, and a reranker —
built from one portable image (`dlabssg/local-llm`) for deployment on a
client's air-gapped network. This is the same pattern OpsGPT already runs in
production (`../OpsGPT-Platform/opsgpt/docker-compose.yml` — one `llamacpp`
image, reused for chat/embed/rerank by changing the flags each service is
started with), packaged standalone so it can ship to a client who is not
running OpsGPT and has no internet access at all.

It is llama.cpp underneath, wrapped in an OpenAI-compatible HTTP API
(`/v1/chat/completions`, `/v1/embeddings`, `/v1/rerank`) — any application that
already speaks that API (OpsGPT included) can point at these three ports and
work unmodified.

---

## 📦 Developer Guide: Build, Push to Docker Hub & Package Client Zip

### Option 1: Automated Script (Fastest)

We provide [`build-and-push.sh`](file:///c:/Users/DOL-70/Documents/Airgab-model-server/build-and-push.sh) to handle building Dockerfiles, saving `.tar` images directly into `client-package/`, pushing to Docker Hub, and optionally compressing `client-package.zip`:

```bash
# Interactive menu (prompts for CPU / GPU / Both, push, and zip)
bash build-and-push.sh

# Build CPU image, push to Docker Hub, and create client-package.zip
BUILD=cpu PUSH=1 ZIP=1 bash build-and-push.sh

# Build GPU (CUDA) image, push to Docker Hub, and create client-package.zip
BUILD=gpu PUSH=1 ZIP=1 bash build-and-push.sh

# Build BOTH images, push to Docker Hub, and create client-package.zip
BUILD=all PUSH=1 ZIP=1 bash build-and-push.sh
```

---

### Option 2: Manual Step-by-Step Commands

#### 1. Build the Docker Images from Dockerfile
```bash
# Build CPU Image (~200MB)
docker build -f Dockerfile -t dlabssg/local-llm:latest .

# Build GPU Image with CUDA 12 (~5GB)
docker build -f Dockerfile.cuda -t dlabssg/local-llm:cuda12 .
```

#### 2. Push Docker Images to Docker Hub
```bash
# 1. Log in to Docker Hub
docker login

# 2. Push CPU image
docker push dlabssg/local-llm:latest

# 3. Push GPU (CUDA) image
docker push dlabssg/local-llm:cuda12
```

#### 3. Save Docker Images to `.tar` in `client-package/`
```bash
mkdir -p client-package

# Export CPU image tar for offline transfer
docker save dlabssg/local-llm:latest -o client-package/local-llm-latest.tar

# Export GPU image tar for offline transfer
docker save dlabssg/local-llm:cuda12 -o client-package/local-llm-cuda12.tar
```

#### 4. Zip `client-package` with Docker Images
Ensure your `.gguf` model files are inside `client-package/models/` (or provide them separately):
```text
client-package/
├── local-llm-latest.tar          # CPU image (or local-llm-cuda12.tar for GPU)
├── models/                       # Place GGUF files here
│   ├── Qwen_Qwen3-8B-Q4_K_M.gguf
│   ├── bge-m3-Q8_0.gguf
│   └── bge-reranker-v2-m3-Q8_0.gguf
├── scripts/
│   └── entrypoint.sh
├── docker-compose.yml
├── setup.sh                      # One-click installer
├── test.sh                       # Smoke test script
├── .env.example
└── README.md
```

Compress the directory into a `.zip` or `.tar.gz`:
```bash
# Create zip file:
zip -r client-package.zip client-package/

# Or create compressed tarball:
tar -czvf client-package.tar.gz client-package/
```

#### 5. How the Client Runs It on the Air-Gapped Machine
Copy `client-package.zip` over USB or offline media to the target server:
```bash
unzip client-package.zip
cd client-package

# Run automated one-click setup
bash setup.sh
```

---

## The air-gap contract

**Building this image needs internet** (it clones llama.cpp and installs
Ubuntu packages). **Running it never does.** Once built, the image contains a
static binary that reads a model file from a local mounted folder and serves
HTTP — it makes no outbound calls, downloads nothing, and phones nowhere. That
split is the whole point: build once, somewhere with internet, then hand the
finished artifact to a network that has none.

Two ways to get the artifact onto the client's box, depending on how air-gapped
"air-gapped" actually is:

1. **Restricted but not fully isolated** (an allowlisted registry mirror, a
   proxy that reaches Docker Hub): `docker pull dlabssg/local-llm:latest`
   directly on the target box, then never touch the network again.
2. **Truly air-gapped, zero exceptions**: build or pull the image on a
   connected machine, then
   ```bash
   docker save dlabssg/local-llm:latest -o local-llm.tar
   # move local-llm.tar across the air gap by whatever means the client's
   # security policy allows (USB, one-way transfer station, etc.)
   docker load -i local-llm.tar
   ```
   `docker compose up` then finds the image already present locally and never
   attempts to reach Docker Hub, because the tag it's looking for already
   exists in the local image store.

Neither path requires the model FILES to touch a registry — those are `.gguf`
files, transferred the same way as the image tar, and referenced by filename
in `.env` (see below). They never get baked into the image.

## Quick start

```bash
# Step 1: detect your hardware and generate optimal .env
bash scripts/detect-hardware.sh
# review .env.generated, fill in model filenames, then:
cp .env.generated .env

# Step 2: deploy
docker compose pull        # or: docker load -i local-llm.tar   (see above)
docker compose up -d       # or: docker compose --profile gpu up -d  (for GPU)
bash scripts/verify.sh     # health + one real call per service
```

## Configuring it

Everything tunable is in `.env` (copy `.env.example` — every value there has a
comment explaining what it does and why the default is what it is). The three
things you cannot skip:

- `LLM_MODEL_FILE`, `EMBED_MODEL_FILE`, `RERANK_MODEL_FILE` — the GGUF
  filenames under `./models/`. Compose refuses to start a service whose file
  isn't set (`docker-compose.yml` uses `${VAR:?message}` for these three on
  purpose — a service silently running with the WRONG model, or failing to
  start with a confusing error, is worse than a clear one up front).
- `EMBED_POOLING` — **this is not a free choice, it's a property of the
  embedding model you picked.** BGE-M3 and nomic-embed-text use `mean`;
  BGE-large-en-v1.5 uses `cls`. Getting it wrong does not error — the server
  starts and answers requests, it just returns embeddings that don't actually
  represent the text well, and nothing will tell you that except worse-than-
  expected search results down the line. Check whatever the model's own
  documentation says.
- `*_THREADS` — set these to match the CPU cores actually available on the
  **client's** box, not whatever machine you built the image on. Use
  `llama-bench` (included in the image) to check real throughput at a few
  thread counts before locking in a value:
  ```bash
  docker run --rm -v "$(pwd)/models:/models:ro" --entrypoint llama-bench \
    dlabssg/local-llm:latest -m /models/<your-model>.gguf -t 4,8,16
  ```

### Tuning for the client's CPU

The shipped image is built with `GGML_AVX2=ON, GGML_AVX512=OFF` — safe,
portable settings that run on essentially any x86_64 server from the last
~10 years. If you know the client's actual CPU supports more (AVX-512, for
instance), rebuilding with matching flags gets real throughput back:

```bash
BUILD_ARGS="--build-arg GGML_AVX512=ON" bash build-and-push.sh
```

Do this on hardware that MATCHES what you're deploying to, or on a machine you
know is a strict superset — a binary built with instructions the runtime CPU
lacks crashes with `Illegal instruction`, not a graceful fallback.

## NUMA — multi-socket CPU optimization

For dual-socket servers (dual Xeon, EPYC, etc.), NUMA-aware configuration
gives a **~50% speedup** in decode throughput (benchmarked: 2.9 → 4.2 tok/s
on a 40-core dual-socket Xeon). The entrypoint wrapper runs `numactl
--interleave=all` when enabled, spreading model memory across both memory
controllers.

### How to enable

Set these in `.env`:

```env
NUMA_ENABLED=1

# Pin the LLM to one NUMA node's cores (use `lscpu` to find yours)
LLM_CPUSET=0-19          # first 20 cores (NUMA node 0)
LLM_THREADS=20            # match the cpuset

# Embed/rerank are lighter — no pinning needed
EMBED_THREADS=8
RERANK_THREADS=8
```

Then `docker compose up -d` as usual.

### Finding your NUMA layout

```bash
lscpu | grep -i numa
# NUMA node0 CPU(s):   0-19
# NUMA node1 CPU(s):   20-39

# Verify with:
numactl --hardware
```

### Disabling kernel NUMA balancing (recommended)

Kernel auto-balancing fights with explicit NUMA pinning. Disable it:

```bash
echo 'kernel.numa_balancing=0' | sudo tee /etc/sysctl.d/99-numa.conf
sudo sysctl -p /etc/sysctl.d/99-numa.conf
```

## GPU — NVIDIA GPU offloading

For clients with NVIDIA GPUs, model layers can be offloaded to GPU VRAM for
dramatically faster inference (10-100x faster than CPU for large models).

### Prerequisites on the host

1. **NVIDIA GPU drivers** — `nvidia-smi` should show your GPU(s)
2. **NVIDIA Container Toolkit** — install with:
   ```bash
   # Add NVIDIA package repo
   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
     | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
   curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
     | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
     | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
   sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   ```
3. **CUDA image built** — `CUDA=1 bash build-and-push.sh`

### Building the GPU image

```bash
# Build locally
CUDA=1 bash build-and-push.sh

# Or for air-gapped transfer:
CUDA=1 bash build-and-push.sh
docker save dlabssg/local-llm:cuda12 -o local-llm-cuda12.tar
# Transfer and load on the target box:
docker load -i local-llm-cuda12.tar
```

### Running with GPU

Set in `.env`:

```env
LOCAL_LLM_IMAGE=dlabssg/local-llm:cuda12

# 99 = offload all layers to GPU. If the model doesn't fit entirely in VRAM,
# llama.cpp automatically keeps remaining layers on CPU (no crash).
LLM_GPU_LAYERS=99
EMBED_GPU_LAYERS=99
RERANK_GPU_LAYERS=99
```

Start with the `gpu` profile:

```bash
docker compose --profile gpu up -d
bash scripts/verify.sh
```

### Partial GPU offloading

If your GPU has limited VRAM, offload only some layers:

```bash
# Check your VRAM
nvidia-smi

# Set layers based on what fits (each layer ~100-400 MB depending on model)
LLM_GPU_LAYERS=20      # offload 20 layers, keep the rest on CPU
EMBED_GPU_LAYERS=99    # embedding models are small, usually fit entirely
RERANK_GPU_LAYERS=99   # reranker models are small too
```

### Pointing an application at these servers

The three ports (defaults: LLM `8097`, embed `8098`, reranker `8099`) speak the
same OpenAI-compatible protocol OpsGPT's own model servers do. If the client is
also running (a copy of) OpsGPT, its `.env` config maps directly:

```
OPSGPT_LLAMACPP_BASE_URL=http://<this-host>:8097
OPSGPT_EMBED_BASE_URL=http://<this-host>:8098     (or OPSGPT_EMBED_BGE_BASE_URL — match the model you loaded)
OPSGPT_RERANKER_BASE_URL=http://<this-host>:8099
```

For anything else: standard OpenAI client libraries work by pointing
`base_url` at `http://<host>:<port>/v1`.

## Security note

These containers have **no authentication** — same as OpsGPT's own model
servers, which is a deliberate tradeoff for a trusted internal network, not an
oversight. Do not publish these ports to anything broader than the client's
internal network; put them behind a firewall/security group that only allows
the application server(s) that are supposed to call them.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | The image: llama.cpp built from source, CPU-only, with NUMA support |
| `Dockerfile.cuda` | GPU variant: same as above but with CUDA for NVIDIA GPU offloading |
| `docker-compose.yml` | CPU services + GPU services (behind `gpu` profile), all from one image |
| `.env.example` | Every configurable value, with defaults, NUMA, GPU, and examples |
| `build-and-push.sh` | Build CPU or GPU image (`CUDA=1`); push to Docker Hub only with `PUSH=1` |
| `scripts/entrypoint.sh` | NUMA-aware entrypoint: runs `numactl --interleave=all` when `NUMA_ENABLED=1` |
| `scripts/detect-hardware.sh` | Auto-detects CPU, NUMA, GPU, RAM and generates optimal `.env.generated` |
| `scripts/verify.sh` | Post-deploy smoke test: health + one real request per service |
| `models/` | Where the client's `.gguf` files go (bind-mounted read-only, nothing committed) |

## Deployment cheat sheet

```bash
# ── CPU, simple ──
cp .env.example .env
# edit .env: set model files + threads
docker compose up -d

# ── CPU, 40-core NUMA ──
cp .env.example .env
# edit .env: set model files, NUMA_ENABLED=1, LLM_CPUSET=0-19, LLM_THREADS=20
docker compose up -d

# ── GPU ──
CUDA=1 bash build-and-push.sh
cp .env.example .env
# edit .env: LOCAL_LLM_IMAGE=dlabssg/local-llm:cuda12, set model files + GPU_LAYERS
docker compose --profile gpu up -d

# ── Verify (all profiles) ──
bash scripts/verify.sh
```
