# frozen_string_literal: true

# A garantia do lado produtor, executável.
#
# Estava só em prosa (ADR-002) até a revisão. A decisão que elimina a janela
# do dual-write era a única central sem prova, enquanto o lado consumidor
# tinha 130 exemplos.
RSpec.describe UltraSync::Outbox do
  let(:store)     { UltraSync::Store::Memory.new }
  let(:outbox)    { described_class.new(store: store) }
  let(:driver_id) { Factories.uuid }

  def state(**overrides) = Factories.driver_state(driver_id: driver_id, **overrides)

  describe "atomicidade", :invariant do
    it "estado e evento nascem juntos" do
      entry = outbox.record!(driver_id: driver_id, state: state, kind: :created)

      expect(store.fetch(driver_id).source_version).to eq(1)
      expect(entry.sequence).to eq(1)
      expect(entry.driver_id).to eq(driver_id)
    end

    it "não existe evento sem estado correspondente" do
      3.times { |i| outbox.record!(driver_id: driver_id, state: state(status: "active"), kind: i.zero? ? :created : :updated) }

      projected = store.fetch(driver_id).source_version
      emitted   = outbox.all.map(&:sequence).max

      expect(emitted).to eq(projected),
                         "o log anuncia versão #{emitted} e o estado está em #{projected}"
    end

    it "não existe estado sem evento correspondente" do
      2.times { |i| outbox.record!(driver_id: driver_id, state: state, kind: i.zero? ? :created : :updated) }

      expect(outbox.all.map(&:sequence)).to eq([1, 2])
    end
  end

  describe "geração de sequence", :invariant do
    # A afirmação central de ADR-003: o contador é incrementado na mesma
    # transação que muda o estado, então não precisa de sequence separada nem
    # de lock explícito.
    it "incrementa monotonicamente por entregador" do
      5.times { |i| outbox.record!(driver_id: driver_id, state: state, kind: i.zero? ? :created : :updated) }

      expect(outbox.all.map(&:sequence)).to eq([1, 2, 3, 4, 5])
    end

    it "é por entregador, não global — 300 mil entidades não contendem" do
      other = Factories.uuid
      outbox.record!(driver_id: driver_id, state: state, kind: :created)
      outbox.record!(driver_id: other, state: Factories.driver_state(driver_id: other), kind: :created)
      outbox.record!(driver_id: driver_id, state: state, kind: :updated)

      by_driver = outbox.all.group_by(&:driver_id).transform_values { |e| e.map(&:sequence) }

      expect(by_driver[driver_id]).to eq([1, 2])
      expect(by_driver[other]).to eq([1]), "o contador vazou entre entregadores"
    end

    it "escritores concorrentes no mesmo entregador recebem versões distintas" do
      barrier = Concurrent::CyclicBarrier.new(12)
      threads = Array.new(12) do
        Thread.new do
          barrier.wait
          outbox.record!(driver_id: driver_id, state: state, kind: :updated)
        end
      end
      threads.each(&:join)

      sequences = outbox.all.map(&:sequence)
      expect(sequences.sort).to eq((1..12).to_a),
                                "versões duplicadas ou puladas: #{sequences.sort.inspect}"
    end
  end

  describe "classificação de canal (ADR-005)", :invariant do
    it "transição de status vai para o fast-lane" do
      entry = outbox.record!(driver_id: driver_id, state: state(status: "blocked"), kind: :status_changed)

      expect(entry.channel).to eq(described_class::FAST_LANE)
    end

    it "criação e alteração de perfil vão para a bulk-lane" do
      created = outbox.record!(driver_id: driver_id, state: state, kind: :created)
      updated = outbox.record!(driver_id: driver_id, state: state, kind: :updated)

      expect([created.channel, updated.channel]).to all(eq(described_class::BULK_LANE))
    end

    it "todo tipo do ciclo de vida tem canal declarado" do
      # Sem isto, adicionar um evento novo sem classificá-lo levantaria
      # KeyError em produção, no primeiro evento daquele tipo.
      kinds = UltraSync::Event::LIFECYCLE_TYPES.values

      expect(described_class::CHANNEL_BY_KIND.keys.sort).to eq(kinds.sort)
    end
  end

  describe "relay at-least-once" do
    it "publica em ordem de inserção" do
      4.times { |i| outbox.record!(driver_id: Factories.uuid, state: state, kind: :created) }

      expect(outbox.pending.map(&:id)).to eq([1, 2, 3, 4])
    end

    it "só sai da fila depois de confirmado pelo broker" do
      entry = outbox.record!(driver_id: driver_id, state: state, kind: :created)

      expect(outbox.pending).to eq([entry])
      outbox.mark_published!(entry)
      expect(outbox.pending).to be_empty
    end

    it "republicação usa o MESMO event_id — é o que torna a retentativa segura" do
      entry = outbox.record!(driver_id: driver_id, state: state, kind: :created)
      first_id = entry.event_id

      # Relay falha após o produce e antes de marcar; republica.
      expect(outbox.pending.first.event_id).to eq(first_id)

      # O consumidor deduplica pelo par (source, id).
      applier = UltraSync::EventApplier.new(store: UltraSync::Store::Memory.new)
      event = Factories.event(driver_id: driver_id, sequence: entry.sequence, id: entry.event_id)

      expect(applier.apply(event)).to eq(:applied)
      expect(applier.apply(event)).to eq(:duplicate)
    end
  end

  describe "métrica de alerta do produtor" do
    it "reporta a idade da linha não publicada mais antiga" do
      expect(outbox.oldest_pending_age).to be_nil

      entry = outbox.record!(driver_id: driver_id, state: state, kind: :created)
      age = outbox.oldest_pending_age(now: Time.now.utc + 90)

      expect(age).to be_within(2).of(90)

      outbox.mark_published!(entry)
      expect(outbox.oldest_pending_age).to be_nil
    end
  end
end
