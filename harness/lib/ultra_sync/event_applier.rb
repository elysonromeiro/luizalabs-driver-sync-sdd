# frozen_string_literal: true

module UltraSync
  # O único caminho de escrita na projeção.
  #
  # Ser o único importa: torna a corretude auditável num lugar só, e dá ao CI
  # e à configuração de agentes um alvo concreto para proteger.
  #
  # ATENÇÃO — este arquivo é path protegido. As invariantes que ele sustenta
  # estão em spec/properties/. Mudança aqui sem mudança correspondente em spec/
  # falha o CI por desenho (ver docs/05-ai-harness.md).
  class EventApplier
    # Desfechos possíveis. Retornar desfecho em vez de booleano é decisão de
    # design, não conveniência: com estado completo (ADR-013), reaplicar um
    # evento de versão igual produz projeção idêntica, então a diferença entre
    # "aplicou" e "ignorou corretamente" é INVISÍVEL no estado final.
    #
    # Ela aparece no efeito colateral — cada escrita efetiva dispara
    # reavaliação de elegibilidade, que pode emitir oferta ao despacho. Sem
    # desfecho, nenhum teste consegue distinguir os dois casos, e a suíte
    # aceita silenciosamente a troca de `<` por `<=` na escrita condicional.
    OUTCOMES = %i[applied duplicate stale].freeze

    attr_reader :store

    def initialize(store:)
      @store = store
    end

    # @return [:applied, :duplicate, :stale]
    def apply(event)
      store.transaction do
        # Deduplicação vem ANTES da comparação de versão, e a ordem importa.
        # As duas cobrem coisas diferentes: esta reconhece o mesmo fato
        # reentregue; a de baixo reconhece um fato mais antigo. Um evento
        # reentregue quando a projeção está atrás passaria pela comparação de
        # versão sem problema — caso comum após rebalanceamento com offset não
        # commitado — e dispararia reavaliação em duplicidade.
        next :duplicate unless store.claim(event.source, event.id)

        rows = store.conditional_upsert(
          driver_id:      event.driver_id,
          state:          event.state,
          source_version: event.sequence
        )

        rows.zero? ? :stale : :applied
      end
    end

    # Aplica uma sequência e devolve os desfechos na mesma ordem.
    def apply_all(events) = events.map { |event| apply(event) }
  end
end
