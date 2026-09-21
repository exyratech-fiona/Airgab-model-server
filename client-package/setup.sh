#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ONE-CLICK SETUP for Air-Gapped LLM Server                                 ║
# ║                                                                             ║
# ║  This script does EVERYTHING:                                               ║
# ║    1. Loads the Docker image from the tar file                              ║
# ║    2. Detects your hardware (CPU, NUMA, GPU, RAM)                           ║
# ║    3. Generates optimal .env configuration                                  ║
# ║    4. Starts all services                                                   ║
# ║    5. Waits for them to be healthy                                          ║
# ║    6. Runs a smoke test                                                     ║
# ║    7. Prints your API endpoints                                             ║
# ║                                                                             ║
# ║  Usage:                                                                     ║
# ║    bash setup.sh                                                            ║
# ║                                                                             ║
# ║  Prerequisites:                                                             ║
# ║    - Docker + Docker Compose v2 installed                                   ║
# ║    - .tar image file in this folder                                         ║
# ║    - .gguf model files in ./models/                                         ║
# ║                                                                             ║
# ║  NO INTERNET REQUIRED.                                                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header()  { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()      { echo -e "  ${GREEN}✔${NC} $1"; }
fail()    { echo -e "  ${RED}✘${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $1"; }
info()    { echo -e "  ${BOLD}$1${NC}"; }

# ══════════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ══════════════════════════════════════════════════════════════════════════════

header "Pre-flight Checks"

# Check Docker
if ! command -v docker &>/dev/null; then
  fail "Docker is not installed. Install it first:"
  echo "    sudo apt update && sudo apt install -y docker.io docker-compose-v2"
  echo "    sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi
ok "Docker installed ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ','))"

if ! docker compose version &>/dev/null 2>&1; then
  fail "Docker Compose v2 not found. Install it:"
  echo "    sudo apt install -y docker-compose-v2"
  exit 1
fi
ok "Docker Compose installed"

# Check if user can run docker without sudo
if ! docker ps &>/dev/null 2>&1; then
  fail "Cannot run Docker. Add yourself to the docker group:"
  echo "    sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi
ok "Docker access OK"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: LOAD DOCKER IMAGE
# ══════════════════════════════════════════════════════════════════════════════

header "Step 1: Loading Docker Image"

# Intelligently detect which tar file to load
TAR_FILE=""
CLIENT_HAS_NVIDIA=0

if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  CLIENT_HAS_NVIDIA=1
fi

if [ -f "./local-llm-cuda12.tar" ] && [ "$CLIENT_HAS_NVIDIA" -eq 1 ]; then
  TAR_FILE="./local-llm-cuda12.tar"
  info "NVIDIA GPU detected on host -> Selected GPU image: $TAR_FILE"
elif [ -f "./local-llm-latest.tar" ]; then
  TAR_FILE="./local-llm-latest.tar"
  info "Selected CPU image: $TAR_FILE"
elif [ -f "./local-llm-cuda12.tar" ]; then
  TAR_FILE="./local-llm-cuda12.tar"
  info "Selected GPU image: $TAR_FILE"
else
  TAR_FILE=$(find . -maxdepth 1 -name "*.tar" -type f | head -1)
fi

if [ -z "$TAR_FILE" ]; then
  # Check if image already exists locally
  if [ "$CLIENT_HAS_NVIDIA" -eq 1 ] && docker image inspect dlabssg/local-llm:cuda12 &>/dev/null 2>&1; then
    ok "Image dlabssg/local-llm:cuda12 already loaded"
    LOADED_IMAGE="dlabssg/local-llm:cuda12"
    IS_GPU_IMAGE=1
  elif docker image inspect dlabssg/local-llm:latest &>/dev/null 2>&1; then
    ok "Image dlabssg/local-llm:latest already loaded"
    LOADED_IMAGE="dlabssg/local-llm:latest"
    IS_GPU_IMAGE=0
  elif docker image inspect dlabssg/local-llm:cuda12 &>/dev/null 2>&1; then
    ok "Image dlabssg/local-llm:cuda12 already loaded"
    LOADED_IMAGE="dlabssg/local-llm:cuda12"
    IS_GPU_IMAGE=1
  else
    fail "No .tar file found in this folder and no image loaded in Docker."
    echo "    Place the Docker image tar file (local-llm-latest.tar or local-llm-cuda12.tar) here."
    exit 1
  fi
