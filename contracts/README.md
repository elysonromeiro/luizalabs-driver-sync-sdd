# Contratos

Esta pasta é a fonte da verdade **da interface e das regras de negócio**. O que isso significa exatamente, e onde para, está em [`behavior/README.md`](behavior/README.md) — vale ler, porque a afirmação genérica "a spec é a fonte da verdade" não sobrevive à pergunta *"me mostre o applier sendo derivado do schema"*.

O resumo:

| Camada | Onde vive a verdade | Enforcement |
|---|---|---|
| **Interface** — eventos e APIs | `schemas/`, `asyncapi.yaml`, `openapi.yaml` | `bin/generate --check`, validação de payload |
| **Regras de negócio** — elegibilidade, despacho, ciclo de vida | [`behavior/`](behavior/README.md) | Interpretadas em runtime; `bin/spec_drives` demonstra |
| **Mecânica** — transação, SQL, laço de consumo | Código, com decisão registrada em ADR | Testes de invariante |

A fronteira é deliberada: **vai para spec o que é decisão de negócio; fica em código o que é mecânica.** Especificar controle de transação em YAML produziria uma linguagem de programação mal escrita.

```bash
cd harness && bin/spec_drives   # a spec manda, em um comando
```

## Layout

```
asyncapi.yaml       Canais, operações e bindings Kafka (AsyncAPI 3.0)
openapi.yaml        Endpoints síncronos do Portal (OpenAPI 3.0.3)
schemas/            JSON Schema draft 2020-12 — o núcleo normativo
examples/           Payloads reais, validados contra os schemas
```

### Schemas

| Arquivo | Papel |
|---|---|
| `envelope.schema.json` | Envelope CloudEvents 1.0 comum a todos os eventos |
| `driver-state.schema.json` | Estado completo do entregador, compartilhado pelos três eventos |
| `driver.created.schema.json` | Cadastro criado |
| `driver.updated.schema.json` | Perfil alterado |
| `driver.status_changed.schema.json` | Transição de status |
| `dead-letter.schema.json` | Evento com defeito permanente |

## Decisões que atravessam todos os contratos

**Estado completo, nunca delta.** Todo evento carrega o objeto `DriverState` inteiro. Deltas exigiriam ordem de entrega para produzir estado correto — justamente a garantia que um pipeline distribuído não dá. Com estado completo, aplicar um evento é atribuição idempotente condicionada à versão. Ver ADR-013.

**`sequence` ordena, `time` audita.** A ordem lógica vem de um contador monotônico por entregador, atribuído pela fonte na mesma transação que muda o estado. Relógio de parede entre produtores distribuídos não é critério de ordenação confiável. Ver ADR-003.

**`(source, id)` deduplica.** O CloudEvents já define esse par como identificador único do evento; não há chave de idempotência separada, para não criar duas verdades sobre a mesma decisão.

**PII não trafega.** Campos sensíveis viram tokens opacos; o valor real sai por `GET /v1/drivers/{id}/sensitive`, sob escopo próprio e auditoria por chamada. `document_type` é exceção deliberada — é classificação, não dado pessoal, e é o que permite à Ultra-rápida recusar pessoa física sem tocar em PII. Ver ADR-007.

## Versionamento e compatibilidade

A versão maior fica no `type` do evento e no caminho do `$id` (`.../v1/...`). Dentro de uma versão maior, **só são aceitas mudanças retrocompatíveis (BACKWARD)**:

| Permitido | Proibido dentro da mesma versão maior |
|---|---|
| Adicionar campo opcional | Adicionar campo obrigatório |
| Adicionar valor a um enum de saída | Remover valor de enum |
| Relaxar restrição (`maximum` maior) | Estreitar tipo ou restrição |
| Adicionar canal ou operação | Remover ou renomear campo |

`bin/schema_compat` verifica isso no CI comparando com a branch base. Quebra de compatibilidade exige nova versão maior, com as duas convivendo até o sunset anunciado.

**Política de deprecação:** N e N+1 rodam em paralelo por no mínimo um ciclo completo de release dos consumidores. A retirada de uma versão é anunciada com antecedência e verificada por telemetria de consumo — nenhum contrato é removido enquanto houver quem o leia.

## Validação local

Os exemplos são validados contra os schemas pela suíte do harness:

```bash
cd harness && bundle exec rspec spec/contracts
```

A verificação corre nas duas direções: os exemplos válidos precisam passar, e o payload defeituoso embutido em `dead-letter.example.json` precisa ser **rejeitado** pelo schema de `driver.updated`. Um schema permissivo demais passaria só na primeira.
