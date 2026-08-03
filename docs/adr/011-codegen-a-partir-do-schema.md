# ADR-011 — Gerar constantes de domínio a partir do schema

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

`contracts/README.md` declara que a especificação é a fonte da verdade. Declaração é barata. A pergunta é o que impede o código de divergir dela na terça-feira em que alguém precisa entregar rápido.

O caso concreto: a política de elegibilidade precisa saber quais são os status válidos de um entregador e quais tipos de veículo existem. Essa lista está no JSON Schema. Se ela for redigitada em Ruby, existem duas verdades — e as duas verdades divergem, sempre, é só questão de quando.

## Decisão

`bin/generate` lê `contracts/schemas/driver-state.schema.json` e emite `harness/lib/ultra_sync/generated/driver_state.rb` com os enums e limites do domínio. `bin/generate --check` compara o arquivo em disco com o que o contrato produziria e **falha o build** se houver divergência, apontando a linha.

Nada em Ruby redigita a lista de status ou de veículos.

## Por que gerar em vez de validar

A alternativa é manter as duas listas e escrever um teste que as compara. Funciona, e é pior por um motivo específico: **quando o teste falha, não fica claro qual lado está certo**. Alguém precisa decidir, sob pressão, se o contrato ou o código representa a intenção — e a decisão errada é indistinguível da certa até chegar em produção.

Com geração, a pergunta não existe. Só há um lugar onde a lista pode ser alterada.

## O que isso habilita nos guardrails

Este é o portão que dá sentido concreto à camada preventiva. Um agente de IA que altere comportamento editando o código gerado — o caminho mais curto quando se quer mudar um enum — falha o CI **antes** da revisão, com a linha divergente nomeada. Sem ele, "a spec é a fonte da verdade" seria uma frase no `CLAUDE.md`, e frase é sugestão.

O hook `Stop` roda `--check` ao fim de cada sessão pelo mesmo motivo: drift não quebra a suíte agora, quebra o CI depois, sem contexto de quem o introduziu.

## Escopo deliberadamente pequeno

Gera apenas **enums e limites**, não classes nem serializadores.

Geradores ambiciosos produzem código que ninguém lê e que impõe as decisões de modelagem da ferramenta ao domínio. Aqui, o que se quer proteger é a lista de valores válidos — que é onde a divergência acontece — e não a forma dos objetos, que o código expressa melhor à mão.

A saída é Ruby legível, com cabeçalho declarando que é gerado e como regenerar. Alguém que caia nesse arquivo num diff entende em cinco segundos o que fazer.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **Gerar constantes** | Escolhida — uma fonte, verificável |
| Duplicar e testar a igualdade | Quando o teste falha, não se sabe qual lado é a intenção |
| Ler o schema em runtime | Custo de I/O e parsing no caminho quente; erro de contrato vira erro de produção em vez de erro de build |
| Gerar classes completas | Código ilegível e acoplamento à modelagem da ferramenta |

A terceira merece nota: ler o schema em runtime parece mais elegante e move a detecção de erro do build para a produção, que é a direção errada.

## Consequências

**Positivas**

- Impossível divergir sem o CI acusar, com a linha nomeada.
- Torna spec-driven development verificável em vez de declaratório.
- Dá aos guardrails contra IA um alvo concreto e barato de checar.

**Negativas**

- Um passo a mais no fluxo: mudou o schema, rode `bin/generate`.
- Arquivo gerado versionado, o que gera ruído em diff. Preferível a gerar em tempo de build, porque assim o valor efetivo é revisável no PR.
- O gerador é código a manter. Mitigado pelo escopo pequeno — são ~120 linhas.

## Relacionadas

- [`contracts/README.md`](../../contracts/README.md) — a política que isto verifica
- [05-ai-harness.md](../05-ai-harness.md) — o guardrail de drift
- [07-repo-ai-native.md](../07-repo-ai-native.md) — o hook `Stop`
