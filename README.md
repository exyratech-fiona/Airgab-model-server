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
cp .env.example .env
# edit .env: at minimum set LLM_MODEL_FILE, EMBED_MODEL_FILE, RERANK_MODEL_FILE
# to the .gguf filenames you've placed under ./models/

docker compose pull        # or: docker load -i local-llm.tar   (see above)
docker compose up -d
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
portable settings that run on essentially any x86_64 server. If you know the
client's actual CPU supports more (AVX-512, for instance), rebuilding with
matching flags gets real throughput back:

```bash
BUILD_ARGS="--build-arg GGML_AVX512=ON" bash build-and-push.sh
```

Do this on hardware that MATCHES what you're deploying to, or on a machine you
know is a strict superset — a binary built with instructions the runtime CPU
lacks crashes with `Illegal instruction`, not a graceful fallback.

### Pointing an application at these servers

The three ports (defaults: LLM `8094`, embed `8090`, reranker `8092`) speak the
same OpenAI-compatible protocol OpsGPT's own model servers do. If the client is
also running (a copy of) OpsGPT, its `.env` config maps directly:

```
OPSGPT_LLAMACPP_BASE_URL=http://<this-host>:8094
OPSGPT_EMBED_BASE_URL=http://<this-host>:8090     (or OPSGPT_EMBED_BGE_BASE_URL — match the model you loaded)
OPSGPT_RERANKER_BASE_URL=http://<this-host>:8092
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
| `Dockerfile` | The image: llama.cpp built from source, CPU-only, no baked-in model |
| `docker-compose.yml` | The three services — llm / embed / reranker — all from that one image |
| `.env.example` | Every configurable value, with defaults and why |
| `build-and-push.sh` | Build locally; push to Docker Hub only with `PUSH=1` and an explicit confirm |
| `scripts/verify.sh` | Post-deploy smoke test: health + one real request per service |
| `models/` | Where the client's `.gguf` files go (bind-mounted read-only, nothing committed) |
