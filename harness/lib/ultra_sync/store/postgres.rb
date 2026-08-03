# frozen_string_literal: true

require "pg"
require "json"

module UltraSync
  module Store
    # Adapter Postgres. É contra ele que a suíte prova o que o adapter em
    # memória só simula: semântica de isolamento, lock de linha, comportamento
    # de ON CONFLICT e deadlock real.
    class Postgres
      SCHEMA = <<~SQL
        CREATE TABLE IF NOT EXISTS driver_projections (
          driver_id      uuid PRIMARY KEY,
          state          jsonb       NOT NULL,
          source_version bigint      NOT NULL,
          updated_at     timestamptz NOT NULL DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS processed_events (
          source       text        NOT NULL,
          event_id     uuid        NOT NULL,
          processed_at timestamptz NOT NULL DEFAULT now(),
          PRIMARY KEY (source, event_id)
        );
      SQL

      attr_reader :query_count, :conn

      # connect_timeout evita que a suíte fique pendurada quando o host existe
      # mas não responde — sem ele, um Postgres inalcançável (e não apenas
      # ausente) travaria a suíte inteira em vez de pular os specs.
      def self.available?(**opts)
        conn = PG.connect(**connection_params(**opts), connect_timeout: 2)
        conn.close
        true
      rescue PG::Error, SocketError
        false
      end

      def self.connection_params(host: nil, port: nil, user: nil, password: nil, dbname: nil)
        {
          host:     host     || ENV.fetch("PGHOST", "127.0.0.1"),
          port:     port     || ENV.fetch("PGPORT", "55432").to_i,
          user:     user     || ENV.fetch("PGUSER", "ultra"),
          password: password || ENV.fetch("PGPASSWORD", "ultra"),
          dbname:   dbname   || ENV.fetch("PGDATABASE", "ultra_sync_test")
        }
      end

      def initialize(**opts)
        @conn = PG.connect(**self.class.connection_params(**opts))
        # CREATE TABLE IF NOT EXISTS emite NOTICE a cada conexão. Ruído puro
        # na saída da suíte, e ruído é o que faz gente parar de ler a saída.
        @conn.exec("SET client_min_messages TO WARNING")
        @query_count = 0
        migrate!
      end

      def migrate!
        exec(SCHEMA)
      end

      def reset!
        exec("TRUNCATE driver_projections, processed_events")
        reset_query_count!
      end

      def close = @conn.close

      def transaction
        exec("BEGIN")
        result = yield
        exec("COMMIT")
        result
      rescue StandardError
        exec("ROLLBACK") rescue nil # rubocop:disable Style/RescueModifier
        raise
      end

      # Avança a versão do entregador ATOMICAMENTE e devolve a nova.
      #
      # O incremento acontece DENTRO da instrução, sob o lock de linha do
      # UPDATE. Não existe leitura prévia, logo não existe janela entre ler e
      # escrever — é a mesma regra que o consumidor segue, aplicada ao
      # produtor.
      #
      # A versão anterior deste código fazia fetch, calculava em Ruby e
      # escrevia. Passava nos testes porque o adapter em memória serializa
      # tudo sob um monitor; contra Postgres real, 7 de 8 escritores
      # concorrentes falhavam. Era o anti-padrão que docs/02-concorrencia.md
      # condena, dentro do próprio repositório.
      def advance_version!(driver_id:, state:)
        exec_params(<<~SQL, [driver_id, JSON.generate(state)]).first["source_version"].to_i
          INSERT INTO driver_projections (driver_id, state, source_version, updated_at)
          VALUES ($1, $2::jsonb, 1, now())
          ON CONFLICT (driver_id) DO UPDATE
             SET state          = EXCLUDED.state,
                 source_version = driver_projections.source_version + 1,
                 updated_at     = now()
          RETURNING source_version
        SQL
      end

      def claim(source, event_id)
        res = exec_params(<<~SQL, [source, event_id])
          INSERT INTO processed_events (source, event_id)
          VALUES ($1, $2)
          ON CONFLICT DO NOTHING
          RETURNING event_id
        SQL
        res.ntuples == 1
      end

      def claimed?(source, event_id)
        exec_params(
          "SELECT 1 FROM processed_events WHERE source = $1 AND event_id = $2", [source, event_id]
        ).ntuples == 1
      end

      # A escrita condicional do ADR-004. O predicado vive no WHERE, então não
      # existe janela entre decidir e escrever — quem decide é o banco, sob o
      # lock de linha implícito do UPDATE.
      def conditional_upsert(driver_id:, state:, source_version:)
        exec_params(<<~SQL, [driver_id, JSON.generate(state), source_version]).cmd_tuples
          INSERT INTO driver_projections (driver_id, state, source_version, updated_at)
          VALUES ($1, $2::jsonb, $3, now())
          ON CONFLICT (driver_id) DO UPDATE
             SET state          = EXCLUDED.state,
                 source_version = EXCLUDED.source_version,
                 updated_at     = now()
           WHERE driver_projections.source_version < EXCLUDED.source_version
        SQL
      end

      # Versão em lote — uma instrução, independentemente do tamanho.
      #
      # O chamador precisa garantir driver_id único no lote: ON CONFLICT não
      # pode afetar a mesma linha duas vezes na mesma instrução, e o Postgres
      # aborta a transação inteira com "cannot affect row a second time".
      # Ver BatchProcessor#collapse.
      def conditional_upsert_all(rows)
        return [] if rows.empty?

        ids = rows.map { |r| r[:driver_id] }
        raise ArgumentError, "driver_id repetido no lote" if ids.uniq.size != ids.size

        values = rows.each_with_index.map { |_, i| "($#{i * 3 + 1}, $#{i * 3 + 2}::jsonb, $#{i * 3 + 3}, now())" }
        params = rows.flat_map { |r| [r[:driver_id], JSON.generate(r[:state]), r[:source_version]] }

        exec_params(<<~SQL, params).map { |row| row["driver_id"] }
          INSERT INTO driver_projections (driver_id, state, source_version, updated_at)
          VALUES #{values.join(', ')}
          ON CONFLICT (driver_id) DO UPDATE
             SET state          = EXCLUDED.state,
                 source_version = EXCLUDED.source_version,
                 updated_at     = now()
           WHERE driver_projections.source_version < EXCLUDED.source_version
          RETURNING driver_id
        SQL
      end

      def claim_all(pairs)
        return [] if pairs.empty?

        values = pairs.each_with_index.map { |_, i| "($#{i * 2 + 1}, $#{i * 2 + 2})" }
        params = pairs.flatten

        exec_params(<<~SQL, params).map { |row| row["event_id"] }
          INSERT INTO processed_events (source, event_id)
          VALUES #{values.join(', ')}
          ON CONFLICT DO NOTHING
          RETURNING event_id
        SQL
      end

      def fetch(driver_id)
        row = exec_params(
          "SELECT driver_id, state, source_version FROM driver_projections WHERE driver_id = $1",
          [driver_id]
        ).first
        return nil unless row

        Memory::Projection.new(
          driver_id:      row["driver_id"],
          state:          JSON.parse(row["state"]),
          source_version: row["source_version"].to_i
        )
      end

      def all
        exec("SELECT driver_id, state, source_version FROM driver_projections").map do |row|
          Memory::Projection.new(
            driver_id:      row["driver_id"],
            state:          JSON.parse(row["state"]),
            source_version: row["source_version"].to_i
          )
        end
      end

      def reset_query_count! = @query_count = 0

      # --- helpers -------------------------------------------------------

      def exec(sql)
        @query_count += 1
        @conn.exec(sql)
      end

      def exec_params(sql, params)
        @query_count += 1
        @conn.exec_params(sql, params)
      end
    end
  end
end
