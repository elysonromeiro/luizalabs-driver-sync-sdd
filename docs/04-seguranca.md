# Segurança

> **Pilar 1.** O enunciado pergunta "como a arquitetura se mantém segura a possíveis ataques". Esta seção responde pelo caminho: o que um atacante ganharia em cada ponto, e o que impede.

## Modelo de ameaça

O ativo mais valioso deste sistema não é o dado pessoal — é a **capacidade de decidir quem pode operar**. Quem consegue injetar um evento forjado consegue ativar um entregador que o Portal reprovou, ou desbloquear alguém bloqueado por fraude. Isso vale mais para um atacante do que qualquer CPF.

Toda a superfície abaixo é avaliada por essa lente.

| Fronteira | O que um atacante ganharia |
|---|---|
| Escrita no tópico de status | Ativar entregador reprovado, desbloquear conta banida |
| Leitura dos tópicos | Base de tokens e padrões operacionais |
| Endpoint `/sensitive` | Base de CPF/CNPJ de 300 mil pessoas |
| Banco da projeção | Estado operacional, sem PII |
| Outbox do Portal | Emitir fato que nunca aconteceu |

## Transporte e identidade

**mTLS em toda comunicação de serviço.** O certificado do cliente carrega a identidade, e não há chamada anônima em rede interna. A premissa é que rede interna não é fronteira de confiança — comprometimento de um pod vizinho não deve dar acesso ao broker.

**ACL por tópico no Kafka**, com privilégio mínimo derivado do certificado:

| Principal | `drivers.status.v1` | `drivers.profile.v1` | `drivers.snapshot.v1` | `drivers.dlq.v1` |
|---|---|---|---|---|
| `portal-outbox-relay` | **write** | **write** | **write** | — |
| `ultra-rapida-consumer` | read | read | read | write |
| `plataforma-n-consumer` | read | read | read | write |

O relay é o **único** principal com permissão de escrita nos canais de ciclo de vida. Um consumidor comprometido pode ler e poluir a própria DLQ; não pode forjar um evento de ativação. Essa assimetria é o controle mais importante da tabela, e decorre de uma escolha simples: papéis de leitura e escrita nunca coincidem no mesmo certificado.

## Evento forjado

ACL cobre o atacante externo. Não cobre o comprometimento do próprio relay.

**Assinatura no envelope.** O relay assina o evento (JWS sobre os atributos canônicos mais o digest do payload) com uma chave que só ele possui, guardada em KMS e nunca em disco. O consumidor verifica antes de aplicar. Assinatura inválida ou ausente é dead letter com o código `invalid_signature`, e alerta imediato — não é cenário tolerável.

> Este código foi acrescentado ao contrato em revisão. Ele era prometido aqui e **não existia** no enum de `dead-letter.schema.json` — promessa de segurança não cumprida é pior que ausente, porque quem lê o contrato acredita que a proteção existe. A verificação de assinatura em si permanece desenho, não implementação: o harness não tem KMS.

Isso não impede um relay comprometido de assinar mentiras. Impede que *outra coisa* que tenha ganhado acesso de escrita ao tópico produza um evento aceito, o que é o cenário muito mais provável.

**Defesa em profundidade no consumidor.** Mesmo assinado, um evento não é obedecido cegamente. A `EligibilityPolicy` reavalia critérios com base no estado projetado: um evento que declare `status: active` com `document_type: cpf` e `background_check: rejected` resulta em entregador **não elegível**, porque a política é avaliada localmente e não delegada ao emissor. A projeção guarda o que o Portal disse; a decisão de deixar operar é da Ultra-rápida.

Essa separação existia por razão de acoplamento ([01-arquitetura.md](01-arquitetura.md)) e se revela também um controle de segurança: comprometer a fonte não é suficiente para comprometer a decisão.

## Replay

Reenviar um evento antigo capturado do tópico — por exemplo, um `status_changed: active` anterior a um bloqueio — é o ataque mais barato contra um sistema orientado a eventos.

Duas defesas já presentes por outras razões o neutralizam:

1. **Deduplicação por `(source, id)`** — o evento reenviado tem o mesmo identificador e é reconhecido como duplicata.
2. **Ordenação por versão** — mesmo com identificador novo, o `sequence` antigo é menor que o projetado, e a escrita condicional o descarta como stale.

