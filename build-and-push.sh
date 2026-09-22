#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Build & Export Script for Airgab-model-server                              ║
# ║                                                                             ║
# ║  Builds Docker images (CPU / GPU) and automatically exports tar packages:   ║
# ║    • CPU Image: dlabssg/local-llm:latest   -> client-package/local-llm-latest.tar ║
# ║    • GPU Image: dlabssg/local-llm:cuda12   -> client-package/local-llm-cuda12.tar ║
# ║                                                                             ║
# ║  Usage:                                                                     ║
# ║    bash build-and-push.sh           # Interactive menu (Choose 1, 2, or 3)  ║
# ║    BUILD=all bash build-and-push.sh # Build BOTH CPU and GPU images         ║
# ║    BUILD=cpu bash build-and-push.sh # Build CPU only                        ║
# ║    BUILD=gpu bash build-and-push.sh # Build GPU (CUDA) only                 ║
# ║                                                                             ║
# ║  Flags:                                                                     ║
# ║    PUSH=1       Push built image(s) to Docker Hub                           ║
# ║    SAVE_TAR=1   Save .tar archive to client-package/ (default: 1)           ║
# ║    ZIP=1        Compress client-package into client-package.zip             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NAMESPACE="${NAMESPACE:-dlabssg}"
IMAGE="${NAMESPACE}/local-llm"
BUILD_ARGS="${BUILD_ARGS:-}"
SAVE_TAR="${SAVE_TAR:-1}"
PUSH="${PUSH:-0}"
ZIP="${ZIP:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p client-package

# ── Select what to build ──────────────────────────────────────────────────────
TARGET="${BUILD:-}"

if [ -z "$TARGET" ]; then
  if [ -t 0 ]; then
    echo -e "${BOLD}${CYAN}Select which image(s) to build:${NC}"
    echo "  1) Both CPU and GPU images (Recommended)"
    echo "  2) CPU image only (dlabssg/local-llm:latest) (~200MB)"
    echo "  3) GPU image only (dlabssg/local-llm:cuda12) (~5GB)"
    read -r -p "Enter choice [1-3] (Default 1): " choice
    case "${choice:-1}" in
      1) TARGET="all" ;;
      2) TARGET="cpu" ;;
      3) TARGET="gpu" ;;
      *) echo "Invalid choice. Exiting."; exit 1 ;;
    esac
  else
    TARGET="all"
  fi
fi

# ── Helper functions ──────────────────────────────────────────────────────────
build_image() {
  local type="$1"
  local dockerfile="$2"
  local tag="$3"
  local tar_name="$4"

  echo -e "\n${BOLD}${CYAN}====================================================${NC}"
  echo -e "${BOLD}${CYAN}  Building ${type} Image: ${IMAGE}:${tag}${NC}"
  echo -e "${BOLD}${CYAN}  Using Dockerfile: ${dockerfile}${NC}"
  echo -e "${BOLD}${CYAN}====================================================${NC}\n"

  # shellcheck disable=SC2086
  docker build ${BUILD_ARGS} -f "${dockerfile}" -t "${IMAGE}:${tag}" .

  echo -e "\n${GREEN}✔ Successfully built ${IMAGE}:${tag}${NC}"

  if [ "$SAVE_TAR" = "1" ]; then
    echo -e "  Saving tar package: ${BOLD}client-package/${tar_name}${NC} (please wait)..."
    docker save "${IMAGE}:${tag}" -o "client-package/${tar_name}"
    echo -e "  ${GREEN}✔ Saved client-package/${tar_name}${NC} ($(du -h "client-package/${tar_name}" | awk '{print $1}'))"
  fi

  if [ "$PUSH" = "1" ]; then
    echo -e "  Pushing ${IMAGE}:${tag} to Docker Hub..."
    docker push "${IMAGE}:${tag}"
    echo -e "  ${GREEN}✔ Pushed ${IMAGE}:${tag}${NC}"
  fi
}

# ── Execute Build ─────────────────────────────────────────────────────────────
if [ "$TARGET" = "cpu" ] || [ "$TARGET" = "all" ]; then
  build_image "CPU" "Dockerfile" "latest" "local-llm-latest.tar"
fi

if [ "$TARGET" = "gpu" ] || [ "$TARGET" = "all" ]; then
  build_image "GPU (CUDA)" "Dockerfile.cuda" "cuda12" "local-llm-cuda12.tar"
fi

# ── Optional Zipping ──────────────────────────────────────────────────────────
if [ "$ZIP" = "0" ] && [ -t 0 ]; then
  echo ""
  read -r -p "Do you want to compress client-package into a zip/tarball now? [y/N]: " do_zip
  if [[ "$do_zip" =~ ^[Yy]$ ]]; then
    ZIP=1
  fi
fi

if [ "$ZIP" = "1" ]; then
  echo ""
  echo -e "${BOLD}${CYAN}Compressing client-package for client delivery...${NC}"
  if command -v zip &>/dev/null; then
    rm -f client-package.zip
    zip -r client-package.zip client-package/
    echo -e "  ${GREEN}✔ Created client-package.zip${NC} ($(du -h client-package.zip | awk '{print $1}'))"
  else
    rm -f client-package.tar.gz
    tar -czvf client-package.tar.gz client-package/
    echo -e "  ${GREEN}✔ Created client-package.tar.gz${NC} ($(du -h client-package.tar.gz | awk '{print $1}'))"
  fi
fi

echo -e "\n${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Build and Package Complete!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo "Files ready in client-package/:"
ls -lh client-package/*.tar 2>/dev/null || true
[ -f "client-package.zip" ] && ls -lh client-package.zip
[ -f "client-package.tar.gz" ] && ls -lh client-package.tar.gz
echo ""
echo -e "${BOLD}How to send to client:${NC}"
echo "  • Copy client-package.zip (or client-package/) to USB / air-gapped machine"
echo "  • The client unzips and runs: bash setup.sh"
echo "  • Place model .gguf files inside client-package/models/"
echo ""
