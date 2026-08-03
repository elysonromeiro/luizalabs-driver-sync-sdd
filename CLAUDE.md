# Contrato operacional com agentes de IA

Este arquivo é lido automaticamente por agentes que trabalham neste repositório. Ele não é um tutorial — é um **contrato**. O que está aqui descreve o que precisa ser preservado e **por quê**, porque instrução que explica intenção generaliza para casos não previstos, enquanto instrução que descreve procedimento envelhece na primeira situação diferente.

---

## Regra fundamental

**A especificação é a fonte da verdade. O código é derivado dela.**

Mudança de comportamento começa em `contracts/schemas/`, nunca em `harness/lib/`. Se você concluiu que precisa alterar código para mudar o que o sistema faz, pare: a alteração pertence ao contrato primeiro.

Isso não é preferência de estilo. É verificado: `bin/generate --check` falha o build se o código gerado divergir do contrato, e `bin/schema_compat` falha se o contrato quebrar consumidores.

---

## Invariantes inegociáveis

Estas quatro propriedades definem a corretude do sistema. Toda mudança precisa preservá-las, e cada uma tem um teste que a prova.

| Invariante | O que significa | Onde é provada |
|---|---|---|
| **Idempotência** | Reprocessar evento antigo ou duplicado não altera o estado | `spec/properties/idempotency_property_spec.rb` |
| **Comutatividade** | O estado final independe da ordem de entrega | `spec/properties/commutativity_property_spec.rb` |
| **Monotonicidade** | `source_version` nunca decresce | `spec/properties/monotonicity_property_spec.rb` |
| **Convergência** | Réplicas com o mesmo conjunto chegam ao mesmo estado | `spec/properties/convergence_property_spec.rb` |

Se uma mudança sua faz alguma delas falhar, **a mudança está errada** — não o teste.

### Detalhes que parecem irrelevantes e não são

- **A comparação de versão é `<`, não `<=`.** Com estado completo, aplicar versão igual produz projeção idêntica, então a diferença é invisível no estado final e só aparece no efeito colateral: cada escrita efetiva dispara reavaliação de elegibilidade, que pode emitir oferta duplicada.
- **O applier devolve `:applied` / `:duplicate` / `:stale`**, não booleano. É isso que torna a distinção acima observável por teste.
- **A deduplicação vem antes da comparação de versão.** As duas cobrem coisas diferentes, e inverter a ordem abre um buraco após rebalanceamento.
- **`BatchProcessor#collapse` ordena por `driver_id`.** Não é estética: sem ordem canônica, dois lotes com interseção deadlockam.
- **Indisponibilidade não gera dead letter.** Ela pausa o consumo. A DLQ é só para defeito permanente de payload.

---

## Caminhos protegidos

Editar qualquer um destes é **bloqueado por hook** antes da escrita acontecer:

```
contracts/schemas/**
harness/spec/properties/**
harness/spec/golden/**
harness/spec/guardrails/**
harness/bin/**
```

O bloqueio não é punição — é sinal de que a mudança pretendida provavelmente deveria ser feita em outro lugar. Se ela genuinamente pertence a um desses caminhos, ela precisa de revisão humana, e o CODEOWNERS garante isso.

Para trabalhar num caminho protegido de forma deliberada, exporte `ULTRASYNC_ALLOW_PROTECTED=1` na sessão e explique a razão no PR.

---

## Proibições

Estas ações são erro, mesmo quando fazem a suíte passar:

1. **Nunca marque um teste como `skip` ou `xit`** para destravar o build. Teste vermelho é informação, não obstáculo.
2. **Nunca delete um exemplo de teste.** O inventário congelado detecta isso e falha o CI.
3. **Nunca relaxe uma asserção** para acomodar comportamento novo. Se o comportamento novo está certo, o teste deve ser reescrito de propósito e explicado.
4. **Nunca regenere os casos golden** para casar com o que o código passou a fazer. Isso transforma regressão em expectativa.
5. **Nunca edite `harness/lib/ultra_sync/generated/`.** É gerado. Mude o contrato e rode `bin/generate`.
6. **Nunca chame `unsafe_write` fora de `spec/`.** Ele existe apenas para demonstrar o lost update.

---

## Antes de declarar pronto

Rode a bateria. Ela é rápida e evita descobrir problema no CI:

```bash
cd harness

bundle exec rspec --tag ~pg --tag ~kafka   # suíte rápida, ~2 s
bin/generate --check                       # código em dia com o contrato
bin/test_inventory --check                 # nenhuma invariante sumiu
bin/check_docs                             # links da documentação
```

Se tocou em caminho crítico, rode também:

```bash
bin/mutate            # toda mutação precisa morrer
bin/coupled_change    # mudança crítica exige mudança em spec/
```

Com Docker no ar, a suíte completa:

```bash
docker compose up -d && bundle exec rspec   # 168 exemplos
```

---

## Convenções

- **Documentação em português**, histórico do Git **em inglês** no padrão Conventional Commits.
- Mensagem de commit explica **por quê**, não o quê — o diff já mostra o quê.
- `main` é protegida. Todo trabalho entra por `feature/*` e Pull Request.
- Diagramas em Mermaid.

---

## Onde entender o desenho

Antes de mudar comportamento, leia a decisão que o originou. Elas estão em `docs/adr/`, cada uma com as alternativas descartadas e o motivo.

| Se você vai mexer em… | Leia |
|---|---|
| Ordenação, versionamento | [ADR-003](docs/adr/003-ordenacao-por-versao.md), [ADR-013](docs/adr/013-estado-completo-vs-delta.md) |
| Escrita, locking, concorrência | [ADR-004](docs/adr/004-locking.md) |
| Consumo, retentativa, DLQ | [ADR-008](docs/adr/008-backpressure.md) |
| Contratos, envelope | [ADR-006](docs/adr/006-cloudevents.md), [`contracts/README.md`](contracts/README.md) |
| Dados pessoais | [ADR-007](docs/adr/007-pii-e-lgpd.md) |
| Testes e guardrails | [docs/05-ai-harness.md](docs/05-ai-harness.md) |

---

## Uma observação sobre este arquivo

Ele é a camada **preventiva** dos guardrails, e a mais frágil das três: depende de você ler e cooperar. Por isso tudo que está aqui tem uma contraparte executável — hook, teste ou verificação de CI — que age independentemente de cooperação.

Se você discordar de alguma regra acima, o caminho é discutir no PR, não contorná-la. As que dá para contornar sem ninguém perceber já foram identificadas e fechadas.
