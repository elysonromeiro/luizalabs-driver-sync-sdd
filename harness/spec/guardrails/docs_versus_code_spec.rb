# frozen_string_literal: true

require_relative "support"

RSpec.describe "Guardrails: documentação versus código" do

  def read_repo(*path) = GuardrailPaths.read_repo(*path)

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
      expect(File.exist?(File.join(GuardrailPaths.repo, path))).to be(true),
                                                        "#{name} é decisão documentada sem código"
    end
  end
end
