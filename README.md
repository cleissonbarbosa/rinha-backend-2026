# Rinha de Backend 2026

Implementação para a Rinha de Backend 2026, com foco em latência p99:

- `GET /ready`
- `POST /fraud-score`
- duas instâncias Nim atrás de Nginx round-robin na porta `9999`
- limites totais no Compose: `1 CPU` e `288MB`
- parsing especializado do payload para reduzir alocação no caminho quente
- núcleo vetorial em Zig linkado estaticamente no binário Nim

## Rodando

```bash
docker compose up -d --build
curl http://localhost:9999/ready
```

Exemplo:

```bash
curl -s http://localhost:9999/fraud-score \
  -H 'Content-Type: application/json' \
  -d '{"id":"tx-1","transaction":{"amount":384.88,"installments":3,"requested_at":"2026-03-11T20:23:35Z"},"customer":{"avg_amount":769.76,"tx_count_24h":3,"known_merchants":["MERC-009","MERC-001"]},"merchant":{"id":"MERC-001","mcc":"5912","avg_amount":298.95},"terminal":{"is_online":false,"card_present":true,"km_from_home":13.7090520965},"last_transaction":{"timestamp":"2026-03-11T14:58:35Z","km_from_current":18.8626479774}}'
```

## Estratégia

A API mantém o Nim no HTTP/parsing e delega o núcleo numérico para `src/vector_core.zig`, linkado como biblioteca estática via ABI C. A decisão usa um classificador conservador e de custo constante, calibrado para reduzir falso negativo e manter o p99 baixo sob o cenário de carga da Rinha.

Para submissão oficial, publique a imagem `linux/amd64` e ajuste o `image:` do `docker-compose.yml` na branch `submission` para apontar para a imagem pública.
