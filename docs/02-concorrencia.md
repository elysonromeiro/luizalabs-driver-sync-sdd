# Concorrência e idempotência

> **Pilar 1.** Como o consumidor aplica um evento sem corromper estado sob duplicação, reordenação e concorrência — e como faz isso em lote sem cair em N+1.

## O caminho de escrita

Toda escrita na projeção passa por um único método. Isso não é elegância: é o que torna a corretude auditável e protegível.

```ruby
module UltraSync
  class EventApplier
    # Aplica um evento e devolve o desfecho.
    #
    # :applied   — evento novo, projeção avançou
    # :duplicate — (source, id) já processado
    # :stale     — sequence menor ou igual ao já projetado
    def apply(event)
      store.transaction do
        return :duplicate unless guard.claim(event.source, event.id)

        rows = store.conditional_upsert(
          driver_id:      event.driver_id,
          state:          event.state,
          source_version: event.sequence
        )

        rows.zero? ? :stale : :applied
      end
    end
  end
end
```

**Por que desfecho e não booleano.** Com estado completo, reaplicar um evento de versão igual produz exatamente o mesmo estado — a diferença entre certo e errado é invisível se olharmos apenas a projeção. Ela aparece no efeito colateral: cada escrita efetiva dispara reavaliação de elegibilidade, que pode emitir oferta ao motor de despacho. Um applier que retorna booleano não deixa nenhum teste distinguir "aplicou" de "ignorou corretamente", e a suíte passa a aceitar silenciosamente a troca de `<` por `<=`.

Esse é o mesmo raciocínio que sustenta o mutation testing do [Pilar 3](05-ai-harness.md): um teste que não consegue observar a diferença não protege nada.

## Duas defesas, coisas diferentes

| Mecanismo | Reconhece | Sem ele |
|---|---|---|
| `processed_events` | O **mesmo fato** reentregue | Reprocessamento dispara reavaliação e oferta duplicada |
| `source_version < :sequence` | Um fato **mais antigo** | Evento atrasado sobrescreve estado novo |

As duas são necessárias. Um evento reentregue quando a projeção está atrás passaria pela comparação de versão sem problema — e é justamente o caso comum após um rebalanceamento, quando o offset não foi commitado.

### Deduplicação

```sql
CREATE TABLE processed_events (
  source      text        NOT NULL,
  event_id    uuid        NOT NULL,
  processed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, event_id)
) PARTITION BY RANGE (processed_at);
```

A reivindicação é uma escrita condicional, não um `SELECT` seguido de `INSERT`:

```sql
INSERT INTO processed_events (source, event_id)
VALUES (:source, :event_id)
ON CONFLICT DO NOTHING;
```

Zero linhas significa que outro processo já reivindicou. Ler antes de inserir criaria exatamente a janela que se quer fechar: dois consumidores leriam "não existe" e ambos processariam.

**Retenção por particionamento.** A tabela cresce com o volume de eventos e existe para responder uma pergunta sobre passado recente. Partições diárias, com `DROP PARTITION` após 30 dias, resolvem: apagar uma partição é instantâneo, enquanto `DELETE` em massa gera bloat e trabalho de vacuum. Trinta dias cobrem com folga qualquer replay operacional; um replay mais antigo que isso é reprocessamento deliberado, e reaplicar estado completo é inofensivo.

### Escrita condicional

```sql
UPDATE driver_projections
   SET state = :state, source_version = :sequence, updated_at = now()
 WHERE driver_id = :driver_id
   AND source_version < :sequence;
```

Detalhada em [ADR-004](adr/004-locking.md). O essencial: não há decisão em Ruby, logo não há janela entre decidir e escrever.

## O bug que isto evita

```ruby
# NÃO fazer isto
projection = DriverProjection.find_by(driver_id: id)
if event.sequence > projection.source_version
  projection.update!(state: event.state, source_version: event.sequence)
end
```

Sob `READ COMMITTED`, dois consumidores executam isto em paralelo:

| Tempo | Consumidor A (seq 7) | Consumidor B (seq 6) |
|---|---|---|
| t1 | lê `source_version = 5` | |
| t2 | | lê `source_version = 5` |
| t3 | 7 > 5 → escreve versão 7 | |
| t4 | | 6 > 5 → **escreve versão 6** |

Estado final: versão 6. A versão 7 foi perdida. Se a 7 era um bloqueio de segurança, alguém bloqueado continua recebendo corridas.

O intervalo entre t1 e t3 é o que torna isso provável, não raro: ele inclui a avaliação de elegibilidade, que faz I/O.

A suíte `spec/concurrency` reproduz esse lost update contra Postgres real e mostra o mesmo teste passando com a escrita condicional. O bug e a correção ficam no mesmo arquivo, porque a versão que falha é a única prova de que a que passa está de fato testando alguma coisa.

## Concorrência determinística

Teste de concorrência com `sleep` e threads passa por sorte e falha por azar. O harness ataca isso em três níveis:

**1. Enumeração de entrelaçamentos.** A seção crítica tem pontos de preempção conhecidos (ler → decidir → escrever). Um scheduler executa **todos** os entrelaçamentos possíveis entre dois consumidores e assere a invariante em cada um. Determinístico, reprodutível, milissegundos.

**2. Colisão real forçada.** `Concurrent::CyclicBarrier` sincroniza N threads no ponto exato da colisão, repetido em muitas iterações.

**3. Postgres real.** Onde a semântica de isolamento importa de fato — `READ COMMITTED` versus `SERIALIZABLE`, `SELECT ... FOR UPDATE`, advisory locks, deadlock provocado.

O nível 1 dá determinismo; o 3 dá realismo. Nenhum basta sozinho, e a tese que atravessa tudo é: **guardrail flaky não é guardrail** — um teste que falha aleatoriamente é desligado pela primeira pessoa apressada, e some da proteção.

