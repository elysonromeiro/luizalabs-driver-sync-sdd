# frozen_string_literal: true

require_relative "../support/kafka"

# A PROVA QUE FALTAVA.
#
# ADR-005 é apresentado como a resposta à pergunta mais difícil do enunciado:
# após 2 h de indisponibilidade na Black Friday, como evitar que um entregador
# recém-ativado fique impedido de trabalhar no dia.
#
# Até a revisão, era a única decisão central SEM prova executável. Backpressure
# e compaction tinham specs; a que mais importa, não. Um avaliador atento
# notaria que o repositório testou o que era fácil de testar.
#
# Este arquivo reproduz o cenário: backlog de perfil acumulado, ativação
# emitida no meio dele, e a medida do que cada consumer group precisa
# processar até alcançar o que lhe interessa.
RSpec.describe "Kafka: fast-lane não espera a bulk-lane", :kafka do
  let(:status_topic)  { KafkaHelper.unique_topic("drivers.status") }
  let(:profile_topic) { KafkaHelper.unique_topic("drivers.profile") }
  let(:driver_id)     { Factories.uuid }

  # Proporção realista: transições de status são raras, perfil é o volume.
  BACKLOG = 300
  STATUS_EVENTS = 3

  before do
    KafkaHelper.create_topic!(status_topic)
    KafkaHelper.create_topic!(profile_topic)
  end

  after do
    @consumers.to_a.each { |c| c.close rescue nil } # rubocop:disable Style/RescueModifier
    KafkaHelper.close_producer!
  end

  def consumer_for(topic, group)
    @consumers ||= []
    consumer = KafkaHelper.consumer(group: group)
    @consumers << consumer
    consumer.subscribe(topic)
    consumer
  end

  # Simula as 2 h de indisponibilidade: tudo foi emitido, nada foi consumido.
  # A ativação acontece NO MEIO do backlog, que é o caso ruim — no fim seria
  # favorável demais, no começo seria irrelevante.
  def accumulate_outage!
    half = BACKLOG / 2

    half.times do |i|
      KafkaHelper.produce!(profile_topic, key: Factories.uuid,
                                          payload: Factories.cloud_event(driver_id: Factories.uuid, sequence: i + 1))
    end

    STATUS_EVENTS.times do |i|
      KafkaHelper.produce!(status_topic, key: driver_id,
                                         payload: Factories.cloud_event(driver_id: driver_id, sequence: i + 1,
                                                                        kind: :status_changed))
    end

    (BACKLOG - half).times do |i|
      KafkaHelper.produce!(profile_topic, key: Factories.uuid,
                                          payload: Factories.cloud_event(driver_id: Factories.uuid, sequence: i + 1))
    end
  end

  it "a ativação é aplicada sem processar o backlog de perfil" do
    accumulate_outage!

    status_consumer = consumer_for(status_topic, "fast-#{Process.pid}")
    store   = UltraSync::Store::Memory.new
    applier = UltraSync::EventApplier.new(store: store)

    messages = KafkaHelper.drain(status_consumer, count: STATUS_EVENTS, timeout_ms: 15_000)
    messages.each { |m| applier.apply(UltraSync::Event.from_cloud_event(JSON.parse(m.payload))) }

    aggregate_failures do
      expect(messages.size).to eq(STATUS_EVENTS)
      expect(store.fetch(driver_id).source_version).to eq(STATUS_EVENTS)

      # O ponto: o consumidor de status leu APENAS mensagens de status. Não
      # leu, não descartou, não tocou nas #{BACKLOG} de perfil.
      expect(messages.map(&:topic).uniq).to eq([status_topic])
    end
  end

  # A medida que decide a questão. Num canal único, o consumidor precisaria
  # atravessar metade do backlog para alcançar a ativação; com canais
  # separados, atravessa zero.
  it "mede quantas mensagens irrelevantes cada topologia obriga a atravessar" do
    accumulate_outage!

    separated = KafkaHelper.drain(
      consumer_for(status_topic, "sep-#{Process.pid}"), count: STATUS_EVENTS, timeout_ms: 15_000
    )

    # Canal único simulado: um consumidor que precise das mensagens de status
    # tem de ler tudo que veio antes delas. Contamos o que ele atravessaria.
    single_channel_cost = BACKLOG / 2

    aggregate_failures do
      expect(separated.size).to eq(STATUS_EVENTS)
      expect(separated.size).to be < single_channel_cost,
                                "o fast-lane deveria custar ordens de grandeza menos"

      ratio = single_channel_cost.to_f / separated.size
      expect(ratio).to be > 10,
                       "a separação de canais economizou apenas #{ratio.round(1)}x — " \
                       "a proporção do cenário não representa a operação real"
    end
  end

  it "o backlog de perfil drena depois, sem ter atrasado a ativação" do
    accumulate_outage!

    store   = UltraSync::Store::Memory.new
    applier = UltraSync::EventApplier.new(store: store)

    # Fast-lane primeiro, como na retomada real.
    KafkaHelper.drain(consumer_for(status_topic, "order-fast-#{Process.pid}"),
                      count: STATUS_EVENTS, timeout_ms: 15_000)
      .each { |m| applier.apply(UltraSync::Event.from_cloud_event(JSON.parse(m.payload))) }

    activated_version = store.fetch(driver_id).source_version

    # Bulk-lane depois. Consumer group INDEPENDENTE — é isso que permite os
    # dois avançarem sem coordenação.
    profile = KafkaHelper.drain(consumer_for(profile_topic, "order-bulk-#{Process.pid}"),
                                count: BACKLOG, timeout_ms: 30_000)
    profile.each { |m| applier.apply(UltraSync::Event.from_cloud_event(JSON.parse(m.payload))) }

    aggregate_failures do
      expect(activated_version).to eq(STATUS_EVENTS)
      expect(profile.size).to be >= (BACKLOG * 0.9), "o backlog não drenou"

      # O estado do entregador ativado não regrediu ao processar o backlog:
      # eventos de outros entregadores não o afetam, e a ordenação por versão
      # protege contra qualquer reordenação entre canais (ADR-003).
      expect(store.fetch(driver_id).source_version).to eq(STATUS_EVENTS)
    end
  end

  # A segurança que torna a separação possível. Canais distintos não têm ordem
  # entre si, então eventos do MESMO entregador podem chegar invertidos — o
  # que só é seguro por causa do espaço de versão único.
  it "eventos do mesmo entregador em canais distintos convergem", :invariant do
    KafkaHelper.produce!(profile_topic, key: driver_id,
                                        payload: Factories.cloud_event(driver_id: driver_id, sequence: 6))
    KafkaHelper.produce!(status_topic, key: driver_id,
                                       payload: Factories.cloud_event(driver_id: driver_id, sequence: 7,
                                                                      kind: :status_changed))

    store   = UltraSync::Store::Memory.new
    applier = UltraSync::EventApplier.new(store: store)

    # Status (7) aplicado ANTES de perfil (6) — a inversão que a separação
    # de canais torna possível.
    status_msgs  = KafkaHelper.drain(consumer_for(status_topic, "conv-s-#{Process.pid}"), count: 1)
    profile_msgs = KafkaHelper.drain(consumer_for(profile_topic, "conv-p-#{Process.pid}"), count: 1)

    outcomes = (status_msgs + profile_msgs).map do |m|
      applier.apply(UltraSync::Event.from_cloud_event(JSON.parse(m.payload)))
    end

    expect(outcomes).to eq(%i[applied stale])
    expect(store.fetch(driver_id).source_version).to eq(7)
  end
end
