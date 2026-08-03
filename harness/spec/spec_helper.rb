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
PG_AVAILABLE = UltraSync.postgres_available?

unless PG_AVAILABLE
  params = UltraSync::Store::Postgres.connection_params
  warn ""
  warn "  [pg] Postgres indisponível em #{params[:host]}:#{params[:port]} — specs :pg serão pulados."
  warn "       Para rodá-los:  docker compose up -d"
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
end
