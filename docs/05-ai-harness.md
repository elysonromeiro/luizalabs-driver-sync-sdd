# AI Harness e guardrails de qualidade

> **Pilar 3.** O time usa agentes de IA para gerar e refatorar código. Como proteger produção disso — e por que a maior parte das respostas cobre só um terço do problema.

## O problema, dito com precisão

A pergunta natural é "como testar código gerado por IA". Ela leva a uma resposta incompleta, porque assume que o risco é o mesmo de código escrito por gente, só que em maior volume.

Não é. Um agente de IA tem três características que mudam o desenho da proteção:

1. **Ele otimiza para a suíte passar**, não para o sistema estar correto. Quando um teste fica vermelho, "consertar o teste" e "consertar o código" são igualmente acessíveis, e o primeiro costuma ser mais barato.
2. **Ele não sabe o que não pode quebrar** a menos que isso esteja escrito em algum lugar que ele leia.
3. **Ele produz volume.** Uma revisão humana que funcionava para dez linhas por hora não funciona para quinhentas.

Disso decorre a tese deste documento:

> **Guardrail confiável é o que não depende da cooperação do agente.**

Uma instrução em prompt é uma sugestão. Um hook que bloqueia a escrita, um teste que falha, uma regra de CODEOWNERS — esses são executados por outra coisa, e o agente não pode escolher ignorá-los.

## Três camadas de defesa

| Camada | Quando age | Mecanismo | Quem executa |
|---|---|---|---|
| **Preventiva** | Antes do código existir | `CLAUDE.md`, subagents com privilégio mínimo, hooks | O harness do agente |
| **Detectiva** | No CI, pós-commit | L1–L6 abaixo | O pipeline |
| **Corretiva** | Pós-merge | CODEOWNERS, rollback, replay | Processo humano |

A maioria das submissões cobre só a do meio. A preventiva é a mais barata — um hook que bloqueia edição de `spec/properties/` custa dez linhas de JSON e age antes de qualquer token ser escrito, enquanto o mesmo guardrail no CI só descobre o problema minutos depois, com contexto já perdido.

A camada preventiva está detalhada em [07-repo-ai-native.md](07-repo-ai-native.md). Este documento cobre a detectiva.

---

## L1 — Invariantes como propriedades

Um teste de exemplo passa com implementações erradas. "Aplicar duas vezes o mesmo evento não muda nada" é satisfeito por um applier que ignora tudo.

Propriedades quantificam sobre qualquer sequência gerada:

```
apply(S) == apply(S ++ duplicatas(S))     idempotência
apply(S) == apply(shuffle(S))             comutatividade
source_version nunca decresce             monotonicidade
N réplicas convergem                      convergência
```

**91 invariantes**, em `harness/spec/properties/` e `harness/spec/concurrency/`.

O gerador e o encolhedor são próprios, sem gem externa. A razão é encolhimento, não dependências: bibliotecas genéricas minimizam bem valores escalares e mal sequências de eventos de domínio — o contraexemplo que produzem costuma violar invariantes da fonte e não diagnostica nada.

## L2 — Concorrência determinística

Teste de concorrência com `sleep` passa por sorte e falha por azar. Quando falha, vira "flaky", e a primeira pessoa apressada o desliga.

Três níveis:

1. **Enumeração** — todos os **20 entrelaçamentos** entre dois consumidores. **9 perdem** a atualização com read-modify-write ingênuo; **0** com escrita condicional.
2. **Colisão real** — threads sincronizadas por `CyclicBarrier`, sem `sleep`.
3. **Postgres real** — lost update sob `READ COMMITTED`, `SERIALIZABLE` abortando com `40001`, deadlock provocado e prevenido.

## L3 — Golden tests

As regras de despacho congeladas caso a caso, com o campo `why` obrigatório em cada um — um caso golden sem justificativa é indistinguível de um bug que virou expectativa.

O buraco conhecido da técnica é o agente regenerar os esperados para casar com o comportamento novo. Fechado por CODEOWNERS sobre `spec/golden/`.

## L4 — Mutation testing

