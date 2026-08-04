# frozen_string_literal: true

require "date"

module UltraSync
  # Critérios de elegibilidade DA ULTRA-RÁPIDA.
  #
  # As regras NÃO estão neste arquivo. Elas vivem em
  # `contracts/behavior/eligibility.yaml`, e esta classe as interpreta.
  #
  # POR QUE ASSIM
  #
  # O SDD afirma desde o início que a especificação é a fonte da verdade e o
  # código é derivado dela. Antes disso valer para comportamento, a afirmação
  # cobria apenas enums — 1,7% do código. As regras que o enunciado cita
  # nominalmente ("critérios de elegibilidade mais restritivos do que os do
  # Portal") viviam em noventa linhas de Ruby que nenhum agente conseguiria
  # derivar de contrato nenhum.
  #
  # Agora um agente que precise mudar um critério edita YAML. O Ruby não sabe
  # quais são as regras — apenas como avaliá-las e em que ordem reportá-las.
  #
  # O que permanece decisão de código, e não de dados:
  #   - a ausência de curto-circuito (todas as regras são avaliadas)
  #   - a ordenação estável dos motivos
  #
  # As duas são propriedades da AVALIAÇÃO, não das regras, e movê-las para o
  # YAML seria transformar configuração em programa.
  #
  # ATENÇÃO — path protegido. Ver docs/05-ai-harness.md.
  class EligibilityPolicy
    SPEC_PATH = File.expand_path("../../../contracts/behavior/eligibility.yaml", __dir__)

    Result = Struct.new(:eligible, :reasons, keyword_init: true) do
      def eligible? = eligible
      def to_s = eligible? ? "elegível" : "não elegível (#{reasons.join(', ')})"
    end

    class << self
      def spec = @spec ||= RuleEngine.load(SPEC_PATH)

      # Motivos possíveis, derivados da spec. Nada aqui é redigitado.
      def reasons = @reasons ||= spec.fetch("rules").map { _1.fetch("id").to_sym }.freeze
    end

    def initialize(today: Time.now.utc.to_date, spec: self.class.spec)
      @spec   = spec
      @engine = RuleEngine.new(today: today)
    end

    def evaluate(state)
      # Sem curto-circuito: todas as regras são avaliadas para que a resposta
      # liste tudo o que impede. Corrigir um problema por vez é caro para o
      # entregador e para o suporte.
      reasons = @spec.fetch("rules")
                     .select { |rule| @engine.violated?(rule, state) }
                     .map { |rule| rule.fetch("id").to_sym }

      Result.new(eligible: reasons.empty?, reasons: reasons.sort)
    end

    def eligible?(state) = evaluate(state).eligible?
  end
end
