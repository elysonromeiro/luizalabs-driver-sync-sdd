# frozen_string_literal: true

require_relative "generators"

# INVARIANTE — não remova, não marque skip, não relaxe a asserção.
RSpec.describe "Invariante: monotonicidade de versão", :invariant do
  it "source_version nunca decresce, em nenhum passo, para nenhum entregador" do
    PropertyCheck.forall(iterations: 200) do |events|
      store   = UltraSync::Store::Memory.new
      applier = UltraSync::EventApplier.new(store: store)
      seen    = Hash.new(0)

      events.each do |event|
        applier.apply(event)
        current = store.fetch(event.driver_id)&.source_version || 0

        expect(current).to be >= seen[event.driver_id]
        seen[event.driver_id] = current
      end
    end
  end

  it "a versão final é sempre a maior emitida para aquele entregador" do
    PropertyCheck.forall(iterations: 200) do |events|
      store = UltraSync::Store::Memory.new
      UltraSync::EventApplier.new(store: store).apply_all(events)

      expected = events.group_by(&:driver_id).transform_values { |es| es.map(&:sequence).max }
      actual   = store.all.to_h { |p| [p.driver_id, p.source_version] }

      expect(actual).to eq(expected)
    end
  end

  # Esta propriedade é a que distingue `<` de `<=` na escrita condicional.
  #
  # Foi adicionada DEPOIS de rodar a mutação e descobrir que as demais
  # propriedades não a pegavam: o gerador padrão produz versões estritamente
  # crescentes por entregador, então dois eventos distintos nunca compartilham
  # versão, e a diferença entre os operadores nunca se manifestava.
  #
  # O cenário aqui é uma fonte defeituosa emitindo dois fatos distintos com a
  # mesma versão. Com `<`, o segundo é corretamente descartado. Com `<=`, ele
  # sobrescreve o primeiro — e dispara uma reavaliação de elegibilidade a
  # mais, que pode virar oferta duplicada no motor de despacho.
  #
  # Usa `generator:` em vez de sortear internamente. A versão anterior fazia
  # `Random.new(Random.new_seed)` dentro do bloco, o que quebrava as três
  # garantias do harness de uma vez: o encolhimento minimizava a entrada
  # ignorada, o contraexemplo reportado não correspondia ao caso que falhou, e
  # `SEED=x` não reproduzia. Verificado empiricamente antes de corrigir — duas
  # execuções com a mesma seed produziam sequências diferentes.
  it "aplica no máximo um evento por (entregador, versão), mesmo se a fonte colidir" do
    PropertyCheck.forall(
      iterations: 200,
      generator: ->(rng) { Generators.colliding_versions(rng: rng) }
    ) do |events|
      store    = UltraSync::Store::Memory.new
      applier  = UltraSync::EventApplier.new(store: store)
      outcomes = events.zip(applier.apply_all(events))

      applied = outcomes.select { |_event, outcome| outcome == :applied }.map(&:first)
      keys    = applied.map { |e| [e.driver_id, e.sequence] }

      expect(keys.uniq.size).to eq(keys.size),
                                "duas aplicações para a mesma (entregador, versão): " \
                                "#{keys.tally.select { |_k, v| v > 1 }.keys.inspect}"
    end
  end
end
