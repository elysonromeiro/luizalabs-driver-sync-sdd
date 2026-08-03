# ADR-013 — Eventos carregam estado completo, não delta

- **Status:** Aceito
- **Data:** 2026-08-03

> Numeração fora de ordem: esta decisão foi tomada durante a modelagem dos contratos, depois que ADRs 001–012 já haviam sido planejadas. Ela é, na prática, a base sobre a qual [ADR-003](003-ordenacao-por-versao.md) e [ADR-005](005-fast-lane.md) se sustentam.

## Contexto

Um evento de mudança pode carregar duas coisas:

- **Delta** — só o que mudou. `{"vehicle": {"type": "car"}}`
- **Estado completo** — o entregador inteiro após a mudança (*state-carried event transfer*)

A escolha parece de eficiência e é, na verdade, de corretude.

## Decisão

Todo evento do ciclo de vida carrega o objeto `DriverState` **completo**.

`driver.updated` inclui um campo `changed_fields`, mas ele é metadado de observabilidade e roteamento — permite ao consumidor decidir se a mudança lhe interessa antes de reavaliar elegibilidade. **A projeção nunca depende dele**: ignorá-lo por completo não produz estado incorreto.

## Justificativa

**Delta exige ordem; estado completo, não.**

Com delta, chegar ao estado correto exige aplicar todos os eventos, exatamente uma vez, na ordem de emissão. As três condições são difíceis num pipeline distribuído, e a terceira é impossível de garantir de ponta a ponta. Perder um delta corrompe o estado de forma silenciosa e permanente — nada no sistema volta a mencionar o campo perdido.

Com estado completo, aplicar um evento é atribuição idempotente condicionada à versão. Daí decorre, sem maquinário adicional:

| Situação | Delta | Estado completo |
|---|---|---|
| Evento duplicado | Pode aplicar duas vezes o mesmo incremento | Atribuição idempotente |
| Evento fora de ordem | Corrompe | Descartado pela versão |
| Evento perdido | Corrompe permanentemente | Próximo evento corrige sozinho |
| Consumidor novo | Precisa de todo o histórico | Basta o último evento |

A terceira linha é a que mais importa na prática: com estado completo, **o sistema se autocorrige**. Uma falha que perca um evento é reparada pelo evento seguinte daquele entregador, sem intervenção.

**Habilita a compaction.** O tópico `drivers.snapshot.v1` ([ADR-009](009-snapshot-compactado.md)) só funciona porque a última mensagem por chave já é o estado inteiro. Com delta, a mensagem retida seria um fragmento sem sentido isolado, e o bootstrap de consumidor novo teria de voltar ao banco do Portal — perdendo o desacoplamento que justifica toda a arquitetura.

**Habilita a separação de canais.** Eventos de status e de perfil vivem em tópicos distintos ([ADR-005](005-fast-lane.md)) e portanto podem ser aplicados fora de ordem entre si. Isso só é seguro porque ambos carregam estado completo e compartilham o mesmo espaço de versão: vence o de maior `sequence`. Com delta, dividir canais seria um defeito de corretude.

## Custo

Cerca de **600 bytes por evento**, contra ~120 de um delta típico.

Em 300 mil entregadores com uma média de poucas mudanças mensais por entregador, a diferença é irrelevante em armazenamento e em banda. Se algum dia deixar de ser, o caminho é compressão no nível do tópico (`zstd`), não voltar a delta.

## Consequências

**Positivas**

- Idempotência, tolerância a reordenação e autocorreção vêm da forma do payload, não de código defensivo espalhado pelo consumidor.
- Consumidor novo faz bootstrap com uma leitura por entregador.
- Cada mensagem é autossuficiente para depuração: ler uma linha do log conta a história inteira daquele momento.

**Negativas**

- Payload maior.
- Toda mudança de campo aparece em todos os eventos, ampliando a superfície do contrato — o que torna a disciplina de compatibilidade em `contracts/README.md` mais importante, não menos.
- Exige atenção com PII: como o estado inteiro trafega sempre, campos sensíveis precisam ser tokenizados na origem. Endereçado por [ADR-007](007-pii-e-lgpd.md).

## Relacionadas

- [ADR-003](003-ordenacao-por-versao.md) — ordenação por versão
- [ADR-005](005-fast-lane.md) — separação de canais
- [ADR-009](009-snapshot-compactado.md) — snapshot compactado
