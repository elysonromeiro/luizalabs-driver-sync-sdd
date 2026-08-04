# frozen_string_literal: true

require_relative "support"

RSpec.describe "Guardrails" do

  describe "ferramentas de proteção" do
    %w[generate mutate test_inventory schema_compat coupled_change check_docs].each do |tool|
      it "bin/#{tool} existe e é executável" do
        path = File.join(GuardrailPaths.harness, "bin", tool)

        expect(File.exist?(path)).to be(true), "bin/#{tool} sumiu"
        expect(File.executable?(path)).to be(true), "bin/#{tool} perdeu a permissão de execução"
      end
    end
  end

  describe "inventário de invariantes" do
    let(:lock) { File.join(GuardrailPaths.harness, "spec/guardrails/invariants.lock") }

    it "o lock existe e está versionado" do
      expect(File.exist?(lock)).to be(true)
    end

    it "cobre um número plausível de invariantes" do
      entries = JSON.parse(File.read(lock))

      # Limite inferior deliberado. Esvaziar o lock faria `--check` passar
      # trivialmente — nada removido de uma lista vazia. Este exemplo é o que
      # torna esse contorno visível.
      expect(entries.size).to be >= 40,
                              "o lock encolheu para #{entries.size} entradas; " \
                              "um lock vazio faz o guardrail passar sem proteger nada"
    end

    it "nenhuma invariante está registrada como desabilitada" do
      disabled = JSON.parse(File.read(lock)).select { _1["pending"] }

      expect(disabled).to be_empty,
                          "invariantes congeladas em estado pendente: #{disabled.map { _1['name'] }}"
    end
  end

  describe "mutações" do
    it "toda mutação aponta para um trecho que ainda existe no código" do
      # Uma mutação cujo trecho sumiu não testa nada e passa despercebida como
      # "morta". Este exemplo transforma isso em falha.
      listing, status = Open3.capture2e(
        File.join(GuardrailPaths.harness, "bin/mutate"), "--list", chdir: GuardrailPaths.harness
      )
      expect(status).to be_success

      files = listing.lines.map { _1.split(/\s{2,}/).first.to_s.strip }.reject(&:empty?)
      expect(files).not_to be_empty

      files.uniq.each do |file|
        expect(File.exist?(File.join(GuardrailPaths.harness, file))).to be(true), "mutação aponta para #{file}, que não existe"
      end
    end
  end

  describe "isolamento do código inseguro" do
    # `unsafe_write` escreve sem comparar versão. Existe só para demonstrar o
    # lost update. Se vazar para o caminho de produção, a proteção inteira cai.
    it "unsafe_write não é chamado por nenhum outro arquivo de lib/" do
      offenders = Dir[File.join(GuardrailPaths.harness, "lib/**/*.rb")].reject do |path|
        path.end_with?("store/memory.rb")
      end.select { |path| File.read(path).include?("unsafe_write") }

      expect(offenders).to be_empty,
                           "unsafe_write vazou para: #{offenders.map { _1.sub("#{GuardrailPaths.harness}/", '') }}"
    end
  end

  describe "cobertura das invariantes por módulo crítico" do
    # Cada arquivo que concentra corretude precisa ser exercitado por ao menos
    # uma invariante. Um módulo crítico sem invariante é um ponto cego que os
    # demais guardrails não enxergam.
    it "todo módulo crítico aparece em algum spec marcado :invariant" do
      invariant_sources = Dir[File.join(GuardrailPaths.harness, "spec/**/*_spec.rb")]
                          .select { |path| File.read(path).include?(":invariant") }
                          .map { |path| File.read(path) }
                          .join("\n")

      critical = {
        "EventApplier"     => "event_applier.rb",
        "EligibilityPolicy" => "eligibility_policy.rb",
        "DispatchRules"    => "dispatch_rules.rb",
        "BatchProcessor"   => "batch_processor.rb",
        "Consumer"         => "consumer.rb",
        "CircuitBreaker"   => "circuit_breaker.rb"
      }

      uncovered = critical.reject { |konstant, _| invariant_sources.include?(konstant) }

      expect(uncovered).to be_empty,
                           "sem invariante que os exercite: #{uncovered.values.join(', ')}"
    end
  end
end
