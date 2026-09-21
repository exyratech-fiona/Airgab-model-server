#!/usr/bin/env bash
# Smoke-test a running stack: health + one real call per role.
#
#   bash scripts/verify.sh                       # uses the ports in .env / defaults
#   LLM_PORT=... EMBED_PORT=... RERANK_PORT=... bash scripts/verify.sh
#
# Exits non-zero if anything fails, so it's usable as a post-deploy gate.

set -uo pipefail

LLM_PORT="${LLM_PORT:-8094}"
EMBED_PORT="${EMBED_PORT:-8090}"
RERANK_PORT="${RERANK_PORT:-8092}"
HOST="${HOST:-localhost}"

fail=0
check() {
  local name="$1" url="$2"
  if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
    echo "  OK    $name  ($url)"
  else
    echo "  FAIL  $name  ($url)"
    fail=1
  fi
}

echo "== health =="
check "llm"      "http://$HOST:$LLM_PORT/health"
check "embed"    "http://$HOST:$EMBED_PORT/health"
check "reranker" "http://$HOST:$RERANK_PORT/health"

echo
echo "== a real call per role (proves the loaded model actually answers) =="

llm_out="$(curl -fsS --max-time 60 "http://$HOST:$LLM_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply with exactly one word: OK"}],"max_tokens":8}' \
  2>/dev/null)"
if [ -n "$llm_out" ] && grep -q '"choices"' <<<"$llm_out"; then
  echo "  OK    llm chat completion"
else
  echo "  FAIL  llm chat completion — $llm_out"
  fail=1
fi

embed_out="$(curl -fsS --max-time 30 "http://$HOST:$EMBED_PORT/v1/embeddings" \
  -H 'Content-Type: application/json' \
  -d '{"input":"test sentence"}' 2>/dev/null)"
if [ -n "$embed_out" ] && grep -q '"embedding"' <<<"$embed_out"; then
  echo "  OK    embed vector returned"
else
  echo "  FAIL  embed vector — $embed_out"
  fail=1
fi

rerank_out="$(curl -fsS --max-time 30 "http://$HOST:$RERANK_PORT/v1/rerank" \
  -H 'Content-Type: application/json' \
  -d '{"query":"test","documents":["a relevant passage","an irrelevant one"]}' 2>/dev/null)"
if [ -n "$rerank_out" ] && grep -q '"results"\|"score"' <<<"$rerank_out"; then
  echo "  OK    reranker scored the pair"
else
  echo "  FAIL  reranker — $rerank_out"
  fail=1
fi

echo
[ "$fail" = "0" ] && echo "All checks passed." || echo "Some checks FAILED — see above."
exit "$fail"
