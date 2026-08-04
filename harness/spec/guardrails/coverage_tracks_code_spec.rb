# frozen_string_literal: true

require_relative "support"

RSpec.describe "Guardrails: cobertura acompanha o código" do

  # Módulos sem lógica de corretude a proteger. Ficar de fora é decisão
  # explícita, não esquecimento — que é a diferença que este spec impõe.
  EXEMPT = {
    "event.rb"                  => "objeto de valor imutável, sem decisão",
    "projection.rb"             => "Struct sem comportamento; mutá-la não produz mutante observável",
    # As regras destes dois saíram do Ruby e viraram contracts/behavior/*.yaml.
    # As classes hoje só interpretam. Mutar a SPEC é o equivalente exato de
    # mutar o código de antes — e é o que bin/mutate faz.
    "eligibility_policy.rb"     => "interpretador; as regras são mutadas em contracts/behavior/eligibility.yaml",
    "dispatch_rules.rb"         => "interpretador; as regras são mutadas em contracts/behavior/dispatch.yaml",
    "backoff.rb"                => "cálculo puro, coberto por unit",
    "generated/driver_state.rb" => "gerado; protegido por bin/generate --check",
    "store/postgres.rb"         => "coberto pelas mutações do adapter em memória, que espelha a semântica"
  }.freeze

  def critical_files
    Dir[File.join(GuardrailPaths.in_harness("lib/ultra_sync"), "**/*.rb")]
      .map { _1.sub("#{GuardrailPaths.in_harness("lib/ultra_sync")}/", "") }
      .reject { |f| EXEMPT.key?(f) }
      .sort
  end

  it "todo módulo de lib/ tem mutação ou está isento com justificativa" do
    mutate = File.read(File.expand_path("../../bin/mutate", __dir__))

    uncovered = critical_files.reject { |f| mutate.include?("lib/ultra_sync/#{f}") }

    expect(uncovered).to be_empty,
                         "sem mutação e sem isenção declarada: #{uncovered.join(', ')}\n" \
                         "Acrescente uma mutação em bin/mutate ou uma isenção em EXEMPT, com o motivo."
  end

  it "todo módulo de lib/ está em coupled_change ou isento" do
    protected_list, = Open3.capture2(
      File.expand_path("../../bin/coupled_change", __dir__), "--list"
    )

    uncovered = critical_files.reject { |f| protected_list.include?("lib/ultra_sync/#{f}") }

    expect(uncovered).to be_empty,
                         "alteráveis sem exigir mudança em spec/: #{uncovered.join(', ')}"
  end

  it "as isenções apontam para arquivos que existem" do
    stale = EXEMPT.keys.reject { |f| File.exist?(File.join(GuardrailPaths.in_harness("lib/ultra_sync"), f)) }

    expect(stale).to be_empty, "isenção para arquivo inexistente: #{stale.join(', ')}"
  end
end
