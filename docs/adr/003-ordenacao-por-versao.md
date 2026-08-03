# ADR-003 — Ordenação por versão monotônica, não por relógio

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

O enunciado exige tratar **atualizações simultâneas do mesmo entregador emitidas fora de ordem**. Isso não é hipótese remota: relay republicando após falha, rebalanceamento de consumer group, replay pós-outage e a própria separação de canais ([ADR-005](005-fast-lane.md)) produzem reordenação rotineiramente.

O consumidor precisa de um critério para responder a uma pergunta só: **este evento é mais novo que o estado que já tenho?**

## Decisão

Cada entregador tem um **contador monotônico** (`sync_version`) incrementado pela fonte na mesma transação que muda o estado. Ele viaja no envelope como a extensão CloudEvents `sequence`.

O consumidor aplica com escrita condicional:

```sql
UPDATE driver_projections
   SET state = :state, source_version = :sequence, updated_at = now()
 WHERE driver_id = :driver_id
   AND source_version < :sequence;
```

Zero linhas afetadas significa que o evento é **stale** — chegou depois de outro mais novo. Descarta-se, e emite-se métrica.

## Alternativas consideradas

| Critério | Funciona? | Por quê |
|---|---|---|
| `occurred_at` (relógio de parede) | **Não** | Clock skew entre instâncias do Portal inverte a ordem de fatos próximos. Duas escritas no mesmo milissegundo são indistinguíveis. Um NTP mal configurado corrompe estado silenciosamente. |
| Offset do Kafka | **Não** | Só é comparável dentro de uma partição. Não sobrevive a replay, não existe quando o estado chega pela API de reconciliação, e é inválido entre canais distintos. |
| Vector clock | Sim, mas | Resolve escrita concorrente sem fonte única. Aqui o Portal **é** a fonte única — não há concorrência real de escrita a resolver. Custo de implementação e de payload sem problema correspondente. |
| **Contador monotônico por entregador** | **Sim** | Total, comparável, gerado transacionalmente pela única fonte de escrita. |

## Por que a comparação é estrita (`<`) e não `<=`

Com estado completo ([ADR-013](013-estado-completo-vs-delta.md)), reaplicar um evento de versão igual produziria exatamente o mesmo estado. A diferença entre `<` e `<=` é, portanto, **invisível se olharmos apenas o estado final** — e é justamente por isso que ela merece registro.

A diferença é observável no **efeito colateral**. O consumidor reavalia a elegibilidade do entregador a cada escrita efetiva e emite evento interno quando ela muda. Com `<=`, uma reentrega gera uma escrita a mais, que dispara reavaliação, que pode emitir oferta duplicada ao motor de despacho. O estado converge; o comportamento observável, não.

Por isso o applier não retorna booleano, e sim um **desfecho**:

| Desfecho | Significado |
|---|---|
| `:applied` | Evento novo, projeção avançou |
| `:duplicate` | `(source, id)` já processado |
| `:stale` | `sequence` menor ou igual ao já projetado |

As propriedades do harness asseram sobre o desfecho, não só sobre o estado. É o que torna a troca de `<` por `<=` detectável — e é exatamente a mutação que `bin/mutate` aplica para provar que o teste tem valor.

## Como a fonte gera o contador

Dentro da transação que muda o entregador:

```sql
UPDATE drivers
   SET status = :status, sync_version = sync_version + 1, updated_at = now()
 WHERE id = :driver_id
RETURNING sync_version;
```

O `UPDATE` toma o lock da linha, então dois writers concorrentes para o mesmo entregador serializam e recebem versões distintas. Não é preciso sequence separada nem lock explícito.

**Escolha deliberada:** o contador é por entregador, não global. Um contador global viraria ponto de contenção entre 300 mil entidades independentes, sem oferecer nada — não existe invariante que dependa de comparar a versão de um entregador com a de outro.

## Consequências

**Positivas**

- Reordenação deixa de ser problema de infraestrutura e vira decisão local de uma linha de SQL.
- A regra vale igualmente para evento vindo do broker e para estado vindo da API de reconciliação — o consumidor tem um único caminho de escrita.
- Torna a separação de canais ([ADR-005](005-fast-lane.md)) segura: eventos do mesmo entregador em tópicos diferentes ainda convergem, porque compartilham o mesmo espaço de versão.

**Negativas**

- Exige disciplina: `sync_version` **precisa** ser incrementado em toda escrita no Portal. Uma migração que altere entregadores sem incrementar produz evento que o consumidor descarta como stale. Endereçado por teste de invariante e por revisão obrigatória do path.
- Eventos descartados como stale são trabalho jogado fora. Aceitável — e a partição por `driver_id` mantém o volume baixo.

## Relacionadas

- [ADR-004](004-locking.md) — por que a escrita condicional dispensa lock pessimista
- [ADR-005](005-fast-lane.md) — separação de canais que esta decisão viabiliza
- [ADR-013](013-estado-completo-vs-delta.md) — por que estado completo é pré-requisito
