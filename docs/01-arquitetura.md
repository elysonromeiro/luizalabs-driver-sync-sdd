# Arquitetura e fluxo de dados

> **Pilar 1.** Componentes, fronteiras e os caminhos que um fato percorre do Portal até virar decisão de despacho.

## Visão geral

O sistema tem uma forma simples e uma propriedade que vale mais que a forma: **o Portal não conhece seus consumidores**. Ele grava o que aconteceu num log durável e segue adiante. Quem precisa do dado se inscreve.

```mermaid
flowchart LR
    subgraph fonte["Fonte da verdade"]
        portal["Portal dos Entregadores<br/>Ruby on Rails<br/>Cadastro, documentação<br/>e aprovação"]
    end

    subgraph backbone["Backbone de eventos"]
        kafka[("Kafka<br/>Log durável,<br/>particionado por driver_id")]
    end

    subgraph consumidores["Consumidores"]
        ultra["Ultra-rápida<br/>Ruby on Rails<br/>Elegibilidade e despacho"]
        futuro["Plataforma N<br/>do ecossistema Magalu<br/>consumer group adicional"]
    end

    entregador(["Entregador"])
    operador(["Operador<br/>do Portal"])

    entregador -->|"cadastro e<br/>atualização"| portal
    operador -->|"aprovação e<br/>bloqueio"| portal
    portal -->|"eventos de<br/>ciclo de vida"| kafka
    kafka -->|"assina"| ultra
    kafka -.->|"assina, sem custo<br/>para a fonte"| futuro
    ultra -->|"ofertas de corrida"| entregador

    style portal fill:#e8f0fe,stroke:#4285f4,stroke-width:2px
    style kafka fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    style ultra fill:#e6f4ea,stroke:#34a853,stroke-width:2px
    style futuro fill:#f5f5f5,stroke:#9e9e9e,stroke-width:1px,stroke-dasharray: 4 4
```

A seta pontilhada é o requisito de agnosticismo do enunciado. Ela não custa nada ao Portal: uma plataforma nova é um consumer group adicional lendo um log que já existe.

## Componentes

```mermaid
flowchart TB
    subgraph portalbox["PORTAL DOS ENTREGADORES"]
        direction TB
        api["API / Admin<br/>Rails"]
        pg1[("Postgres<br/>drivers<br/>driver_outbox")]
        relay["Outbox Relay<br/>processo Ruby<br/>LISTEN/NOTIFY + polling"]
        recon["API de Reconciliação<br/>checksums · feed · PII"]

        api -->|"1 transação:<br/>estado + evento"| pg1
        pg1 -->|"NOTIFY"| relay
        recon --> pg1
    end

    subgraph kafkabox["KAFKA"]
        direction TB
        tstatus[["drivers.status.v1<br/>fast-lane · 12 part."]]
        tprofile[["drivers.profile.v1<br/>bulk-lane · 24 part."]]
        tsnap[["drivers.snapshot.v1<br/>compactado · 24 part."]]
        tdlq[["drivers.dlq.v1<br/>dead letter"]]
        registry["Schema Registry<br/>compat BACKWARD"]
    end

    subgraph ultrabox["ULTRA-RÁPIDA"]
        direction TB
        cstatus["Consumer · status<br/>group próprio"]
        cprofile["Consumer · perfil<br/>group próprio"]
        applier["Event Applier<br/>dedupe + escrita condicional"]
        policy["Eligibility Policy<br/>regras da Ultra-rápida"]
        pg2[("Postgres<br/>driver_projections<br/>processed_events")]
        dispatch["Motor de Despacho"]
        breaker["Circuit Breaker<br/>pause/resume"]
    end

    reconjob["Job de Reconciliação<br/>checksum por faixa"]

    relay --> tstatus
    relay --> tprofile
    relay --> tsnap
    registry -.->|"valida"| relay

    tstatus --> cstatus
    tprofile --> cprofile
    cstatus --> applier
    cprofile --> applier
    applier --> pg2
    applier -->|"payload<br/>inválido"| tdlq
    applier -->|"estado mudou"| policy
    policy --> dispatch
    breaker -.->|"pausa e<br/>retoma"| cstatus
    breaker -.->|"pausa e<br/>retoma"| cprofile
    pg2 -.->|"degradação"| breaker

    tsnap -.->|"bootstrap /<br/>catch-up"| reconjob
    reconjob -.->|"só faixas<br/>divergentes"| recon
    reconjob --> pg2

    style pg1 fill:#e8f0fe,stroke:#4285f4
    style pg2 fill:#e6f4ea,stroke:#34a853
    style applier fill:#fce8e6,stroke:#ea4335,stroke-width:2px
    style breaker fill:#fef7e0,stroke:#f9ab00,stroke-width:2px
```

