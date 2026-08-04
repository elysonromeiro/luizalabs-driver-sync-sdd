# frozen_string_literal: true

require "json"
require "json_schemer"

# Fecha o laço do spec-driven development: os exemplos do contrato são
# validados contra os schemas, e os eventos que o harness produz também.
#
# ESCOPO: este arquivo valida PAYLOADS contra JSON Schema. Ele NÃO valida que
# `asyncapi.yaml` e `openapi.yaml` são documentos válidos segundo suas
# especificações — isso é `npm --prefix contracts run validate`, com os
# parsers oficiais.
#
# A separação foi aprendida da forma difícil. Uma versão anterior deste
# comentário justificava não usar as ferramentas oficiais "porque exigem Node
# e não estariam cobertas pelo mesmo pipeline". A justificativa estava errada:
# a AsyncAPI era INVÁLIDA para o parser oficial — `$ref` absolutos para um
# domínio inexistente faziam o dereferenciador tentar a rede — e a verificação
# caseira não via, porque só checava se o YAML parseava.
#
# "O arquivo parseia" e "a ferramenta padrão aceita" são afirmações
# diferentes, e o enunciado pede a segunda.
#
# A verificação corre nas DUAS direções. Só validar o que deve passar deixa
# escapar um schema permissivo demais — que aceitaria qualquer coisa e passaria
# no teste positivo sem proteger nada.
RSpec.describe "Contratos: conformidade" do
  CONTRACTS = File.join(REPO_ROOT, "contracts")

  # Todos os schemas carregados num mapa de resolução por $id, para que os
  # $ref absolutos entre arquivos resolvam sem rede.
  SCHEMAS = Dir[File.join(CONTRACTS, "schemas/*.json")].to_h do |path|
    doc = JSON.parse(File.read(path))
    [URI(doc.fetch("$id")), doc]
  end.freeze

  RESOLVER = proc { |uri| SCHEMAS.fetch(uri) { raise "ref não resolvida: #{uri}" } }

  def schemer_for(filename)
    JSONSchemer.schema(
      JSON.parse(File.read(File.join(CONTRACTS, "schemas", filename))),
      ref_resolver: RESOLVER,
      meta_schema:  "https://json-schema.org/draft/2020-12/schema"
    )
  end

  def errors_for(filename, instance)
    schemer_for(filename).validate(instance).to_a
  end

  PAIRS = {
    "driver.created.example.json"        => "driver.created.schema.json",
    "driver.updated.example.json"        => "driver.updated.schema.json",
    "driver.status_changed.example.json" => "driver.status_changed.schema.json",
    "dead-letter.example.json"           => "dead-letter.schema.json"
  }.freeze

  describe "exemplos do contrato" do
    PAIRS.each do |example, schema|
      it "#{example} valida contra #{schema}" do
        instance = JSON.parse(File.read(File.join(CONTRACTS, "examples", example)))
        errors = errors_for(schema, instance)

        expect(errors).to be_empty,
                          -> { errors.map { |e| "#{e['data_pointer']} — #{e['type']}" }.join("\n") }
      end
    end

    it "cobre todo schema de evento com ao menos um exemplo" do
      event_schemas = Dir[File.join(CONTRACTS, "schemas/*.json")]
                      .map { File.basename(_1) }
                      .reject { %w[envelope.schema.json driver-state.schema.json].include?(_1) }

      expect(PAIRS.values.sort).to eq(event_schemas.sort)
    end
  end

  # A direção que importa tanto quanto a de cima.
  describe "rejeição de payload inválido" do
    it "o payload defeituoso do dead-letter é rejeitado por driver.updated.v1" do
      malformed = JSON.parse(
        File.read(File.join(CONTRACTS, "examples/dead-letter.example.json"))
      ).fetch("original_event")

      errors = errors_for("driver.updated.schema.json", malformed)
      pointers = errors.map { _1["data_pointer"] }.sort

      expect(pointers).to eq([
                               "/data/driver/operating_area/ibge_city_code",
                               "/data/driver/vehicle/cargo_capacity_kg",
                               "/subject"
                             ])
    end

    it "o exemplo de dead-letter reporta exatamente os erros que o validador encontra" do
      dead_letter = JSON.parse(File.read(File.join(CONTRACTS, "examples/dead-letter.example.json")))
      declared = dead_letter.dig("failure", "schema_errors").map { _1["pointer"] }.sort
      actual = errors_for("driver.updated.schema.json", dead_letter.fetch("original_event"))
               .map { _1["data_pointer"] }.sort

      # Se divergirem, o exemplo virou ficção — e um exemplo que mente é pior
      # que exemplo nenhum, porque é copiado.
      expect(declared).to eq(actual)
    end

    it "campo obrigatório ausente é rejeitado" do
      instance = JSON.parse(File.read(File.join(CONTRACTS, "examples/driver.created.example.json")))
      instance["data"]["driver"].delete("document_type")

      expect(errors_for("driver.created.schema.json", instance)).not_to be_empty
    end

    it "valor fora do enum é rejeitado" do
      instance = JSON.parse(File.read(File.join(CONTRACTS, "examples/driver.created.example.json")))
      instance["data"]["driver"]["status"] = "suspended"

      expect(errors_for("driver.created.schema.json", instance)).not_to be_empty
    end

    it "campo extra não declarado é rejeitado" do
      instance = JSON.parse(File.read(File.join(CONTRACTS, "examples/driver.created.example.json")))
      instance["data"]["driver"]["salario"] = 5000

      expect(errors_for("driver.created.schema.json", instance)).not_to be_empty
    end
  end

  # O harness não pode produzir evento que o contrato recusaria — senão as
  # invariantes estariam sendo verificadas sobre dados que a produção nunca
  # veria.
  describe "eventos gerados pelo harness" do
    it "as fábricas produzem envelopes válidos para os três tipos" do
      %i[created updated status_changed].each do |kind|
        driver_id = Factories.uuid
        sequence  = kind == :created ? 1 : 4
        envelope  = Factories.cloud_event(driver_id: driver_id, sequence: sequence, kind: kind)

        schema = "driver.#{kind}.schema.json"
        errors = errors_for(schema, envelope)

        expect(errors).to be_empty,
                          -> { "#{kind}: " + errors.map { |e| "#{e['data_pointer']} — #{e['type']}" }.join("; ") }
      end
    end

    # O gerador de propriedades é o que produz VOLUME. Se ele emite evento que
    # o contrato recusaria, as invariantes rodam sobre payloads que a produção
    # nunca veria — e a suíte inteira perde parte do valor sem que nada falhe.
    #
    # Adicionado em revisão, depois de descobrir exatamente isso: o gerador
    # sorteava o tipo livremente e produzia `driver.created` com sequence 3,
    # violando o `const: "1"` do schema. O spec cobria as fábricas e não o
    # gerador, que em retrospecto é o ponto cego óbvio.
    it "os eventos do gerador de propriedades validam contra o contrato" do
      require_relative "../properties/generators"

      offenders = []
      10.times do |seed|
        Generators.event_sequence(rng: Random.new(seed)).each do |event|
          envelope = Factories.cloud_event(
            driver_id: event.driver_id, sequence: event.sequence,
            kind: event.kind, state: event.state
          )
          errors = errors_for("driver.#{event.kind}.schema.json", envelope)
          next if errors.empty?

          offenders << "#{event.inspect}: #{errors.map { _1['data_pointer'] }.uniq.join(', ')}"
        end
      end

      expect(offenders.uniq.first(5)).to be_empty,
                                         "o gerador produz eventos fora do contrato:\n  " +
                                         offenders.uniq.first(5).join("\n  ")
    end

    it "os enums do código gerado batem com o contrato" do
      driver_state = SCHEMAS.fetch(
        URI("https://schemas.magalu.com.br/logistica/driver-sync/v1/driver-state.schema.json")
      )

      expect(UltraSync::Generated::DriverState::STATUSES)
        .to eq(driver_state.dig("$defs", "DriverStatus", "enum"))
      expect(UltraSync::Generated::DriverState::VEHICLE_TYPES)
        .to eq(driver_state.dig("$defs", "Vehicle", "properties", "type", "enum"))
      expect(UltraSync::Generated::DriverState::SEGMENTS)
        .to eq(driver_state.dig("properties", "segments", "items", "enum"))
    end

    # A política de elegibilidade só pode aceitar veículos que o contrato
    # conhece. Se alguém adicionar um tipo à lista da política sem adicioná-lo
    # ao contrato, este exemplo pega.
    it "os veículos aceitos pela política existem no contrato" do
      # A lista saiu do Ruby e virou spec: contracts/behavior/eligibility.yaml.
      # Este exemplo continua valendo — agora garante que a regra declarada em
      # YAML não cita veículo que o contrato de dados desconhece, que é a
      # divergência que duas specs separadas permitiriam.
      allowed = UltraSync::EligibilityPolicy.spec
                                            .fetch("rules")
                                            .find { _1["id"] == "vehicle_not_allowed" }
                                            .dig("when", "not_in")

      unknown = allowed - UltraSync::Generated::DriverState::VEHICLE_TYPES

      expect(unknown).to be_empty,
                         "a política aceita veículos que o contrato não conhece: #{unknown.inspect}"
    end
  end
end
