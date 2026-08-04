# frozen_string_literal: true

require_relative "support"

RSpec.describe "Guardrails: contratos" do

  it "nenhum $ref entre schemas usa URI absoluta" do
    offenders = Dir[File.join(GuardrailPaths.in_repo("contracts"), "schemas/*.json")].flat_map do |path|
      File.read(path).scan(/"\$ref":\s*"(https?:[^"]+)"/).flatten
          .map { "#{File.basename(path)} → #{_1}" }
    end

    expect(offenders).to be_empty,
                         "$ref absoluto faz o parser oficial tentar a rede e falhar:\n  " +
                         offenders.join("\n  ")
  end

  it "existe validação com os parsers oficiais, e o CI a executa" do
    expect(File.exist?(File.join(GuardrailPaths.in_repo("contracts"), "validate.mjs"))).to be(true),
                                                                    "contracts/validate.mjs sumiu"

    ci = File.read(File.expand_path("../../../.github/workflows/ci.yml", __dir__))
    expect(ci).to include("contracts run validate"),
                  "o CI não valida os contratos contra as especificações oficiais"
  end

  it "todo schema referenciado pelo AsyncAPI existe em disco" do
    asyncapi = File.read(File.join(GuardrailPaths.in_repo("contracts"), "asyncapi.yaml"))
    missing = asyncapi.scan(%r{\$ref:\s*'(\./[^']+)'}).flatten.uniq
                      .reject { File.exist?(File.join(GuardrailPaths.in_repo("contracts"), _1)) }

    expect(missing).to be_empty, "referências quebradas: #{missing.join(', ')}"
  end
end
