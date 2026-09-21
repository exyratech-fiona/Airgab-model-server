#!/usr/bin/env bash
# Build the local-llm image, and optionally push it to Docker Hub.
#
#   bash build-and-push.sh                 # build + tag only, no push
#   PUSH=1 bash build-and-push.sh           # build, tag, AND push
#
# Pushing requires you to already be authenticated (`docker login`) as a user
# who can write to the namespace below — this script does not log in for you
# and does not carry any credentials. PUSH defaults to 0 on purpose: building
# is safe to run any time, publishing an image is not something to do by
# accident.
#
# Rebuilding for the client's actual CPU: pass GGML_* build args if you know
# their hardware supports more than the safe AVX2 default this Dockerfile
# ships with — see README.md "Tuning for the client's CPU". Example:
#   BUILD_ARGS="--build-arg GGML_AVX512=ON" bash build-and-push.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NAMESPACE="${NAMESPACE:-dlabssg}"
IMAGE="${NAMESPACE}/local-llm"
TAG="${TAG:-latest}"
BUILD_ARGS="${BUILD_ARGS:-}"

echo "== building ${IMAGE}:${TAG} =="
# shellcheck disable=SC2086
docker build ${BUILD_ARGS} -t "${IMAGE}:${TAG}" .

echo
echo "Built ${IMAGE}:${TAG}."
echo "  Local smoke test:   bash scripts/verify.sh"
echo "  Save for transfer:  docker save ${IMAGE}:${TAG} -o local-llm-${TAG}.tar"

if [ "${PUSH:-0}" = "1" ]; then
  echo
  echo "== pushing ${IMAGE}:${TAG} (PUSH=1) =="
  echo "This publishes the image publicly on Docker Hub under ${NAMESPACE}."
  read -r -p "Continue? [y/N] " confirm
  if [ "${confirm:-}" != "y" ] && [ "${confirm:-}" != "Y" ]; then
    echo "Aborted — image was built but not pushed."
    exit 0
  fi
  docker push "${IMAGE}:${TAG}"
else
  echo
  echo "Not pushed (PUSH=1 not set). To publish: docker login, then"
  echo "  PUSH=1 bash build-and-push.sh"
fi
