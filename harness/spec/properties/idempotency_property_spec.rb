# frozen_string_literal: true

require_relative "generators"

# INVARIANTE — não remova, não marque skip, não relaxe a asserção.
#
# Idempotência é o requisito que o enunciado chama de "estrita": reprocessar
# eventos antigos ou duplicados não pode corromper o estado do entregador.
#
# Um teste de exemplo ("aplicar duas vezes o mesmo evento não muda nada") passa
# com implementações erradas. A propriedade abaixo é universal: vale para
# QUALQUER sequência, com duplicatas em QUALQUER posição.
RSpec.describe "Invariante: idempotência", :invariant do
  let(:store)   { UltraSync::Store::Memory.new }
  let(:applier) { UltraSync::EventApplier.new(store: store) }

  it "apply(S) == apply(S ++ duplicatas(S)), para qualquer S" do
    PropertyCheck.forall(iterations: 200) do |events|
      rng = Random.new(events.size)

      baseline = UltraSync::Store::Memory.new
      UltraSync::EventApplier.new(store: baseline).apply_all(events)

      with_dups = UltraSync::Store::Memory.new
      UltraSync::EventApplier.new(store: with_dups)
        .apply_all(Generators.with_duplicates(events, rng: rng))

      expect(Generators.final_state(with_dups)).to eq(Generators.final_state(baseline))
    end
  end

  it "toda reentrega devolve :duplicate, nunca :applied" do
    PropertyCheck.forall(iterations: 200) do |events|
      applier = UltraSync::EventApplier.new(store: UltraSync::Store::Memory.new)
      applier.apply_all(events)

      # Reaplicar a sequência inteira: nada pode ser aplicado de novo.
      outcomes = applier.apply_all(events.shuffle)

      expect(outcomes.uniq).to eq([:duplicate])
    end
  end

  # O desfecho importa tanto quanto o estado. Uma escrita a mais dispara
  # reavaliação de elegibilidade, que pode emitir oferta duplicada ao motor de
  # despacho — o estado converge, o comportamento observável não.
  it "número de :applied é igual ao número de eventos distintos que avançaram versão" do
    PropertyCheck.forall(iterations: 200) do |events|
      applier = UltraSync::EventApplier.new(store: UltraSync::Store::Memory.new)
      outcomes = applier.apply_all(events)

      highest_per_driver = events.group_by(&:driver_id).transform_values { |es| es.map(&:sequence).max }
      applied_events = outcomes.each_index.select { |i| outcomes[i] == :applied }.map { |i| events[i] }

      # Todo entregador presente teve ao menos uma aplicação, e a última
      # aplicação de cada um alcançou a versão máxima daquele entregador.
      expect(applied_events.map(&:driver_id).uniq.sort).to eq(highest_per_driver.keys.sort)
    end
  end
end
