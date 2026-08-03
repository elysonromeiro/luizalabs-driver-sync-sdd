# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "ultra_sync"
require_relative "support/factories"

REPO_ROOT = File.expand_path("../..", __dir__)

# Specs marcados :pg exigem o Postgres do docker-compose. A disponibilidade é
# decidida AQUI, no carregamento, e não num hook before(:suite): o filtro de
# exclusão precisa existir antes de os grupos serem registrados, senão os
# exemplos rodam e falham em vez de serem pulados.
#
# Quem clona o repositório roda a suíte inteira sem Docker e vê o que sobra,
# com uma mensagem dizendo o que está faltando e como obter.
# ULTRASYNC_ENUMERATE_ALL faz o carregamento ignorar a disponibilidade das
# dependências e registrar TODOS os exemplos.
#
# Existe para os guardrails que contam exemplos (`bin/test_inventory`,
# documented_numbers_spec). Sem isso, a contagem depende de quais serviços
# estão no ar: no job `fast` do CI, sem Docker, os exemplos :pg e :kafka são
# filtrados e o inventário conclui que invariantes foram REMOVIDAS. O
# guardrail acusava o ambiente em vez do código.
#
# Seguro porque quem usa esta variável roda com --dry-run: os exemplos são
# enumerados, nunca executados, então nenhuma conexão é aberta.
ENUMERATE_ALL   = ENV["ULTRASYNC_ENUMERATE_ALL"] == "1"
PG_AVAILABLE    = ENUMERATE_ALL || UltraSync.postgres_available?
KAFKA_AVAILABLE = ENUMERATE_ALL || UltraSync.kafka_available?

if !PG_AVAILABLE && !ENUMERATE_ALL
  params = UltraSync::Store::Postgres.connection_params
  warn ""
  warn "  [pg] Postgres indisponível em #{params[:host]}:#{params[:port]} — specs :pg serão pulados."
  warn "       Para rodá-los:  docker compose up -d"
  warn ""
end

if !KAFKA_AVAILABLE && !ENUMERATE_ALL
  warn ""
  warn "  [kafka] Broker indisponível em #{ENV.fetch('KAFKA_BROKERS', '127.0.0.1:59092')} — specs :kafka serão pulados."
  warn "          Para rodá-los:  docker compose up -d"
  warn ""
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.example_status_persistence_file_path = ".rspec_status"
  config.filter_run_when_matching :focus
  config.filter_run_excluding(:pg) unless PG_AVAILABLE
  config.filter_run_excluding(:kafka) unless KAFKA_AVAILABLE
end
