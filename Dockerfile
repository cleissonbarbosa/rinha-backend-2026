FROM nimlang/nim:2.2.4-alpine AS build

WORKDIR /src
COPY src ./src

RUN apk add --no-cache zig

RUN mkdir -p /out && zig build-lib \
    -static \
    -O ReleaseFast \
    -femit-bin=/out/libvector_core.a \
    src/vector_core.zig

RUN nim c \
    -d:release \
    -d:danger \
    --mm:arc \
    --threads:off \
    --opt:speed \
    --passC:-flto \
    --passL:-flto \
    --passL:/out/libvector_core.a \
    -o:/out/rinha \
    src/server.nim

FROM alpine:3.20

RUN adduser -D -H -u 10001 app
COPY --from=build /out/rinha /app/rinha

USER app
EXPOSE 8080
ENTRYPOINT ["/app/rinha"]
