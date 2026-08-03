# ADR-007 — PII fora do evento e apagamento por destruição de chave

- **Status:** Aceito
- **Data:** 2026-08-03

## Contexto

O cadastro de entregador contém dado pessoal: CPF ou CNPJ, nome, telefone, endereço, placa. Duas decisões anteriores tornam isso um problema específico, não genérico:

1. **Estado completo** ([ADR-013](013-estado-completo-vs-delta.md)) — o entregador inteiro trafega em todo evento. O que estiver no payload estará em toda mensagem, replicado em todas as réplicas de todas as partições.
2. **Tópico compactado** (ADR-009) — `drivers.snapshot.v1` retém o último estado **indefinidamente**. Não há retenção que expire.

Junte as duas e o resultado é: qualquer PII no payload vive para sempre num log append-only replicado. A LGPD garante ao titular o direito à eliminação (art. 18, VI), e um log append-only é, por definição, o lugar mais difícil de apagar algo.

## Decisão

### 1. PII não entra no evento

Campos sensíveis viram **tokens opacos** gerados por um serviço de tokenização:

```json
{
  "document_type": "cnpj",
  "document_token": "tok_9Hn2QpVx4LrT8mKdZbW3aYcE"
}
```

Quem legitimamente precisa do valor real chama `GET /v1/drivers/{id}/sensitive`, com escopo `drivers.pii` e auditoria por chamada.

**`document_type` é exceção deliberada.** Saber que alguém é CNPJ e não CPF é classificação de natureza jurídica, não dado pessoal — e é exatamente o campo que a Ultra-rápida precisa para recusar pessoa física. Sem ele no evento, cada avaliação de elegibilidade exigiria uma chamada síncrona ao Portal, transformando um requisito de negócio simples num acoplamento caro.

Esse é o teste que aplicamos a cada campo: **qual a decisão que ele habilita, e ela exige o valor ou só a categoria?** Quase sempre é a categoria.

### 2. Apagamento por destruição de chave (crypto-shredding)

Tokenizar reduz a exposição mas não resolve o apagamento: dado pseudonimizado continua sendo dado pessoal enquanto existir meio de reidentificação. O token no log aponta para um registro no cofre.

Cada titular tem uma **chave de criptografia própria**, guardada em KMS. O cofre guarda o valor cifrado com ela.

```
titular → chave_kms(driver_id) → ciphertext no cofre → token no evento
```

Apagar é **destruir a chave**. O ciphertext remanescente deixa de ser reversível, e o token vira uma referência sem destino. Não é preciso reescrever o log, o que seria impossível.

Fluxo completo de uma solicitação de eliminação:

| Passo | Ação |
|---|---|
| 1 | Destruir a chave KMS do titular |
| 2 | Remover o registro do cofre |
| 3 | Publicar **tombstone** em `drivers.snapshot.v1` (`data` nulo, mesma chave) — a compaction libera o último estado retido |
| 4 | Consumidores apagam a projeção local ao receber a tombstone |
| 5 | `GET /sensitive` passa a responder `410 Gone` |

Os eventos históricos nos tópicos de ciclo de vida expiram naturalmente pela retenção de 7 dias. O que fica além disso é o snapshot, e a tombstone o remove.

**Ressalva honesta:** se o apagamento por destruição de chave satisfaz plenamente o direito à eliminação — em vez de constituir anonimização, que tem tratamento distinto na LGPD — é avaliação jurídica, não arquitetural. O desenho torna o apagamento *tecnicamente possível e verificável*, que é a parte que cabe à engenharia. A adequação precisa de validação do DPO antes de ir a produção.

## Alternativas consideradas

| Abordagem | Apaga do log? | Custo |
|---|---|---|
| **Token + crypto-shredding** | Sim, por irreversibilidade | Cofre e KMS a operar |
| PII em claro no evento | **Não** — impossível sem reescrever o log | Nenhum, até o primeiro pedido de eliminação |
| Criptografia por campo com chave global | Não — apagar um titular exigiria rotacionar tudo | Menor |
| Retenção curta em todos os tópicos | Perderia o snapshot compactado | Sacrificaria o catch-up |

A terceira é a que mais parece funcionar e não funciona: uma chave global protege contra vazamento de disco, mas não dá granularidade de apagamento por titular. É a que se escolhe quando o requisito lido é confidencialidade e o requisito real é eliminação.

## Consequências

**Positivas**

- O log de eventos deixa de ser repositório de PII, o que reduz drasticamente a superfície: um vazamento de tópico expõe tokens, não documentos.
- A maioria dos consumidores nunca vê dado pessoal — o motor de despacho decide elegibilidade sem jamais chamar o endpoint sensível.
- Apagamento é uma operação de segundos e auditável, não um projeto.
- Acesso a PII fica concentrado num endpoint, o que torna a auditoria completa por construção.

**Negativas**

- Um serviço de tokenização e um cofre a operar, ambos no caminho crítico do cadastro.
- Quem precisa do valor real paga uma chamada a mais.
- Chave destruída é irreversível: apagamento indevido não tem desfazer. Exige confirmação em dois passos e trilha de aprovação.
- A tombstone precisa chegar a todos os consumidores — um consumidor fora do ar durante o apagamento só o processa ao voltar, e esse intervalo precisa ser monitorado.

## Relacionadas

- [ADR-013](013-estado-completo-vs-delta.md) — por que o estado inteiro trafega
- ADR-009 — retenção indefinida do snapshot
- [04-seguranca.md](../04-seguranca.md) — superfície de ataque completa
