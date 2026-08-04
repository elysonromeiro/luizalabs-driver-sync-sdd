# frozen_string_literal: true

require "json"
require "open3"
require "yaml"

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

# Achado do primeiro ciclo de revisão independente.
#
# O enunciado pede contratos "em formato padrão AsyncAPI ou OpenAPI 3.0" e
# "exemplos funcionais". A verificação que existia checava apenas que o YAML
# parseava e que os `$ref` apontavam para arquivos existentes.
#
# Não é a mesma coisa. O `asyncapi.yaml` estava **inválido** para o parser
# oficial durante todo o desenvolvimento: os `$ref` entre schemas eram URIs
# absolutas para um domínio que não resolve, e o dereferenciador tentava
# buscar pela rede. Quem abrisse no AsyncAPI Studio veria erro.
RSpec.describe "Guardrails: contratos" do
  CONTRACTS_DIR = File.expand_path("../../../contracts", __dir__)

  it "nenhum $ref entre schemas usa URI absoluta" do
    offenders = Dir[File.join(CONTRACTS_DIR, "schemas/*.json")].flat_map do |path|
      File.read(path).scan(/"\$ref":\s*"(https?:[^"]+)"/).flatten
          .map { "#{File.basename(path)} → #{_1}" }
    end

    expect(offenders).to be_empty,
                         "$ref absoluto faz o parser oficial tentar a rede e falhar:\n  " +
                         offenders.join("\n  ")
  end

  it "existe validação com os parsers oficiais, e o CI a executa" do
    expect(File.exist?(File.join(CONTRACTS_DIR, "validate.mjs"))).to be(true),
                                                                    "contracts/validate.mjs sumiu"

    ci = File.read(File.expand_path("../../../.github/workflows/ci.yml", __dir__))
    expect(ci).to include("contracts run validate"),
                  "o CI não valida os contratos contra as especificações oficiais"
  end

  it "todo schema referenciado pelo AsyncAPI existe em disco" do
    asyncapi = File.read(File.join(CONTRACTS_DIR, "asyncapi.yaml"))
    missing = asyncapi.scan(%r{\$ref:\s*'(\./[^']+)'}).flatten.uniq
                      .reject { File.exist?(File.join(CONTRACTS_DIR, _1)) }

    expect(missing).to be_empty, "referências quebradas: #{missing.join(', ')}"
  end
end

# Achado do segundo ciclo de revisão independente.
#
# Reindentar `dispatch_cases.json` com um `json.dump` quebrou a string que a
# sabotagem 6 procurava. O roteiro passou a reportar "trecho não encontrado" e
# deixou de cobrir a mutação — **sem nenhum alarde**, porque o script já
# tratava isso como problema mas ninguém rodava o script a cada mudança.
#
# Guardrail cujo alvo é frágil não some fazendo barulho: ele passa a reportar
# sucesso, que é o pior resultado possível.
RSpec.describe "Guardrails: alvos de sabotagem e mutação existem" do
  HARNESS_ROOT = File.expand_path("../..", __dir__)

  def targets_from(script, key)
    File.read(File.join(HARNESS_ROOT, "bin", script))
        .scan(/#{key}:\s*"([^"]+)"|#{key}:\s*'([^']+)'/)
        .flatten.compact
  end

  it "toda mutação aponta para um trecho que ainda existe" do
    source = File.read(File.join(HARNESS_ROOT, "bin/mutate"))
    entries = source.scan(/file:\s*"([^"]+)".*?from:\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')/m)

    missing = entries.filter_map do |file, dq, sq|
      needle = (dq || sq).to_s.gsub('\\"', '"').gsub("\\\\", "\\")
      path = File.join(HARNESS_ROOT, file)
      next unless File.exist?(path)
      next if File.read(path).include?(needle)

      "#{file}: #{needle[0, 60].inspect}"
    end

    expect(missing).to be_empty,
                       "mutação com alvo inexistente — reporta 'morta' sem ter testado nada:\n  " +
                       missing.join("\n  ")
  end

  it "toda sabotagem aponta para um trecho que ainda existe" do
    source = File.read(File.join(HARNESS_ROOT, "bin/sabotage"))
    entries = source.scan(/file:\s*"([^"]+)".*?mutate:\s*\[\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')/m)

    missing = entries.filter_map do |file, dq, sq|
      needle = (dq || sq).to_s.gsub('\\"', '"')
      path = File.expand_path(file, HARNESS_ROOT)
      next unless File.exist?(path)
      next if File.read(path).include?(needle)

      "#{file}: #{needle[0, 60].inspect}"
    end

    expect(missing).to be_empty,
                       "sabotagem com alvo inexistente — o roteiro deixa de cobrir a barreira:\n  " +
                       missing.join("\n  ")
  end
end

# O guardrail que separa spec-driven de configuração com nome bonito.
#
# Ter arquivos de spec não prova nada. O que prova é que eles são AUTORIDADE:
# mudar a spec muda o comportamento, e o código não pode divergir dela.
#
# Estes exemplos verificam a afirmação dos três níveis declarados em
# contracts/behavior/README.md. Sem eles, "nível 1 — interpretado" seria mais
# uma afirmação de documento que ninguém confere — exatamente o vetor que a
# revisão adversarial mais encontrou neste repositório.
RSpec.describe "Guardrails: spec-driven é verificável" do
  REPO_ROOT_SD = File.expand_path("../../..", __dir__)

  def repo(*parts) = File.join(REPO_ROOT_SD, *parts)

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
