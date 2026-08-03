# frozen_string_literal: true

require "securerandom"

# Fábricas de estado e evento.
#
# Determinismo é requisito, não conveniência: os testes de propriedade
# reportam a seed usada, e uma falha só é diagnosticável se puder ser
# reproduzida com aquela seed. Por isso toda geração aleatória passa por um
# Random explícito, nunca por SecureRandom ou Kernel#rand.
module Factories
  module_function

  SOURCE = "/magalu/logistica/portal-entregadores"

  # UUID v4 determinístico a partir de um Random controlado.
  def uuid(rng = Random.new)
    bytes = rng.bytes(16).unpack("C*")
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    hex = bytes.map { |b| format("%02x", b) }.join
    [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
  end

  def token(rng = Random.new)
    chars = [*"A".."Z", *"a".."z", *"0".."9"]
    "tok_#{Array.new(24) { chars[rng.rand(chars.size)] }.join}"
  end

  # Estado válido e elegível por padrão. Sobrescrever campos pontualmente é o
  # que os testes de política fazem para isolar um critério por vez.
  def driver_state(driver_id: nil, rng: Random.new, **overrides)
    id = driver_id || uuid(rng)
    {
      "driver_id"          => id,
      "status"             => "active",
      "document_type"      => "cnpj",
      "document_token"     => token(rng),
      "vehicle"            => {
        "type"              => "motorcycle",
        "plate_token"       => token(rng),
        "cargo_capacity_kg" => 30
      },
      "delivery_radius_km" => 12.5,
      "operating_area"     => { "ibge_city_code" => "3550308", "uf" => "SP" },
      "segments"           => %w[goods food],
      "compliance"         => {
        "background_check"       => "approved",
        "documents_valid_until"  => "2028-05-30",
        "approved_at"            => "2026-08-03T06:02:55.771Z"
      },
      "created_at"         => "2026-08-03T02:14:07.418Z",
      "updated_at"         => "2026-08-03T02:14:07.418Z"
    }.merge(stringify(overrides))
  end

  def event(driver_id:, sequence:, kind: :updated, rng: Random.new, state: nil, id: nil, source: SOURCE)
    type = {
      created:        "br.com.magalu.logistica.driver.created.v1",
      updated:        "br.com.magalu.logistica.driver.updated.v1",
      status_changed: "br.com.magalu.logistica.driver.status_changed.v1"
    }.fetch(kind)

    UltraSync::Event.new(
      id:          id || uuid(rng),
      source:      source,
      type:        type,
      driver_id:   driver_id,
      sequence:    sequence,
      occurred_at: "2026-08-03T02:14:07.418Z",
      state:       state || driver_state(driver_id: driver_id, rng: rng)
    )
  end

  # Envelope CloudEvents completo, para os testes de decodificação e de
  # conformidade com o contrato.
  #
  # `data` carrega os campos específicos de cada tipo. Isso não é detalhe: sem
  # eles o envelope é recusado pelo schema, e o harness estaria exercitando as
  # invariantes sobre payloads que a produção nunca veria. O spec de
  # conformidade existe para pegar exatamente essa divergência — e pegou.
  def cloud_event(driver_id:, sequence:, kind: :updated, rng: Random.new, **opts)
    ev = event(driver_id: driver_id, sequence: sequence, kind: kind, rng: rng, **opts)
    {
      "specversion"     => "1.0",
      "id"              => ev.id,
      "source"          => ev.source,
      "type"            => ev.type,
      "time"            => ev.occurred_at,
      "subject"         => ev.driver_id,
      "sequence"        => ev.sequence.to_s,
      "sequencetype"    => "Integer",
      "partitionkey"    => ev.driver_id,
      "datacontenttype" => "application/json",
      "dataschema"      => "https://schemas.magalu.com.br/logistica/driver-sync/v1/#{ev.type.split('.')[-2]}.schema.json",
      "data"            => { "driver" => ev.state }.merge(type_specific_data(kind))
    }
  end

  def type_specific_data(kind)
    case kind
    when :updated
      { "changed_fields" => ["/delivery_radius_km"] }
    when :status_changed
      { "previous_status" => "active",
        "reason"          => { "code" => "security_block", "actor" => { "kind" => "system" } } }
    else
      {}
    end
  end

  def stringify(hash)
    hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
  end
end
