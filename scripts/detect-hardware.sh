#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Hardware Discovery & .env Generator for Airgab-model-server               ║
# ║                                                                             ║
# ║  Run this on the CLIENT's machine BEFORE deployment. It detects:            ║
# ║    • CPU cores, sockets, threads-per-core                                   ║
# ║    • NUMA topology (nodes, cores-per-node)                                  ║
# ║    • CPU instruction sets (AVX, AVX2, AVX-512, FMA, F16C)                   ║
# ║    • NVIDIA GPU presence, count, VRAM                                       ║
# ║    • Available system RAM                                                   ║
# ║    • Docker & NVIDIA Container Toolkit status                               ║
# ║                                                                             ║
# ║  Output:                                                                    ║
# ║    1. A hardware report printed to stdout                                   ║
# ║    2. A recommended .env file written to .env.generated                     ║
# ║                                                                             ║
# ║  Usage:                                                                     ║
# ║    bash scripts/detect-hardware.sh                                          ║
# ║    # review .env.generated, then:                                           ║
# ║    cp .env.generated .env                                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

header()  { echo -e "\n${BOLD}${CYAN}══ $1 ══${NC}"; }
ok()      { echo -e "  ${GREEN}✔${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()    { echo -e "  ${RED}✘${NC} $1"; }
info()    { echo -e "  ${BOLD}$1${NC}: $2"; }

# ── Detect CPU ────────────────────────────────────────────────────────────────
header "CPU"

TOTAL_CORES=$(nproc 2>/dev/null || echo 1)
PHYSICAL_CORES=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/ {gsub(/ /,"",$2); print $2}' || echo "")
SOCKETS=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/ {gsub(/ /,"",$2); print $2}' || echo "1")
THREADS_PER_CORE=$(lscpu 2>/dev/null | awk -F: '/^Thread\(s\) per core/ {gsub(/ /,"",$2); print $2}' || echo "1")
CPU_MODEL=$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2}' || echo "unknown")

# Calculate actual physical cores
if [ -n "$PHYSICAL_CORES" ] && [ -n "$SOCKETS" ]; then
  TOTAL_PHYSICAL=$((PHYSICAL_CORES * SOCKETS))
else
  TOTAL_PHYSICAL=$TOTAL_CORES
fi

info "Model"              "$CPU_MODEL"
info "Sockets"            "$SOCKETS"
info "Cores per socket"   "${PHYSICAL_CORES:-unknown}"
info "Threads per core"   "$THREADS_PER_CORE"
info "Total logical CPUs" "$TOTAL_CORES (nproc)"
info "Total physical cores" "$TOTAL_PHYSICAL"

if [ "$THREADS_PER_CORE" -gt 1 ] 2>/dev/null; then
  warn "Hyperthreading is ON. Use physical core count ($TOTAL_PHYSICAL) for thread settings, not nproc ($TOTAL_CORES)."
fi

# ── Detect CPU flags (AVX, AVX2, AVX-512, FMA, F16C) ─────────────────────────
header "CPU Instruction Sets"

detect_flag() {
  local flag="$1"
  local display="$2"
  if grep -qw "$flag" /proc/cpuinfo 2>/dev/null; then
    ok "$display: supported"
    echo "ON"
  else
    fail "$display: NOT supported"
    echo "OFF"
  fi
}

AVX_SUPPORT=$(detect_flag "avx" "AVX")
AVX2_SUPPORT=$(detect_flag "avx2" "AVX2")
FMA_SUPPORT=$(detect_flag "fma" "FMA")
F16C_SUPPORT=$(detect_flag "f16c" "F16C")
AVX512_SUPPORT=$(detect_flag "avx512f" "AVX-512")

# ── Detect NUMA ───────────────────────────────────────────────────────────────
header "NUMA Topology"

NUMA_NODES=0
NUMA_ENABLED_REC=0
NUMA_CPUSET_LLM=""

if command -v numactl &>/dev/null; then
  NUMA_NODES=$(numactl --hardware 2>/dev/null | awk '/^available/ {print $2}' || echo 0)
fi

# Fallback: check lscpu
if [ "$NUMA_NODES" -eq 0 ] 2>/dev/null; then
  NUMA_NODES=$(lscpu 2>/dev/null | awk -F: '/^NUMA node\(s\)/ {gsub(/ /,"",$2); print $2}' || echo 1)
fi

