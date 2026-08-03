# frozen_string_literal: true

require "set"
require "concurrent"

require_relative "ultra_sync/generated/driver_state"
require_relative "ultra_sync/projection"
require_relative "ultra_sync/event"
require_relative "ultra_sync/schema_validator"
require_relative "ultra_sync/store/memory"
require_relative "ultra_sync/event_applier"
require_relative "ultra_sync/backoff"
require_relative "ultra_sync/circuit_breaker"
require_relative "ultra_sync/consumer"
require_relative "ultra_sync/eligibility_policy"
require_relative "ultra_sync/dispatch_rules"
require_relative "ultra_sync/batch_processor"
require_relative "ultra_sync/outbox"
require_relative "ultra_sync/reconciliation"

# Motor de Sincronização de Entregadores — harness executável.
#
# Isto não é a implementação de produção. É o conjunto mínimo de código
# necessário para que as invariantes do SDD sejam EXECUTÁVEIS em vez de
# afirmadas: idempotência, comutatividade sob reordenação, ausência de lost
# update e ausência de N+1.
#
# O adapter Postgres é carregado sob demanda para que a suíte default rode sem
# a gem `pg` estar disponível.
module UltraSync
  VERSION = "1.0.0"

  # Sonda de disponibilidade do broker.
  #
  # Silenciada de propósito. Quando o Kafka não está no ar — o caso normal no
  # job rápido do CI — a librdkafka despeja "Connection refused" no stderr e o
  # finalizador do cliente levanta ThreadError em trap context. Nada disso é
  # falha: é a sonda funcionando. Ruído numa saída de CI faz gente parar de ler
  # a saída, que é o custo real.
  def self.kafka_available?(brokers: ENV.fetch("KAFKA_BROKERS", "127.0.0.1:59092"))
    require "rdkafka"
    require "logger"

    previous_logger = Rdkafka::Config.logger
    Rdkafka::Config.logger = Logger.new(File::NULL)

    admin = Rdkafka::Config.new(
      "bootstrap.servers" => brokers,
      "socket.timeout.ms" => 2000,
      "log_level"         => 0
    ).admin

    begin
      admin.metadata(nil, 3000)
      true
    ensure
      # Fechar explicitamente evita que o finalizador rode em trap context.
      admin.close
    end
  rescue LoadError, StandardError
    false
  ensure
    Rdkafka::Config.logger = previous_logger if defined?(Rdkafka)
  end

  def self.postgres_store!(**opts)
    require_relative "ultra_sync/store/postgres"
    Store::Postgres.new(**opts)
  end

  def self.postgres_available?
    require_relative "ultra_sync/store/postgres"
    Store::Postgres.available?
  rescue LoadError
    false
  end
end
