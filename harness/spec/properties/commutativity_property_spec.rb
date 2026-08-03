# frozen_string_literal: true

require_relative "generators"

# INVARIANTE — não remova, não marque skip, não relaxe a asserção.
#
# É a propriedade que responde diretamente ao requisito de "tratamento de
# atualizações simultâneas do mesmo entregador emitidas fora de ordem".
#
# Se ela vale, reordenação deixa de ser um problema a tratar: o pipeline pode
# entregar na ordem que quiser. É também o que torna seguro separar status e
# perfil em canais distintos (ADR-005), já que canais diferentes não têm
# ordem entre si.
RSpec.describe "Invariante: comutatividade sob reordenação", :invariant do
  it "apply(S) == apply(shuffle(S)), para qualquer S" do
    PropertyCheck.forall(iterations: 200) do |events|
      reference = UltraSync::Store::Memory.new
      UltraSync::EventApplier.new(store: reference).apply_all(events)

      5.times do |i|
        shuffled = UltraSync::Store::Memory.new
        UltraSync::EventApplier.new(store: shuffled)
          .apply_all(events.shuffle(random: Random.new(i)))

        expect(Generators.final_state(shuffled)).to eq(Generators.final_state(reference))
      end
    end
  end

  it "a ordem inversa produz o mesmo estado que a ordem de emissão" do
    PropertyCheck.forall(iterations: 200) do |events|
      forward = UltraSync::Store::Memory.new
      UltraSync::EventApplier.new(store: forward).apply_all(events)

      backward = UltraSync::Store::Memory.new
      UltraSync::EventApplier.new(store: backward).apply_all(events.reverse)

      expect(Generators.final_state(backward)).to eq(Generators.final_state(forward))
    end
  end

  # O estado final converge em qualquer ordem, mas o CAMINHO não é o mesmo:
  # entregar em ordem inversa faz quase tudo ser descartado como stale.
  #
  # Isso não é defeito — é a razão de o `partitionkey` ser o driver_id. A
  # ordenação por partição não é necessária para corretude, e sim para não
  # desperdiçar trabalho. Registrar a diferença aqui evita que alguém conclua,
  # da propriedade acima, que a chave de partição é dispensável.
  it "entregar em ordem reduz o volume de eventos descartados como stale" do
    PropertyCheck.forall(iterations: 50) do |events|
      in_order = events.sort_by { |e| [e.driver_id, e.sequence] }

      ordered_stale = UltraSync::EventApplier
                      .new(store: UltraSync::Store::Memory.new)
                      .apply_all(in_order).count(:stale)

      reversed_stale = UltraSync::EventApplier
                       .new(store: UltraSync::Store::Memory.new)
                       .apply_all(in_order.reverse).count(:stale)

      expect(ordered_stale).to eq(0)
      expect(reversed_stale).to be >= ordered_stale
    end
  end
end
