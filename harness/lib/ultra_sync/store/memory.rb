# frozen_string_literal: true

require "monitor"

module UltraSync
  module Store
    # Adapter em memória. É o default da suíte: roda em milissegundos e não
    # exige Docker, o que importa para quem clona o repositório e quer ver a
    # coisa funcionando antes de subir infraestrutura.
    #
    # A semântica replicada aqui é a mesma do Postgres nos dois pontos que
    # importam para corretude:
    #   - claim  → INSERT ... ON CONFLICT DO NOTHING
    #   - upsert → UPDATE ... WHERE source_version < :sequence
    #
    # Ambas são atômicas sob o mesmo monitor, exatamente como seriam sob o lock
    # de linha do Postgres. Um adapter que não fosse atômico aqui faria a suíte
    # in-memory passar por sorte e mascarar o bug que a suíte :pg pega.
    class Memory
      include MonitorMixin

      Projection = Struct.new(:driver_id, :state, :source_version, keyword_init: true)

      attr_reader :query_count

      def initialize
        super()
        reset!
      end

      def reset!
        synchronize do
          @projections = {}
          @claimed     = {}
          @query_count = 0
        end
      end

      # Não há transação real em memória. O monitor reentrante dá a garantia
      # que a suíte precisa — atomicidade da sequência claim + upsert.
      def transaction
        synchronize { yield }
      end

      def claim(source, event_id)
        synchronize do
          @query_count += 1
          key = [source, event_id]
          return false if @claimed.key?(key)

          @claimed[key] = true
        end
      end

      def claimed?(source, event_id)
        synchronize { @claimed.key?([source, event_id]) }
      end

      # Devolve o número de linhas afetadas, como o UPDATE do Postgres:
      # 1 quando aplicou, 0 quando o evento era stale.
      def conditional_upsert(driver_id:, state:, source_version:)
        synchronize do
          @query_count += 1
          current = @projections[driver_id]
          return 0 if current && current.source_version >= source_version

          @projections[driver_id] = Projection.new(
            driver_id: driver_id, state: state, source_version: source_version
          )
          1
        end
      end

      # Versão em lote. Espelha o INSERT ... ON CONFLICT DO UPDATE ... WHERE
      # do Postgres: uma "query", e devolve apenas quem de fato mudou.
      def conditional_upsert_all(rows)
        synchronize do
          @query_count += 1
          ids = rows.map { |r| r[:driver_id] }
          raise ArgumentError, "driver_id repetido no lote" if ids.uniq.size != ids.size

          rows.each_with_object([]) do |row, applied|
            current = @projections[row[:driver_id]]
            next if current && current.source_version >= row[:source_version]

            @projections[row[:driver_id]] = Projection.new(
              driver_id:      row[:driver_id],
              state:          row[:state],
              source_version: row[:source_version]
            )
            applied << row[:driver_id]
          end
        end
      end

      def claim_all(pairs)
        synchronize do
          @query_count += 1
          pairs.reject { |source, id| @claimed.key?([source, id]) }
               .each { |source, id| @claimed[[source, id]] = true }
               .map { |_source, id| id }
        end
      end

      def fetch(driver_id)
        synchronize { @projections[driver_id] }
      end

      def all = synchronize { @projections.values }

      def delete(driver_id) = synchronize { @projections.delete(driver_id) }

      # ATENÇÃO — existe APENAS para demonstrar o lost update em
      # spec/concurrency. Escreve sem comparar versão, que é exatamente o bug
      # que a escrita condicional evita.
      #
      # Nada em lib/ pode chamar este método. Há um guardrail no CI que falha
      # se ele aparecer fora de spec/.
      def unsafe_write(driver_id:, state:, source_version:)
        synchronize do
          @query_count += 1
          @projections[driver_id] = Projection.new(
            driver_id: driver_id, state: state, source_version: source_version
          )
          1
        end
      end

      def reset_query_count! = synchronize { @query_count = 0 }
    end
  end
end