Um atacante precisaria forjar `id` novo **e** `sequence` maior que o corrente **e** assinatura válida. Os dois primeiros são triviais; o terceiro exige a chave do relay.

**Detecção:** um pico na taxa de eventos stale é sinal de replay em curso, e está na tabela de alertas de [03-resiliencia.md](03-resiliencia.md). A métrica existe para operação e serve para segurança sem custo adicional.

## Dados pessoais

Detalhado em [ADR-007](adr/007-pii-e-lgpd.md). O resumo relevante para segurança:

- **Nenhum dado pessoal trafega nos eventos.** Vazamento de tópico expõe tokens opacos.
- Valores reais ficam num cofre, cifrados com **chave por titular**.
- Acesso passa por um endpoint com escopo dedicado (`drivers.pii`), finalidade declarada e **auditoria por chamada**.
- Apagamento é destruição de chave, o que torna o ciphertext residual irreversível.

O parâmetro `fields` do endpoint é obrigatório e restrito: pedir mais campos do que o necessário é possível, mas fica registrado com identidade e finalidade. Isso transforma exfiltração gradual em algo detectável por análise de padrão de acesso, em vez de indistinguível do uso legítimo.

## Superfície da API de reconciliação

`GET /v1/drivers` devolve estado em lote e é o endpoint mais atraente para exfiltração em massa.

| Controle | Efeito |
|---|---|
| Escopo `drivers.read` separado de `drivers.pii` | O feed nunca devolve PII, só tokens |
| Rate limit adaptativo | Reduz o teto sob carga; exfiltração rápida esbarra nele |
| Keyset pagination sem `OFFSET` | Impede salto arbitrário; a varredura é sequencial e observável |
| Servido de réplica | Abuso não degrada o caminho de escrita do Portal |

A paginação por keyset foi escolhida por desempenho ([openapi.yaml](../contracts/openapi.yaml)) e tem efeito colateral defensivo: forçar travessia sequencial torna a varredura completa lenta e evidente na telemetria.

## Segredos e cadeia de suprimentos

- Credenciais e chaves em KMS, injetadas em runtime. Nada de segredo em imagem, variável de ambiente commitada ou arquivo de configuração.
- `Gemfile.lock` versionado e verificação de vulnerabilidade (`bundler-audit`) no CI, no job `fast`.
- Imagens fixadas por digest, não por tag móvel — inclusive no `docker-compose.yml` e nos service containers do CI.
- Dependência nova em path crítico exige revisão humana via CODEOWNERS — o mesmo mecanismo que protege as invariantes contra código gerado por IA ([05-ai-harness.md](05-ai-harness.md)).

Esse último ponto merece registro: num repositório onde agentes de IA geram código, **a cadeia de suprimentos inclui o agente**. Uma dependência introduzida por sugestão automática tem o mesmo peso de uma escolhida por uma pessoa, e passa pela mesma porta.

## Auditoria

| Evento | Onde fica | Retenção |
|---|---|---|
| Mudança de estado do entregador | Log do Kafka + outbox | 7 dias no log; trilha permanente no Portal |
| Acesso a PII | Log de auditoria do endpoint | Conforme política de retenção legal |
| Apagamento de titular | Trilha de aprovação em dois passos | Permanente |
| Aplicação de evento na projeção | `processed_events` | 30 dias |

`processed_events` não existe para auditoria — existe para deduplicação —, mas responde de graça a "este evento chegou aqui e quando", que é a primeira pergunta de qualquer investigação de divergência.

## O que este desenho não cobre

Declarado explicitamente, porque desenho de segurança que não lista lacunas não foi levado a sério:

- **Insider com acesso legítimo ao Portal** pode aprovar um entregador que não deveria. Nenhum controle desta arquitetura impede — é problema de segregação de funções e trilha de aprovação no Portal, fora do escopo do motor de sincronização.
- **Comprometimento do KMS** derruba a tokenização e o crypto-shredding simultaneamente. É a dependência de confiança única do desenho.
- **Negação de serviço no broker** não é endereçada aqui; depende da postura de infraestrutura do cluster gerenciado.

## Relacionadas

- [ADR-007](adr/007-pii-e-lgpd.md) — dados pessoais e eliminação
- [ADR-008](adr/008-backpressure.md) — por que a DLQ é alertável
- [03-resiliencia.md](03-resiliencia.md) — métricas que servem à detecção
