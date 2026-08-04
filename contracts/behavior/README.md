# Especificação de comportamento

Estes arquivos não descrevem o sistema. Eles **são** o sistema, na parte que cobrem.

```bash
cd harness && bin/spec_drives
```

Cinco demonstrações que alteram **apenas** um arquivo daqui e mostram o comportamento mudando — com verificação por hash de que nenhum arquivo de `lib/` foi tocado.

---

## A pergunta que isto responde

> *"Você tem uns YAML. E daí? Todo mundo tem arquivo de configuração."*

A diferença não é o formato. É **quem manda quando os dois discordam**:

| | Configuração | Spec-driven |
|---|---|---|
| Se divergirem | O código está certo; ajusta-se o arquivo | A spec está certa; **o código tem o bug** |
| Enforcement | Nenhum | O build quebra |

O teste que decide:

1. **Mude a spec sem tocar em código.** O comportamento mudou? → `bin/spec_drives`
2. **Mude o código sem tocar na spec.** O build quebrou? → `bin/generate --check` e `bin/mutate`

---

## Os três níveis, e onde cada parte do sistema está

Nem tudo deve ser spec, e saber onde parar importa mais que a quantidade de YAML. Especificar controle de transação e SQL em YAML produziria uma linguagem de programação mal escrita.

### Nível 1 — Interpretado

A spec **é** o comportamento. Não há geração; o código lê e avalia. Divergência é impossível por construção.

| Spec | Interpretado por | O que decide |
|---|---|---|
| [`eligibility.yaml`](eligibility.yaml) | `EligibilityPolicy` | Os 7 critérios da Ultra-rápida |
| [`dispatch.yaml`](dispatch.yaml) | `DispatchRules` | Encaixe entre oferta e entregador |
| [`lifecycle.yaml`](lifecycle.yaml) | `Outbox` | Transições válidas e roteamento de canal |

Nenhuma dessas classes contém uma regra. Elas sabem **como avaliar**, não **quais são**.

### Nível 2 — Gerado, com portão de drift

A spec é a fonte; o código é derivado e versionado. `bin/generate --check` falha o build se divergirem.

| Spec | Gera | Portão |
|---|---|---|
| [`../schemas/driver-state.schema.json`](../schemas/driver-state.schema.json) | Enums e limites do domínio | `bin/generate --check` |

### Nível 3 — Declarado e verificado

O comportamento fica em código porque é **mecânica**, não decisão de negócio. A spec declara a decisão, e um guardrail verifica que o código a obedece.

| Spec | Declara | Verificado por |
|---|---|---|
| [`applier.yaml`](applier.yaml) | Ordem das verificações e operador de comparação | `spec/guardrails` |

O caso do `applier.yaml` é o mais instrutivo. A **ordem** — deduplicação antes da comparação de versão — é decisão de desenho: inverter não quebra nenhum teste de estado final, e por isso precisa estar escrita. Já o `UPDATE ... WHERE` é mecânica de banco, e transformá-lo em YAML pioraria o sistema.

### O que fica fora, e por quê

| Componente | Por que não é spec |
|---|---|
| Escrita condicional, controle de transação | Mecânica de banco de dados |
| Laço de consumo, pause/resume | Mecânica de cliente Kafka |
| Reconciliação por checksum | Algoritmo, não regra de negócio |

A fronteira: **vai para spec o que é decisão de negócio — quais critérios, em que ordem, por qual canal. Fica em código o que é mecânica.**

---

## Como adicionar um critério

O procedimento inteiro, sem tocar em Ruby:

1. Acrescente a regra em `eligibility.yaml` com `id`, `field`, `when` e `why`
2. Acrescente um caso em `harness/spec/golden/dispatch_cases.json` com o `why`
3. `cd harness && bundle exec rspec spec/golden`

O campo `why` é obrigatório nos dois. Regra sem justificativa é indistinguível de acidente seis meses depois.

## Predicados disponíveis

A lista é **fechada** de propósito. Predicado novo é decisão de desenho, não conveniência de quem escreve a regra — predicado arbitrário em spec vira código disfarçado de configuração.

| Predicado | Significado |
|---|---|
| `equals` / `not_equals` | Compara o valor do campo |
| `in` / `not_in` | Pertinência em lista |
| `empty` | Array ou string vazios, ou ausente |
| `absent` | Campo ausente ou nulo |
| `lt` / `lte` / `gt` / `gte` | Comparação numérica |
| `date_before` | Data anterior à referência (`today` é aceito) |
| `not_included_in_driver_field` | Campo da oferta não está na lista do entregador |
| `greater_than_driver_field` | Campo da oferta excede o do entregador |

## Relacionadas

- [`../README.md`](../README.md) — contratos de interface
- [`../../docs/05-ai-harness.md`](../../docs/05-ai-harness.md) — guardrails
