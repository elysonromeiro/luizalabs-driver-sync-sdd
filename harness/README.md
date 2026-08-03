# Harness

Código executável que torna as invariantes do SDD **verificáveis** em vez de afirmadas.

Isto não é a implementação de produção. É o conjunto mínimo necessário para que idempotência, comutatividade sob reordenação, ausência de lost update e ausência de N+1 possam ser provadas — e, mais importante, para que a **quebra** delas seja detectada automaticamente.

## Como rodar

```bash
cd harness
bundle install

bundle exec rspec                 # tudo o que a máquina permitir
bundle exec rspec --tag invariant # só as invariantes
bin/generate --check              # código gerado em dia com o contrato
bin/check_docs                    # links da documentação
```

Sem Docker, a suíte roda e passa — os specs que exigem Postgres são pulados com aviso. Para incluí-los:

```bash
docker compose up -d              # na raiz do repositório
bundle exec rspec --tag pg
```

| Modo | Exemplos | Tempo |
|---|---|---|
| Sem Docker | 63 | ~0,7 s |
| Com Postgres | 77 | ~2,5 s |
| Com Postgres e Kafka | 84 | ~13 s |

## O que cada camada prova

| Diretório | Prova |
|---|---|
| `spec/unit` | Comportamento pontual do decodificador, do applier e das políticas |
| `spec/properties` | Invariantes universais, sobre qualquer sequência gerada |
| `spec/concurrency` | Ausência de lost update, por enumeração e contra Postgres real |
| `spec/golden` | Regressão caso a caso das regras de despacho |
| `spec/messaging` | Backpressure e compaction contra Kafka real |
| `spec/contracts` | Conformidade nas duas direções com os schemas |

### Propriedades, não exemplos

Um exemplo como "aplicar duas vezes o mesmo evento não muda nada" passa com implementações erradas. As propriedades em `spec/properties` quantificam sobre qualquer sequência:

```
apply(S) == apply(S ++ duplicatas(S))     idempotência
apply(S) == apply(shuffle(S))             comutatividade
source_version nunca decresce             monotonicidade
N réplicas convergem                      convergência
```

O gerador e o encolhedor são próprios, sem gem externa. A razão é encolhimento, não dependências: bibliotecas genéricas minimizam bem valores escalares e mal sequências de eventos de domínio — o contraexemplo que produzem costuma violar invariantes da fonte e não diagnostica nada. O encolhedor aqui remove eventos preservando a estrutura de versionamento, e reporta a seed:

```
SEED=1234 bundle exec rspec spec/properties
```

### Concorrência sem `sleep`

Teste de concorrência com threads e `sleep` passa por sorte. Aqui há três níveis:

1. **Enumeração** — `spec/concurrency/interleaving_spec.rb` percorre os **20 entrelaçamentos possíveis** entre dois consumidores. Nove deles perdem a atualização com read-modify-write ingênuo; nenhum perde com escrita condicional. Determinístico, milissegundos.
2. **Colisão real** — threads sincronizadas por `CyclicBarrier`, sem `sleep`.
3. **Postgres real** — lost update reproduzido sob `READ COMMITTED`, `SERIALIZABLE` abortando com SQLSTATE `40001`, `FOR UPDATE` bloqueando, deadlock provocado e prevenido.

A versão **que falha** é mantida como exemplo que passa. Sem ela, a versão correta passaria trivialmente e não demonstraria nada.

### N+1 por contagem, não por tempo

```
lote de 10  → 4 queries
lote de 100 → 4 queries
lote de 500 → 4 queries
50 eventos um a um → 200 queries
```

A asserção é sobre contagem porque contagem é determinística e tempo é ruidoso. Uma refatoração que troque o upsert em lote por um laço não muda nenhum resultado — só o custo.

### Mensageria: as duas teses contrariáveis

`spec/messaging` executa contra Kafka real as duas afirmações do SDD que soam erradas para quem vem de arquitetura de requisição-resposta:

**Backpressure vence fail-fast.** Dependência cai → breaker abre → consumidor pausa → **DLQ vazia**, offset congelado. Dependência volta → retoma do mesmo offset, backlog drena, nada perdido. O spec de veneno de payload é a contraparte: se tudo fosse pausa, uma mensagem defeituosa travaria o pipeline para sempre.

**Compaction serve catch-up.** Um consumidor novo reconstrói a base **sem uma query ao Portal**. Medido neste broker: 100 mensagens sob uma chave compactam para **4 retidas**, 96% de redução.

Nenhuma asserção depende de tempo decorrido — todas são sobre estado observável (breaker aberto, offset congelado, profundidade da DLQ, lag pelas marcas d'água do broker).

## Spec-driven na prática

`bin/generate` deriva os enums e limites do domínio de `contracts/schemas/driver-state.schema.json`. Nada em Ruby redigita a lista de status ou de tipos de veículo.

```bash
bin/generate           # regenera
bin/generate --check   # falha se o arquivo em disco divergir do contrato
```

Editar o arquivo gerado à mão faz o CI falhar apontando a linha divergente. É o que transforma "a spec é a fonte da verdade" em portão de build.

## Paths protegidos

Estes arquivos concentram a corretude do sistema. Alterá-los sem alterar `spec/` correspondente falha o CI por desenho:

- `lib/ultra_sync/event_applier.rb`
- `lib/ultra_sync/eligibility_policy.rb`
- `lib/ultra_sync/dispatch_rules.rb`
- `spec/properties/`
- `spec/golden/`

O mecanismo completo está em `docs/05-ai-harness.md`.

## Nota sobre `unsafe_write`

`Store::Memory#unsafe_write` escreve sem comparar versão. Existe **apenas** para demonstrar o lost update em `spec/concurrency`, e nada em `lib/` pode chamá-lo. Há um guardrail no CI que falha se ele aparecer fora de `spec/`.
