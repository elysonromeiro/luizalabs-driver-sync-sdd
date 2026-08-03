# frozen_string_literal: true

module UltraSync
  # Consumo em lote sem N+1.
  #
  # O consumidor puxa lotes, não mensagens avulsas. Escrito de forma ingênua,
  # o lote emite 3 queries por evento; escrito assim, emite 2 no total,
  # independentemente do tamanho.
  #
  # A suíte assere sobre a CONTAGEM de queries e não sobre tempo: contagem é
  # determinística, tempo é ruidoso. Uma refatoração que troque o upsert em
  # lote por um laço não muda nenhum resultado — só o custo — e é exatamente o
  # tipo de mudança que um agente de IA faz "para melhorar a legibilidade".
  class BatchProcessor
    Result = Struct.new(:applied, :duplicates, :stale, keyword_init: true)

    def initialize(store:)
      @store = store
    end

    def process(events)
      return Result.new(applied: [], duplicates: [], stale: []) if events.empty?

      @store.transaction do
        # 1. Reivindica todos os event_ids de uma vez. Devolve só os novos.
        claimed_ids = @store.claim_all(events.map { |e| [e.source, e.id] }).to_set
        fresh       = events.select { |e| claimed_ids.include?(e.id) }
        duplicates  = events.reject { |e| claimed_ids.include?(e.id) }

        next Result.new(applied: [], duplicates: duplicates, stale: []) if fresh.empty?

        # 2. Colapsa por entregador. NÃO é otimização — é requisito de
        #    corretude. ON CONFLICT não pode afetar a mesma linha duas vezes na
        #    mesma instrução, e o Postgres aborta a TRANSAÇÃO INTEIRA com
        #    "cannot affect row a second time". Um lote com duas mudanças do
        #    mesmo entregador é rotineiro (operador altera perfil e status em
        #    sequência; drain de backlog), então sem este passo o consumidor
        #    quebraria justamente sob a carga que existe para absorver.
        collapsed = collapse(fresh)

        # 3. Upsert condicional em lote — uma instrução. RETURNING diz quem de
        #    fato mudou, que é o insumo da reavaliação de elegibilidade.
        applied_ids = @store.conditional_upsert_all(
          collapsed.map do |e|
            { driver_id: e.driver_id, state: e.state, source_version: e.sequence }
          end
        ).to_set

        applied = collapsed.select { |e| applied_ids.include?(e.driver_id) }
        stale   = fresh - applied

        Result.new(applied: applied, duplicates: duplicates, stale: stale)
      end
    end

    # Por entregador, só o evento de maior sequence importa — os anteriores
    # seriam sobrescritos por ele de qualquer forma, já que cada evento carrega
    # estado completo.
    #
    # A ordenação por driver_id é ordem canônica de aquisição de lock: duas
    # transações com interseção adquirem na mesma ordem e nunca formam ciclo.
    # Sem isso, dois lotes com interseção invertida deadlockam sob carga
    # (ADR-004).
    def collapse(events)
      events
        .group_by(&:driver_id)
        .map { |_driver_id, group| group.max_by(&:sequence) }
        .sort_by(&:driver_id)
    end
  end
end
