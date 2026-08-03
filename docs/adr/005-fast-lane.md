# ADR-005 — Canais separados por criticidade, não por entidade

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

O modelo óbvio é um tópico por entidade: `drivers.v1` carregando os três eventos do ciclo de vida. É o que a maioria das arquiteturas orientadas a eventos faz por padrão, e é o que quase deu certo aqui.

O problema aparece na recuperação. O enunciado pede um plano para indisponibilidade total de 2 h durante a Black Friday, **evitando que um entregador recém-ativado fique impedido de trabalhar no dia**.

Com canal único, a matemática é desfavorável. Suponha 2 h de backlog acumulado, dominado por atualização de perfil — o evento de maior volume. Quando o consumo retoma, a fila drena em ordem. A ativação do entregador, emitida às 14h05, está atrás de todo o tráfego de perfil emitido antes dela. O entregador espera o drain inteiro para poder trabalhar, num dia em que cada hora parada é receita perdida para ele e capacidade perdida para a operação.

Aumentar paralelismo não resolve: a ordem por partição é justamente o que impede pular a fila.

## Decisão

Separar os canais por **criticidade operacional**, não por entidade:

| Canal | Conteúdo | Volume | Criticidade |
|---|---|---|---|
| `drivers.status.v1` | `driver.status_changed` | Baixo | Máxima — segundos importam |
| `drivers.profile.v1` | `driver.created`, `driver.updated` | Alto | Tolerante a atraso |

Cada um com consumer group próprio e independente.

## Consequência que dá o resultado

O fast-lane carrega uma fração do volume. Após as mesmas 2 h de indisponibilidade, ele drena em **segundos**, enquanto a bulk-lane leva o tempo que precisar. A ativação chega imediatamente; a atualização de raio de entrega chega quando chegar, e ninguém se importa.

Isso não é otimização de desempenho. É a diferença entre o entregador trabalhar ou não naquele dia, e resulta de uma escolha de topologia tomada no desenho — não de um ajuste feito durante o incidente.

## Por que isso é seguro

Separar canais significa que eventos do mesmo entregador viajam por partições diferentes, e portanto **podem ser aplicados fora de ordem entre si**. Numa arquitetura convencional isso seria um defeito de corretude.

Aqui é seguro por duas decisões anteriores, e a coerência entre elas é o ponto:

1. **Estado completo** ([ADR-013](013-estado-completo-vs-delta.md)) — todo evento carrega o entregador inteiro, então não há fragmento cuja perda ou reordenação corrompa algo.
2. **Espaço de versão único** ([ADR-003](003-ordenacao-por-versao.md)) — `sync_version` é global por entregador, atravessando os dois canais. Um `status_changed` de versão 7 aplicado antes de um `updated` de versão 6 faz o segundo ser corretamente descartado como stale.

Sem qualquer uma das duas, esta decisão seria um erro. Com as duas, sai de graça.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Canal único com prioridade por header | Kafka não tem fila de prioridade. Ordem é por partição, ponto. |
| Canal único com mais partições | Aumenta paralelismo entre entregadores, não a prioridade dentro de um. O backlog continua à frente. |
| Consumer group separado lendo o mesmo tópico e filtrando | O consumidor de status ainda precisa **ler e descartar** todo o volume de perfil para encontrar o que lhe interessa. Drena mais rápido que processar, mas ainda é proporcional ao backlog total. |
| Canal por segmento (`goods`, `food`) | Divide por dimensão que não corresponde a criticidade. Um bloqueio de segurança em `food` continuaria atrás de perfil de `food`. |

A terceira é a mais tentadora e a mais enganosa: parece resolver e apenas troca o custo de processar pelo de ler.

## Consequências

**Positivas**

- Recuperação prioriza o que é operacionalmente urgente, por construção.
- Os dois consumer groups escalam de forma independente — o de status é pequeno e barato, o de perfil dimensiona por throughput.
- Lag do fast-lane vira um sinal de alerta limpo: qualquer crescimento ali é anomalia real, não ruído de volume.

**Negativas**

- Dois tópicos e dois consumer groups para operar e monitorar em vez de um.
- Um consumidor que precise de ordem estrita entre status e perfil não a tem. Nenhum caso de uso atual precisa, e a ordenação por versão garante convergência do estado final — mas é uma limitação a declarar, não a esconder.
- A classificação de um evento novo em fast-lane ou bulk-lane vira decisão de design a cada evento adicionado. Codificada no procedimento da skill `add-event`.

## Relacionadas

- [ADR-003](003-ordenacao-por-versao.md) — espaço de versão único
- [ADR-013](013-estado-completo-vs-delta.md) — estado completo
- ADR-009 — o terceiro canal, para catch-up