info "NUMA nodes" "$NUMA_NODES"

if [ "$NUMA_NODES" -gt 1 ]; then
  ok "Multi-socket detected — NUMA optimization recommended"
  NUMA_ENABLED_REC=1

  # Get cores for each NUMA node
  echo ""
  for node in $(seq 0 $((NUMA_NODES - 1))); do
    node_cpus=$(lscpu 2>/dev/null | awk -F: "/^NUMA node${node} CPU/ {gsub(/^[ \t]+/,\"\",\$2); print \$2}" || echo "unknown")
    info "  Node $node CPUs" "$node_cpus"

    # Use physical cores across both nodes (skipping hyperthreads)
    NUMA_CPUSET_LLM="0-$((TOTAL_PHYSICAL - 1))"
  done

  # Physical cores per node (for thread count)
  if [ -n "$PHYSICAL_CORES" ]; then
    CORES_PER_NODE=$PHYSICAL_CORES
  else
    CORES_PER_NODE=$((TOTAL_CORES / NUMA_NODES))
  fi
  info "  Cores per node" "$CORES_PER_NODE"

  echo ""
  warn "Disable kernel NUMA balancing for best performance:"
  echo "    echo 'kernel.numa_balancing=0' | sudo tee /etc/sysctl.d/99-numa.conf"
  echo "    sudo sysctl -p /etc/sysctl.d/99-numa.conf"

  # Check current NUMA balancing status
  if [ -f /proc/sys/kernel/numa_balancing ]; then
    NUMA_BAL=$(cat /proc/sys/kernel/numa_balancing)
    if [ "$NUMA_BAL" = "1" ]; then
      warn "NUMA balancing is currently ENABLED (suboptimal)"
    else
      ok "NUMA balancing is already disabled"
    fi
  fi
else
  ok "Single-socket — no NUMA optimization needed"
  CORES_PER_NODE=$TOTAL_PHYSICAL
fi

# ── Detect RAM ────────────────────────────────────────────────────────────────
header "System Memory"

TOTAL_RAM_KB=$(awk '/^MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
AVAIL_RAM_KB=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
AVAIL_RAM_GB=$((AVAIL_RAM_KB / 1024 / 1024))

info "Total RAM"     "${TOTAL_RAM_GB} GB"
info "Available RAM" "${AVAIL_RAM_GB} GB"

# Recommend mem limits based on available RAM
if [ "$TOTAL_RAM_GB" -ge 32 ]; then
  LLM_MEM="16g"
  EMBED_MEM="4g"
  RERANK_MEM="4g"
elif [ "$TOTAL_RAM_GB" -ge 16 ]; then
  LLM_MEM="10g"
  EMBED_MEM="3g"
  RERANK_MEM="3g"
else
  LLM_MEM="6g"
  EMBED_MEM="2g"
  RERANK_MEM="2g"
  warn "Low RAM (${TOTAL_RAM_GB} GB). Consider smaller quantized models (Q4_K_M or lower)."
fi

# ── Detect GPU ────────────────────────────────────────────────────────────────
header "NVIDIA GPU"

HAS_GPU=0
GPU_COUNT_DETECTED=0
GPU_INFO=""

if command -v nvidia-smi &>/dev/null; then
  if nvidia-smi &>/dev/null; then
    HAS_GPU=1
    GPU_COUNT_DETECTED=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    ok "NVIDIA driver: installed"
    info "GPU count" "$GPU_COUNT_DETECTED"

    echo ""
    # Print each GPU's details
    gpu_idx=0
    while IFS=',' read -r name vram_total vram_free driver_ver cuda_ver; do
      # Trim whitespace
      name=$(echo "$name" | xargs)
      vram_total=$(echo "$vram_total" | xargs)
      vram_free=$(echo "$vram_free" | xargs)
      driver_ver=$(echo "$driver_ver" | xargs)
      cuda_ver=$(echo "$cuda_ver" | xargs)

      info "  GPU $gpu_idx"      "$name"
      info "    VRAM total"      "$vram_total"
      info "    VRAM free"       "$vram_free"
      info "    Driver"          "$driver_ver"
      info "    CUDA version"    "$cuda_ver"
      gpu_idx=$((gpu_idx + 1))
    done < <(nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version,cuda_version \
               --format=csv,noheader 2>/dev/null)

    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)
  else
    fail "nvidia-smi found but failed — driver issue?"
  fi
