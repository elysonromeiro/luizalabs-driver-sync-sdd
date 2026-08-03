# frozen_string_literal: true

RSpec.describe UltraSync::BatchProcessor do
  let(:store)   { UltraSync::Store::Memory.new }
  let(:subject) { described_class.new(store: store) }

  describe "#collapse", :invariant do
    it "mantém apenas o evento de maior sequence por entregador" do
      a = Factories.uuid
      b = Factories.uuid
      events = [
        Factories.event(driver_id: a, sequence: 2),
        Factories.event(driver_id: b, sequence: 7),
        Factories.event(driver_id: a, sequence: 5),
        Factories.event(driver_id: a, sequence: 1),
        Factories.event(driver_id: b, sequence: 3)
      ]

      collapsed = subject.collapse(events)

      expect(collapsed.size).to eq(2)
      expect(collapsed.to_h { |e| [e.driver_id, e.sequence] }).to eq(a => 5, b => 7)
    end

    # Mutação que sobreviveu à suíte rápida: remover o `sort_by`. A garantia
    # existia apenas em spec/concurrency/pg_batch_spec.rb, que é :pg e não roda
    # em cada PR.
    #
    # Sem ordem canônica, dois lotes com interseção escrita em ordens opostas
    # formam ciclo de lock e o Postgres aborta um deles — erro intermitente sob
    # carga, caro de diagnosticar.
    it "devolve em ordem canônica de driver_id, para prevenir deadlock" do
      ids = Array.new(8) { Factories.uuid }
      events = ids.shuffle.map { |id| Factories.event(driver_id: id, sequence: 1) }

      collapsed = subject.collapse(events)
      driver_ids = collapsed.map(&:driver_id)

      expect(driver_ids).to eq(driver_ids.sort),
                            "lote fora de ordem canônica — duas transações com interseção " \
                            "podem adquirir locks em ordens opostas e deadlockar"
    end

    it "a ordem canônica independe da ordem de chegada" do
      ids = Array.new(6) { Factories.uuid }
      events = ids.map { |id| Factories.event(driver_id: id, sequence: 1) }

      forward  = subject.collapse(events).map(&:driver_id)
      backward = subject.collapse(events.reverse).map(&:driver_id)

      expect(forward).to eq(backward)
    end
  end

  describe "#process" do
    it "aplica apenas a maior versão e reporta duplicatas" do
      driver_id = Factories.uuid
      first  = Factories.event(driver_id: driver_id, sequence: 1)
      second = Factories.event(driver_id: driver_id, sequence: 4)

      result = subject.process([first, second, first])

      expect(result.applied.map(&:sequence)).to eq([4])
      expect(result.duplicates.size).to eq(1)
      expect(store.fetch(driver_id).source_version).to eq(4)
    end

    it "emite um número constante de queries, independentemente do tamanho" do
      counts = [5, 50, 200].map do |size|
        store.reset!
        events = Array.new(size) { Factories.event(driver_id: Factories.uuid, sequence: 1) }
        store.reset_query_count!
        subject.process(events)
        store.query_count
      end

      expect(counts.uniq.size).to eq(1),
                                  "a contagem de queries variou com o tamanho do lote: #{counts.inspect}"
    end
  end
end