Cobertura mede quais linhas rodaram, não se alguém olhou o resultado. `expect(true).to be true` atinge 100% de cobertura e protege zero.

`bin/mutate` estraga o código de propósito e exige que a suíte perceba:

```
$ bin/mutate
[ 1/12] memory.rb            morta
...
[17/17] circuit_breaker.rb   morta

Todas as 19 mutações foram mortas pela suíte.
```

**Este guardrail já se pagou duas vezes**, e as duas histórias valem mais que o número:

**Primeira.** Na Fase 3, trocar `<` por `<=` na escrita condicional **sobreviveu a todas as quatro propriedades**. O gerador emitia versões estritamente crescentes por entregador, então dois eventos nunca colidiam de versão e os operadores eram indistinguíveis. A suíte parecia completa e tinha um vazio exatamente na comparação central do desenho. A propriedade que faltava foi escrita por causa disso.

**Segunda.** Na primeira execução completa, **3 de 19 mutações sobreviveram**. `Consumer` e `CircuitBreaker` não tinham nenhum teste rápido — a proteção existia só em `spec/messaging`, que é `:kafka` e não roda em cada PR. Um guardrail que só age com Docker no ar protege menos do que aparenta.

Corrigir isso expôs um terceiro problema: duplicata **dentro do mesmo lote** não era contabilizada, porque nem o `ON CONFLICT DO NOTHING` do Postgres nem o adapter em memória distinguem repetição da mesma chave na mesma instrução. O processamento em lote não era equivalente ao individual — que é justamente a propriedade de convergência que o harness afirma.

E o último sobrevivente foi melhor que um teste faltando: apontou **código morto**. Depois que a retentativa migrou para dentro do `handle`, um `break` anterior tornou o guard de commit inalcançável.

Feito à mão em vez da gem `mutant` por escopo: aqui interessam poucas mutações muito bem escolhidas nos arquivos que concentram corretude, com uma etiqueta dizendo qual invariante deveria morrer com cada uma.

## L5 — Meta-guardrails

Onde mora a originalidade. Todos os anteriores assumem que os testes continuam existindo.

### Inventário de invariantes

A lista de exemplos `:invariant` é congelada num lock. **Remover, renomear ou marcar `xit` falha o CI.** Acrescentar é sempre permitido — proteção que atrapalha crescer vira proteção desligada.

```
$ bin/test_inventory --check
test_inventory: 1 problema(s)

  DESABILITADA (skip/xit): Invariante: monotonicidade de versão
  source_version nunca decresce, em nenhum passo, para nenhum entregador
```

Este é o vetor mais simples e o menos coberto: **o agente apaga o teste que incomoda**. A suíte fica verde, a cobertura cai um pouco, ninguém nota.

### Compatibilidade de contrato

`bin/schema_compat` transforma a tabela de compatibilidade de `contracts/README.md` em portão de build. A assimetria é o ponto: um produtor que adiciona campo obrigatório não quebra a si mesmo, quebra quem consome — quem paga o erro não é quem o comete.

```
$ bin/schema_compat
schema_compat: 3 quebra(s) de compatibilidade contra origin/main

  campo OBRIGATÓRIO adicionado: /nickname
  valor de ENUM removido em /DriverStatus: ["offboarded"]
  MÁXIMO reduzido em /delivery_radius_km: 200 → 50
```

### Mudança desacoplada

`bin/coupled_change` falha quando um arquivo crítico muda sem nenhuma mudança em `spec/`. Grosseiro de propósito: não tenta julgar se a mudança é perigosa, só força que alguém tenha pensado no teste. Falso positivo custa uma linha de spec; falso negativo custa produção.

### Drift entre spec e código

`bin/generate --check` falha se o código gerado divergir do contrato — o portão que sustenta o spec-driven development do [Pilar 2](../contracts/README.md).

## L6 — Contorno dos próprios guardrails

Meta-testes em `spec/guardrails/` verificam que as proteções ainda existem: os binários presentes e executáveis, o lock acima de um piso mínimo (um lock vazio faria `--check` passar trivialmente), nenhuma invariante congelada em estado pendente, e todo módulo crítico coberto por ao menos uma invariante.

