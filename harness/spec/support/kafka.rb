# frozen_string_literal: true

require "rdkafka"
require "json"

# Utilitários mínimos de Kafka para os specs :kafka.
#
# Nomes de tópico são únicos por execução. Sem isso, um teste herdaria o estado
# do anterior e passaria ou falharia dependendo da ordem — que é ruído, e ruído
# em teste de mensageria é como se ganha fama de flaky.
module KafkaHelper
  module_function

  BROKERS = ENV.fetch("KAFKA_BROKERS", "127.0.0.1:59092")

  def unique_topic(prefix)
    "#{prefix}.#{Process.pid}.#{(Time.now.to_f * 1000).to_i}"
  end

  def producer
    Rdkafka::Config.new(
      "bootstrap.servers" => BROKERS,
      "acks"              => "all",
      "enable.idempotence" => true
    ).producer
  end

  def consumer(group:, offset: "earliest", extra: {})
    Rdkafka::Config.new({
      "bootstrap.servers"  => BROKERS,
      "group.id"           => group,
      "auto.offset.reset"  => offset,
      "enable.auto.commit" => false,
      "session.timeout.ms" => 6000
    }.merge(extra)).consumer
  end

  def admin
    Rdkafka::Config.new("bootstrap.servers" => BROKERS).admin
  end

  # Cria tópico e ESPERA os metadados propagarem. Produzir num tópico
  # recém-criado sem esperar é a principal causa de intermitência nestes testes.
  def create_topic!(name, partitions: 1, config: {})
    client = admin
    client.create_topic(name, partitions, 1, config).wait
    30.times do
      break if client.metadata(name, 3000).topics.any? { |t| t[:topic_name] == name }

      sleep 0.1
    end
    client.close
    name
  end

  def produce!(topic, key:, payload:, headers: {})
    handle = producer_pool.produce(
      topic: topic, key: key, payload: JSON.generate(payload), headers: headers
    )
    handle.wait
  end

  def producer_pool
    @producer_pool ||= producer
  end

  def close_producer!
    @producer_pool&.close
    @producer_pool = nil
  end

  # Consome até `count` mensagens ou até esgotar o tempo. Devolve o que
  # conseguiu — os specs asserem sobre o conteúdo, não sobre ter chegado
  # exatamente no prazo.
  def drain(consumer, count:, timeout_ms: 10_000)
    collected = []
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (timeout_ms / 1000.0)

    while collected.size < count && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      message = consumer.poll(500)
      next unless message

      collected << message
    end

    collected
  end

  # Lag do consumer group: quantas mensagens existem além do offset commitado.
  def lag_for(consumer, topic, partition: 0)
    committed = consumer.committed
    tpl = committed.to_h[topic]
    committed_offset = tpl&.find { |p| p.partition == partition }&.offset || 0

    _low, high = consumer.query_watermark_offsets(topic, partition, 5000)
    high - committed_offset
  end
end
