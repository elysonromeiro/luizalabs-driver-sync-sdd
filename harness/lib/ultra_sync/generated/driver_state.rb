# frozen_string_literal: true
#
# ARQUIVO GERADO — NÃO EDITE À MÃO.
#
# Origem: contracts/schemas/driver-state.schema.json
# Regenerar: harness/bin/generate
#
# Editar este arquivo diretamente faz `bin/generate --check` falhar no CI.
# Para mudar qualquer valor abaixo, mude o contrato e regenere.

module UltraSync
  module Generated
    module DriverState
      STATUSES          = %w[pending_approval active inactive blocked offboarded].freeze
      VEHICLE_TYPES     = %w[on_foot bicycle scooter motorcycle car van].freeze
      DOCUMENT_TYPES    = %w[cpf cnpj].freeze
      SEGMENTS          = %w[goods food].freeze
      BACKGROUND_CHECKS = %w[pending approved rejected expired].freeze

      REQUIRED_FIELDS   = %w[driver_id status document_type document_token vehicle delivery_radius_km operating_area segments compliance created_at updated_at].freeze

      MAX_DELIVERY_RADIUS_KM = 200
      MAX_CARGO_CAPACITY_KG  = 3500
    end
  end
end
