# ADR-008 — Pausar o consumo sob degradação, em vez de falhar rápido

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

O consumidor depende do Postgres da Ultra-rápida e do serviço de elegibilidade. Quando uma dessas dependências degrada, o consumidor precisa decidir o que fazer com o evento que tem em mãos.

O reflexo herdado de arquiteturas de requisição-resposta é **falhar rápido**: retenta algumas vezes, desiste, manda para a DLQ, segue para a próxima mensagem. Mantém o consumidor vivo e o lag baixo.

Aplicado a um consumidor de log, esse reflexo produz um resultado ruim. Uma indisponibilidade de banco de 10 minutos, com o volume deste domínio, despeja dezenas de milhares de eventos perfeitamente válidos na DLQ. Depois é preciso reprocessá-los — fora de ordem em relação ao tráfego que continuou fluindo, com risco de aplicar estado velho sobre estado novo, e com esforço humano para organizar o replay. Trocou-se um problema temporário por trabalho permanente, gerado no pior momento possível.

## Decisão

Sob falha **transitória** de dependência, o circuit breaker abre e o consumidor **pausa as partições atribuídas**:

```ruby
def on_dependency_failure(error)
  breaker.record_failure(error)
  return unless breaker.open?

  consumer.pause(consumer.assignment)   # offset NÃO avança
  schedule_probe(interval: 30.seconds)
end

def on_probe_success
  breaker.close
  consumer.resume(consumer.assignment)
end
```

O offset não avança. O log do Kafka segura a fila. Quando a dependência volta, o consumo retoma exatamente de onde parou, **em ordem**, sem nada a reorganizar.

A DLQ fica reservada a falha **permanente de payload** — schema inválido, tipo desconhecido, referência que nunca resolverá. A taxonomia de `dead-letter.schema.json` não tem nenhum código para falha transitória, e essa ausência é a decisão.

## Justificativa

**O broker já é a fila durável.** Numa arquitetura de fila tradicional, parar de consumir significa acumular mensagens em memória ou perdê-las, então falhar rápido faz sentido. Num log com retenção, parar de consumir é apenas não avançar um número inteiro. A infraestrutura para "segurar a fila" já está paga.

**Ordem é preservada de graça.** Reprocessar da DLQ mistura eventos antigos com o tráfego atual. Ainda que a ordenação por versão ([ADR-003](003-ordenacao-por-versao.md)) impeça corrupção, o resultado é uma enxurrada de eventos descartados como stale — trabalho puro. Pausar evita isso inteiramente.

**Backpressure é sinal honesto.** Um consumidor que consome e falha esconde o problema: parece saudável, com lag baixo e DLQ crescendo. Um consumidor pausado mostra lag crescente, que é exatamente a métrica que descreve a realidade — e que aciona o alerta certo.

**A DLQ vira alertável.** Como só recebe defeito real, qualquer mensagem nova é acionável. Uma DLQ que também recebe ruído de infraestrutura tem sua profundidade ignorada em poucas semanas, e deixa de servir para o que existe.

## O que isto exige

**Retenção suficiente.** Pausar só é seguro enquanto o Kafka retiver o que não foi consumido. Com retenção de 7 dias, o consumidor pode ficar fora por muito mais tempo que qualquer indisponibilidade plausível. Passado o limite, há perda real — por isso a idade da mensagem não consumida mais antiga é métrica de alerta, não apenas o lag.

**O produtor precisa do comportamento espelhado.** Se o Kafka é quem está fora, o Portal continua gravando no outbox e o relay acumula ([ADR-002](002-outbox-vs-cdc.md)). O disco do outbox precisa ser dimensionado para o pior caso previsto, e a idade da linha não publicada mais antiga precisa ser monitorada. Os dois lados seguram; nenhum descarta.

**Distinguir transitório de permanente com precisão.** Classificar erro permanente como transitório trava o consumidor para sempre num veneno. A regra é conservadora: a lista de erros transitórios é **fechada e explícita** (timeout de conexão, pool esgotado, `PG::ConnectionBad`, indisponibilidade do serviço de elegibilidade). Tudo o que não estiver nela é tratado como permanente e vai para a DLQ. Errar para o lado de dead-letter é recuperável por replay; errar para o lado de pausar não é.

## Alternativas consideradas

| Estratégia | Ordem preservada | Trabalho gerado | Sinal de observabilidade |
|---|---|---|---|
| **Pausar (escolhida)** | Sim | Nenhum | Lag crescente — honesto |
| DLQ + replay | Não | Reprocessamento manual | DLQ cheia — ambíguo |
| Retentativa infinita sem pausar | Sim | Nenhum | Consumidor vivo martelando dependência caída |
| Descartar e reconciliar depois | Não | Reconciliação completa | Divergência silenciosa |

A retentativa infinita sem pausar merece destaque porque é a que mais se parece com a escolhida. A diferença é o efeito sobre a dependência: um consumidor que retenta em laço mantém pressão sobre um banco que está tentando se recuperar, e frequentemente é o que impede a recuperação. Pausar com probe periódico dá trégua.

## Verificação

Esta decisão é a mais contrariável do documento, então foi executada contra Kafka real em vez de apenas afirmada. Os specs estão em `harness/spec/messaging/backpressure_spec.rb`:

| Cenário | Verificado |
|---|---|
| Dependência cai | Breaker abre, consumidor pausa, **DLQ vazia**, offset congelado em `-1` |
| Durante a pausa | Lag igual à altura total do log, calculado pelas marcas d'água do broker |
| Dependência volta | Probe fecha o breaker, consumo retoma do mesmo offset, backlog drena, nenhum evento perdido |
| Payload defeituoso | **Vai** para a DLQ, breaker permanece fechado, consumo não trava |

O último é a contraparte necessária: se tudo fosse pausa, um veneno travaria o pipeline para sempre.

Todas as asserções são sobre **estado observável** — breaker aberto, partições pausadas, offset congelado, profundidade da DLQ — e nenhuma sobre tempo decorrido. Asserção temporal é a origem mais comum de teste de resiliência intermitente, e seria incoerente defender que guardrail instável não é guardrail e entregar um.

> **O que a implementação revelou.** Escrever estes testes expôs um bug de perda de dado no consumidor: avançar o offset para qualquer desfecho que não fosse pausa fazia com que uma mensagem em retentativa tivesse seu offset commitado — e portanto sumisse na retomada. Os desfechos que autorizam commit passaram a ser lista explícita. Expôs também que a retentativa com backoff estava documentada e não implementada, o que impedia o breaker de acumular falhas dentro de um lote.

## Consequências

**Positivas**

- Nenhum evento perdido ou reordenado por indisponibilidade.
- Recuperação é automática e não requer intervenção.
- DLQ vira métrica de qualidade com zero falso positivo.
- A dependência degradada recebe trégua em vez de pressão adicional.

**Negativas**

- O lag cresce durante a indisponibilidade, e com ele o tempo até o dado refletir. O SLA de 30 s **é violado** enquanto durar — isso é explícito e aceito: um dado atrasado é preferível a um dado perdido ou aplicado fora de ordem.
- Exige classificação correta de erro, que é código a manter.
- Retenção do tópico vira restrição operacional, não detalhe de configuração.

## Relacionadas

- [ADR-002](002-outbox-vs-cdc.md) — comportamento espelhado no produtor
- [ADR-005](005-fast-lane.md) — por que o fast-lane drena primeiro na retomada
- [03-resiliencia.md](../03-resiliencia.md) — backoff, breaker e observabilidade
