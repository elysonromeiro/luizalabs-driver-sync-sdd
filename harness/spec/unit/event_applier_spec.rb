# frozen_string_literal: true

RSpec.describe UltraSync::EventApplier do
  let(:store)     { UltraSync::Store::Memory.new }
  let(:applier)   { described_class.new(store: store) }
  let(:driver_id) { Factories.uuid }

  describe "#apply" do
    it "aplica um evento novo e avança a projeção" do
      event = Factories.event(driver_id: driver_id, sequence: 1, kind: :created)

      expect(applier.apply(event)).to eq(:applied)
      expect(store.fetch(driver_id).source_version).to eq(1)
    end

    it "reconhece reentrega do mesmo evento como duplicata" do
      event = Factories.event(driver_id: driver_id, sequence: 1)

      expect(applier.apply(event)).to eq(:applied)
      expect(applier.apply(event)).to eq(:duplicate)
    end

    it "descarta evento com sequence menor que a projetada" do
      applier.apply(Factories.event(driver_id: driver_id, sequence: 7))

      expect(applier.apply(Factories.event(driver_id: driver_id, sequence: 6))).to eq(:stale)
      expect(store.fetch(driver_id).source_version).to eq(7)
    end

    # Esta é a diferença entre `<` e `<=` na escrita condicional, e a razão de
    # o applier devolver desfecho em vez de booleano. Com estado completo, o
    # estado final é idêntico nos dois casos — só o desfecho distingue.
    it "descarta evento com sequence IGUAL à projetada" do
      applier.apply(Factories.event(driver_id: driver_id, sequence: 5))

      outcome = applier.apply(Factories.event(driver_id: driver_id, sequence: 5))

      expect(outcome).to eq(:stale)
    end

    it "deduplica antes de comparar versão" do
      event = Factories.event(driver_id: driver_id, sequence: 3)
      applier.apply(event)

      # Some com a projeção: se a comparação de versão viesse primeiro, o
      # evento seria reaplicado (não há versão corrente para barrá-lo). É a
      # deduplicação que o reconhece — caso comum após rebalanceamento com
      # offset não commitado.
      store.delete(driver_id)
      expect(store.fetch(driver_id)).to be_nil

      expect(applier.apply(event)).to eq(:duplicate)
      expect(store.fetch(driver_id)).to be_nil
    end

    it "trata entregadores distintos de forma independente" do
      other = Factories.uuid
      applier.apply(Factories.event(driver_id: driver_id, sequence: 9))

      expect(applier.apply(Factories.event(driver_id: other, sequence: 1))).to eq(:applied)
      expect(store.fetch(other).source_version).to eq(1)
      expect(store.fetch(driver_id).source_version).to eq(9)
    end

    it "não distingue tipos de evento no caminho de escrita" do
      # Todos carregam estado completo, então a origem não muda a regra.
      # É isso que torna seguro separá-los em canais distintos (ADR-005).
      expect(applier.apply(Factories.event(driver_id: driver_id, sequence: 1, kind: :created))).to eq(:applied)
      expect(applier.apply(Factories.event(driver_id: driver_id, sequence: 2, kind: :updated))).to eq(:applied)
      expect(applier.apply(Factories.event(driver_id: driver_id, sequence: 3, kind: :status_changed))).to eq(:applied)
    end
  end

  describe "#apply_all" do
    it "devolve os desfechos na ordem de entrada" do
      a = Factories.event(driver_id: driver_id, sequence: 2)
      b = Factories.event(driver_id: driver_id, sequence: 1)

      expect(applier.apply_all([a, b, a])).to eq(%i[applied stale duplicate])
    end
  end
end
