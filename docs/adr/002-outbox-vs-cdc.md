# ADR-002 — Transactional Outbox com relay por polling, CDC como evolução

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

Quando o Portal muda o estado de um entregador, duas coisas precisam acontecer: a linha muda no Postgres e o evento chega ao Kafka. A forma ingênua — atualizar o banco e depois publicar — é um **dual-write**, e tem duas janelas de falha que não se fecham com retentativa:

```ruby
# NÃO fazer isto
driver.update!(status: "blocked")   # commitou
kafka.produce(event)                 # e se o processo morrer aqui?
```

Se o publish falha depois do commit, o entregador está bloqueado no Portal e ativo na Ultra-rápida — o pior estado possível para um bloqueio de segurança. Se invertermos a ordem, publicamos um fato que pode nunca ter sido commitado.

Envolver o Kafka numa transação distribuída (2PC) resolveria no papel e é inviável na prática: acopla a disponibilidade da escrita no Portal à disponibilidade do broker.

## Decisão

**Transactional Outbox.** O Portal grava o evento numa tabela `driver_outbox` **dentro da mesma transação** que altera o entregador. Um processo relay lê a tabela e publica no Kafka.

```ruby
ActiveRecord::Base.transaction do
  driver.update!(status: "blocked", sync_version: driver.sync_version + 1)
  DriverOutbox.create!(
    event_id:       SecureRandom.uuid,
    driver_id:      driver.id,
    sequence:       driver.sync_version,
    type:           "br.com.magalu.logistica.driver.status_changed.v1",
    channel:        "drivers.status.v1",
    payload:        DriverEventSerializer.new(driver).as_json
  )
end
```

Atomicidade do Postgres garante que estado e evento existem juntos ou não existem. Não há janela.

O relay é acionado por **`LISTEN/NOTIFY`** com fallback para polling periódico:

- Um trigger `AFTER INSERT` em `driver_outbox` emite `NOTIFY driver_outbox`.
- O relay fica em `LISTEN`, acorda em milissegundos e drena o que houver.
- Um polling de segurança a cada 5 s cobre notificação perdida — `NOTIFY` não é durável e uma reconexão pode perder o sinal.

O relay publica **em ordem de `id` por entregador**, marca a linha como publicada e é *at-least-once*: pode republicar sob falha. Isso é seguro porque o `event_id` é estável e o consumidor deduplica por `(source, id)`.

## Alternativas consideradas

| Abordagem | Latência típica | Carga no Postgres | Infra adicional | Ordenação |
|---|---|---|---|---|
| Dual-write | mínima | nenhuma | nenhuma | — **incorreto** |
| **Outbox + LISTEN/NOTIFY** | ~10–100 ms | leve (índice parcial) | processo relay | por `id` |
| Outbox + polling puro (1 s) | até 1 s | polling constante | processo relay | por `id` |
| CDC (Debezium sobre o WAL) | ~10 ms | mínima | Kafka Connect + slot de replicação | por LSN |

## Justificativa

O SLA é de **30 s no P99**. Qualquer opção acima entrega isso com folga de duas ordens de grandeza, então **latência não é o critério de decisão** — e é importante dizer isso explicitamente, porque é o critério pelo qual se escolhe CDC por reflexo.

O que decide é custo de operação. Debezium exige Kafka Connect, um slot de replicação lógica no Postgres primário e monitoramento próprio; um slot que para de ser consumido faz o WAL crescer até o disco encher, o que é um modo de falha novo e severo introduzido num sistema que ainda não precisa dele.

O outbox precisa apenas de uma tabela, um índice parcial e um processo Ruby — tecnologia que o time já opera. `LISTEN/NOTIFY` elimina o polling agressivo mantendo a simplicidade.

CDC fica registrado como evolução natural quando o volume tornar o polling de fallback caro, ou quando outros domínios do Portal precisarem de captura de mudanças e o custo da infraestrutura passar a ser diluído.

## Detalhes que importam

**Índice parcial.** A tabela cresce, mas a consulta do relay só olha o que não foi publicado:

```sql
CREATE INDEX idx_outbox_unpublished
  ON driver_outbox (id)
  WHERE published_at IS NULL;
```

O índice permanece pequeno independentemente do tamanho da tabela.

**Retenção.** Linhas publicadas são removidas após 7 dias, em lotes, fora do horário de pico. O outbox é buffer de entrega, não trilha de auditoria — a trilha é o próprio log do Kafka.

**Dimensionamento para indisponibilidade.** Se o Kafka ficar fora por 2 h, o outbox acumula tudo. É preciso monitorar a idade da linha não publicada mais antiga e dimensionar o disco para o pior caso previsto. Este é o mecanismo que faz a decisão [ADR-008](008-backpressure.md) funcionar do lado do produtor.

## Consequências

**Positivas**

- Não existe estado em que o Portal e o log divirjam por falha de publicação.
- O Portal nunca depende da disponibilidade do Kafka para aceitar uma escrita.
- Relay é reiniciável e idempotente por construção.

**Negativas**

- Uma escrita a mais por mudança de estado. Irrelevante no volume deste domínio.
- Mais um processo para operar e monitorar.
- Republicação sob falha é esperada, o que transfere a responsabilidade de deduplicação ao consumidor — coberto por [ADR-003](003-ordenacao-por-versao.md).

## Relacionadas

- [ADR-001](001-broker.md) — escolha do broker
- [ADR-003](003-ordenacao-por-versao.md) — de onde vem `sequence`
- [ADR-008](008-backpressure.md) — comportamento sob indisponibilidade
