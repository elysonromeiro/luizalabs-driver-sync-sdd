# ADR-006 — CloudEvents 1.0 como envelope canônico

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

Todo evento precisa de metadados comuns: identificador, origem, tipo, instante, chave de particionamento, correlação de trace. A escolha é entre inventar essa estrutura ou adotar uma existente.

O requisito de agnosticismo pesa aqui. Se outras plataformas do ecossistema vão consumir este fluxo, cada uma precisará decodificar o envelope. Um formato proprietário significa que cada consumidor escreve — e mantém — o seu parser.

## Decisão

**CloudEvents 1.0**, em JSON Event Format, com três extensões padronizadas:

| Extensão | Uso |
|---|---|
| `sequence` + `sequencetype` | Contador monotônico por entregador ([ADR-003](003-ordenacao-por-versao.md)) |
| `partitionkey` | `driver_id`, para ordenação por partição |
| `traceparent` / `tracestate` | W3C Trace Context, propagando o trace da origem ao consumo |

Mais uma extensão proprietária, `dataclassification`, declarando a sensibilidade do payload.

**Deduplicação usa `(source, id)`**, que o CloudEvents já define como identificador único. Não foi criada extensão de idempotência: seria uma segunda fonte de verdade para a mesma decisão, e duas fontes de verdade divergem.

## Alternativas consideradas

| Opção | Ferramental pronto | Custo de payload | Evolução de schema |
|---|---|---|---|
| **CloudEvents + JSON Schema** | SDKs oficiais em várias linguagens | Médio (texto) | Por JSON Schema + Registry |
| Envelope proprietário | Nenhum — cada consumidor escreve o seu | Menor | Convenção interna |
| Avro + Schema Registry | Bom no ecossistema Kafka | **Menor** (binário) | Nativa e rigorosa |
| JSON sem envelope | Nenhum | Menor | Nenhuma |

Avro é tecnicamente superior em dois pontos reais: payload binário compacto e verificação de compatibilidade nativa no Registry. Ficou de fora por consumo, não por mérito — exige que todo consumidor do ecossistema adote o toolchain Avro e resolva schemas em tempo de execução. Para um contrato cuja premissa é *ser fácil de assinar*, JSON legível por qualquer stack vence, e a verificação de compatibilidade é recuperada por `bin/schema_compat` no CI.

Se o volume crescer a ponto de o tamanho do payload importar, o caminho é compressão `zstd` no nível do tópico, que resolve a maior parte da diferença sem mudar o contrato.

## Consequências

**Positivas**

- Consumidor novo decodifica com SDK pronto, não com parser escrito à mão.
- `traceparent` dá rastreabilidade ponta a ponta sem convenção interna.
- Atributos obrigatórios do padrão evitam o envelope que nasce mínimo e cresce por acréscimo ad hoc.

**Negativas**

- Payload maior que binário.
- Nomes de atributo do CloudEvents são restritos a letras minúsculas e dígitos, sem separadores — daí `partitionkey` e `dataclassification` em vez das formas com sublinhado, o que destoa do estilo do restante do payload. Preço de aderir ao padrão em vez de aproximá-lo.

## Relacionadas

- [ADR-003](003-ordenacao-por-versao.md) — semântica de `sequence`
- `contracts/README.md` — política de compatibilidade
