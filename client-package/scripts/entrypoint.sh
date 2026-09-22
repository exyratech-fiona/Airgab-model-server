#!/usr/bin/env bash
# Entrypoint wrapper: optionally runs llama-server under numactl for NUMA-aware
# memory interleaving. Controlled by the NUMA_ENABLED env var (set in .env).
#
# When NUMA_ENABLED=1:
#   exec numactl --interleave=all llama-server "$@"
# Otherwise:
#   exec llama-server "$@"
#
# This lets one image work on both single-socket and multi-socket boxes without
# separate Dockerfiles or compose overrides — the client sets one variable.

set -euo pipefail

EXTRA_ARGS=()
if [ "${LLM_THINKING:-0}" = "1" ]; then
  export LLAMA_ARG_REASONING="on"
  EXTRA_ARGS+=("--jinja")
else
  export LLAMA_ARG_REASONING="off"
  export LLAMA_ARG_THINK_BUDGET="0"
  if llama-server --help 2>&1 | grep -q -- '--reasoning'; then
    EXTRA_ARGS+=("--reasoning" "off" "--reasoning-budget" "0")
  elif llama-server --help 2>&1 | grep -q -- '--chat-template-kwargs'; then
    EXTRA_ARGS+=("--chat-template-kwargs" '{"enable_thinking":false}')
  fi
fi

if [ "${NUMA_ENABLED:-0}" = "1" ]; then
  exec numactl --interleave=all llama-server "${EXTRA_ARGS[@]}" "$@"
else
  exec llama-server "${EXTRA_ARGS[@]}" "$@"
fi

