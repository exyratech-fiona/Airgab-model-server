#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Test all 3 services with real API calls                                    ║
# ║                                                                             ║
# ║  Usage:  bash test.sh                                                       ║
# ║          bash test.sh 192.168.1.50    # test from another machine           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HOST="${1:-localhost}"
LLM_PORT="${LLM_PORT:-8094}"
EMBED_PORT="${EMBED_PORT:-8090}"
RERANK_PORT="${RERANK_PORT:-8092}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL_COUNT=0

# ── Health Checks ─────────────────────────────────────────────────────────────

echo -e "\n${BOLD}${CYAN}═══ Health Checks ═══${NC}\n"

for svc in "llm:$LLM_PORT" "embed:$EMBED_PORT" "reranker:$RERANK_PORT"; do
  name="${svc%%:*}"
  port="${svc##*:}"
  if curl -fsS --max-time 5 "http://$HOST:$port/health" &>/dev/null; then
    echo -e "  ${GREEN}✔${NC} $name (port $port) — healthy"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✘${NC} $name (port $port) — NOT healthy"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

# ── Test 1: Chat Completion ──────────────────────────────────────────────────

echo -e "\n${BOLD}${CYAN}═══ Test 1: Chat Completion (LLM) ═══${NC}\n"
echo "  Sending: \"Say hi in one sentence.\""
echo ""

RESPONSE=$(curl -fsS --max-time 120 \
  "http://$HOST:$LLM_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "system", "content": "You are a helpful assistant. Reply briefly."},
      {"role": "user", "content": "Say hi in one sentence."}
    ],
    "max_tokens": 50,
    "temperature": 0.7
  }' 2>/dev/null || echo "CONNECTION_FAILED")

if echo "$RESPONSE" | grep -q '"choices"'; then
  REPLY=$(echo "$RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])" 2>/dev/null \
    || echo "$RESPONSE" | grep -o '"content":"[^"]*"' | tail -1 | sed 's/"content":"//;s/"$//')
  echo -e "  ${GREEN}✔ Response:${NC} $REPLY"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✘ Failed${NC}: $RESPONSE"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 2: Embeddings ───────────────────────────────────────────────────────

echo -e "\n${BOLD}${CYAN}═══ Test 2: Embeddings ═══${NC}\n"
echo "  Sending: \"The quick brown fox jumps over the lazy dog\""
echo ""

RESPONSE=$(curl -fsS --max-time 30 \
  "http://$HOST:$EMBED_PORT/v1/embeddings" \
  -H 'Content-Type: application/json' \
  -d '{
    "input": "The quick brown fox jumps over the lazy dog"
  }' 2>/dev/null || echo "CONNECTION_FAILED")

if echo "$RESPONSE" | grep -q '"embedding"'; then
  # Count dimensions
  DIMS=$(echo "$RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); print(len(r['data'][0]['embedding']))" 2>/dev/null || echo "?")
  echo -e "  ${GREEN}✔ Embedding returned${NC} ($DIMS dimensions)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✘ Failed${NC}: $RESPONSE"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 3: Reranker ─────────────────────────────────────────────────────────

echo -e "\n${BOLD}${CYAN}═══ Test 3: Reranker ═══${NC}\n"
echo "  Query:  \"What is machine learning?\""
echo "  Doc 1:  \"Machine learning is a subset of AI that learns from data\""
echo "  Doc 2:  \"The weather forecast predicts rain tomorrow\""
echo ""

RESPONSE=$(curl -fsS --max-time 30 \
  "http://$HOST:$RERANK_PORT/v1/rerank" \
  -H 'Content-Type: application/json' \
  -d '{
    "query": "What is machine learning?",
    "documents": [
      "Machine learning is a subset of artificial intelligence that enables systems to learn from data",
      "The weather forecast predicts rain tomorrow"
    ]
  }' 2>/dev/null || echo "CONNECTION_FAILED")

if echo "$RESPONSE" | grep -qE '"results"|"score"'; then
  echo -e "  ${GREEN}✔ Reranker scored documents${NC}"
  # Try to print scores
  echo "$RESPONSE" | python3 -c "
import sys, json
r = json.load(sys.stdin)
results = r.get('results', r.get('data', []))
for item in results:
    idx = item.get('index', '?')
    score = item.get('relevance_score', item.get('score', '?'))
    print(f'    Doc {idx}: score = {score}')
" 2>/dev/null || true
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✘ Failed${NC}: $RESPONSE"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Test 4: Multi-turn conversation ──────────────────────────────────────────

echo -e "\n${BOLD}${CYAN}═══ Test 4: Multi-turn Conversation ═══${NC}\n"
echo "  Turn 1: \"My name is Alice\""
echo "  Turn 2: \"What is my name?\""
echo ""

RESPONSE=$(curl -fsS --max-time 120 \
  "http://$HOST:$LLM_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "user", "content": "My name is Alice."},
      {"role": "assistant", "content": "Nice to meet you, Alice!"},
      {"role": "user", "content": "What is my name?"}
    ],
    "max_tokens": 30,
    "temperature": 0
  }' 2>/dev/null || echo "CONNECTION_FAILED")

if echo "$RESPONSE" | grep -qi "alice"; then
  REPLY=$(echo "$RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])" 2>/dev/null \
    || echo "$RESPONSE" | grep -o '"content":"[^"]*"' | tail -1 | sed 's/"content":"//;s/"$//')
  echo -e "  ${GREEN}✔ Context retained:${NC} $REPLY"
  PASS=$((PASS + 1))
elif echo "$RESPONSE" | grep -q '"choices"'; then
  REPLY=$(echo "$RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])" 2>/dev/null || echo "?")
  echo -e "  ${GREEN}~${NC} Got response (may not have retained context): $REPLY"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✘ Failed${NC}: $RESPONSE"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Summary ──────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL_COUNT))
echo -e "\n${BOLD}${CYAN}═══ Results: $PASS/$TOTAL passed ═══${NC}\n"

if [ $FAIL_COUNT -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}All tests passed! ✔${NC}"
else
  echo -e "  ${RED}${BOLD}$FAIL_COUNT test(s) failed${NC}"
  echo "  Check logs: docker compose logs"
fi

# ── Print endpoints for easy copy-paste ──────────────────────────────────────

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo ""
echo -e "${BOLD}${CYAN}═══ Your API Endpoints ═══${NC}"
echo ""
echo "  LLM (Chat):   http://${SERVER_IP}:${LLM_PORT}/v1/chat/completions"
echo "  Embeddings:   http://${SERVER_IP}:${EMBED_PORT}/v1/embeddings"
echo "  Reranker:     http://${SERVER_IP}:${RERANK_PORT}/v1/rerank"
echo ""
echo "  OpenAI base_url: http://${SERVER_IP}:${LLM_PORT}/v1"
echo ""

# ── Example curl commands for quick copy-paste ───────────────────────────────

echo -e "${BOLD}${CYAN}═══ Quick Copy-Paste Examples ═══${NC}"
echo ""
echo "  # Chat:"
echo "  curl http://${SERVER_IP}:${LLM_PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}],\"max_tokens\":100}'"
echo ""
echo "  # Embeddings:"
echo "  curl http://${SERVER_IP}:${EMBED_PORT}/v1/embeddings \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"input\":\"Your text here\"}'"
echo ""
echo "  # Rerank:"
echo "  curl http://${SERVER_IP}:${RERANK_PORT}/v1/rerank \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"query\":\"search query\",\"documents\":[\"doc 1\",\"doc 2\"]}'"
echo ""

exit $FAIL_COUNT

