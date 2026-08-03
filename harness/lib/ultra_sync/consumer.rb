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
    # Payload que não conforma com o contrato. Erro permanente por definição:
    # nenhuma retentativa conserta um schema violado.
    class SchemaViolation < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super("payload rejeitado pelo contrato: #{errors.map { _1['pointer'] }.join(', ')}")
      end
    end

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

    attr_reader :breaker, :stats, :dead_letters, :eligibility_decisions

    def initialize(applier:, breaker: CircuitBreaker.new, backoff: Backoff.new,
                   transient_errors: TRANSIENT_ERRORS,
                   validator: SchemaValidator.default,
                   policy: EligibilityPolicy.new)
      @applier          = applier
      @breaker          = breaker
      @backoff          = backoff
      @transient_errors = transient_errors
      @validator        = validator
      @policy           = policy
      # Decisões de elegibilidade emitidas ao motor de despacho. Só é
      # acrescentada quando a escrita foi EFETIVA — é este o efeito colateral
      # que justifica o applier devolver desfecho em vez de booleano, e até a
      # revisão ele não existia no código, o que tornava a justificativa
      # hipotética.
      @eligibility_decisions = []
      @dead_letters     = []
      @paused           = false
      @stats            = Stats.new(processed: 0, dead_lettered: 0, paused_count: 0,
                                    resumed_count: 0, retries: 0, committed_offset: -1)
    end

    def paused? = @paused

    # Desfechos que autorizam avançar o offset — a ÚNICA porta de saída.
    #
    # Ser lista explícita, e não `unless :paused`, é o que torna a regra
    # verificável: incluir `:paused` aqui commitaria o offset de mensagens que
    # ainda serão reentregues, e elas sumiriam na retomada. `bin/mutate` aplica
    # exatamente essa mutação.
    #
    # Havia aqui um segundo guard, `break if outcome == :paused`, que tornava
    # esta verificação inalcançável — os únicos desfechos restantes já eram
    # committable. A mutação sobreviveu justamente por isso, e apontar código
    # morto é um resultado tão útil quanto apontar teste faltando.
    COMMITTABLE = %i[processed dead_lettered].freeze

    # Processa um lote. Devolve o offset até onde é seguro commitar.
    #
    # Ao pausar, o offset NÃO avança: as mensagens do lote em diante voltarão a
    # ser entregues quando o consumo retomar. É isso que preserva a ordem sem
    # gerar trabalho de reconciliação.
    def process_batch(messages)
      messages.each do |message|
        break if @paused
        break unless COMMITTABLE.include?(handle(message))

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
          outcome = @breaker.call { @applier.apply(event) }
          @stats.processed += 1
          # Só reavalia quando a projeção AVANÇOU. Reavaliar em :duplicate ou
          # :stale emitiria oferta repetida ao despacho — exatamente o efeito
          # que a comparação estrita `<` existe para evitar.
          reevaluate_eligibility(event) if outcome == :applied
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
    #
    # A validação contra o contrato acontece AQUI, na borda, antes de aplicar.
    # Sem ela o código `schema_validation_failed` do dead letter era
    # inalcançável — e código de falha inalcançável é pior que ausente, porque
    # descreve uma proteção que quem lê o contrato acredita existir.
    def decode(message)
      type = message[:payload]["type"]
      unless @validator.known_type?(type)
        dead_letter(message, Event::UnknownType.new("tipo desconhecido: #{type}"),
                    code: "unknown_event_type")
        return nil
      end

      errors = @validator.validate(message[:payload])
      if errors.any?
        dead_letter(message, SchemaViolation.new(errors), code: "schema_validation_failed",
                             schema_errors: errors)
        return nil
      end

      Event.from_cloud_event(message[:payload])
    rescue Event::UnknownType, KeyError, TypeError => e
      dead_letter(message, e, code: "unknown_event_type")
      nil
    end

    def reevaluate_eligibility(event)
      result = @policy.evaluate(event.state)
      @eligibility_decisions << {
        driver_id: event.driver_id,
        sequence:  event.sequence,
        eligible:  result.eligible?,
        reasons:   result.reasons
      }
    end

    def dead_letter(message, error, code: "policy_evaluation_error", schema_errors: nil)
      failure = {
        "code"         => code,
        "message"      => error.message,
        "attempts"     => 1,
        "offset"       => message[:offset],
        "source_topic" => message[:topic]
      }
      failure["schema_errors"] = schema_errors if schema_errors

      @dead_letters << {
        "dead_lettered_at" => Time.now.utc.iso8601,
        "consumer"         => "ultra-rapida.driver-sync",
        "failure"          => failure,
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