else
  warn "nvidia-smi not found — no NVIDIA GPU or drivers not installed"
fi

# ── Check NVIDIA Container Toolkit ───────────────────────────────────────────
if [ "$HAS_GPU" -eq 1 ]; then
  echo ""
  if command -v nvidia-ctk &>/dev/null; then
    ok "NVIDIA Container Toolkit: installed"
  else
    fail "NVIDIA Container Toolkit: NOT installed"
    echo "    Install with:"
    echo "      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \\"
    echo "        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    echo "      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \\"
    echo "        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \\"
    echo "        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    echo "      sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
    echo "      sudo nvidia-ctk runtime configure --runtime=docker"
    echo "      sudo systemctl restart docker"
  fi

  # Test Docker GPU access
  if docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi &>/dev/null 2>&1; then
    ok "Docker GPU access: working"
  else
    warn "Docker GPU access: not verified (test image not available or runtime not configured)"
  fi
fi

# ── Check Docker ──────────────────────────────────────────────────────────────
header "Docker"

if command -v docker &>/dev/null; then
  ok "Docker: installed ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ','))"
else
  fail "Docker: NOT installed"
fi

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
  ok "Docker Compose: installed ($(docker compose version 2>/dev/null | awk '{print $NF}'))"
else
  fail "Docker Compose: NOT installed or not v2"
fi

# ── Check for model files ────────────────────────────────────────────────────
header "Model Files"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$(dirname "$SCRIPT_DIR")/models"

if [ -d "$MODELS_DIR" ]; then
  GGUF_FILES=$(find "$MODELS_DIR" -name "*.gguf" -type f 2>/dev/null)
  if [ -n "$GGUF_FILES" ]; then
    ok "Found .gguf files in models/:"
    while IFS= read -r f; do
      size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
      fname=$(basename "$f")
      info "  $fname" "$size"
    done <<< "$GGUF_FILES"
  else
    warn "No .gguf files found in $MODELS_DIR"
    echo "    Place your model files there before starting."
  fi
else
  warn "models/ directory not found"
fi

# ══════════════════════════════════════════════════════════════════════════════
# CALCULATE RECOMMENDED VALUES
# ══════════════════════════════════════════════════════════════════════════════

header "Recommended Configuration"

# Thread counts
if [ "$NUMA_ENABLED_REC" -eq 1 ]; then
  # Multi-socket: LLM uses all physical cores across both sockets (interleaved)
  REC_LLM_THREADS=$TOTAL_PHYSICAL
  REC_EMBED_THREADS=8
  REC_RERANK_THREADS=8
  [ "$REC_EMBED_THREADS" -gt "$TOTAL_PHYSICAL" ] && REC_EMBED_THREADS=$((TOTAL_PHYSICAL / 2))
  [ "$REC_RERANK_THREADS" -gt "$TOTAL_PHYSICAL" ] && REC_RERANK_THREADS=$((TOTAL_PHYSICAL / 2))
  [ "$REC_EMBED_THREADS" -lt 2 ] && REC_EMBED_THREADS=2
  [ "$REC_RERANK_THREADS" -lt 2 ] && REC_RERANK_THREADS=2
else
  # Single socket: LLM gets all physical cores, embed/rerank get half
  REC_LLM_THREADS=$TOTAL_PHYSICAL
  REC_EMBED_THREADS=$(( TOTAL_PHYSICAL / 2 ))
  REC_RERANK_THREADS=$(( TOTAL_PHYSICAL / 2 ))
  [ "$REC_EMBED_THREADS" -lt 2 ] && REC_EMBED_THREADS=2
  [ "$REC_RERANK_THREADS" -lt 2 ] && REC_RERANK_THREADS=2
fi

# Deployment mode
if [ "$HAS_GPU" -eq 1 ]; then
  DEPLOY_MODE="GPU"
  REC_IMAGE="dlabssg/local-llm:cuda12"
  REC_START="docker compose --profile gpu up -d"
  info "Mode" "GPU offloading (${GPU_INFO})"
else
  DEPLOY_MODE="CPU"
  REC_IMAGE="dlabssg/local-llm:latest"
  REC_START="docker compose up -d"
  if [ "$NUMA_ENABLED_REC" -eq 1 ]; then
    info "Mode" "CPU with NUMA ($NUMA_NODES nodes, $CORES_PER_NODE cores/node)"
  else
    info "Mode" "CPU single-socket ($TOTAL_PHYSICAL cores)"
  fi