O **Event Applier** está destacado porque é onde mora toda a corretude do sistema. É o único caminho de escrita na projeção, e é ele que o harness protege com testes de propriedade e que a configuração de agentes marca como path protegido.

### Responsabilidades

| Componente | Responsabilidade | Nunca faz |
|---|---|---|
| **API / Admin** | Muda o entregador e grava o evento na mesma transação | Chamar consumidor de forma síncrona |
| **Outbox Relay** | Publica o que foi commitado, em ordem, at-least-once | Decidir conteúdo de evento |
| **Consumer** | Puxa do tópico, entrega ao applier, gerencia offset | Aplicar regra de negócio |
| **Event Applier** | Deduplica, compara versão, escreve condicionalmente | Interpretar elegibilidade |
| **Eligibility Policy** | Decide se o entregador pode receber ofertas | Escrever na projeção |
| **Circuit Breaker** | Pausa e retoma consumo sob degradação | Descartar mensagem |
| **Job de Reconciliação** | Detecta e corrige divergência | Varrer a base inteira |

A separação entre **applier** e **policy** é a que sustenta o requisito de validadores próprios: a projeção guarda o que o Portal disse, a policy decide o que a Ultra-rápida faz com isso. O Portal aceita pessoa física; a Ultra-rápida não. Nenhuma dessas duas verdades precisa da outra, e mudar a regra da Ultra-rápida não exige re-sincronizar nada.

## Fluxo principal

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operador
    participant API as Portal API
    participant PG1 as Postgres<br/>(Portal)
    participant R as Outbox Relay
    participant K as Kafka
    participant C as Consumer
    participant A as Event Applier
    participant PG2 as Postgres<br/>(Ultra)
    participant P as Eligibility Policy

    Op->>API: aprova entregador
    activate API
    rect rgb(232, 240, 254)
        Note over API,PG1: uma transação — sem janela de inconsistência
        API->>PG1: UPDATE drivers SET status='active',<br/>sync_version = sync_version + 1
        API->>PG1: INSERT INTO driver_outbox (...)
        PG1-->>API: COMMIT
    end
    deactivate API
    API-->>Op: 200 OK

    PG1->>R: NOTIFY driver_outbox
    R->>PG1: SELECT ... WHERE published_at IS NULL
    R->>K: produce(drivers.status.v1, key=driver_id)
    R->>K: produce(drivers.snapshot.v1, key=driver_id)
    R->>PG1: UPDATE ... SET published_at = now()

    K->>C: poll
    C->>A: apply(event)
    activate A
    A->>PG2: INSERT INTO processed_events (source, event_id)<br/>ON CONFLICT DO NOTHING
    PG2-->>A: 1 linha — evento novo
    A->>PG2: UPDATE driver_projections SET ...<br/>WHERE source_version < :sequence
    PG2-->>A: 1 linha — aplicado
    deactivate A
    A->>P: reavalia elegibilidade
    P->>P: CNPJ? doc válido?<br/>background check aprovado?
    P-->>C: elegível — libera para ofertas
    C->>K: commit offset
```

O bloco destacado é o coração da decisão [ADR-002](adr/002-outbox-vs-cdc.md). Estado e evento nascem juntos ou não nascem. Não existe caminho em que o Portal registre uma aprovação que o log desconheça.

Note também a ordem no fim: o offset é commitado **depois** do processamento. É o que torna a entrega at-least-once — e é por isso que a deduplicação existe.

## Evento fora de ordem

O caso que o enunciado pede explicitamente. Dois eventos do mesmo entregador chegam invertidos, seja por replay, rebalanceamento ou pela separação de canais.

```mermaid
sequenceDiagram
    autonumber
    participant K as Kafka
    participant A as Event Applier
    participant PG as Postgres (Ultra)

    Note over K: emitidos na ordem 6 → 7,<br/>entregues na ordem 7 → 6

    K->>A: driver.status_changed<br/>sequence = 7 (blocked)
    A->>PG: INSERT processed_events ON CONFLICT DO NOTHING
    PG-->>A: 1 linha
    A->>PG: UPDATE ... WHERE source_version < 7
    PG-->>A: 1 linha afetada
    Note right of A: :applied<br/>projeção agora está em 7

    K->>A: driver.updated<br/>sequence = 6 (raio de entrega)
    A->>PG: INSERT processed_events ON CONFLICT DO NOTHING
    PG-->>A: 1 linha — é um evento distinto
    A->>PG: UPDATE ... WHERE source_version < 6
    PG-->>A: 0 linhas afetadas
    Note right of A: :stale<br/>descartado, métrica emitida

    Note over A,PG: estado final correto: blocked.<br/>Nenhum código verificou ordem.
