# frozen_string_literal: true

module UltraSync
  # Evento do ciclo de vida, decodificado do envelope CloudEvents.
  #
  # É deliberadamente um objeto de valor imutável: um evento é um fato que já
  # aconteceu, e nada no consumidor tem motivo para alterá-lo.
  class Event
    LIFECYCLE_TYPES = {
      "br.com.magalu.logistica.driver.created.v1"        => :created,
      "br.com.magalu.logistica.driver.updated.v1"        => :updated,
      "br.com.magalu.logistica.driver.status_changed.v1" => :status_changed
    }.freeze

    class UnknownType < StandardError; end

    attr_reader :id, :source, :type, :driver_id, :sequence, :occurred_at, :state

    # Decodifica um envelope CloudEvents (Hash com chaves string).
    def self.from_cloud_event(envelope)
      type = envelope.fetch("type")
      raise UnknownType, "tipo desconhecido: #{type}" unless LIFECYCLE_TYPES.key?(type)

      new(
        id:          envelope.fetch("id"),
        source:      envelope.fetch("source"),
        type:        type,
        driver_id:   envelope.fetch("subject"),
        # `sequence` viaja como string no contrato para preservar precisão em
        # consumidores JavaScript. Aqui vira Integer — comparar versões como
        # string daria "10" < "9", que é o tipo de bug que não aparece em teste
        # com números de um dígito.
        sequence:    Integer(envelope.fetch("sequence")),
        occurred_at: envelope.fetch("time"),
        state:       envelope.fetch("data").fetch("driver")
      )
    end

    def initialize(id:, source:, type:, driver_id:, sequence:, occurred_at:, state:)
      @id          = id
      @source      = source
      @type        = type
      @driver_id   = driver_id
      @sequence    = sequence
      @occurred_at = occurred_at
      @state       = state.freeze
      freeze
    end

    def kind = LIFECYCLE_TYPES.fetch(@type)

    # Chave de deduplicação. O CloudEvents define (source, id) como
    # identificador único do evento — não existe chave de idempotência
    # separada, para não haver duas verdades sobre a mesma decisão.
    def dedupe_key = [@source, @id]

    def status = @state["status"]

    def to_h
      { id: @id, source: @source, type: @type, driver_id: @driver_id,
        sequence: @sequence, occurred_at: @occurred_at, state: @state }
    end

    def ==(other)
      other.is_a?(Event) && to_h == other.to_h
    end
    alias eql? ==

    def hash = to_h.hash

    def inspect
      "#<Event #{kind} driver=#{@driver_id[0, 8]} seq=#{@sequence} id=#{@id[0, 8]}>"
    end
  end
end