else
  info "Loading $TAR_FILE (this may take a few minutes)..."
  docker load -i "$TAR_FILE"
  ok "Image loaded from $TAR_FILE"

  if [[ "$TAR_FILE" =~ "cuda" ]] || docker image inspect dlabssg/local-llm:cuda12 &>/dev/null 2>&1; then
    LOADED_IMAGE="dlabssg/local-llm:cuda12"
    IS_GPU_IMAGE=1
  else
    LOADED_IMAGE="dlabssg/local-llm:latest"
    IS_GPU_IMAGE=0
  fi
fi

ok "Active image: $LOADED_IMAGE (mode: $([ "$IS_GPU_IMAGE" -eq 1 ] && echo "GPU" || echo "CPU"))"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: CHECK MODEL FILES
# ══════════════════════════════════════════════════════════════════════════════

header "Step 2: Checking Model Files"

if [ ! -d "./models" ]; then
  mkdir -p ./models
  fail "Created models/ directory — place your .gguf files there and re-run."
  exit 1
fi

GGUF_FILES=$(find ./models -name "*.gguf" -type f 2>/dev/null)
GGUF_COUNT=$(echo "$GGUF_FILES" | grep -c . 2>/dev/null || echo 0)

if [ "$GGUF_COUNT" -eq 0 ]; then
  fail "No .gguf model files found in ./models/"
  echo "    Place your 3 model files (LLM, embedding, reranker) in ./models/ and re-run."
  exit 1
fi

echo ""
echo "  Found $GGUF_COUNT model file(s):"
for f in $GGUF_FILES; do
  size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
  echo "    $(basename "$f")  ($size)"
done

# Auto-detect model roles
LLM_FILE=""
EMBED_FILE=""
RERANK_FILE=""

for f in $GGUF_FILES; do
  fname=$(basename "$f")
  fl=$(echo "$fname" | tr '[:upper:]' '[:lower:]')

  if echo "$fl" | grep -qiE '(rerank|cross.?encoder)'; then
    RERANK_FILE="$fname"
  elif echo "$fl" | grep -qiE '(embed|bge-m3|nomic|e5-|gte-)'; then
    EMBED_FILE="$fname"
  elif echo "$fl" | grep -qiE '(instruct|chat|llm|qwen|mistral|llama|phi|gemma|deepseek|yi-|coder)'; then
    LLM_FILE="$fname"
  fi
done

# If only some were detected, assign remaining files
UNASSIGNED=()
for f in $GGUF_FILES; do
  fname=$(basename "$f")
  if [ "$fname" != "$LLM_FILE" ] && [ "$fname" != "$EMBED_FILE" ] && [ "$fname" != "$RERANK_FILE" ]; then
    UNASSIGNED+=("$fname")
  fi
done

# Fill in blanks from unassigned
for u in "${UNASSIGNED[@]:-}"; do
  [ -z "$u" ] && continue
  if [ -z "$LLM_FILE" ]; then
    LLM_FILE="$u"
  elif [ -z "$EMBED_FILE" ]; then
    EMBED_FILE="$u"
  elif [ -z "$RERANK_FILE" ]; then
    RERANK_FILE="$u"
  fi
done

echo ""
if [ -n "$LLM_FILE" ]; then ok "LLM model:      $LLM_FILE"; else warn "LLM model: not detected"; fi
if [ -n "$EMBED_FILE" ]; then ok "Embed model:    $EMBED_FILE"; else warn "Embed model: not detected"; fi
if [ -n "$RERANK_FILE" ]; then ok "Reranker model: $RERANK_FILE"; else warn "Reranker model: not detected"; fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: DETECT HARDWARE & GENERATE .env
# ══════════════════════════════════════════════════════════════════════════════

header "Step 3: Detecting Hardware"

# CPU
TOTAL_CORES=$(nproc 2>/dev/null || echo 4)
PHYSICAL_CORES=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/ {gsub(/ /,"",$2); print $2}' || echo "")
SOCKETS=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/ {gsub(/ /,"",$2); print $2}' || echo "1")
THREADS_PER_CORE=$(lscpu 2>/dev/null | awk -F: '/^Thread\(s\) per core/ {gsub(/ /,"",$2); print $2}' || echo "1")
CPU_MODEL=$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2}' || echo "unknown")

