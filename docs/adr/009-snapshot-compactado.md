# ADR-009 — Tópico compactado como fonte de catch-up e bootstrap

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

Duas situações exigem reconstruir o estado de toda a base de entregadores:

1. **Onboarding** — uma plataforma nova do ecossistema Magalu passa a consumir o fluxo e precisa do estado corrente de 300 mil entregadores.
2. **Recuperação** — um consumidor ficou fora além da retenção dos tópicos de ciclo de vida e não pode simplesmente retomar do offset.

A resposta óbvia é o consumidor chamar o Portal e paginar a base inteira. Ela funciona e é ruim pelo mesmo motivo nas duas situações: transforma "adicionar um consumidor" e "recuperar de um incidente" em operações que geram carga na fonte — a segunda no pior momento possível.

Pior: isso destrói a premissa de fan-out desacoplado. Se cada consumidor novo custa uma varredura de 300 mil registros no OLTP do Portal, o custo de crescer o ecossistema é pago por quem não tem nada a ver com ele.

## Decisão

Um terceiro tópico, **`drivers.snapshot.v1`**, com `cleanup.policy=compact` e `driver_id` como chave.

O relay publica nele **junto com todo evento de ciclo de vida**, com a mesma chave. A compaction do Kafka se encarrega de reter apenas a última mensagem por chave.

Ler esse tópico do offset zero devolve o estado corrente de toda a base — uma mensagem por entregador, sem histórico, sem tocar o Portal.

## Por que isto funciona de graça

Não foi preciso construir um mecanismo de snapshot. Ele decorre de duas decisões anteriores:

1. **Estado completo** ([ADR-013](013-estado-completo-vs-delta.md)) — a última mensagem por chave **já é** o estado inteiro. Com delta, a mensagem retida seria um fragmento sem sentido isolado e o snapshot exigiria materialização própria.
2. **Ordenação por versão** ([ADR-003](003-ordenacao-por-versao.md)) — o consumidor aplica o que lê pela mesma regra de sempre. Não há caminho de código especial para bootstrap, e portanto não há caminho de código especial para dar errado.

A segunda consequência é a mais importante na prática: **o bootstrap é seguro mesmo com o log parcialmente compactado**, que é o estado normal de um tópico vivo. Se a compaction ainda não rodou, o consumidor lê versões intermediárias e as descarta como stale. O resultado é idêntico.

## Verificação

Medido contra Kafka real em `harness/spec/messaging/compaction_spec.rb`:

| Medida | Resultado |
|---|---|
| 100 mensagens sob uma chave | **4 retidas** após compaction |
| Redução do log | **96%** |
| Queries ao Portal durante o bootstrap | **0** |

A última linha é a que sustenta a decisão. As outras duas são consequência.

## Alternativas consideradas

| Alternativa | Custo para o Portal | Por que não |
|---|---|---|
| **Tópico compactado** | Zero | Escolhida |
| Paginar a API do Portal | Varredura de 300 mil registros | Onboarding e recuperação passam a impactar a fonte |
| Snapshot periódico em S3 | Baixo, mas periódico | Materialização própria a construir e operar; o snapshot fica defasado entre execuções |
| Retenção infinita nos tópicos de ciclo de vida | Zero | O consumidor teria de reprocessar o histórico inteiro — em vez de uma mensagem por entregador, todas as que já existiram |

A terceira é a alternativa séria, e o que a derruba é reimplementar à mão exatamente o que a compaction já faz — com uma superfície de falha nova e um intervalo de defasagem.

## Consequências

**Positivas**

- Consumidor novo custa **zero** ao Portal. É a premissa de fan-out da arquitetura tornada operacional.
- Recuperação de indisponibilidade longa não precisa da fonte.
- Nenhum caminho de código específico para bootstrap.

**Negativas**

- Um tópico a mais para operar, com configuração de compaction que precisa estar certa — o bootstrap depende dela, e a dependência não é óbvia para quem opera.
- Retenção **indefinida**: o snapshot não expira. Isso é o que cria o problema de LGPD que [ADR-007](007-pii-e-lgpd.md) resolve por tombstone e destruição de chave.
- Duplica o volume de escrita do relay — cada evento é publicado duas vezes. Aceitável no volume deste domínio.

## Relacionadas

- [ADR-013](013-estado-completo-vs-delta.md) — pré-requisito
- [ADR-003](003-ordenacao-por-versao.md) — por que não há caminho especial
- [ADR-007](007-pii-e-lgpd.md) — apagamento num log que não expira
- [ADR-010](010-reconciliacao-por-checksum.md) — o passo seguinte quando há drift
