# frozen_string_literal: true

module UltraSync
  # Regras de despacho: dado um entregador e uma oferta, ele pode recebê-la?
  #
  # É a regra de negócio de maior valor do consumidor, e por isso o alvo mais
  # provável de uma "simplificação" bem-intencionada de um agente de IA. A
  # proteção não é este comentário — é spec/golden/dispatch_cases.json, que
  # congela o comportamento caso a caso, e o CODEOWNERS que exige revisão
  # humana para alterá-lo.
  #
  # ATENÇÃO — path protegido. Ver docs/05-ai-harness.md.
  class DispatchRules
    Offer = Struct.new(:segment, :weight_kg, :distance_km, keyword_init: true)

    Decision = Struct.new(:accepted, :reasons, keyword_init: true) do
      def accepted? = accepted
    end

    REASONS = %i[
      driver_not_eligible
      segment_not_served
      exceeds_cargo_capacity
      outside_delivery_radius
    ].freeze

    def initialize(policy: EligibilityPolicy.new)
      @policy = policy
    end

    def decide(state, offer)
      reasons = []

      # Elegibilidade é pré-requisito, não uma regra entre outras: um
      # entregador inelegível não recebe oferta nenhuma, independentemente do
      # encaixe operacional.
      reasons << :driver_not_eligible unless @policy.eligible?(state)

      segments = state["segments"] || []
      reasons << :segment_not_served unless segments.include?(offer.segment)

      capacity = state.dig("vehicle", "cargo_capacity_kg")
      reasons << :exceeds_cargo_capacity unless capacity && offer.weight_kg <= capacity

      radius = state["delivery_radius_km"]
      reasons << :outside_delivery_radius unless radius && offer.distance_km <= radius

      Decision.new(accepted: reasons.empty?, reasons: reasons.sort)
    end
  end
end
