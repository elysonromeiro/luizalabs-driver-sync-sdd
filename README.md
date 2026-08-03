# Motor de Sincronização de Entregadores

**System Design Document** — Desafio Técnico LuizaLabs / Magalu, Logística Ultra Rápida.

Este documento descreve a arquitetura de um motor de sincronização que propaga o ciclo de vida de entregadores do **Portal dos Entregadores** para a **Ultra-rápida** e, por construção, para qualquer outra plataforma do ecossistema Magalu que venha a consumir o mesmo fluxo.

---

## 1. Contexto

A operação de entrega Ultra Rápida executa e acompanha entregas de última milha (*last mile*) em todo o Brasil. Dois sistemas sustentam essa operação:

| Sistema | Papel |
|---|---|
| **Portal dos Entregadores** | *System of Record*. Detém a verdade sobre o entregador: cadastro, manutenção de dados, gestão documental e o processo de aprovação que determina quem está apto a operar. |
| **Ultra-rápida** | Engine logística que conecta entregadores e clientes dos segmentos *goods* e *food*. Consome os dados do Portal para decidir quem pode receber ofertas de corrida. |

O Portal detém o dado atualizado. A Ultra-rápida precisa dele quase em tempo real — sem o dado corrente, o entregador não recebe oferta, e um entregador bloqueado por segurança continuaria recebendo.

---

## 2. O problema

Sincronizar o ciclo de vida do entregador entre os dois sistemas, respeitando três tensões que puxam em direções opostas:

1. **Latência versus consistência.** O dado precisa chegar rápido, mas nunca corrompido por reprocessamento ou reordenação.
2. **Acoplamento versus autonomia.** A Ultra-rápida tem critérios de elegibilidade *mais restritivos* que o Portal — por exemplo, o Portal aceita entregador pessoa física e a Ultra-rápida não. Essa divergência é legítima e não pode vazar para a fonte.
3. **Especificidade versus generalidade.** A solução atende a Ultra-rápida hoje, mas precisa nascer agnóstica: outras plataformas do ecossistema devem consumir o mesmo fluxo sem reescrita da arquitetura core.

### Requisitos e restrições

| Dimensão | Restrição |
|---|---|
| **Volumetria** | ~300.000 entregadores ativos |
| **SLA de sincronização** | Dado emitido pelo Portal reflete na Ultra-rápida em no máximo **30 s (P99)** |
| **Stack do core** | Ecossistema principal em **Ruby on Rails** |
| **Ciclo de vida** | Criação; ativação/inativação em tempo real (ex.: bloqueio de segurança); atualização de perfil (troca de veículo, mudança de raio de entrega) |
| **Idempotência** | Reprocessar evento antigo ou duplicado não pode corromper o estado do entregador |
| **Concorrência** | Atualizações simultâneas do mesmo entregador, emitidas **fora de ordem**, precisam convergir |
| **Elegibilidade** | Validadores próprios do consumidor, mais restritivos que os da fonte |
| **Segurança** | A arquitetura precisa se manter íntegra sob tentativa de ataque |

---

## 3. Estrutura deste documento

> Em construção. As seções são publicadas por fase, cada uma via Pull Request.

| Pilar | Documento | Estado |
|---|---|---|
| 1 — Arquitetura e fluxo de dados | [`docs/01-arquitetura.md`](docs/01-arquitetura.md) | **pronto** |
| 1 — Concorrência e idempotência | [`docs/02-concorrencia.md`](docs/02-concorrencia.md) | **pronto** |
| 1 — Resiliência e tolerância a falhas | [`docs/03-resiliencia.md`](docs/03-resiliencia.md) | **pronto** |
| 1 — Segurança e dados sensíveis | [`docs/04-seguranca.md`](docs/04-seguranca.md) | **pronto** |
| 2 — Contratos de eventos | [`contracts/`](contracts/README.md) | **pronto** |
| 3 — AI harness e guardrails | `docs/05-ai-harness.md` | pendente |
| 3 — Repositório AI-native | `docs/07-repo-ai-native.md` | pendente |
| Especialista | `docs/06-especialista.md` | pendente |

### Decisões arquiteturais

Cada decisão fica registrada como ADR, com as alternativas que foram descartadas e o motivo.

| ADR | Decisão |
|---|---|
| [001](docs/adr/001-broker.md) | Kafka como backbone — replay e compaction decidem, não throughput |
| [002](docs/adr/002-outbox-vs-cdc.md) | Transactional Outbox com relay, CDC como evolução |
| [003](docs/adr/003-ordenacao-por-versao.md) | Ordenação por versão monotônica, não por relógio |
| [004](docs/adr/004-locking.md) | Escrita condicional como padrão, lock pessimista por exceção |
| [005](docs/adr/005-fast-lane.md) | Canais separados por criticidade, não por entidade |
| [006](docs/adr/006-cloudevents.md) | CloudEvents 1.0 como envelope canônico |
| [007](docs/adr/007-pii-e-lgpd.md) | PII fora do evento e apagamento por destruição de chave |
| [008](docs/adr/008-backpressure.md) | Pausar o consumo sob degradação, em vez de falhar rápido |
| [013](docs/adr/013-estado-completo-vs-delta.md) | Eventos carregam estado completo, não delta |

As ADRs 009 a 012 chegam nas fases seguintes.

---

## 4. Convenções do repositório

- **Documentação em português**; histórico do Git em inglês, no padrão [Conventional Commits](https://www.conventionalcommits.org/).
- `main` é a branch principal. Cada fase de trabalho entra por uma branch `feature/*` e um Pull Request.
- Diagramas em [Mermaid](https://mermaid.js.org/), renderizados nativamente pelo GitHub.

O enunciado original do desafio não é redistribuído aqui; o contexto e os requisitos acima o reproduzem no que é necessário para acompanhar o documento.

---

## Autor

Elyson Romeiro — candidatura ao nível **Especialista / Staff Engineer**.
