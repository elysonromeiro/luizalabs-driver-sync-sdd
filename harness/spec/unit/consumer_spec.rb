# frozen_string_literal: true

# Testes rápidos do consumidor, sem broker.
#
# Existem porque `bin/mutate` os exigiu. As mutações "offset avança em mensagem
# que será retentada" e "breaker nunca abre" SOBREVIVERAM à suíte rápida: a
# proteção existia apenas em spec/messaging, que é :kafka e não roda em cada
# PR. Um guardrail que só age quando o Docker está no ar protege menos do que
# parece.
RSpec.describe UltraSync::Consumer do
  let(:driver_id) { Factories.uuid }
  let(:store)     { UltraSync::Store::Memory.new }

  # Applier controlável: falha de forma transitória enquanto `available` for
  # falso, sem depender de banco nem de rede.
  let(:applier) do
    Class.new do
      attr_accessor :available

      def initialize(store)
        @inner     = UltraSync::EventApplier.new(store: store)
        @available = true
      end

      def apply(event)
        raise Errno::ECONNREFUSED, "dependência indisponível" unless @available

        @inner.apply(event)
      end
    end.new(store)
  end

  def message(sequence, offset:, type: nil)
    payload = Factories.cloud_event(driver_id: driver_id, sequence: sequence)
    payload = payload.merge("type" => type) if type
    { offset: offset, topic: "drivers.status.v1", payload: payload }
  end

  def consumer(threshold: 3, max_attempts: 4)
    described_class.new(
      applier: applier,
      breaker: UltraSync::CircuitBreaker.new(threshold: threshold, reset_after: 0.0),
      backoff: UltraSync::Backoff.immediate(max_attempts: max_attempts)
    )
  end

  describe "caminho feliz" do
    it "processa e avança o offset" do
      subject = consumer
      offset = subject.process_batch([message(1, offset: 0), message(2, offset: 1)])

      expect(offset).to eq(1)
      expect(subject.stats.processed).to eq(2)
      expect(store.fetch(driver_id).source_version).to eq(2)
    end
  end

  describe "sob indisponibilidade", :invariant do
    it "abre o breaker e pausa em vez de gerar dead letter" do
      subject = consumer(threshold: 2)
      applier.available = false

      subject.process_batch([message(1, offset: 0), message(2, offset: 1)])

      aggregate_failures do
        expect(subject.breaker).to be_open
        expect(subject).to be_paused
        expect(subject.dead_letters).to be_empty
      end
    end

    # Esta é a mutação que sobreviveu. Commitar o offset de uma mensagem que
    # ainda será retentada faz ela sumir na retomada — perda silenciosa de
    # dado, do tipo que só aparece em produção como divergência inexplicada.
    it "NÃO avança o offset de mensagem que será retentada" do
      subject = consumer(threshold: 2)
      applier.available = false

      offset = subject.process_batch([message(1, offset: 0), message(2, offset: 1)])

      expect(offset).to eq(-1), "offset avançou apesar de nada ter sido processado"
      expect(subject.stats.committed_offset).to eq(-1)
    end

    it "interrompe o lote na primeira falha, para não entregar fora de ordem" do
      subject = consumer(threshold: 99, max_attempts: 2)   # breaker nunca abre
      applier.available = false

      subject.process_batch([message(1, offset: 0), message(2, offset: 1), message(3, offset: 2)])

      # Nenhuma mensagem processada e offset intacto: seguir para a segunda
      # depois de falhar na primeira aplicaria versões fora de ordem.
      expect(subject.stats.processed).to eq(0)
      expect(subject.stats.committed_offset).to eq(-1)
    end

    it "retoma do mesmo offset quando a dependência volta" do
      subject = consumer(threshold: 2)
      batch = [message(1, offset: 0), message(2, offset: 1), message(3, offset: 2)]

      applier.available = false
      subject.process_batch(batch)
      expect(subject).to be_paused

      applier.available = true
      subject.breaker.record_success
      subject.resume!
      offset = subject.process_batch(batch)

      expect(offset).to eq(2)
      expect(store.fetch(driver_id).source_version).to eq(3)
      expect(subject.dead_letters).to be_empty
    end
  end

  describe "defeito permanente de payload" do
    it "gera dead letter e segue adiante, sem pausar" do
      subject = consumer
      subject.process_batch([message(1, offset: 0, type: "br.com.magalu.logistica.driver.exploded.v1")])

      aggregate_failures do
        expect(subject.dead_letters.size).to eq(1)
        expect(subject.dead_letters.first.dig("failure", "code")).to eq("unknown_event_type")
        expect(subject).not_to be_paused
        expect(subject.breaker).to be_closed
        expect(subject.stats.committed_offset).to eq(0)   # avança: a mensagem foi resolvida
      end
    end

    it "não conta veneno de payload como falha de dependência" do
      subject = consumer(threshold: 2)
      3.times do |i|
        subject.process_batch(
          [message(i + 1, offset: i, type: "br.com.magalu.logistica.driver.exploded.v1")]
        )
      end

      # Três defeitos seguidos não abrem o breaker. Se abrissem, um punhado de
      # mensagens malformadas travaria o consumo de tudo o mais.
      expect(subject.breaker).to be_closed
      expect(subject).not_to be_paused
      expect(subject.stats.dead_lettered).to eq(3)
    end
  end
end
