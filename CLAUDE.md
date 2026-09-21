# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A standalone, client-facing deliverable: three model-serving containers (LLM, embeddings,
reranker) built from **one image** and shipped for deployment on a client's network that may
have no internet access at all. It is not part of the OpsGPT-Platform / document-intelligence
workflow described in the repo root's `CLAUDE.md` — it does not consume either of those
services and neither of them consumes it. Treat it as its own thing.

It is the same pattern `OpsGPT-Platform/opsgpt/docker-compose.yml` already runs in production —
one `llamacpp`-family image, reused three times by changing the `command:` flags — pulled out
into a package that works without OpsGPT and without internet at runtime. See `README.md` for
the deployment story aimed at whoever actually runs this on the client's box.

## The one rule that matters

**The build stage needs internet (clones llama.cpp, installs apt packages). The runtime stage
must never need it.** Any change to this Dockerfile that adds a network call to the *runtime*
stage — a model download, a version check, anything — breaks the entire reason this package
exists. `--hf-repo` / `--hf-file` (llama.cpp's built-in model-download flags) must never appear
in `docker-compose.yml`; every `--model` is a local path under the bind-mounted `./models`.

## Structure

| File | Role |
|---|---|
| `Dockerfile` | Multi-stage: build llama.cpp from source (`build`), copy the binary into a slim runtime image. ISA flags (`GGML_AVX2`, `GGML_AVX512`, …) are build ARGs, not hardcoded — the target CPU is unknown at build time, unlike OpsGPT's own Dockerfile which is tuned for one known box. |
| `docker-compose.yml` | Three services (`llm`, `embed`, `reranker`), all `${LOCAL_LLM_IMAGE}`, differing only in flags. `${VAR:?message}` on the three `*_MODEL_FILE` vars means compose refuses to start a service with no model configured, rather than starting it wrong. |
| `.env.example` | Every tunable, documented. `EMBED_POOLING` is the one that matters most: it's a property of *which embedding model* was chosen (mean vs cls), not a free parameter, and choosing wrong degrades quality silently rather than erroring. |
| `build-and-push.sh` | Builds locally always; pushes to Docker Hub only with `PUSH=1` **and** an interactive confirm. Never push non-interactively from a script or on someone else's behalf without being asked. |
| `scripts/verify.sh` | Post-deploy check: health, then one real request per role (chat completion / embedding / rerank) — health alone doesn't prove the loaded GGUF is being embedding/reranking correctly. |
| `models/` | Where the client's `.gguf` files go. Nothing under it is committed except `README.md` — see `.gitignore`. |

## Working on this

- Changes to the Dockerfile that add ISA flags, dependencies, or build steps are fine to
  make freely — this is a from-scratch deliverable, not a fork of something else to keep in
  sync with.
- If you DO want to reuse something from `OpsGPT-Platform/opsgpt/docker/llamacpp/Dockerfile`
  (the reference this was generalised from), copy the specific technique — don't turn this
  into a symlink or shared-file relationship with that folder. They are versioned and shipped
  independently; a client running this package must not need anything from `OpsGPT-Platform`.
- No test suite exists yet beyond `scripts/verify.sh`, which needs a running stack (it is a
  smoke test, not a unit test). There is nothing here to unit test — it's a Dockerfile and a
  compose file.
- Before pushing a new tag to Docker Hub, confirm with whoever asked, even if `build-and-push.sh`
  is the tool being used — the script's own confirm prompt is a safety net, not a substitute
  for asking.
