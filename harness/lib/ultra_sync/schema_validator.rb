# frozen_string_literal: true

require "json"
require "json_schemer"

module UltraSync
  # Validação do payload contra o contrato, no momento do consumo.
  #
  # POR QUE ISTO EXISTE
  #
  # `dead-letter.schema.json` declara o código `schema_validation_failed`, e
  # até a revisão nada o produzia: o consumidor decodificava o envelope lendo
  # campos, sem validar. Um payload que violasse o contrato — capacidade de
  # carga acima do máximo, código IBGE malformado — seria aplicado à projeção
  # sem que nada reclamasse.
  #
  # Um código de falha inalcançável é pior que ausente: ele descreve uma
  # proteção que o leitor do contrato acredita existir.
  #
  # ONDE VALIDAR
  #
  # Na borda do consumo, antes de aplicar. Validar depois seria tarde; validar
  # na produção do evento não protege contra produtor comprometido ou versão
  # divergente de schema, que é o caso que interessa.
  class SchemaValidator
    class MissingSchema < StandardError; end

    CONTRACTS_DIR = File.expand_path("../../../contracts", __dir__)

    def self.default = @default ||= new

    def initialize(contracts_dir: CONTRACTS_DIR)
      @schemas = Dir[File.join(contracts_dir, "schemas/*.json")].to_h do |path|
        doc = JSON.parse(File.read(path))
        [URI(doc.fetch("$id")), doc]
      end
      @resolver = proc { |uri| @schemas.fetch(uri) { raise MissingSchema, uri.to_s } }
      @compiled = {}
      @by_type  = index_by_event_type
    end

    # Existe schema para este tipo de evento?
    #
    # Distinguir "tipo desconhecido" de "payload inválido" importa: são
    # códigos de dead letter diferentes e diagnósticos diferentes. O primeiro
    # é contrato faltando ou consumidor desatualizado; o segundo é produtor
    # emitindo fora do que o contrato permite.
    def known_type?(type) = @by_type.key?(type)

    # @return [Array<Hash>] erros no formato do dead letter; vazio quando válido
    def validate(envelope)
      schema_id = @by_type[envelope["type"]]
      return [] unless schema_id # tipo desconhecido é tratado por known_type?

      schemer_for(schema_id).validate(envelope).map do |error|
        {
          "pointer" => error["data_pointer"].to_s.empty? ? "/" : error["data_pointer"],
          "detail"  => describe(error)
        }
      end
    end

    def valid?(envelope) = validate(envelope).empty?

    private

    def schemer_for(schema_id)
      @compiled[schema_id] ||= JSONSchemer.schema(
        @schemas.fetch(schema_id),
        ref_resolver: @resolver,
        meta_schema:  "https://json-schema.org/draft/2020-12/schema"
      )
    end

    # Mapeia o `type` do CloudEvents para o schema que o valida, lendo o
    # `const` declarado no próprio contrato. Assim, adicionar um evento novo
    # não exige tocar neste arquivo — o contrato continua sendo a fonte.
    def index_by_event_type
      @schemas.each_with_object({}) do |(id, doc), acc|
        const = doc["allOf"]&.dig(1, "properties", "type", "const")
        acc[const] = id if const
      end
    end

    def describe(error)
      case error["type"]
      when "required" then "campo obrigatório ausente: #{error.dig('details', 'missing_keys')&.join(', ')}"
      when "enum"     then "valor fora do enum permitido"
      when "format"   then "não conforma com o formato #{error.dig('schema', 'format')}"
      when "maximum"  then "acima do máximo #{error.dig('schema', 'maximum')}"
      when "minimum"  then "abaixo do mínimo #{error.dig('schema', 'minimum')}"
      when "pattern"  then "não casa com o padrão #{error.dig('schema', 'pattern')}"
      else error["type"].to_s
      end
    end
  end
end
