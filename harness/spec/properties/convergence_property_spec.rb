# frozen_string_literal: true

require_relative "generators"

# INVARIANTE — não remova, não marque skip, não relaxe a asserção.
#
# Convergência é a propriedade que sustenta o fan-out da Seção Especialista.
# Se N consumidores independentes, recebendo o mesmo conjunto de eventos em
# ordens e agrupamentos diferentes, chegam ao mesmo estado, então adicionar
# uma plataforma ao ecossistema não exige coordenação nenhuma com as demais.
RSpec.describe "Invariante: convergência entre consumidores", :invariant do
  it "N réplicas com o mesmo conjunto convergem, qualquer que seja a ordem" do
    PropertyCheck.forall(iterations: 150) do |events|
      states = Array.new(4) do |i|
        store = UltraSync::Store::Memory.new
        UltraSync::EventApplier.new(store: store)
          .apply_all(events.shuffle(random: Random.new(i * 7919)))
        Generators.final_state(store)
      end

      expect(states.uniq.size).to eq(1)
    end
  end

  # Um consumidor que processa em lote e outro que processa evento a evento
  # precisam chegar ao mesmo lugar. Sem isso, a otimização de lote seria uma
  # mudança de comportamento disfarçada de mudança de desempenho.
  it "processamento em lote converge com processamento individual" do
    PropertyCheck.forall(iterations: 150) do |events|
      one_by_one = UltraSync::Store::Memory.new
      UltraSync::EventApplier.new(store: one_by_one).apply_all(events)

      batched = UltraSync::Store::Memory.new
      processor = UltraSync::BatchProcessor.new(store: batched)
      events.each_slice(7) { |slice| processor.process(slice) }

      expect(Generators.final_state(batched)).to eq(Generators.final_state(one_by_one))
    end
  end

  # A convergência de ESTADO não basta: o lote também precisa CLASSIFICAR os
  # eventos como o caminho individual classificaria. A contagem de duplicatas
  # alimenta métrica, e uma métrica que discorda do comportamento real é pior
  # que métrica nenhuma.
  #
  # Esta propriedade foi acrescentada depois de um teste unitário revelar que
  # duplicata DENTRO do mesmo lote não era contabilizada — nem o
  # `ON CONFLICT DO NOTHING` do Postgres nem o adapter em memória distinguem
  # repetição da mesma chave na mesma instrução.
  it "o lote classifica duplicatas como o processamento individual classificaria" do
    PropertyCheck.forall(iterations: 150) do |events|
      rng       = Random.new(events.size)
      with_dups = Generators.with_duplicates(events, rng: rng)

      individual = UltraSync::EventApplier.new(store: UltraSync::Store::Memory.new)
                                          .apply_all(with_dups).count(:duplicate)

      result = UltraSync::BatchProcessor.new(store: UltraSync::Store::Memory.new)
                                        .process(with_dups)

      expect(result.duplicates.size).to eq(individual)
    end
  end

  # Recuperação: um consumidor que ficou fora e depois recebe TUDO de novo
  # (replay a partir do offset zero) precisa chegar ao mesmo estado de quem
  # nunca caiu. É a garantia que torna o plano de DR seguro.
  it "replay completo converge com consumo contínuo" do
    PropertyCheck.forall(iterations: 150) do |events|
      continuous = UltraSync::Store::Memory.new
      UltraSync::EventApplier.new(store: continuous).apply_all(events)

      # Réplica que perdeu metade e depois reprocessou o log inteiro.
      recovered = UltraSync::Store::Memory.new
      recovered_applier = UltraSync::EventApplier.new(store: recovered)
      recovered_applier.apply_all(events.first(events.size / 2))
      recovered_applier.apply_all(events)

      expect(Generators.final_state(recovered)).to eq(Generators.final_state(continuous))
    end
  end
end
