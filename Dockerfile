# Portable llama.cpp model server for air-gapped client deployments.
#
# ONE image, run three times (LLM / embedding / reranker) — the role is decided
# entirely by the `command:` flags a compose service passes at runtime (model
# file, --embeddings/--reranking, pooling mode), not by anything baked into the
# image. This mirrors OpsGPT's own docker-compose.yml, which runs the same
# `opsgpt/llamacpp:latest` image as its chat model, both embedders, and its
# reranker. See ../OpsGPT-Platform/opsgpt/docker/llamacpp/Dockerfile — this is
# that recipe, generalised: ISA flags become build args instead of a hardcoded
# Haswell target, because this image ships to hardware we have not benchmarked.
#
# AIR-GAP CONTRACT: the runtime stage never makes a network call. It does not
# download a model — llama-server is invoked with a LOCAL --model path only,
# never --hf-repo. A client with zero internet access can `docker load` this
# image from a tar and run it forever without it ever needing to reach out.
# (The BUILD needs internet, to fetch llama.cpp source and apt packages. Build
# it here, ship the finished image — see README.md for the two transfer paths.)
#
# Multi-stage: a heavy build stage (toolchain + sources), a slim runtime stage.

# ---------- build stage ----------
FROM ubuntu:24.04 AS build

ARG LLAMA_CPP_REF=master

# ISA flags for the build host's CPU family. Defaults are the safe, portable
# choice (AVX2, no AVX-512) that runs on essentially any x86_64 server from the
# last ~10 years. If you know the CLIENT's exact CPU, rebuild with matching
# flags for real throughput gains — see README.md "Tuning for the client's CPU".
# GGML_NATIVE=OFF keeps the build deterministic: it does NOT silently pick up
# extensions (e.g. AVX-512) that happen to exist on whichever machine builds it
# but not on the machine that will run it.
ARG GGML_NATIVE=OFF
ARG GGML_AVX=ON
ARG GGML_AVX2=ON
ARG GGML_FMA=ON
ARG GGML_F16C=ON
ARG GGML_AVX512=OFF

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        ccache \
        libcurl4-openssl-dev \
        libgomp1 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${LLAMA_CPP_REF}" https://github.com/ggml-org/llama.cpp.git . \
    && git rev-parse HEAD > /llama.cpp.commit

# LLAMA_CURL=ON only affects whether the BINARY supports --hf-repo; we simply
# never pass that flag at runtime. Leaving curl support compiled in costs
# nothing and keeps this Dockerfile identical to the reference one it is based
# on, which is worth more than shaving one build dependency.
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=${GGML_NATIVE} \
        -DGGML_AVX=${GGML_AVX} \
        -DGGML_AVX2=${GGML_AVX2} \
        -DGGML_FMA=${GGML_FMA} \
        -DGGML_F16C=${GGML_F16C} \
        -DGGML_AVX512=${GGML_AVX512} \
        -DLLAMA_CURL=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=ON \
        -DLLAMA_BUILD_SERVER=ON \
    && cmake --build build --config Release --target llama-server llama-bench -j "$(nproc)"

# Collect the server binary + the shared libs it links (libllama, libggml*, etc.)
# llama-bench ships too: it lets a deployer benchmark thread counts and batch
# sizes on the CLIENT's actual hardware before picking values for compose, which
# matters because that hardware is unknown at build time.
RUN mkdir -p /opt/llama/bin /opt/llama/lib \
    && cp build/bin/llama-server /opt/llama/bin/ \
    && cp build/bin/llama-bench /opt/llama/bin/ \
    && find build -name "*.so" -exec cp {} /opt/llama/lib/ \; \
    && cp /llama.cpp.commit /opt/llama/

# ---------- runtime stage ----------
FROM ubuntu:24.04 AS runtime

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libcurl4 \
        libgomp1 \
        ca-certificates \
        curl \
        numactl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10001 -m -d /home/llama llama

COPY --from=build /opt/llama/bin/ /usr/local/bin/
COPY --from=build /opt/llama/lib/ /usr/local/lib/
COPY --from=build /opt/llama/llama.cpp.commit /etc/llama.cpp.commit
RUN ldconfig

USER llama
EXPOSE 8080

# Healthcheck hits llama.cpp's own /health endpoint — no OpsGPT-specific code
# in this image at all.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=5 \
    CMD curl -fsS http://localhost:8080/health || exit 1

# Model path, role flags (--embeddings/--reranking/--pooling), threads, context
# etc. are ALL supplied by docker-compose as CLI args — see docker-compose.yml.
# Nothing here decides "this is the LLM" vs "this is the reranker".
ENTRYPOINT ["llama-server"]
