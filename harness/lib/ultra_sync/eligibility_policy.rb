# frozen_string_literal: true

require "date"

module UltraSync
  # Critérios de elegibilidade DA ULTRA-RÁPIDA.
  #
  # Esta classe é a razão de a projeção existir separada da política. O Portal
  # é a fonte da verdade sobre o entregador; a Ultra-rápida decide o que fazer
  # com essa verdade, e seus critérios são mais restritivos — o Portal aceita
  # pessoa física, aqui não.
  #
  # Consequência prática: mudar uma regra abaixo não exige re-sincronizar nada.
  # A projeção guarda o que o Portal disse; a decisão é reavaliada localmente.
  #
  # Consequência de segurança (docs/04-seguranca.md): um evento forjado que
  # declare status "active" não basta. A política reavalia a partir do estado
  # projetado, então comprometer a fonte não é suficiente para comprometer a
  # decisão.
  #
  # ATENÇÃO — path protegido. Ver docs/05-ai-harness.md.
  class EligibilityPolicy
    Result = Struct.new(:eligible, :reasons, keyword_init: true) do
      def eligible? = eligible
      def to_s = eligible? ? "elegível" : "não elegível (#{reasons.join(', ')})"
    end

    # Motivos são códigos estáveis, não frases. Eles entram nos casos golden e
    # em métrica — texto livre mudaria a cada refatoração e quebraria os dois.
    REASONS = %i[
      not_active
      individual_not_allowed
      background_check_not_approved
      documents_expired
      no_segments
      invalid_delivery_radius
      vehicle_not_allowed
    ].freeze

    # A Ultra-rápida não despacha a pé nem de bicicleta: o modelo de operação
    # pressupõe deslocamento motorizado dentro do raio declarado.
    ALLOWED_VEHICLE_TYPES = %w[scooter motorcycle car van].freeze

    # A data corrente em **UTC**, não no fuso do servidor.
    #
    # `Date.today` usa o fuso local. Todos os instantes deste sistema são UTC —
    # o contrato exige RFC 3339 em UTC —, então comparar validade documental
    # contra uma data local abre uma janela de até um dia em que a política
    # discorda de si mesma dependendo de onde o processo roda.
    #
    # O sintoma seria um entregador elegível numa réplica e inelegível em
    # outra, sem nada no evento explicando a diferença — o tipo de divergência
    # que se investiga por horas. Encontrado em revisão; o default era
    # `Date.today`.
    def initialize(today: Time.now.utc.to_date)
      @today = today
    end

    def evaluate(state)
      reasons = []

      reasons << :not_active unless state["status"] == "active"

      # O critério que o enunciado cita nominalmente: o Portal permite pessoa
      # física, a Ultra-rápida não. Decidido com `document_type`, que é
      # classificação e não dado pessoal — por isso trafega no evento
      # enquanto o número em si fica atrás de API autorizada (ADR-007).
      reasons << :individual_not_allowed unless state["document_type"] == "cnpj"

      compliance = state["compliance"] || {}
      reasons << :background_check_not_approved unless compliance["background_check"] == "approved"

      valid_until = compliance["documents_valid_until"]
      reasons << :documents_expired if valid_until && Date.parse(valid_until) < @today

      segments = state["segments"] || []
      reasons << :no_segments if segments.empty?

      radius = state["delivery_radius_km"]
      reasons << :invalid_delivery_radius unless radius.is_a?(Numeric) && radius.positive?

      vehicle_type = state.dig("vehicle", "type")
      reasons << :vehicle_not_allowed unless ALLOWED_VEHICLE_TYPES.include?(vehicle_type)

      Result.new(eligible: reasons.empty?, reasons: reasons.sort)
    end

    def eligible?(state) = evaluate(state).eligible?
  end
end