```

O ponto que este diagrama existe para mostrar: **nada no consumidor inspeciona ordem**. A decisão inteira está no predicado do `UPDATE`, e é o banco que a executa atomicamente.

## Evento duplicado

```mermaid
sequenceDiagram
    autonumber
    participant K as Kafka
    participant A as Event Applier
    participant PG as Postgres (Ultra)

    K->>A: evento id=abc, sequence=7
    A->>PG: INSERT processed_events (source, 'abc')<br/>ON CONFLICT DO NOTHING
    PG-->>A: 1 linha
    A->>PG: UPDATE ... WHERE source_version < 7
    PG-->>A: 1 linha
    Note right of A: :applied

    Note over K,A: relay republica após falha,<br/>ou o offset não foi commitado

    K->>A: evento id=abc, sequence=7 (mesmo id)
    A->>PG: INSERT processed_events (source, 'abc')<br/>ON CONFLICT DO NOTHING
    PG-->>A: 0 linhas
    Note right of A: :duplicate<br/>sai antes de tocar a projeção
    Note over A,PG: nenhuma escrita, nenhuma<br/>reavaliação de elegibilidade
```

A deduplicação vem antes da escrita condicional de propósito. As duas juntas cobrem coisas diferentes: `processed_events` reconhece o **mesmo fato** reentregue; a comparação de versão reconhece um **fato mais antigo**. Só a segunda não bastaria — reprocessar o mesmo evento passaria pelo `WHERE` se a projeção estivesse atrás, e dispararia reavaliação de elegibilidade em duplicidade.

## Degradação da Ultra-rápida

```mermaid
sequenceDiagram
    autonumber
    participant K as Kafka
    participant C as Consumer
    participant B as Circuit Breaker
    participant PG as Postgres (Ultra)
    participant DLQ as drivers.dlq.v1

    K->>C: poll — lote de eventos
    C->>PG: UPDATE driver_projections
    PG--xC: timeout
    C->>B: registra falha (1/5)
    Note over C: backoff exponencial<br/>com jitter, retenta

    C->>PG: retry
    PG--xC: timeout
    C->>B: registra falha (5/5)

    rect rgb(254, 247, 224)
        B->>B: abre
        B->>C: pause(partições)
        Note over C,K: consumo parado.<br/>Offset NÃO avança.<br/>Nada vai para a DLQ.
    end

    Note over DLQ: DLQ permanece vazia —<br/>isto é indisponibilidade,<br/>não defeito de payload

    loop a cada 30 s
        B->>PG: probe — SELECT 1
        PG--xB: ainda fora
    end

    B->>PG: probe
    PG-->>B: ok
    rect rgb(230, 244, 234)
        B->>B: meio-aberto → fecha
        B->>C: resume(partições)
    end

    K->>C: poll — retoma do mesmo offset
    Note over C,PG: backlog drena em ordem.<br/>Nenhum evento perdido,<br/>nenhum replay a organizar.
```

Este é o desenho de [ADR-008](adr/008-backpressure.md), e a escolha contraintuitiva do documento: sob degradação, **parar de consumir é melhor que falhar rápido**. O log do Kafka já é uma fila durável e ordenada; despejar o backlog na DLQ trocaria um problema temporário por trabalho permanente de reconciliação, gerado exatamente no momento em que o sistema está mais frágil.

## Onde cada requisito é atendido

| Requisito do enunciado | Onde |
|---|---|
| SLA de 30 s no P99 | Outbox com `LISTEN/NOTIFY` (~100 ms) + consumo contínuo — [ADR-002](adr/002-outbox-vs-cdc.md) |
| Idempotência estrita | `processed_events` + escrita condicional — [ADR-003](adr/003-ordenacao-por-versao.md) |
| Eventos fora de ordem | Versão monotônica por entregador — [ADR-003](adr/003-ordenacao-por-versao.md) |
| Concorrência | Escrita condicional sem lock pessimista — [ADR-004](adr/004-locking.md) |
| Validadores próprios | `EligibilityPolicy` separada da projeção |
| Ativação em tempo real | Fast-lane dedicado — [ADR-005](adr/005-fast-lane.md) |
| Arquitetura agnóstica | Consumer group por consumidor, custo zero na fonte — [ADR-001](adr/001-broker.md) |
| Segurança | mTLS, ACL por tópico, PII tokenizada — [04-seguranca.md](04-seguranca.md) |

## Próximas seções

- [Concorrência e idempotência](02-concorrencia.md) — o detalhe do applier, N+1 no Rails
- [Resiliência](03-resiliencia.md) — backoff, circuit breaker, DLQ
- [Segurança](04-seguranca.md) — superfície de ataque e dados pessoais
