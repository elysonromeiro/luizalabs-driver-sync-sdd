# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "ultra_sync"
require_relative "support/factories"

REPO_ROOT = File.expand_path("../..", __dir__)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.example_status_persistence_file_path = ".rspec_status"
  config.filter_run_when_matching :focus

  # Specs marcados :pg exigem o Postgres do docker-compose. Em vez de falhar
  # quando ele não está no ar, são pulados com mensagem clara — quem clona o
  # repositório consegue rodar a suíte inteira sem Docker e ver o que sobra.
  config.before(:suite) do
    next unless RSpec.world.all_example_groups.any? { |g| g.metadata[:pg] }

    unless UltraSync.postgres_available?
      RSpec.configure do |c|
        c.filter_run_excluding :pg
      end
      warn "\n  [pg] Postgres indisponível em #{UltraSync::Store::Postgres.connection_params[:host]}:" \
           "#{UltraSync::Store::Postgres.connection_params[:port]} — specs :pg serão pulados."
      warn "       Suba com: docker compose up -d\n\n"
    end
  end
end
