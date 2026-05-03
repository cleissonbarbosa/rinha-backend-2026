# Rinha de Backend 2026

Implementação para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026). Classificação de transações como fraude ou legítimas por busca vetorial.

## Stack

| Camada | Tecnologia | Por quê |
|---|---|---|
| Load balancer | Custom (hare) | evitar overhead de proxies genéricos.. |
| API ×2 | Nim + httpbeast | parser JSON manual, FFI direto p/ Zig |
| vector core | Zig 0.13 | k-NN sobre índice IVF com SIMD AVX2/FMA/F16C |
| Dataset | `references.json.gz` | baixado no build e convertido para `vectors.bin`, `labels.bin` e `ivf.bin` |

## test

```bash
docker compose up -d --build
curl -fsS http://localhost:9999/ready
```
