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
  EXTRA_ARGS+=("--jinja")
fi

if [ "${NUMA_ENABLED:-0}" = "1" ]; then
  exec numactl --interleave=all llama-server "${EXTRA_ARGS[@]}" "$@"
else
  exec llama-server "${EXTRA_ARGS[@]}" "$@"
fi

