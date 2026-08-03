# frozen_string_literal: true

RSpec.describe UltraSync::Event do
  let(:driver_id) { Factories.uuid }

  describe ".from_cloud_event" do
    it "decodifica um envelope CloudEvents completo" do
      envelope = Factories.cloud_event(driver_id: driver_id, sequence: 7, kind: :status_changed)
      event = described_class.from_cloud_event(envelope)

      expect(event.driver_id).to eq(driver_id)
      expect(event.sequence).to eq(7)
      expect(event.kind).to eq(:status_changed)
      expect(event.source).to eq(Factories::SOURCE)
    end

    # `sequence` viaja como string no contrato, para preservar precisão em
    # consumidores JavaScript. Se o consumidor esquecer de converter, a
    # comparação de versão passa a ser lexicográfica — e "10" < "9" é verdade
    # em string. O bug some em teste com números de um dígito, então este
    # exemplo usa dois.
    it "converte sequence para Integer, não deixa como string" do
      envelope = Factories.cloud_event(driver_id: driver_id, sequence: 10)
      event = described_class.from_cloud_event(envelope)

      expect(event.sequence).to be_a(Integer)
      expect(event.sequence).to eq(10)
      expect(event.sequence).to be > 9
    end

    it "rejeita tipo desconhecido em vez de aplicar às cegas" do
      envelope = Factories.cloud_event(driver_id: driver_id, sequence: 1)
      envelope["type"] = "br.com.magalu.logistica.driver.exploded.v1"

      expect { described_class.from_cloud_event(envelope) }
        .to raise_error(described_class::UnknownType, /exploded/)
    end
  end

  describe "#dedupe_key" do
    it "é o par (source, id) definido pelo CloudEvents" do
      event = Factories.event(driver_id: driver_id, sequence: 1)
      expect(event.dedupe_key).to eq([event.source, event.id])
    end

    it "distingue o mesmo id vindo de sources diferentes" do
      id = Factories.uuid
      a = Factories.event(driver_id: driver_id, sequence: 1, id: id, source: "/portal-a")
      b = Factories.event(driver_id: driver_id, sequence: 1, id: id, source: "/portal-b")

      expect(a.dedupe_key).not_to eq(b.dedupe_key)
    end
  end

  it "é imutável — um fato que já aconteceu não muda" do
    event = Factories.event(driver_id: driver_id, sequence: 1)

    expect(event).to be_frozen
    expect { event.state["status"] = "blocked" }.to raise_error(FrozenError)
  end
end