fi

info "LLM threads"    "$REC_LLM_THREADS"
info "Embed threads"  "$REC_EMBED_THREADS"
info "Rerank threads" "$REC_RERANK_THREADS"
info "NUMA"           "$([ "$NUMA_ENABLED_REC" -eq 1 ] && echo "enabled (cpuset: $NUMA_CPUSET_LLM)" || echo "disabled")"
info "LLM memory limit"    "$LLM_MEM"
info "Embed memory limit"  "$EMBED_MEM"
info "Rerank memory limit" "$RERANK_MEM"

if [ "$HAS_GPU" -eq 1 ]; then
  info "GPU layers"   "99 (offload all)"
fi

# Thinking / Reasoning mode selection
REC_THINKING=0
if [ -t 0 ]; then
  echo ""
  echo -e "  Select Thinking / Reasoning Mode:"
  echo "    1) OFF — Standard Chat Model (Recommended: direct answers, no <think> box)"
  echo "    2) ON  — Reasoning Model (DeepSeek-R1, QwQ: enables <think> chain-of-thought)"
  read -r -p "  Choose [1/2] (Default 1): " user_think_opt
  case "${user_think_opt:-1}" in
    1) REC_THINKING=0 ;;
    2) REC_THINKING=1 ;;
    *) REC_THINKING=0 ;;
  esac
fi

# ══════════════════════════════════════════════════════════════════════════════
# GENERATE .env FILE
# ══════════════════════════════════════════════════════════════════════════════

ENV_FILE="$(dirname "$SCRIPT_DIR")/.env.generated"

cat > "$ENV_FILE" <<ENVEOF
# ┌──────────────────────────────────────────────────────────────────────────┐
# │  Auto-generated by detect-hardware.sh on $(date '+%Y-%m-%d %H:%M:%S')        │
# │  Host: $(hostname)                                                       
# │  CPU:  ${CPU_MODEL}
# │  RAM:  ${TOTAL_RAM_GB} GB
# │  GPU:  $([ "$HAS_GPU" -eq 1 ] && echo "$GPU_INFO" || echo "none")
# └──────────────────────────────────────────────────────────────────────────┘
#
# Review this file, fill in your model filenames, then:
#   cp .env.generated .env
#   $REC_START

# ---- Image ----
LOCAL_LLM_IMAGE=${REC_IMAGE}

# ---- LLM (chat / completion) ----
# ⚠ REQUIRED: set this to your .gguf filename under ./models/
LLM_MODEL_FILE=
LLM_MODEL_NAME=opsgpt
LLM_PORT=8097
LLM_CTX=8192
LLM_THREADS=${REC_LLM_THREADS}
LLM_PARALLEL=1
LLM_MEM_LIMIT=${LLM_MEM}
LLM_THINKING=${REC_THINKING}

# ---- Embeddings ----
# ⚠ REQUIRED: set this to your .gguf filename under ./models/
EMBED_MODEL_FILE=
EMBED_MODEL_NAME=embed
EMBED_PORT=8098
EMBED_CTX=4096
EMBED_THREADS=${REC_EMBED_THREADS}
EMBED_MEM_LIMIT=${EMBED_MEM}
# mean: BGE-M3, nomic-embed-text.  cls: BGE-large-en-v1.5.
EMBED_POOLING=mean

# ---- Reranker ----
# ⚠ REQUIRED: set this to your .gguf filename under ./models/
RERANK_MODEL_FILE=
RERANK_MODEL_NAME=reranker
RERANK_PORT=8099
RERANK_CTX=4096
RERANK_THREADS=${REC_RERANK_THREADS}
RERANK_MEM_LIMIT=${RERANK_MEM}

# ---- NUMA ----
NUMA_ENABLED=${NUMA_ENABLED_REC}
NUMA_MODE=distribute
LLM_CPUSET=${NUMA_CPUSET_LLM}
EMBED_CPUSET=
RERANK_CPUSET=

# ---- GPU ----
GPU_COUNT=${GPU_COUNT_DETECTED:-all}
LLM_GPU_LAYERS=$([ "$HAS_GPU" -eq 1 ] && echo 99 || echo 0)
EMBED_GPU_LAYERS=$([ "$HAS_GPU" -eq 1 ] && echo 99 || echo 0)
RERANK_GPU_LAYERS=$([ "$HAS_GPU" -eq 1 ] && echo 99 || echo 0)
ENVEOF

