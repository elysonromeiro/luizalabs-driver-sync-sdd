# frozen_string_literal: true

require "json"
require "open3"

# Meta-testes: verificam as PROTEÇÕES, não o comportamento do sistema.
#
# São a camada que percebe quando os outros guardrails deixam de existir. Sem
# eles, apagar `bin/mutate` ou esvaziar o lock de invariantes seria uma
# mudança silenciosa — e a suíte continuaria verde reportando segurança que
# não existe mais.
RSpec.describe "Guardrails" do
  HARNESS = File.expand_path("../..", __dir__)

  describe "ferramentas de proteção" do
    %w[generate mutate test_inventory schema_compat coupled_change check_docs].each do |tool|
      it "bin/#{tool} existe e é executável" do
        path = File.join(HARNESS, "bin", tool)

        expect(File.exist?(path)).to be(true), "bin/#{tool} sumiu"
        expect(File.executable?(path)).to be(true), "bin/#{tool} perdeu a permissão de execução"
      end
    end
  end

  describe "inventário de invariantes" do
    let(:lock) { File.join(HARNESS, "spec/guardrails/invariants.lock") }

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
        File.join(HARNESS, "bin/mutate"), "--list", chdir: HARNESS
      )
      expect(status).to be_success

      files = listing.lines.map { _1.split(/\s{2,}/).first.to_s.strip }.reject(&:empty?)
      expect(files).not_to be_empty

      files.uniq.each do |file|
        expect(File.exist?(File.join(HARNESS, file))).to be(true), "mutação aponta para #{file}, que não existe"
      end
    end
  end

  describe "isolamento do código inseguro" do
    # `unsafe_write` escreve sem comparar versão. Existe só para demonstrar o
    # lost update. Se vazar para o caminho de produção, a proteção inteira cai.
    it "unsafe_write não é chamado por nenhum outro arquivo de lib/" do
      offenders = Dir[File.join(HARNESS, "lib/**/*.rb")].reject do |path|
        path.end_with?("store/memory.rb")
      end.select { |path| File.read(path).include?("unsafe_write") }

      expect(offenders).to be_empty,
                           "unsafe_write vazou para: #{offenders.map { _1.sub("#{HARNESS}/", '') }}"
    end
  end

  describe "cobertura das invariantes por módulo crítico" do
    # Cada arquivo que concentra corretude precisa ser exercitado por ao menos
    # uma invariante. Um módulo crítico sem invariante é um ponto cego que os
    # demais guardrails não enxergam.
    it "todo módulo crítico aparece em algum spec marcado :invariant" do
      invariant_sources = Dir[File.join(HARNESS, "spec/**/*_spec.rb")]
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

# Acrescentado em revisão adversarial.
#
# A revisão encontrou nove problemas, e a maioria tinha a mesma forma: o
# documento afirmava o que o código não fazia. Nenhum guardrail pegava, porque
# todos verificam código contra código.
#
# Estes exemplos cobrem a fatia verificável desse vetor: afirmações
# ESTRUTURADAS, onde a prosa referencia algo nomeável no repositório.
RSpec.describe "Guardrails: documentação versus código" do
  ROOT_DIR = File.expand_path("../../..", __dir__)

  def read_repo(*path) = File.read(File.join(ROOT_DIR, *path))

  # `schema_validation_failed` esteve no contrato e inalcançável. Código de
  # falha que nada produz descreve uma proteção que quem lê acredita existir.
  it "todo código de dead letter do contrato é produzível pelo consumidor" do
    codes = JSON.parse(read_repo("contracts/schemas/dead-letter.schema.json"))
                .dig("$defs", "Failure", "properties", "code", "enum")

    consumer = read_repo("harness/lib/ultra_sync/consumer.rb")

    # Códigos que o harness ainda não produz precisam estar declarados como
    # desenho, não implementação — em vez de passarem por implementados.
    documented_as_design = %w[
      malformed_payload unsupported_schema_version
      missing_required_reference invalid_signature
    ]

    unreachable = codes.reject do |code|
      consumer.include?(%("#{code}")) || documented_as_design.include?(code)
    end

    expect(unreachable).to be_empty,
                           "códigos inalcançáveis e não declarados como desenho: #{unreachable.inspect}"
  end

  it "o CI executa as verificações que a documentação de segurança promete" do
    ci = read_repo(".github/workflows/ci.yml")
    security = read_repo("docs/04-seguranca.md")

    promised = { "bundler-audit" => "bundler-audit" }

    missing = promised.reject { |doc_term, ci_term| !security.include?(doc_term) || ci.include?(ci_term) }

    expect(missing).to be_empty,
                       "docs/04-seguranca.md promete #{missing.keys.join(', ')}, ausente(s) do CI"
  end

  it "as imagens de contêiner estão fixadas por digest, como a documentação afirma" do
    return unless read_repo("docs/04-seguranca.md").include?("fixadas por digest")

    tagged = read_repo("docker-compose.yml").scan(/^\s*image:\s*(\S+)/).flatten
                                            .reject { _1.include?("@sha256:") }

    expect(tagged).to be_empty, "imagens por tag móvel: #{tagged.inspect}"
  end

  # ADR-002 é a decisão central do lado produtor. Ficou como prosa pura até a
  # revisão, enquanto o lado consumidor tinha 130 exemplos.
  it "as decisões centrais têm contrapartida executável" do
    { "Outbox"         => "harness/lib/ultra_sync/outbox.rb",
      "SchemaValidator" => "harness/lib/ultra_sync/schema_validator.rb",
      "Reconciliation" => "harness/lib/ultra_sync/reconciliation.rb",
      "CircuitBreaker" => "harness/lib/ultra_sync/circuit_breaker.rb" }.each do |name, path|
      expect(File.exist?(File.join(ROOT_DIR, path))).to be(true),
                                                        "#{name} é decisão documentada sem código"
    end
  end
