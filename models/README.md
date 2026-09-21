# Put your GGUF model files here

This folder is bind-mounted read-only into all three containers as `/models`.
Nothing in this repo ships a model — the client supplies their own `.gguf`
files (already licensed/approved for their use), and their filenames go into
`.env` as `LLM_MODEL_FILE`, `EMBED_MODEL_FILE`, `RERANK_MODEL_FILE`.

Getting a GGUF onto an air-gapped box is the client's transfer problem to
solve (USB drive, internal file share, whatever their policy allows) — this
repo only expects the files to already be here by the time `docker compose up`
runs.

Nothing under this folder except this README is committed to git — see
`.gitignore` in the repo root.
