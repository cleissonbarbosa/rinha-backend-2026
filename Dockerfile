FROM nimlang/nim:2.2.4-alpine AS build

WORKDIR /src

RUN apk add --no-cache curl gzip ca-certificates xz tar

# Pin Zig to 0.13.0 so our @Vector / posix calls have a stable target.
RUN curl -fsSL --retry 5 --retry-delay 2 \
        -o /tmp/zig.tar.xz \
        https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz && \
    mkdir -p /opt/zig && \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && \
    rm /tmp/zig.tar.xz && \
    ln -s /opt/zig/zig /usr/local/bin/zig

COPY src ./src

# Compile the build-time preprocessor (separate from the server binary).
RUN nim c \
    -d:release \
    --mm:arc \
    --threads:off \
    --opt:speed \
    -o:/usr/local/bin/preprocess \
    src/preprocess.nim

# Fetch the official reference dataset and convert it to a compact binary
# layout (SoA float16 vectors + u8 labels). The raw .json.gz never makes it
# into the runtime image.
RUN mkdir -p /data && \
    curl -fsSL --retry 5 --retry-delay 2 \
        -o /tmp/references.json.gz \
        https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/references.json.gz && \
    gunzip -f /tmp/references.json.gz && \
    /usr/local/bin/preprocess /tmp/references.json /data/vectors.bin /data/labels.bin && \
    rm -f /tmp/references.json

# Compile the Zig vector core. -mcpu=haswell unlocks AVX2 + FMA + F16C, which
# matches the official Mac Mini Late 2014 test box (Intel i5/i7 Haswell).
RUN mkdir -p /out && zig build-lib \
    -static \
    -fPIC \
    -O ReleaseFast \
    -mcpu=haswell \
    -femit-bin=/out/libvector_core.a \
    src/vector_core.zig

RUN nim c \
    -d:release \
    -d:danger \
    --mm:arc \
    --threads:off \
    --opt:speed \
    --passC:-flto \
    --passC:-march=haswell \
    --passL:-flto \
    --passL:/out/libvector_core.a \
    -o:/out/rinha \
    src/server.nim

FROM alpine:3.20

RUN adduser -D -H -u 10001 app

COPY --from=build /out/rinha /app/rinha
COPY --from=build /data/vectors.bin /data/vectors.bin
COPY --from=build /data/labels.bin /data/labels.bin

RUN chown -R app:app /data

USER app
EXPOSE 8080
ENTRYPOINT ["/app/rinha"]