if [ -n "$PHYSICAL_CORES" ] && [ -n "$SOCKETS" ]; then
  TOTAL_PHYSICAL=$((PHYSICAL_CORES * SOCKETS))
else
  TOTAL_PHYSICAL=$TOTAL_CORES
fi

ok "CPU: $CPU_MODEL"
ok "Cores: $TOTAL_PHYSICAL physical, $TOTAL_CORES logical, $SOCKETS socket(s)"

# NUMA
NUMA_NODES=$(lscpu 2>/dev/null | awk -F: '/^NUMA node\(s\)/ {gsub(/ /,"",$2); print $2}' || echo 1)
NUMA_ENABLED_REC=0
NUMA_CPUSET=""

if [ "$NUMA_NODES" -gt 1 ]; then
  NUMA_ENABLED_REC=1
  NUMA_CPUSET=$(lscpu 2>/dev/null | awk -F: '/^NUMA node0 CPU/ {gsub(/^[ \t]+/,"",$2); print $2}' || echo "")
  ok "NUMA: $NUMA_NODES nodes (will enable interleaving)"
  CORES_PER_NODE=${PHYSICAL_CORES:-$((TOTAL_CORES / NUMA_NODES))}
else
  ok "NUMA: single socket (no optimization needed)"
  CORES_PER_NODE=$TOTAL_PHYSICAL
fi

