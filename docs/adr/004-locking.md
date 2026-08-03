# ADR-004 — Escrita condicional como padrão, lock pessimista por exceção

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

Dois consumidores do mesmo consumer group podem processar eventos do mesmo entregador ao mesmo tempo — durante rebalanceamento, ou porque um replay concorre com o consumo ao vivo. A sequência ingênua é um *read-modify-write* clássico:

```ruby
# NÃO fazer isto
projection = DriverProjection.find_by(driver_id: id)   # lê versão 4
if event.sequence > projection.source_version          # decide fora da transação
  projection.update!(state: event.state, source_version: event.sequence)
end
```

Entre a leitura e a escrita, outro processo pode ter avançado a projeção. O resultado é **lost update**: a versão maior é sobrescrita pela menor, e o entregador fica com estado antigo — que, no caso de um bloqueio de segurança, significa alguém bloqueado continuando a receber corridas.

## Decisão

**Escrita condicional (optimistic) como padrão.** A comparação de versão vai para dentro do `WHERE`, e o banco decide atomicamente:

```sql
UPDATE driver_projections
   SET state = :state, source_version = :sequence, updated_at = now()
 WHERE driver_id = :driver_id
   AND source_version < :sequence;
```

Não há janela entre decidir e escrever, porque não há decisão em Ruby — há uma única instrução que o Postgres executa sob lock de linha implícito. O número de linhas afetadas é a resposta: 1 aplicou, 0 era stale.

**Lock pessimista apenas onde existir invariante multi-linha** que a escrita condicional não cubra. No fluxo de sincronização, não existe: a transação do consumidor toca a tabela de deduplicação e a projeção, e ambas são protegidas por escrita condicional (`ON CONFLICT DO NOTHING` e o `UPDATE` acima). **Nenhum `SELECT ... FOR UPDATE` é necessário**, e essa ausência é deliberada.

## Alternativas consideradas

| Estratégia | Contenção | Round-trips | Quando faz sentido |
|---|---|---|---|
| **Escrita condicional** | Nenhuma além do lock de linha | 1 | Padrão aqui |
| `SELECT ... FOR UPDATE` | Serializa por entregador; segura lock durante o processamento | 2+ | Invariante que abrange várias linhas |
| `SERIALIZABLE` | Abortos sob concorrência, com retry obrigatório | 1 + retries | Invariantes que o banco precisa inferir |
| `pg_advisory_xact_lock` | Serializa por chave arbitrária | 2 | Coordenar trabalho fora do modelo de linhas |

`SELECT ... FOR UPDATE` funcionaria, mas segura o lock da linha durante todo o processamento — inclusive durante a avaliação de elegibilidade — e exige um round-trip a mais. Serializa o que não precisa ser serializado.

`SERIALIZABLE` transforma a colisão em `PG::TRSerializationFailure` (SQLSTATE `40001`) que o aplicativo precisa capturar e reexecutar. É a ferramenta certa quando existe invariante que o banco precisa deduzir de várias leituras; aqui a invariante cabe num `WHERE`, e pagar aborto e retry por ela é desperdício.

Advisory locks continuam úteis **fora** do caminho de consumo: o job de reconciliação usa `pg_advisory_xact_lock(hashtext(driver_id))` para garantir que reconciliação e consumo ao vivo não trabalhem no mesmo entregador simultaneamente.

> As três estratégias são medidas contra Postgres real na suíte `spec/concurrency` — contenção, throughput e custo de aborto. A decisão acima é a hipótese; os números do harness são a verificação.

## Prevenção de deadlock

Onde mais de uma linha for tocada na mesma transação, a ordem de aquisição é **canônica e ordenada por `driver_id`**. Processamento em lote ordena o lote antes de escrever:

```ruby
events.sort_by(&:driver_id).each { |e| apply(e) }
```

Duas transações que toquem o mesmo conjunto de entregadores vão adquirir os locks na mesma ordem e nunca formar ciclo. Sem isso, dois lotes com interseção invertida deadlockam sob carga — e o Postgres resolve abortando um deles, o que aparece como erro intermitente em produção e é caro de diagnosticar.

## Consequências

**Positivas**

- Zero contenção entre entregadores distintos: 300 mil entidades independentes escalam horizontalmente sem coordenação.
- Lost update é impossível por construção, não por disciplina de código.
- O caminho de escrita é uma instrução, o que o torna trivial de auditar e de proteger com teste.

**Negativas**

- Evento stale consome um round-trip antes de ser descartado. Barato, e a partição por chave mantém o volume baixo.
- A regra depende de `source_version` estar sempre correto. Um agente de IA que "simplifique" o `WHERE` remove a proteção inteira sem quebrar nenhum teste de estado final — razão pela qual o applier reporta desfecho e não booleano ([ADR-003](003-ordenacao-por-versao.md)), e razão pela qual esse arquivo é path protegido.

## Relacionadas

- [ADR-003](003-ordenacao-por-versao.md) — origem e semântica de `sequence`
- [ADR-013](013-estado-completo-vs-delta.md) — por que a escrita é uma atribuição
