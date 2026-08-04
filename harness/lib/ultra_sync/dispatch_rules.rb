# frozen_string_literal: true

module UltraSync
  # Regras de despacho: dado um entregador e uma oferta, ele pode recebê-la?
  #
  # As regras NÃO estão neste arquivo. Vivem em
  # `contracts/behavior/dispatch.yaml` e esta classe as interpreta — ver
  # `EligibilityPolicy` para o raciocínio completo.
  #
  # É a regra de negócio de maior valor do consumidor, e por isso o alvo mais
  # provável de uma "simplificação" bem-intencionada de um agente de IA. A
  # proteção não é este comentário — é spec/golden/dispatch_cases.json, que
  # congela o comportamento caso a caso, e o CODEOWNERS que exige revisão
  # humana para alterá-lo.
  #
  # ATENÇÃO — path protegido. Ver docs/05-ai-harness.md.
  class DispatchRules
    SPEC_PATH = File.expand_path("../../../contracts/behavior/dispatch.yaml", __dir__)

    Offer = Struct.new(:segment, :weight_kg, :distance_km, keyword_init: true)

    Decision = Struct.new(:accepted, :reasons, keyword_init: true) do
      def accepted? = accepted
    end

    class << self
      def spec = @spec ||= RuleEngine.load(SPEC_PATH)

      # Motivos possíveis, derivados da spec. Nada aqui é redigitado.
      def reasons
        @reasons ||= ([spec.dig("prerequisite", "id")] +
                      spec.fetch("rules").map { _1.fetch("id") }).map(&:to_sym).freeze
      end
    end

    def initialize(policy: EligibilityPolicy.new, spec: self.class.spec)
      @policy = policy
      @spec   = spec
      @engine = RuleEngine.new
    end

    def decide(state, offer)
      reasons = []

      # Pré-requisito, avaliado antes das regras de encaixe. Um entregador
      # inelegível não recebe oferta nenhuma, por melhor que seja o encaixe —
      # e mantê-lo separado é o que impede que elegibilidade vire uma condição
      # entre outras, passível de ser compensada.
      reasons << @spec.dig("prerequisite", "id").to_sym unless @policy.eligible?(state)

      @spec.fetch("rules").each do |rule|
        reasons << rule.fetch("id").to_sym if @engine.violated?(rule, state, offer: offer)
      end

      Decision.new(accepted: reasons.empty?, reasons: reasons.sort)
    end
  end
end
