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

# Acrescentado em revisão. Dois achados que estes exemplos fecham:
#
# 1. `schema_validation_failed` estava no contrato e era INALCANÇÁVEL — nada
#    validava payload contra schema no consumo. Código de falha inalcançável é
#    pior que ausente: descreve uma proteção que quem lê o contrato acredita
#    existir.
#
# 2. A reavaliação de elegibilidade não existia. Ela é o efeito colateral usado
#    para justificar o applier devolver desfecho em vez de booleano, então a
#    justificativa era hipotética.
RSpec.describe "#{UltraSync::Consumer} — validação e elegibilidade" do
  let(:driver_id) { Factories.uuid }
  let(:store)     { UltraSync::Store::Memory.new }

  def consumer
    UltraSync::Consumer.new(
      applier: UltraSync::EventApplier.new(store: store),
      backoff: UltraSync::Backoff.immediate
    )
  end

  def message(payload, offset: 0)
    { offset: offset, topic: "drivers.profile.v1", payload: payload }
  end

  describe "validação contra o contrato", :invariant do
    it "rejeita payload que viola o schema, com o código correto" do
      payload = Factories.cloud_event(driver_id: driver_id, sequence: 2)
      payload["data"]["driver"]["vehicle"]["cargo_capacity_kg"] = 99_999   # acima do máximo

      subject = consumer
      subject.process_batch([message(payload)])

      failure = subject.dead_letters.first["failure"]
      aggregate_failures do
        expect(failure["code"]).to eq("schema_validation_failed")
        expect(failure["schema_errors"].map { _1["pointer"] })
          .to include("/data/driver/vehicle/cargo_capacity_kg")
        expect(store.fetch(driver_id)).to be_nil, "payload inválido foi aplicado à projeção"
      end
    end

    it "distingue tipo desconhecido de payload inválido" do
      unknown = Factories.cloud_event(driver_id: driver_id, sequence: 1)
                         .merge("type" => "br.com.magalu.logistica.driver.exploded.v1")

      subject = consumer
      subject.process_batch([message(unknown)])

      expect(subject.dead_letters.first.dig("failure", "code")).to eq("unknown_event_type")
    end

    it "aceita payload válido" do
      subject = consumer
      subject.process_batch([message(Factories.cloud_event(driver_id: driver_id, sequence: 1, kind: :created))])

      expect(subject.dead_letters).to be_empty
      expect(store.fetch(driver_id).source_version).to eq(1)
    end
  end

  describe "reavaliação de elegibilidade", :invariant do
    it "emite decisão quando a projeção avança" do
      subject = consumer
      subject.process_batch([message(Factories.cloud_event(driver_id: driver_id, sequence: 1, kind: :created))])

      expect(subject.eligibility_decisions.size).to eq(1)
      expect(subject.eligibility_decisions.first[:driver_id]).to eq(driver_id)
    end

    # O ponto que justifica a comparação estrita `<`. Reavaliar em duplicata
    # ou em evento stale emitiria oferta repetida ao motor de despacho — o
    # estado converge, o comportamento observável não.
    it "NÃO emite decisão em duplicata nem em evento stale" do
      subject = consumer
      envelope = Factories.cloud_event(driver_id: driver_id, sequence: 5)

      subject.process_batch([message(envelope, offset: 0)])
      expect(subject.eligibility_decisions.size).to eq(1)

      # mesma mensagem reentregue → :duplicate
      subject.process_batch([message(envelope, offset: 1)])
      # evento anterior chegando atrasado → :stale
      subject.process_batch([message(Factories.cloud_event(driver_id: driver_id, sequence: 3), offset: 2)])

      expect(subject.eligibility_decisions.size).to eq(1),
                                                   "reavaliou #{subject.eligibility_decisions.size} vezes — " \
                                                   "oferta duplicada chegaria ao despacho"
    end

    it "a decisão reflete a política da Ultra-rápida, não o status do Portal" do
      # Portal diz ativo; a Ultra-rápida recusa pessoa física.
      payload = Factories.cloud_event(
        driver_id: driver_id, sequence: 1, kind: :created,
        state: Factories.driver_state(driver_id: driver_id, status: "active", document_type: "cpf")
      )

      subject = consumer
      subject.process_batch([message(payload)])

      decision = subject.eligibility_decisions.first
      expect(decision[:eligible]).to be(false)
      expect(decision[:reasons]).to include(:individual_not_allowed)
    end
  end
end
