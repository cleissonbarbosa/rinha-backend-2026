# Rinha de Backend 2026

Implementação para a Rinha de Backend 2026 — busca por vetor para classificar transações como fraude ou legítimas

## Stack

| Camada | Tecnologia | Por quê |
|---|---|---|
| Load balancer | Nginx 1.27 alpine | round-robin + keepalive 128 |
| API ×2 | Nim | parser JSON manual, FFI direto p/ Zig |
| vector core | Zig | k-NN brute force com SIMD AVX2/F16C |
| Dataset | `references.json.gz` oficial | pré-processado em build time |

## test

```bash
docker compose up -d --build
curl http://localhost:9999/ready
```