end

# Diagramas precisam RENDERIZAR no GitHub, não apenas parsear.
#
# O GitHub renderiza mermaid com `securityLevel: strict`, que desabilita HTML
# nos rótulos. Um `<b>Portal</b>` não fica em negrito — aparece como texto
# literal dentro do nó, e o diagrama sai ilegível. A sintaxe está correta, o
# parser aceita, e o resultado visual é lixo.
#
# Encontrado quando o autor reportou que o GitHub "não estava renderizando".
# Nove blocos tinham HTML. `<br/>` é a única tag suportada de forma
# consistente e permanece.
RSpec.describe "Guardrails: diagramas Mermaid" do
  DOCS_ROOT = File.expand_path("../../..", __dir__)

  def mermaid_blocks
    Dir[File.join(DOCS_ROOT, "{README.md,docs/**/*.md}")].flat_map do |path|
      File.read(path).scan(/```mermaid\n(.*?)```/m).flatten.map { |body| [path, body] }
    end
  end

  it "existem diagramas para verificar" do
    expect(mermaid_blocks.size).to be >= 10
  end

  it "nenhum rótulo usa HTML além de <br/>" do
    offenders = mermaid_blocks.flat_map do |path, body|
      body.scan(%r{</?(\w+)[^>]*>}).flatten
          .reject { |tag| tag.casecmp("br").zero? }
          .map { |tag| "#{path.sub("#{DOCS_ROOT}/", '')}: <#{tag}>" }
    end

    expect(offenders.uniq).to be_empty,
                              "o GitHub renderiza mermaid com securityLevel strict — estas tags " \
                              "aparecem como texto literal no diagrama:\n  #{offenders.uniq.join("\n  ")}"
  end

  it "as cercas não têm espaço à direita, que impede o GitHub de reconhecer o bloco" do
    bad = Dir[File.join(DOCS_ROOT, "{README.md,docs/**/*.md}")].select do |path|
      File.read(path).match?(/^```mermaid[ \t]+$/)
    end

    expect(bad).to be_empty
  end
end

# A raiz de um problema encontrado na terceira revisão adversarial.
#
# `bin/mutate` e `bin/coupled_change` têm listas FIXAS de arquivos críticos.
# Três módulos entraram em fases posteriores — outbox, schema_validator,
# reconciliation — e nenhuma das listas soube que existiam. Os guardrails não
# cresceram com o código.
#
# Isso é a "erosão lenta" que docs/05-ai-harness.md declara como não coberta,
# acontecendo dentro do próprio repositório. Corrigir as listas resolve o
# sintoma; este spec resolve a causa — módulo novo em lib/ultra_sync/ sem
# cobertura falha o CI, e a lista não pode mais ficar para trás em silêncio.
RSpec.describe "Guardrails: cobertura acompanha o código" do
  LIB_ROOT = File.expand_path("../../lib/ultra_sync", __dir__)

  # Módulos sem lógica de corretude a proteger. Ficar de fora é decisão
  # explícita, não esquecimento — que é a diferença que este spec impõe.
  EXEMPT = {
    "event.rb"                  => "objeto de valor imutável, sem decisão",
    "backoff.rb"                => "cálculo puro, coberto por unit",
    "generated/driver_state.rb" => "gerado; protegido por bin/generate --check",
    "store/postgres.rb"         => "coberto pelas mutações do adapter em memória, que espelha a semântica"
  }.freeze

  def critical_files
    Dir[File.join(LIB_ROOT, "**/*.rb")]
      .map { _1.sub("#{LIB_ROOT}/", "") }
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
    stale = EXEMPT.keys.reject { |f| File.exist?(File.join(LIB_ROOT, f)) }

    expect(stale).to be_empty, "isenção para arquivo inexistente: #{stale.join(', ')}"
  end
end
