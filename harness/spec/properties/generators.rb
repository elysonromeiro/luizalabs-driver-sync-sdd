# frozen_string_literal: true

# Property-based testing sem gem externa.
#
# A decisão de não usar `rantly` ou `propcheck` é sobre ENCOLHIMENTO, não sobre
# dependências. Bibliotecas genéricas encolhem bem valores escalares e mal
# sequências de eventos de domínio: o contraexemplo minimizado que elas
# produzem costuma ser uma sequência que não respeita as invariantes da fonte
# (versões não monotônicas, entregadores inventados no meio) e portanto não
# diagnostica nada — só distrai.
#
# O encolhimento aqui conhece o domínio: remove eventos preservando a estrutura
# de versionamento por entregador, e reporta a seed para reprodução exata.
module PropertyCheck
  class Falsified < StandardError
    attr_reader :counterexample, :seed, :iteration, :original

    def initialize(counterexample:, seed:, iteration:, original:, cause_message:)
      @counterexample = counterexample
      @seed = seed
      @iteration = iteration
      @original = original
      super(build_message(cause_message))
    end

    def build_message(cause_message)
      <<~MSG

        Propriedade falsificada na iteração #{@iteration} (seed: #{@seed})

          #{cause_message}

        Contraexemplo minimizado (#{@counterexample.size} evento(s), de #{@original.size} originais):
        #{format_events(@counterexample)}

        Para reproduzir exatamente:
          SEED=#{@seed} bundle exec rspec <arquivo>
      MSG
    end

    def format_events(events)
      events.map { |e| "  #{e.inspect}" }.join("\n")
    end
  end

  module_function

  # Executa `iterations` casos. Em caso de falha, encolhe o contraexemplo
  # antes de reportar.
  #
  # `generator:` permite trocar a forma dos casos mantendo seed, encolhimento
  # e reprodução. Antes disso, uma propriedade que precisasse de outra forma
  # de entrada gerava internamente com seed própria — e perdia as três coisas
  # de uma vez. Era o caso da propriedade de colisão de versão, justamente a
  # que existe para pegar a mutação mais sutil do repositório.
  def forall(iterations: 200, seed: nil, generator: nil, &property)
    seed ||= (ENV["SEED"] || Random.new_seed).to_i
    rng = Random.new(seed)

    iterations.times do |i|
      events = generator ? generator.call(rng) : yield_generator(rng)

      begin
        property.call(events)
      rescue StandardError => e
        minimal = shrink(events) { |candidate| fails?(candidate, &property) }
        raise Falsified.new(
          counterexample: minimal, seed: seed, iteration: i + 1,
          original: events, cause_message: e.message.lines.first.to_s.strip
        )
      end
    end
  end

  def fails?(events, &property)
    property.call(events)
    false
  rescue StandardError
    true
  end

  # Encolhimento guloso: tenta remover um evento por vez enquanto a falha
  # persistir. Converge para a menor subsequência que ainda falsifica.
  def shrink(events)
    current = events
    changed = true

    while changed && current.size > 1
      changed = false
      current.each_index do |i|
        candidate = current.dup
        candidate.delete_at(i)
        next if candidate.empty? || !yield(candidate)

        current = candidate
        changed = true
        break
      end
    end

    current
  end

  # Gerador de sequências de eventos, embutido para que `forall` seja
  # autocontido nos specs.
  def yield_generator(rng)
    Generators.event_sequence(rng: rng)
  end
end

module Generators
  module_function

  # Uma sequência como o Portal a emitiria: por entregador, versões
  # estritamente crescentes começando em 1. A ORDEM DO ARRAY é a ordem de
  # emissão; as propriedades embaralham a entrega, que é o que o pipeline faz.
  def event_sequence(rng:, max_drivers: 4, max_events_per_driver: 6)
    driver_count = 1 + rng.rand(max_drivers)
    drivers = Array.new(driver_count) { Factories.uuid(rng) }

    drivers.flat_map do |driver_id|
      count = 1 + rng.rand(max_events_per_driver)
      (1..count).map do |sequence|
        # `driver.created` tem `sequence` const "1" no contrato — é o primeiro
        # fato registrado sobre um entregador. Sortear o tipo livremente
        # produzia :created com sequence 3, que o schema RECUSARIA.
        #
        # Isso significava que as invariantes rodavam sobre eventos que a
        # produção nunca veria. Encontrado em revisão: o spec de conformidade
        # cobria as fábricas e não o gerador, que é o ponto cego óbvio em
        # retrospecto — o gerador é justamente o que produz volume.
        kind = sequence == 1 ? :created : %i[updated status_changed][rng.rand(2)]

        Factories.event(
          driver_id: driver_id,
          sequence:  sequence,
          kind:      kind,
          rng:       rng,
          state:     Factories.driver_state(
            driver_id: driver_id,
            rng:       rng,
            status:    %w[pending_approval active inactive blocked][rng.rand(4)],
            delivery_radius_km: rng.rand(1..50)
          )
        )
      end
    end.shuffle(random: rng)
  end

  # Duplicatas de eventos já presentes, embaralhadas junto — simula reentrega.
  def with_duplicates(events, rng:, ratio: 0.4)
    count = [(events.size * ratio).ceil, 1].max
    dups = Array.new(count) { events[rng.rand(events.size)] }
    (events + dups).shuffle(random: rng)
  end

  # Sequência com COLISÃO DE VERSÃO: eventos distintos (ids diferentes)
  # compartilhando o mesmo `sequence` para o mesmo entregador.
  #
  # Isso não deveria acontecer — a fonte incrementa o contador na mesma
  # transação que muda o estado. Mas "não deveria" não é garantia, e uma
  # migração que altere entregadores sem incrementar `sync_version` produz
  # exatamente isto. O consumidor precisa ser defensivo: no máximo uma
  # aplicação por (entregador, versão).
  def colliding_versions(rng:, drivers: 3, versions: 4, collisions: 2)
    Array.new(drivers) { Factories.uuid(rng) }.flat_map do |driver_id|
      (1..versions).flat_map do |sequence|
        Array.new(1 + rng.rand(collisions)) do
          Factories.event(
            driver_id: driver_id, sequence: sequence, rng: rng,
            state: Factories.driver_state(
              driver_id: driver_id, rng: rng,
              status: %w[active inactive blocked][rng.rand(3)]
            )
          )
        end
      end
    end.shuffle(random: rng)
  end

  # Estado final por entregador, para comparação entre execuções.
  def final_state(store)
    store.all.to_h { |p| [p.driver_id, [p.source_version, p.state]] }
  end
end
