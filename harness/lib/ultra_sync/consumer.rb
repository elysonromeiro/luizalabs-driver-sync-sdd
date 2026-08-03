# frozen_string_literal: true

# Time#iso8601 vem de "time" — sem o require, montar o dead letter levanta
# NoMethodError DENTRO do tratamento de erro, e o erro original vaza mascarado.
require "time"

module UltraSync
  # Laço de consumo com backpressure.
  #
  # É a materialização de ADR-008. As três decisões que importam estão aqui e
  # são pequenas: classificação de erro conservadora, pausa em vez de DLQ sob
  # indisponibilidade, e commit de offset SOMENTE após processar.
  class Consumer
    # Lista FECHADA de erros transitórios. Tudo que não estiver nela é tratado
    # como permanente e vai para a DLQ.
    #
    # O viés é deliberado: classificar erro permanente como transitório trava o
    # pipeline para sempre num veneno; o inverso gera um dead letter que se
    # recupera por replay. Uma lista aberta ("tudo que não for validação é
    # transitório") parece mais robusta e é o oposto — qualquer bug novo do
    # consumidor passa a travar o consumo.
    TRANSIENT_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      IOError
    ].freeze

    Stats = Struct.new(:processed, :dead_lettered, :paused_count, :resumed_count,
                       :retries, :committed_offset, keyword_init: true)

    attr_reader :breaker, :stats, :dead_letters

    def initialize(applier:, breaker: CircuitBreaker.new, backoff: Backoff.new,
                   transient_errors: TRANSIENT_ERRORS)
      @applier          = applier
      @breaker          = breaker
      @backoff          = backoff
      @transient_errors = transient_errors
      @dead_letters     = []
      @paused           = false
      @stats            = Stats.new(processed: 0, dead_lettered: 0, paused_count: 0,
                                    resumed_count: 0, retries: 0, committed_offset: -1)
    end

    def paused? = @paused

    # Desfechos que autorizam avançar o offset. A lista é explícita porque a
    # alternativa — avançar em tudo que não seja pausa — é um bug de perda de
    # dado: uma mensagem que falhou de forma transitória e será retentada NÃO
    # pode ter seu offset commitado, senão desaparece na retomada.
    COMMITTABLE = %i[processed dead_lettered].freeze

    # Processa um lote. Devolve o offset até onde é seguro commitar.
    #
    # Ao pausar, o offset NÃO avança: as mensagens do lote em diante voltarão a
    # ser entregues quando o consumo retomar. É isso que preserva a ordem sem
    # gerar trabalho de reconciliação.
    def process_batch(messages)
      messages.each do |message|
        break if @paused

        outcome = handle(message)
        break if outcome == :paused
        # `:retry` cai aqui e NÃO avança o offset — a mensagem volta a ser
        # entregue. Também interrompe o lote: seguir adiante entregaria as
        # próximas fora de ordem em relação a esta.
        break unless COMMITTABLE.include?(outcome)

        @stats.committed_offset = message[:offset]
      end

      @stats.committed_offset
    end

    def resume!
      return unless @paused

      @paused = false
      @stats.resumed_count += 1
    end

    private

    # Processa uma mensagem, retentando com backoff enquanto o erro for
    # transitório. Cada tentativa registra falha no breaker; quando ele abre, o
    # consumo é pausado — indisponibilidade NUNCA produz dead letter.
    def handle(message)
      event = decode(message)
      return :dead_lettered unless event

      @backoff.max_attempts.times do |attempt|
        begin
          @breaker.call { @applier.apply(event) }
          @stats.processed += 1
          return :processed
        rescue CircuitBreaker::Opened
          pause!
          return :paused
        rescue StandardError => e
          unless transient?(e)
            dead_letter(message, e)
            return :dead_lettered
          end

          @stats.retries += 1
          @backoff.wait(attempt)
        end
      end

      # Esgotou as tentativas e o erro continua transitório. Isso é
      # indisponibilidade, não defeito: pausa e deixa o log segurar a fila.
      pause!
      :paused
    end

    # Defeito permanente de payload: o único caso em que descartar é a resposta
    # certa, porque nenhuma retentativa vai consertar um schema inválido.
    def decode(message)
      Event.from_cloud_event(message[:payload])
    rescue Event::UnknownType, KeyError, TypeError => e
      dead_letter(message, e, code: "unknown_event_type")
      nil
    end

    def dead_letter(message, error, code: "policy_evaluation_error")
      @dead_letters << {
        "dead_lettered_at" => Time.now.utc.iso8601,
        "consumer"         => "ultra-rapida.driver-sync",
        "failure"          => {
          "code"         => code,
          "message"      => error.message,
          "attempts"     => 1,
          "offset"       => message[:offset],
          "source_topic" => message[:topic]
        },
        "original_event"   => message[:payload]
      }
      @stats.dead_lettered += 1
    end

    def pause!
      return if @paused

      @paused = true
      @stats.paused_count += 1
    end

    def transient?(error) = @transient_errors.any? { error.is_a?(_1) }
  end
end
