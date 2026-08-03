# ADR-001 — Kafka como backbone de eventos

- **Status:** Aceito
- **Data:** 2026-08-03
- **Decisores:** Time de Logística Ultra Rápida

## Contexto

O Portal precisa propagar mudanças de estado de ~300 mil entregadores para a Ultra-rápida em até 30 s no P99, e a arquitetura precisa nascer agnóstica: outras plataformas do ecossistema Magalu devem consumir o mesmo fluxo depois, sem reescrita e **sem gerar carga adicional no Portal**.

Além do transporte, três necessidades derivadas de outras decisões deste SDD pesam na escolha:

1. **Replay a partir de um ponto no tempo** — o plano de recuperação (ADR-009) depende de reprocessar o que já foi emitido, após uma indisponibilidade longa.
2. **Retenção do último estado por entregador** — o bootstrap de um consumidor novo precisa reconstruir a base sem varrer o banco do Portal.
3. **Ordenação por entregador** — mesmo com a ordenação lógica garantida por `sequence` (ADR-003), receber em ordem reduz drasticamente o volume de eventos descartados como stale.

## Decisão

Adotamos **Apache Kafka** como backbone, com `driver_id` como chave de partição.

Em nuvem, a recomendação é consumir Kafka gerenciado (Amazon MSK ou equivalente) em vez de operar o cluster: a complexidade operacional é o principal custo desta decisão, e terceirizá-la é o que a torna aceitável.

## Alternativas consideradas

| Critério | **Kafka** | SNS + SQS | SQS FIFO | RabbitMQ |
|---|---|---|---|---|
| Fan-out sem custo no produtor | Consumer groups independentes lendo o mesmo log | Uma fila por consumidor; o SNS replica a mensagem N vezes | Idem, com replicação | Exchange fanout, uma fila por consumidor |
| Ordenação por entregador | Por partição, com `driver_id` como chave | Não oferece | Sim, via `MessageGroupId` | Por fila; frágil sob múltiplos consumidores |
| Replay histórico | Reset de offset, retenção configurável | Não — mensagem some após o ack | Não | Não |
| Último estado por chave | Log compaction nativa | Não | Não | Não |
| Throughput | Muito alto | Alto | **300 msg/s por message group** | Alto |
| Complexidade operacional | **Alta** | Baixa | Baixa | Média |

## Justificativa

Os dois critérios que decidem são **replay** e **compaction**, e nenhuma das alternativas oferece qualquer um dos dois.

Sem replay, o plano de recuperação de uma indisponibilidade de 2 h precisaria reconstruir estado a partir do banco do Portal — exatamente a carga que a arquitetura existe para evitar, e no pior momento possível para gerá-la.

Sem compaction, o bootstrap de um consumidor novo teria de varrer 300 mil registros no Portal. Isso transformaria "adicionar uma plataforma ao ecossistema" numa operação que impacta a fonte, quebrando a premissa de fan-out desacoplado que o enunciado pede.

Seria possível reconstruir os dois recursos sobre SNS+SQS mantendo um snapshot próprio em S3 ou DynamoDB, com um processo de atualização e um de leitura. Mas isso é reimplementar log compaction à mão, com uma superfície de falha nova, para economizar complexidade operacional que um serviço gerenciado já absorve.

O limite de 300 msg/s por *message group* do SQS FIFO não é restritivo aqui — o agrupamento seria por entregador —, mas o serviço continua sem replay e sem compaction.

## Consequências

**Positivas**

- Consumidor novo custa zero ao Portal: é um consumer group a mais lendo um log que já existe.
- Recuperação por reset de offset é uma operação de minutos, sem tocar o OLTP.
- Ordenação por partição reduz o volume de eventos stale, embora a corretude não dependa dela.

**Negativas**

- Complexidade operacional maior que a de uma fila gerenciada simples. Mitigada por Kafka gerenciado, não eliminada.
- Exige disciplina de governança de schema para que a retenção longa não vire um acervo de payloads que ninguém sabe mais decodificar. Endereçado pelo Schema Registry e pela política de compatibilidade em `contracts/README.md`.
- Rebalanceamento de consumer group causa pausa momentânea de consumo. Aceitável diante do SLA de 30 s.

**Condição que invalidaria esta decisão**

Se a organização não tiver acesso a Kafka gerenciado e não tiver quem opere um cluster, o custo passa a superar o benefício. Nesse cenário, SNS+SQS com um snapshot store próprio é o caminho, assumindo conscientemente o trabalho de reimplementar compaction.

## Relacionadas

- [ADR-002](002-outbox-vs-cdc.md) — como os eventos chegam ao broker
- [ADR-005](005-fast-lane.md) — separação de canais por criticidade
- ADR-009 — uso da compaction para catch-up