---

## O pipeline

Seis jobs, em duas velocidades:

| Job | O que roda | Tempo alvo |
|---|---|---|
| **fast** | Sintaxe + suíte sem dependências | ~1 min |
| **contracts** | `generate --check`, `schema_compat`, conformidade | ~2 min |
| **postgres** | Specs `:pg` com service container | ~3 min |
| **kafka** | Specs `:kafka` com broker no compose | ~4 min |
| **mutation** | `bin/mutate` | ~5 min |
| **guardrails** | Inventário, mudança desacoplada, meta-testes, links | ~2 min |

A separação por velocidade é deliberada. Um CI que leva quinze minutos para dizer qualquer coisa é um CI que as pessoas aprendem a ignorar enquanto continuam trabalhando — e guardrail que chega tarde demais protege menos do que parece.

## Como cada vetor é coberto

| O que um agente pode fazer | O que barra |
|---|---|
| Quebrar idempotência ou ordenação | L1 — propriedades |
| Introduzir race condition | L2 — enumeração + Postgres |
| Alterar regra de despacho | L3 — golden + CODEOWNERS |
| Escrever teste que não testa | L4 — mutação |
| Apagar ou desabilitar um teste | L5 — inventário |
| Quebrar consumidor com mudança de schema | L5 — compat |
| Mudar comportamento sem tocar em teste | L5 — mudança desacoplada |
| Editar código gerado em vez do contrato | L5 — drift |
| Desativar os próprios guardrails | L6 — meta-testes + CODEOWNERS |
| Regenerar goldens para casar com o novo | CODEOWNERS — revisão humana |

## O buraco que a revisão encontrou nos próprios guardrails

Uma revisão adversarial deste repositório encontrou nove problemas, e a maioria compartilhava a mesma forma: **o documento afirmava o que o código não fazia**.

- A segurança prometia um código de dead letter para assinatura inválida que não existia no contrato.
- Prometia `bundler-audit` no CI, que não existia.
- Prometia imagens fixadas por digest, que estavam por tag.
- O contrato declarava `schema_validation_failed`, e nada validava payload no consumo — código de falha inalcançável.
- A justificativa para o applier devolver desfecho em vez de booleano apoiava-se num efeito colateral (reavaliação de elegibilidade) que não estava implementado.

Nenhum dos seis níveis acima pega isso, e a razão é estrutural: **todos verificam código contra código**. Nenhum lê a prosa.

Isso é uma limitação real da abordagem, não um descuido pontual. Documentação é onde a intenção mora, e é justamente o artefato que os guardrails automatizados não alcançam. Duas mitigações parciais foram acrescentadas — o spec de números documentados e o de códigos de falha alcançáveis — mas ambas cobrem afirmações *estruturadas*. Uma frase em prosa dizendo que algo é feito continua fora de alcance.

Registrar isso importa mais que corrigir os seis casos: quem herdar este repositório precisa saber que a camada detectiva tem esse limite.

## O que este desenho não resolve

Declarado, porque proteção sem limites declarados não foi levada a sério:

- **Agente que escreve código correto para o problema errado.** Nenhum guardrail aqui detecta requisito mal entendido. Isso continua sendo revisão humana.
- **Invariante que ninguém pensou em escrever.** As propriedades cobrem o que se sabia cobrir. Mutação reduz o ponto cego, não o elimina — como as duas histórias da L4 mostram, ele existia.
- **Erosão lenta.** Um agente que degrada a qualidade em incrementos que passam individualmente pelo CI não é detectado por nada aqui.
- **Documentação que descreve o que o código não faz.** Ver a seção acima — é o vetor que a revisão adversarial mais encontrou, e o que os guardrails automatizados menos alcançam.

## Relacionadas

- [07-repo-ai-native.md](07-repo-ai-native.md) — camada preventiva
- [02-concorrencia.md](02-concorrencia.md) — as invariantes
- [`harness/README.md`](../harness/README.md) — como rodar
