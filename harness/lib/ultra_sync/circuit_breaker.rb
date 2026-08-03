# frozen_string_literal: true

require "monitor"

module UltraSync
  # Circuit breaker de três estados, conforme docs/03-resiliencia.md.
  #
  # A particularidade deste breaker não está na máquina de estados — está no
  # que ele faz ao abrir. Em arquitetura de requisição-resposta, abrir
  # significa falhar rápido. Aqui significa PAUSAR o consumo (ADR-008): o log
  # do Kafka já é a fila durável, então não avançar o offset preserva ordem e
  # não gera trabalho de replay.
  #
  # A transição por meio-aberto existe para não trocar uma avalanche por outra:
  # fechar direto faria o consumidor retomar com todo o backlog contra um banco
  # recém-recuperado.
  class CircuitBreaker
    include MonitorMixin

    class Opened < StandardError; end

    STATES = %i[closed open half_open].freeze

    attr_reader :state, :failure_count, :transitions

    def initialize(threshold: 5, reset_after: 30.0, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      super()
      @threshold     = threshold
      @reset_after   = reset_after
      @clock         = clock
      @state         = :closed
      @failure_count = 0
      @opened_at     = nil
      # Trilha das transições. Existe para que o teste assere sobre ESTADO
      # OBSERVÁVEL em vez de sobre tempo decorrido — asserção temporal é a
      # origem mais comum de teste de resiliência flaky.
      @transitions   = []
    end

    def closed?    = synchronize { @state == :closed }
    def open?      = synchronize { @state == :open }
    def half_open? = synchronize { @state == :half_open }

    def record_success
      synchronize do
        @failure_count = 0
        transition_to(:closed) unless @state == :closed
      end
    end

    def record_failure
      synchronize do
        @failure_count += 1
        transition_to(:open) if @state != :open && @failure_count >= @threshold
        @state
      end
    end

    # Chamado pelo laço de consumo. Devolve true quando é hora de tentar um
    # probe — o que move o breaker para meio-aberto.
    def probe_due?
      synchronize do
        return false unless @state == :open
        return false if @clock.call - @opened_at < @reset_after

        transition_to(:half_open)
        true
      end
    end

    # Envolve uma chamada a dependência externa.
    def call
      raise Opened, "circuit breaker aberto" if open?

      result = yield
      record_success
      result
    rescue StandardError => e
      raise if e.is_a?(Opened)

      record_failure
      raise
    end

    private

    def transition_to(next_state)
      raise ArgumentError, "estado inválido: #{next_state}" unless STATES.include?(next_state)

      @opened_at = @clock.call if next_state == :open
      @transitions << [@state, next_state]
      @state = next_state
    end
  end
end
