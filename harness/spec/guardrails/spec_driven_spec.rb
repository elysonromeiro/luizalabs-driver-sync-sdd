# frozen_string_literal: true

require_relative "support"

RSpec.describe "Guardrails: spec-driven é verificável" do

  def repo(*parts) = File.join(GuardrailPaths.repo, *parts)

  # Nível 1: cada spec interpretada precisa ser lida por alguém em lib/.
  # Spec que ninguém lê é documentação se passando por comportamento.
  INTERPRETED = {
    "eligibility.yaml" => "eligibility_policy.rb",
    "dispatch.yaml"    => "dispatch_rules.rb",
    "lifecycle.yaml"   => "outbox.rb"
  }.freeze

  INTERPRETED.each do |spec_file, lib_file|
    it "#{spec_file} é realmente lido por #{lib_file}" do
      source = File.read(repo("harness/lib/ultra_sync", lib_file))

      expect(source).to include("behavior/#{spec_file}"),
                        "#{lib_file} não carrega #{spec_file} — a spec é decorativa"
    end
  end

  it "as classes interpretadoras não contêm regras codificadas" do
    # Se um id de regra aparece literal no Ruby, ele foi redigitado — e passa a
    # existir em dois lugares que podem divergir.
    offenders = INTERPRETED.filter_map do |spec_file, lib_file|
      spec = YAML.safe_load_file(repo("contracts/behavior", spec_file))
      ids  = (spec["rules"] || []).map { _1["id"] }
      next if ids.empty?

      source = File.read(repo("harness/lib/ultra_sync", lib_file))
      hardcoded = ids.select { |id| source.include?(%("#{id}")) || source.include?(":#{id}") }
      "#{lib_file}: #{hardcoded.join(', ')}" if hardcoded.any?
    end

    expect(offenders).to be_empty,
                         "regra redigitada em Ruby — passa a existir em dois lugares:\n  " +
                         offenders.join("\n  ")
  end

  it "toda spec de comportamento tem uma demonstração em bin/spec_drives" do
    demos = File.read(repo("harness/bin/spec_drives"))

    uncovered = Dir[repo("contracts/behavior/*.yaml")]
                .map { File.basename(_1) }
                .reject { |f| demos.include?("behavior/#{f}") }

    # applier.yaml é nível 3 (declarado e verificado), não interpretado —
    # mudá-lo não muda comportamento, então não cabe demonstração.
    expect(uncovered - ["applier.yaml"]).to be_empty,
                                            "spec sem demonstração de autoridade: #{uncovered.join(', ')}"
  end

  # Nível 3: o applier.yaml declara decisões que o código implementa. O
  # guardrail é o que impede a declaração de virar ficção.
  describe "applier.yaml declara e o código obedece" do
    let(:spec) { YAML.safe_load_file(repo("contracts/behavior/applier.yaml")) }
    let(:source) { File.read(repo("harness/lib/ultra_sync/event_applier.rb")) }

    it "os desfechos declarados são os que o applier devolve" do
      declared = spec.fetch("outcomes").keys.map(&:to_sym).sort

      expect(UltraSync::EventApplier::OUTCOMES.sort).to eq(declared)
    end

    it "a ordem das verificações é a declarada" do
      steps = spec.fetch("decisions").map { _1.fetch("step") }
      positions = steps.map { |s| source.index(s.split("_").last) }

      expect(positions.compact.size).to eq(steps.size),
                                        "passo declarado que não aparece no código: #{steps.inspect}"
      expect(positions).to eq(positions.sort),
                           "a ordem no código difere da declarada em applier.yaml — " \
                           "e inverter dedupe e versão não quebra nenhum teste de estado final"
    end

    it "o operador de comparação é o declarado" do
      operator = spec.fetch("version_comparison").fetch("operator")
      memory = File.read(repo("harness/lib/ultra_sync/store/memory.rb"))
      postgres = File.read(repo("harness/lib/ultra_sync/store/postgres.rb"))

      expect(operator).to eq("<")
      expect(postgres).to include("source_version < EXCLUDED.source_version")
      expect(memory).to include("current.source_version >= source_version")
    end
  end
end