# Auto-fill model files if exactly 3 .gguf files or if names are recognizable
if [ -d "$MODELS_DIR" ]; then
  GGUF_LIST=$(find "$MODELS_DIR" -name "*.gguf" -type f -exec basename {} \; 2>/dev/null | sort)
  GGUF_COUNT=$(echo "$GGUF_LIST" | grep -c . 2>/dev/null || echo 0)

  for f in $GGUF_LIST; do
    fl=$(echo "$f" | tr '[:upper:]' '[:lower:]')
    if echo "$fl" | grep -qiE '(rerank|cross.?encoder)'; then
      sed -i "s/^RERANK_MODEL_FILE=$/RERANK_MODEL_FILE=$f/" "$ENV_FILE"
    elif echo "$fl" | grep -qiE '(embed|bge-m3|nomic|e5-|gte-)'; then
      sed -i "s/^EMBED_MODEL_FILE=$/EMBED_MODEL_FILE=$f/" "$ENV_FILE"
    elif echo "$fl" | grep -qiE '(instruct|chat|llm|qwen|mistral|llama|phi|gemma|deepseek|yi-)'; then
      sed -i "s/^LLM_MODEL_FILE=$/LLM_MODEL_FILE=$f/" "$ENV_FILE"
    fi
  done
fi

# ══════════════════════════════════════════════════════════════════════════════
# BUILD FLAGS REPORT
# ══════════════════════════════════════════════════════════════════════════════

header "Docker Build Flags"

echo -e "  If building the image on THIS machine for THIS machine's CPU:"
echo ""
echo -e "    ${BOLD}bash build-and-push.sh${NC}"
if [ "$AVX512_SUPPORT" = "ON" ]; then
  echo -e "    # or with AVX-512 (detected on this CPU):"
  echo -e "    ${BOLD}BUILD_ARGS=\"--build-arg GGML_AVX512=ON\" bash build-and-push.sh${NC}"
fi
if [ "$HAS_GPU" -eq 1 ]; then
  echo ""
  echo -e "    # GPU build:"
  echo -e "    ${BOLD}CUDA=1 bash build-and-push.sh${NC}"
fi

echo ""
echo "  Build args for this CPU:"
echo "    --build-arg GGML_AVX=${AVX_SUPPORT}"
echo "    --build-arg GGML_AVX2=${AVX2_SUPPORT}"
echo "    --build-arg GGML_FMA=${FMA_SUPPORT}"
echo "    --build-arg GGML_F16C=${F16C_SUPPORT}"
echo "    --build-arg GGML_AVX512=${AVX512_SUPPORT}"

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

header "Summary"

echo -e "  Generated: ${BOLD}${ENV_FILE}${NC}"
echo ""
echo "  Next steps:"
echo "    1. Review .env.generated"
echo "    2. Fill in model filenames (LLM_MODEL_FILE, EMBED_MODEL_FILE, RERANK_MODEL_FILE)"
echo "    3. cp .env.generated .env"

if [ "$HAS_GPU" -eq 1 ]; then
  echo "    4. Build GPU image:  CUDA=1 bash build-and-push.sh"
  echo "    5. Start:            docker compose --profile gpu up -d"
else
  echo "    4. Pull or build:    docker compose pull   (or: bash build-and-push.sh)"
  echo "    5. Start:            docker compose up -d"
fi

echo "    6. Verify:           bash scripts/verify.sh"
echo ""

# Check for any issues that need attention
ISSUES=0
if [ "$HAS_GPU" -eq 1 ] && ! command -v nvidia-ctk &>/dev/null; then
  warn "Install NVIDIA Container Toolkit before using GPU mode (see above)"
  ISSUES=1
fi
if [ -z "$(find "$MODELS_DIR" -name "*.gguf" -type f 2>/dev/null)" ]; then
  warn "No .gguf model files found in models/ — place them there before starting"
  ISSUES=1
fi
if [ "$NUMA_ENABLED_REC" -eq 1 ] && [ -f /proc/sys/kernel/numa_balancing ] && [ "$(cat /proc/sys/kernel/numa_balancing)" = "1" ]; then
  warn "Disable NUMA balancing for best performance (see above)"
  ISSUES=1
fi

if [ "$ISSUES" -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}No issues detected — ready to deploy!${NC}"
fi

echo ""

