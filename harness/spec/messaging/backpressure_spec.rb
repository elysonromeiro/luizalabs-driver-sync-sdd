# frozen_string_literal: true

require_relative "../support/kafka"

# A tese mais contrariável do SDD, contra Kafka real.
#
# ADR-008 afirma que, sob degradação de dependência, PAUSAR o consumo é melhor
# que falhar rápido. É uma afirmação que soa errada para quem vem de
# arquitetura de requisição-resposta, e afirmação assim precisa de prova.
#
# Todas as asserções são sobre ESTADO OBSERVÁVEL — breaker aberto, consumidor
# pausado, offset congelado, DLQ vazia, lag calculado a partir das marcas
# d'água do broker. Nenhuma depende de quanto tempo passou, porque asserção
# temporal é a origem mais comum de teste de resiliência flaky, e seria
# incoerente pregar "guardrail flaky não é guardrail" e entregar um.
RSpec.describe "Kafka: backpressure sob degradação", :kafka do
  let(:topic)     { KafkaHelper.unique_topic("drivers.status") }
  let(:driver_id) { Factories.uuid }
  let(:store)     { UltraSync::Store::Memory.new }

  # Dependência que falha de forma transitória — o banco da Ultra-rápida fora.
  let(:failing_applier) do
    Class.new do
      attr_accessor :available
      attr_reader :applied

      def initialize(store)
        @inner = UltraSync::EventApplier.new(store: store)
        @available = true
        @applied = 0
      end

      def apply(event)
        raise Errno::ECONNREFUSED, "postgres indisponível" unless @available

        @applied += 1
        @inner.apply(event)
      end
    end.new(store)
  end

  before { KafkaHelper.create_topic!(topic) }

  # Consumidores rdkafka precisam ser fechados sempre. Se o exemplo falha antes
  # do close, o finalizador roda em trap context e polui a saída com um
  # ThreadError que não tem nada a ver com o teste.
  after do
    @kafka_consumers.to_a.each { |c| c.close rescue nil }
    KafkaHelper.close_producer!
  end

  def kafka_consumer(group)
    @kafka_consumers ||= []
    consumer = KafkaHelper.consumer(group: group)
    @kafka_consumers << consumer
    consumer
  end

  def publish(count, from: 1)
    (from...(from + count)).each do |sequence|
      KafkaHelper.produce!(
        topic,
        key:     driver_id,
        payload: Factories.cloud_event(driver_id: driver_id, sequence: sequence)
      )
    end
  end

  def poll_batch(consumer, count)
    KafkaHelper.drain(consumer, count: count).map do |message|
      { offset: message.offset, topic: message.topic, payload: JSON.parse(message.payload) }
    end
  end

  it "para de consumir e NÃO gera dead letter quando a dependência cai" do
    publish(20)

    breaker  = UltraSync::CircuitBreaker.new(threshold: 3, reset_after: 0.0)
    consumer = UltraSync::Consumer.new(applier: failing_applier, breaker: breaker,
                                        backoff: UltraSync::Backoff.immediate(max_attempts: 4))
    kafka    = kafka_consumer("backpressure-#{Process.pid}")
    kafka.subscribe(topic)

    batch = poll_batch(kafka, 20)
    expect(batch.size).to be >= 10, "não chegou mensagem suficiente para o cenário"

    # Dependência cai antes do processamento.
    failing_applier.available = false
    consumer.process_batch(batch)

    aggregate_failures "estado após a queda da dependência" do
      expect(breaker).to be_open
      expect(consumer).to be_paused
      expect(consumer.stats.paused_count).to eq(1)

      # O ponto central: nada foi para a DLQ. Indisponibilidade não é defeito
      # de payload, e tratá-la como tal trocaria um problema temporário por
      # trabalho permanente de reconciliação.
      expect(consumer.dead_letters).to be_empty
      expect(consumer.stats.dead_lettered).to eq(0)

      # E o offset não avançou: as mensagens continuam no log, em ordem.
      expect(consumer.stats.committed_offset).to eq(-1)
    end

  end

  it "o lag cresce durante a pausa — e é ele o sinal honesto" do
    publish(15)

    kafka = kafka_consumer("lag-#{Process.pid}")
    kafka.subscribe(topic)
    batch = poll_batch(kafka, 15)

    breaker  = UltraSync::CircuitBreaker.new(threshold: 2, reset_after: 0.0)
    consumer = UltraSync::Consumer.new(applier: failing_applier, breaker: breaker,
                                        backoff: UltraSync::Backoff.immediate(max_attempts: 4))
    failing_applier.available = false
    consumer.process_batch(batch)

    expect(consumer).to be_paused

    # Nenhum offset commitado ⇒ o lag é a altura total do log. Um consumidor
    # que consumisse e falhasse pareceria saudável, com lag baixo e DLQ
    # crescendo; o pausado mostra exatamente a métrica que descreve a
    # realidade.
    lag = KafkaHelper.lag_for(kafka, topic)
    expect(lag).to be >= batch.size

  end

  it "retoma do mesmo offset e drena o backlog quando a dependência volta" do
    publish(12)

    kafka = kafka_consumer("resume-#{Process.pid}")
    kafka.subscribe(topic)
    batch = poll_batch(kafka, 12)
    expect(batch.size).to be >= 5

    breaker  = UltraSync::CircuitBreaker.new(threshold: 2, reset_after: 0.0)
    consumer = UltraSync::Consumer.new(applier: failing_applier, breaker: breaker,
                                        backoff: UltraSync::Backoff.immediate(max_attempts: 4))

    failing_applier.available = false
    consumer.process_batch(batch)
    expect(consumer).to be_paused
    expect(store.all).to be_empty

    # Dependência volta. O probe move o breaker para meio-aberto e o consumo
    # retoma — do MESMO lote, porque o offset nunca avançou.
    failing_applier.available = true
    expect(breaker.probe_due?).to be(true)
    breaker.record_success
    consumer.resume!

    consumer.process_batch(batch)

    aggregate_failures "estado após a retomada" do
      expect(consumer).not_to be_paused
      expect(consumer.stats.resumed_count).to eq(1)
      expect(breaker).to be_closed
      expect(consumer.dead_letters).to be_empty

      # Nenhum evento perdido: a projeção alcançou a maior versão do lote.
      highest = batch.map { |m| m[:payload]["sequence"].to_i }.max
      expect(store.fetch(driver_id).source_version).to eq(highest)
    end

  end

  it "payload com defeito permanente VAI para a DLQ, ao contrário da indisponibilidade" do
    # A contraparte necessária. Se tudo fosse pausa, a DLQ não existiria e um
    # veneno travaria o pipeline para sempre.
    KafkaHelper.produce!(
      topic, key: driver_id,
      payload: Factories.cloud_event(driver_id: driver_id, sequence: 1)
                        .merge("type" => "br.com.magalu.logistica.driver.exploded.v1")
    )

    kafka = kafka_consumer("poison-#{Process.pid}")
    kafka.subscribe(topic)
    batch = poll_batch(kafka, 1)

    consumer = UltraSync::Consumer.new(applier: failing_applier,
                                        backoff: UltraSync::Backoff.immediate)
    consumer.process_batch(batch)

    aggregate_failures "veneno de payload" do
      expect(consumer.dead_letters.size).to eq(1)
      expect(consumer.dead_letters.first.dig("failure", "code")).to eq("unknown_event_type")
      expect(consumer).not_to be_paused          # segue adiante, não trava
      expect(consumer.breaker).to be_closed      # não conta como falha de dependência
    end

  end
end
