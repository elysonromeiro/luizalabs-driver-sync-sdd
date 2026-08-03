# ADR-012 — Separação de poderes entre agentes de IA

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

O time usa agentes de IA para gerar e refatorar código. A configuração óbvia é um agente generalista com acesso total ao repositório: ele lê o requisito, escreve o código, escreve o teste, roda a suíte e abre o PR.

Essa configuração tem um defeito estrutural, e ele não é sobre capacidade do modelo.

**O agente que escreve a implementação tem incentivo a escrever o teste que ela passa.** Não por má-fé: quando o objetivo é "faça a suíte ficar verde", escrever um teste que descreve o comportamento produzido é o caminho mais curto, e é indistinguível — para o próprio agente — de escrever um teste que exige o comportamento correto. O resultado é uma suíte que documenta a implementação em vez de restringi-la.

É o mesmo motivo pelo qual um desenvolvedor não aprova o próprio PR, e a resposta é a mesma.

## Decisão

Sete subagents com **privilégio mínimo e papéis que não se sobrepõem**, definidos em `.claude/agents/`:

| Agente | Papel | Escreve em |
|---|---|---|
| `spec-guardian` | Único autorizado a alterar contratos | `contracts/` |
| `event-modeler` | Traduz requisito de negócio em evento | `contracts/` |
| `invariant-prover` | Aponta a invariante ameaçada e escreve a propriedade | `spec/properties/` |
| `concurrency-auditor` | Audita diff atrás de corridas | — read-only |
| `harness-runner` | Roda a bateria e reporta | — read-only |
| `adr-writer` | Registra decisão com trade-off explícito | `docs/adr/` |
| `guardrail-redteam` | Tenta burlar as proteções | — read-only |

A regra estrutural:

> **Quem escreve o código não escreve a invariante que o restringe, e ninguém verifica o próprio trabalho.**

## Como a separação age na prática

Três agentes são **read-only** — `concurrency-auditor`, `harness-runner`, `guardrail-redteam`. Isso é deliberado e é o que dá valor ao que eles dizem: um auditor que pode consertar o que encontrou tende a consertar em vez de reportar, e o achado nunca chega a quem precisava saber.

O `harness-runner` é o caso mais claro. Quem executa a verificação **e** a conserta tem o mesmo incentivo do parágrafo de abertura: a forma mais rápida de fazer um teste passar quase nunca é a correta.

O `guardrail-redteam` fecha o ciclo por cima. Seu trabalho é encontrar o caminho pelo qual um agente mal-comportado passaria — e o que ele acha vira teste novo. É fuzzing aplicado à própria política de segurança, e existe porque as proteções deste repositório foram desenhadas por quem também escreveu o código que elas protegem.

## Quando NÃO usar

Esta é a parte que costuma faltar em desenho multiagente, e é o que separa quem operou o modelo de quem leu sobre ele.

Orquestração custa tokens e latência. Ela só se paga quando o **custo do erro** é alto:

| Mudança | Fluxo apropriado |
|---|---|
| Alterar `event_applier.rb` | Pipeline completo — auditor, prover, runner |
| Adicionar evento ao contrato | `event-modeler` → `spec-guardian` → `harness-runner` |
| Corrigir typo em documentação | **Nenhum agente.** Edite e siga. |
| Renomear variável local | Nenhum agente. O CI cobre. |
| Ajustar mensagem de log | Nenhum agente. |

Rodar um pipeline de cinco agentes para corrigir um acento é a forma mais rápida de fazer o time desligar a orquestração inteira.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Agente generalista com acesso total | O defeito do contexto: escreve o teste que a própria implementação passa |
| Dois agentes (implementador + revisor) | Melhor, mas o revisor genérico dilui atenção. Um auditor de concorrência com escopo estreito acha o que um revisor geral não vê |
| Separação só por prompt, sem restringir ferramentas | Instrução é sugestão. Restrição de `tools` é executada pelo harness — a mesma diferença entre placa e porta trancada |
| Um agente por arquivo | Granularidade sem significado. A separação precisa acompanhar a fronteira de **incentivo**, não a de diretório |

## Consequências

**Positivas**

- Teste e implementação nascem de contextos distintos, que é o que os torna independentes.
- Restrição de ferramentas é executada pelo harness, não confiada ao modelo.
- Papéis estreitos produzem prompts estreitos, e prompt estreito produz resultado melhor que prompt genérico.
- `guardrail-redteam` transforma "achamos que está protegido" em achado concreto ou em lista do que foi tentado.

**Negativas**

- Mais tokens e mais latência por mudança. Mitigado pela tabela de quando não usar — que precisa ser respeitada, ou a orquestração é abandonada por atrito.
- Handoff entre agentes perde contexto. Cada definição pede relatório explícito por isso.
- A configuração precisa de manutenção: agente cujo escopo não acompanha o código vira ruído.

**Limitação declarada**

O formato de subagents e hooks aqui é o do **Claude Code**. Gemini e Copilot têm mecanismos próprios e a configuração não é portável. O que é portável é o princípio — separar por incentivo, restringir por ferramenta, nunca deixar o mesmo ator implementar e aprovar. Fingir neutralidade de ferramenta seria pior que declarar a limitação.

## Relacionadas

- [05-ai-harness.md](../05-ai-harness.md) — camada detectiva
- `docs/07-repo-ai-native.md` — camada preventiva em detalhe
