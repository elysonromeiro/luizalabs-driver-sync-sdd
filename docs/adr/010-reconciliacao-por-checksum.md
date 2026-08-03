# ADR-010 — Reconciliação por checksum de faixa, não por varredura

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

Depois de uma indisponibilidade longa, é preciso responder a uma pergunta operacional: **o consumidor está em dia com o Portal?**

O tópico compactado ([ADR-009](009-snapshot-compactado.md)) resolve a recuperação de estado, mas não responde a essa pergunta. Ele reconstrói; não diz se era necessário reconstruir. E existem cenários em que a divergência não vem de indisponibilidade — bug de consumidor, migração no Portal que esqueceu de incrementar `sync_version`, replay mal executado.

A resposta ingênua é comparar os 300 mil registros dos dois lados. Ela transfere a base inteira para descobrir que 50 divergem, e faz isso no momento em que o sistema está mais frágil.

## Decisão

**Escada de custo crescente.** Cada degrau só é usado se o anterior não resolver.

| Degrau | Mecanismo | Custo para o Portal |
|---|---|---|
| 1 | Replay do consumer group a partir do offset | **zero** |
| 2 | Bootstrap pelo tópico compactado | **zero** |
| 3 | `GET /v1/drivers/checksums` — achar as faixas divergentes | leve, agregado, em réplica |
| 4 | `GET /v1/drivers` nas faixas divergentes — keyset pagination | moderado, em réplica |

O degrau 3 é a decisão que este ADR registra. Divide a base em faixas por `hash(driver_id) % buckets` e devolve, por faixa, a contagem e um checksum agregado sobre os pares `(driver_id, source_version)`.

Comparar 1024 números é trivial. Só as faixas que não baterem exigem o degrau 4.

## Por que XOR

O checksum precisa ser **independente de ordem**. Se não fosse, os dois lados teriam de ordenar antes de comparar — e ordenar 300 mil registros no OLTP é exatamente a carga que se quer evitar.

XOR é comutativo e associativo, então `a ^ b ^ c == c ^ a ^ b`. Cada lado agrega na ordem que quiser e chega ao mesmo número.

**Limitação registrada:** XOR é auto-inverso (`a ^ a == 0`), então um registro contado duas vezes se cancela e some do checksum. Isso é seguro aqui porque `driver_id` é chave primária nos dois lados — não existe duplicata a mascarar. Não seria adequado para um conjunto com repetição, e vale dizer isso em vez de deixar a armadilha para quem reusar a técnica.

## A parte que só apareceu ao executar

O Portal computa o checksum em SQL, agregado no banco. O consumidor computa em Ruby, sobre a projeção. As duas expressões precisam produzir **o mesmo número**.

Na primeira execução do spec de paridade, as contagens bateram e os checksums não:

```
sql  = -2650426647071125052
ruby = 15796317426638426564
```

São os mesmos bits. `bigint` do Postgres é 64 bits **com sinal**; `Integer` do Ruby é ilimitado.

Sem normalização, a reconciliação acusaria divergência em **toda faixa, sempre** — e o modo de falha é silencioso, porque "os checksums não batem" é precisamente o que se espera ver quando há drift de verdade. O resultado seria gerar carga no OLTP durante uma recuperação, para um problema que não existe. Pior que não ter reconciliação.

Duas correções decorreram disso:

1. Normalização explícita para 64 bits sem sinal nos dois lados.
2. O contrato passou a transportar o checksum como **hexadecimal de 16 caracteres**, não como número, para que a representação numérica de nenhuma linguagem consumidora reintroduza o problema.

O spec de paridade existe só para isso, e se pagou na primeira execução.

## Keyset, nunca OFFSET

O degrau 4 pagina por `(updated_at, driver_id)` com cursor.

`OFFSET` degrada para varredura a cada página: para chegar à página N, o banco produz e descarta todas as anteriores, e o custo total da travessia cresce quadraticamente. Num cenário de recuperação — o único em que este degrau é usado — isso é o oposto do que se quer.

O spec assere sobre o **plano de execução**, verificando que o índice composto é usado. Asserção sobre tempo seria ruidosa; sobre o plano, é determinística.

Controles adicionais no degrau 4: servido de réplica de leitura, com rate limit adaptativo que reduz o teto sob carga, e congelado durante janela de pico.

## Verificação

Medido em `harness/spec/reconciliation/`:

| Cenário | Resultado |
|---|---|
| Checksum sob ordem embaralhada | idêntico |
| Um entregador com versão atrasada em 1.000 | aponta **exatamente** a faixa dele |
| 5 divergências em 5.000 entregadores | **< 5% da base** a transferir |
| Paridade SQL × Ruby, 500 registros | idêntica em todas as faixas |
| Travessia por keyset de 250 registros | sem repetir nem pular, usando índice |

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **Checksum por faixa** | Escolhida |
| Comparar tudo | Transfere 300 mil para achar 50 |
| Árvore de Merkle completa | Localiza melhor a divergência, mas exige estrutura persistida e sincronizada dos dois lados. Faixa fixa dá quase o mesmo com uma query agregada |
| Comparar apenas `count(*)` | Não detecta divergência de versão — o caso mais comum e o mais perigoso |
| Confiar no lag do consumer group | Diz o que falta consumir, não se o que foi consumido está correto |

A última é a mais tentadora porque é gratuita, e é a que falha exatamente nos casos que motivaram este ADR: bug de consumidor e migração sem incremento de versão não aparecem no lag.

## Consequências

**Positivas**

- Detectar divergência custa uma query agregada, sem transferir dado de entregador.
- Reconciliação toca apenas o que divergiu.
- A mesma técnica serve para verificação periódica de saúde, não só para recuperação.

**Negativas**

- Duas implementações do mesmo cálculo (SQL e Ruby), que podem divergir. Mitigado pelo spec de paridade — que é obrigatório, não opcional.
- O número de faixas é um trade-off a calibrar: mais faixas isolam melhor e encarecem a comparação; menos faixas fazem o contrário.
- O checksum detecta divergência, não diz **qual** entregador divergiu dentro da faixa. É por desenho — descobrir isso é o degrau 4.

## Relacionadas

- [ADR-009](009-snapshot-compactado.md) — os degraus 1 e 2
- [ADR-003](003-ordenacao-por-versao.md) — `source_version` é o que entra no checksum
- [`contracts/openapi.yaml`](../../contracts/openapi.yaml) — os endpoints