## Consumo em lote sem N+1

O consumidor puxa lotes, não mensagens avulsas. Escrito de forma ingênua, o lote vira N+1 imediatamente.

### O anti-padrão

```ruby
# NÃO fazer isto
events.each do |event|
  next unless ProcessedEvent.create_or_find_by(source: event.source, event_id: event.id).persisted?
  projection = DriverProjection.find_by(driver_id: event.driver_id)   # 1 query por evento
  projection.update!(state: event.state, source_version: event.sequence)  # + 1 por evento
end
```

Para um lote de 500 eventos: **1.501 queries**. Não é estimativa — é contagem. Cada evento gera uma reivindicação, uma leitura e uma escrita.

### O padrão

Três instruções, independentemente do tamanho do lote:

```ruby
def process_batch(events)
  # 1. Colapsa o lote: por entregador, só o evento de maior sequence importa.
  #    Necessário e sutil — ON CONFLICT não pode afetar a mesma linha duas vezes
  #    na mesma instrução. Sem este passo, um lote com duas mudanças do mesmo
  #    entregador aborta a transação inteira (ver nota abaixo).
  latest = events
             .group_by(&:driver_id)
             .transform_values { |es| es.max_by { |e| e.sequence } }
             .values
             .sort_by(&:driver_id)   # ordem canônica — previne deadlock (ADR-004)

  # 2. Reivindica todos os event_ids de uma vez.
  claimed = ProcessedEvent.insert_all(
    events.map { { source: _1.source, event_id: _1.id } },
    unique_by: %i[source event_id],
    returning: %i[event_id]
  ).rows.flatten.to_set

  fresh = latest.select { claimed.include?(_1.id) }
  return if fresh.empty?

  # 3. Upsert condicional em lote — uma instrução.
  conditional_upsert_all(fresh)
end
```

O upsert condicional em lote não tem API no ActiveRecord, porque `upsert_all` não expõe o `WHERE` do `DO UPDATE`. O Postgres suporta:

```sql
INSERT INTO driver_projections (driver_id, state, source_version, updated_at)
VALUES (...), (...), (...)
ON CONFLICT (driver_id) DO UPDATE
   SET state          = EXCLUDED.state,
       source_version = EXCLUDED.source_version,
       updated_at     = now()
 WHERE driver_projections.source_version < EXCLUDED.source_version
RETURNING driver_id;
```

O `WHERE` no `DO UPDATE` preserva exatamente a semântica da escrita condicional individual, em lote. `RETURNING` devolve quem de fato mudou — é assim que o processamento em lote continua sabendo distinguir `:applied` de `:stale`, que é o insumo da reavaliação de elegibilidade.

Isso exige SQL literal em vez do ActiveRecord. É uma exceção deliberada e localizada num método: a alternativa seria emitir uma instrução por entregador e perder duas ordens de grandeza de eficiência para manter a pureza do ORM.

**Por que o passo 1 não é opcional.** Se o mesmo `driver_id` aparecer duas vezes no mesmo `INSERT`, o Postgres aborta — e aborta a transação inteira, não só a linha:

```
ERROR:  ON CONFLICT DO UPDATE command cannot affect row a second time
HINT:  Ensure that no rows proposed for insertion within the same command
       have duplicate constrained values.
```

Um lote que contenha duas mudanças do mesmo entregador é ocorrência normal, não excepcional: acontece sempre que um operador altera perfil e status em sequência, e sempre durante drain de backlog. Sem o colapso prévio, o consumidor quebraria justamente sob a carga que ele existe para absorver.

> Os três comportamentos afirmados nesta seção — o `WHERE` no `DO UPDATE`, o `RETURNING` devolvendo apenas as linhas efetivamente alteradas e o erro de chave repetida — foram verificados contra PostgreSQL 16 antes de serem escritos aqui, e viram teste na suíte `spec/concurrency`.

### O ganho

| Lote de 500 eventos | Queries |
|---|---|
| Ingênuo | 1.501 |
| Em lote | **3** |

O harness conta as queries emitidas e falha se o número crescer com o tamanho do lote. Uma asserção sobre a **forma** do acesso, não sobre tempo de execução — porque tempo é ruidoso e contagem é determinística, e porque um agente de IA que "refatore para clareza" trocando o upsert em lote por um laço não muda nenhum resultado, só o custo.

### Outros N+1 no caminho

| Onde | Sintoma | Correção |
|---|---|---|
| Serialização de projeção com associações | Uma query por associação por registro | `includes(:vehicle, :operating_area)` |
| Reavaliação de elegibilidade consultando configuração por entregador | Uma query por entregador | Carregar a configuração uma vez por lote e passar adiante |
| Emissão de evento interno por entregador | Um `INSERT` por entregador | `insert_all` no outbox interno |

## O que o harness prova

| Invariante | Como |
|---|---|
| Idempotência | `apply(S) == apply(S ++ duplicatas(S))` para qualquer sequência |
| Comutatividade | `apply(S) == apply(shuffle(S))` |
| Monotonicidade | `source_version` nunca decresce |
| Convergência | Réplicas com o mesmo conjunto em ordens distintas convergem |
| Ausência de lost update | Entrelaçamentos enumerados + colisão real em Postgres |
| Ausência de N+1 | Contagem de queries constante no tamanho do lote |

Detalhado em [05-ai-harness.md](05-ai-harness.md).

## Relacionadas

- [ADR-003](adr/003-ordenacao-por-versao.md) — ordenação por versão monotônica
- [ADR-004](adr/004-locking.md) — escrita condicional e prevenção de deadlock
- [ADR-013](adr/013-estado-completo-vs-delta.md) — por que a escrita é atribuição