# RAM
TOTAL_RAM_GB=$(($(awk '/^MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 / 1024))
ok "RAM: ${TOTAL_RAM_GB} GB"

# GPU
HAS_GPU=0
GPU_COUNT_DETECTED=0
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  HAS_GPU=1
  GPU_COUNT_DETECTED=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
  GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 | xargs)
  ok "GPU: $GPU_COUNT_DETECTED x $GPU_NAME ($GPU_VRAM)"
else
  ok "GPU: none detected (CPU-only mode)"
fi

# Calculate thread counts
if [ "$NUMA_ENABLED_REC" -eq 1 ]; then
  REC_LLM_THREADS=$CORES_PER_NODE
  REC_EMBED_THREADS=$(( CORES_PER_NODE / 2 ))
  REC_RERANK_THREADS=$(( CORES_PER_NODE / 2 ))
else
  REC_LLM_THREADS=$TOTAL_PHYSICAL
  REC_EMBED_THREADS=$(( TOTAL_PHYSICAL / 2 ))
  REC_RERANK_THREADS=$(( TOTAL_PHYSICAL / 2 ))
fi
[ "$REC_EMBED_THREADS" -lt 2 ] && REC_EMBED_THREADS=2
[ "$REC_RERANK_THREADS" -lt 2 ] && REC_RERANK_THREADS=2

# Memory limits
if [ "$TOTAL_RAM_GB" -ge 32 ]; then
  LLM_MEM="16g"; EMBED_MEM="4g"; RERANK_MEM="4g"
elif [ "$TOTAL_RAM_GB" -ge 16 ]; then
  LLM_MEM="10g"; EMBED_MEM="3g"; RERANK_MEM="3g"
else
  LLM_MEM="6g"; EMBED_MEM="2g"; RERANK_MEM="2g"
fi

# Determine deployment mode
USE_GPU=0
if [ "$HAS_GPU" -eq 1 ] && [ "$IS_GPU_IMAGE" -eq 1 ]; then
  USE_GPU=1
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: GENERATE .env
# ══════════════════════════════════════════════════════════════════════════════

header "Step 4: Generating Configuration"

# Get the server's IP for endpoint display
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

cat > .env <<ENVEOF
# Auto-generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Host: $(hostname) | CPU: ${TOTAL_PHYSICAL} cores | RAM: ${TOTAL_RAM_GB}GB | GPU: $([ "$HAS_GPU" -eq 1 ] && echo "$GPU_NAME" || echo "none")

# ---- Image ----
LOCAL_LLM_IMAGE=${LOADED_IMAGE}

# ---- LLM ----
LLM_MODEL_FILE=${LLM_FILE}
LLM_MODEL_NAME=llm
LLM_PORT=8094
LLM_CTX=8192
LLM_THREADS=${REC_LLM_THREADS}
LLM_PARALLEL=1
LLM_MEM_LIMIT=${LLM_MEM}

# ---- Embeddings ----
EMBED_MODEL_FILE=${EMBED_FILE}
EMBED_MODEL_NAME=embed
EMBED_PORT=8090
EMBED_CTX=4096
EMBED_THREADS=${REC_EMBED_THREADS}
EMBED_MEM_LIMIT=${EMBED_MEM}
EMBED_POOLING=mean

# ---- Reranker ----
RERANK_MODEL_FILE=${RERANK_FILE}
RERANK_MODEL_NAME=reranker
RERANK_PORT=8092
RERANK_CTX=4096
RERANK_THREADS=${REC_RERANK_THREADS}
RERANK_MEM_LIMIT=${RERANK_MEM}

# ---- NUMA ----
NUMA_ENABLED=${NUMA_ENABLED_REC}
NUMA_MODE=distribute
LLM_CPUSET=${NUMA_CPUSET}
EMBED_CPUSET=
RERANK_CPUSET=

# ---- GPU ----
GPU_COUNT=${GPU_COUNT_DETECTED:-all}
LLM_GPU_LAYERS=$([ "$USE_GPU" -eq 1 ] && echo 99 || echo 0)
EMBED_GPU_LAYERS=$([ "$USE_GPU" -eq 1 ] && echo 99 || echo 0)
RERANK_GPU_LAYERS=$([ "$USE_GPU" -eq 1 ] && echo 99 || echo 0)
ENVEOF

ok "Generated .env"

# Validate required fields
MISSING=0
if [ -z "$LLM_FILE" ]; then
  warn "LLM_MODEL_FILE is empty — edit .env and set it manually"
  MISSING=1
fi
if [ -z "$EMBED_FILE" ]; then
  warn "EMBED_MODEL_FILE is empty — edit .env and set it manually"
  MISSING=1
fi
if [ -z "$RERANK_FILE" ]; then
  warn "RERANK_MODEL_FILE is empty — edit .env and set it manually"
  MISSING=1
fi

if [ "$MISSING" -eq 1 ]; then
  echo ""
  warn "Some model files could not be auto-detected."
  echo "    Edit .env and fill in the missing model filenames, then re-run this script."
  echo "    Available .gguf files in models/:"
  for f in $GGUF_FILES; do echo "      $(basename "$f")"; done
  exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: START SERVICES
# ══════════════════════════════════════════════════════════════════════════════

header "Step 5: Starting Services"

# Stop any existing containers
docker compose down 2>/dev/null || true

if [ "$USE_GPU" -eq 1 ]; then
  info "Starting in GPU mode..."
  docker compose --profile gpu up -d
else
  info "Starting in CPU mode..."
  docker compose up -d
fi

ok "Containers started"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: WAIT FOR HEALTH
# ══════════════════════════════════════════════════════════════════════════════

header "Step 6: Waiting for Models to Load"

info "Models are loading into memory. This can take 1-5 minutes..."
echo ""

LLM_PORT=8094
EMBED_PORT=8090
RERANK_PORT=8092

MAX_WAIT=300  # 5 minutes
INTERVAL=10
ELAPSED=0

LLM_READY=0
EMBED_READY=0
RERANK_READY=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
  if [ $LLM_READY -eq 0 ] && curl -fsS --max-time 3 "http://localhost:$LLM_PORT/health" &>/dev/null; then
    ok "LLM server ready"
    LLM_READY=1
  fi
  if [ $EMBED_READY -eq 0 ] && curl -fsS --max-time 3 "http://localhost:$EMBED_PORT/health" &>/dev/null; then
    ok "Embedding server ready"
    EMBED_READY=1
  fi
  if [ $RERANK_READY -eq 0 ] && curl -fsS --max-time 3 "http://localhost:$RERANK_PORT/health" &>/dev/null; then
    ok "Reranker server ready"
    RERANK_READY=1
  fi

  if [ $LLM_READY -eq 1 ] && [ $EMBED_READY -eq 1 ] && [ $RERANK_READY -eq 1 ]; then
    break
  fi

  echo -ne "  Waiting... ${ELAPSED}s / ${MAX_WAIT}s\r"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

if [ $LLM_READY -eq 0 ] || [ $EMBED_READY -eq 0 ] || [ $RERANK_READY -eq 0 ]; then
  warn "Some services didn't become healthy in ${MAX_WAIT}s."
  echo "    Check logs: docker compose logs"
  echo "    They may still be loading — large models take longer."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: TEST
# ══════════════════════════════════════════════════════════════════════════════

header "Step 7: Running Tests"

PASS=0
TOTAL=3

# Test LLM
echo ""
info "Testing LLM (chat completion)..."
LLM_RESPONSE=$(curl -fsS --max-time 120 "http://localhost:$LLM_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":50}' \
  2>/dev/null || echo "FAIL")

if echo "$LLM_RESPONSE" | grep -q '"choices"'; then
  REPLY=$(echo "$LLM_RESPONSE" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"$//')
  ok "LLM responded: \"$REPLY\""
  PASS=$((PASS + 1))
else
  fail "LLM test failed"
  echo "    Response: $LLM_RESPONSE"
fi

# Test Embeddings
echo ""
info "Testing Embeddings..."
EMBED_RESPONSE=$(curl -fsS --max-time 30 "http://localhost:$EMBED_PORT/v1/embeddings" \
  -H 'Content-Type: application/json' \
  -d '{"input":"Hello world test sentence"}' \
  2>/dev/null || echo "FAIL")

if echo "$EMBED_RESPONSE" | grep -q '"embedding"'; then
  DIMS=$(echo "$EMBED_RESPONSE" | grep -o '"embedding":\[[^]]*\]' | head -1 | tr ',' '\n' | wc -l)
  ok "Embeddings returned vector (${DIMS} dimensions)"
  PASS=$((PASS + 1))
else
  fail "Embedding test failed"
  echo "    Response: $EMBED_RESPONSE"
fi

# Test Reranker
echo ""
info "Testing Reranker..."
RERANK_RESPONSE=$(curl -fsS --max-time 30 "http://localhost:$RERANK_PORT/v1/rerank" \
  -H 'Content-Type: application/json' \
  -d '{"query":"What is AI?","documents":["Artificial intelligence is the simulation of human intelligence","The weather is sunny today"]}' \
  2>/dev/null || echo "FAIL")

if echo "$RERANK_RESPONSE" | grep -qE '"results"|"score"'; then
  ok "Reranker scored documents successfully"
  PASS=$((PASS + 1))
else
  fail "Reranker test failed"
  echo "    Response: $RERANK_RESPONSE"
fi

# ══════════════════════════════════════════════════════════════════════════════
# DONE — PRINT ENDPOINTS
# ══════════════════════════════════════════════════════════════════════════════

header "Setup Complete — $PASS/$TOTAL tests passed"

echo ""
echo -e "  ${BOLD}Your API Endpoints:${NC}"
echo ""
echo -e "  ${GREEN}LLM (Chat)${NC}"
echo "    Local:   http://localhost:${LLM_PORT}/v1/chat/completions"
echo "    Network: http://${SERVER_IP}:${LLM_PORT}/v1/chat/completions"
echo ""
echo -e "  ${GREEN}Embeddings${NC}"
echo "    Local:   http://localhost:${EMBED_PORT}/v1/embeddings"
echo "    Network: http://${SERVER_IP}:${EMBED_PORT}/v1/embeddings"
echo ""
echo -e "  ${GREEN}Reranker${NC}"
echo "    Local:   http://localhost:${RERANK_PORT}/v1/rerank"
echo "    Network: http://${SERVER_IP}:${RERANK_PORT}/v1/rerank"
echo ""
echo -e "  ${BOLD}Health Checks:${NC}"
echo "    curl http://localhost:${LLM_PORT}/health"
echo "    curl http://localhost:${EMBED_PORT}/health"
echo "    curl http://localhost:${RERANK_PORT}/health"
echo ""
echo -e "  ${BOLD}Management:${NC}"
echo "    Stop all:     docker compose down"
echo "    Start all:    docker compose up -d"
echo "    View logs:    docker compose logs -f"
echo "    Re-test:      bash test.sh"
echo ""
echo -e "  ${BOLD}OpenAI-compatible — use with any client:${NC}"
echo "    base_url = http://${SERVER_IP}:${LLM_PORT}/v1"
echo ""

