---
name: add-event
description: Procedimento completo para adicionar um evento novo ao ciclo de vida do entregador, na ordem obrigatória — schema, exemplo, código gerado, applier, propriedade, golden, ADR. Use ao introduzir qualquer evento novo no contrato.
---

# Adicionar um evento ao ciclo de vida

Este procedimento existe porque a ordem importa. Cada passo depende do anterior, e a tentação constante — "já sei o que o código precisa fazer, escrevo o schema depois" — é exatamente o que a regra fundamental do repositório proíbe.

Se você seguir na ordem, o CI passa. Se pular passos, ele falha em pontos que parecem desconexos do que você fez.

---

## Passo 0 — Decidir se é mesmo um evento novo

Antes de tudo, pergunte se o que você quer não cabe num evento existente.

Todos os eventos carregam **estado completo** ([ADR-013](../../../docs/adr/013-estado-completo-vs-delta.md)), então "um campo novo mudou" **não** justifica evento novo — justifica campo novo em `driver-state.schema.json`, e o `driver.updated` já o carrega.

Evento novo se justifica quando existe **intenção distinta** que o consumidor precisa distinguir. `driver.status_changed` existe separado de `driver.updated` não porque carrega dados diferentes (carrega os mesmos), mas porque tem criticidade diferente e viaja por outro canal.

Se a resposta for "não é evento novo", pare aqui. Adicione o campo ao estado e siga.

---

## Passo 1 — Classificar o canal

Fast-lane ou bulk-lane? A pergunta que decide não é sobre volume:

> Se este evento ficar **duas horas** atrás de um backlog, alguém é prejudicado de forma irreversível naquele dia?

| Resposta | Canal | Exemplo |
|---|---|---|
| Sim | `drivers.status.v1` | Bloqueio de segurança, ativação |
| Não | `drivers.profile.v1` | Troca de veículo, mudança de raio |

Ver [ADR-005](../../../docs/adr/005-fast-lane.md). Registre a classificação e a justificativa — ela entra na ADR do passo 7.

---

## Passo 2 — Escrever o schema

Em `contracts/schemas/driver.<nome>.schema.json`, seguindo o padrão dos existentes:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.magalu.com.br/logistica/driver-sync/v1/driver.<nome>.schema.json",
  "title": "driver.<nome>",
  "description": "O que este evento significa e por que trafega no canal escolhido.",
  "allOf": [
    { "$ref": ".../envelope.schema.json" },
    { "type": "object",
      "properties": {
        "type": { "const": "br.com.magalu.logistica.driver.<nome>.v1" },
        "data": { "$ref": "#/$defs/Data" } } }
  ],
  "$defs": {
    "Data": {
      "type": "object",
      "required": ["driver"],
      "additionalProperties": false,
      "properties": {
        "driver": { "$ref": ".../driver-state.schema.json" }
      }
    }
  }
}
```

**Regras que o CI verifica:**

- `additionalProperties: false` — sem isso, campo com erro de digitação passa silenciosamente.
- Campos novos nascem **opcionais**. Obrigatório quebra produtor antigo.
- PII nunca em claro. Token opaco ([ADR-007](../../../docs/adr/007-pii-e-lgpd.md)).
- A `description` explica **por quê**, não repete o nome do campo. É o que um agente lê ao trabalhar no contrato.

> `contracts/schemas/` é caminho protegido. O hook vai bloquear a escrita. Isso é intencional — use o subagent `spec-guardian` ou `ULTRASYNC_ALLOW_PROTECTED=1` de forma deliberada.

---

## Passo 3 — Escrever o exemplo

Em `contracts/examples/driver.<nome>.example.json`. Um payload realista, coerente com os demais exemplos (o mesmo entregador atravessa todos eles como uma história).

Valide:

```bash
cd harness && bundle exec rspec spec/contracts
```

O spec de conformidade também exige que **todo schema de evento tenha exemplo**. Ele falha se você criar um sem o outro.

---

## Passo 4 — Declarar no AsyncAPI

Em `contracts/asyncapi.yaml`, adicione a mensagem em `components.messages` e vincule-a ao canal escolhido no passo 1, com as operações `send` e `receive`.

---

## Passo 5 — Regenerar o código derivado

```bash
cd harness && bin/generate
```

Só é necessário se você tocou em `driver-state.schema.json`. Rode de qualquer forma — `bin/generate --check` no CI vai falhar se houver drift.

---

## Passo 6 — Ensinar o applier a reconhecer o tipo

Em `harness/lib/ultra_sync/event.rb`, adicione o tipo ao mapa `LIFECYCLE_TYPES`.

**Não adicione lógica condicional por tipo no caminho de escrita.** Todos os eventos carregam estado completo e são aplicados pela mesma regra; é isso que torna seguro separá-los em canais distintos. Se você sentiu vontade de escrever `if event.kind == :novo`, revise o desenho.

Tipo desconhecido vai para a DLQ com `unknown_event_type` — esse é o comportamento correto e já existe.

---

## Passo 7 — Propriedade, golden e ADR

**Propriedade** — o evento novo precisa entrar no gerador de `spec/properties/generators.rb`, senão as invariantes não o exercitam e você tem cobertura aparente.

**Golden** — se o evento influencia elegibilidade ou despacho, adicione casos em `spec/golden/dispatch_cases.json`, cada um com o campo `why`.

**ADR** — se a classificação de canal ou a modelagem envolveu trade-off, registre em `docs/adr/`. Use o subagent `adr-writer`.

---

## Passo 8 — Verificar

```bash
cd harness
bundle exec rspec --tag ~pg --tag ~kafka
bin/generate --check
bin/schema_compat
bin/test_inventory --check
bin/mutate
bin/check_docs
```

---

## Checklist

- [ ] Confirmado que é evento novo, não campo novo (passo 0)
- [ ] Canal classificado com justificativa registrada
- [ ] Schema com `additionalProperties: false` e campos opcionais
- [ ] Exemplo criado e validando
- [ ] AsyncAPI atualizado
- [ ] `bin/generate` rodado
- [ ] Tipo registrado em `LIFECYCLE_TYPES`, sem condicional no caminho de escrita
- [ ] Gerador de propriedades cobre o tipo novo
- [ ] Casos golden, se afeta despacho
- [ ] ADR, se houve trade-off
- [ ] Bateria completa verde
