# frozen_string_literal: true

# Processamento em lote contra Postgres real: contagem de queries, o erro de
# chave repetida que torna o colapso obrigatório, e prevenção de deadlock.
RSpec.describe "Postgres: processamento em lote", :pg do
  let(:store) { UltraSync.postgres_store! }

  before { store.reset! }
  after  { store.close }

  # A afirmação de docs/02-concorrencia.md, verificada. A asserção é sobre
  # CONTAGEM e não sobre tempo: contagem é determinística, tempo é ruidoso — e
  # uma refatoração que troque o upsert em lote por um laço não muda nenhum
  # resultado, só o custo.
  describe "ausência de N+1", :invariant do
    it "emite um número constante de queries, independentemente do tamanho do lote" do
      counts = [10, 100, 500].map do |size|
        store.reset!
        events = Array.new(size) { Factories.event(driver_id: Factories.uuid, sequence: 1) }

        store.reset_query_count!
        UltraSync::BatchProcessor.new(store: store).process(events)
        store.query_count
      end

      # BEGIN + claim_all + upsert_all + COMMIT = 4, para qualquer tamanho.
      expect(counts).to eq([4, 4, 4])
    end

    it "o anti-padrão cresce linearmente — é isso que o lote evita" do
      events = Array.new(50) { Factories.event(driver_id: Factories.uuid, sequence: 1) }
      applier = UltraSync::EventApplier.new(store: store)

      store.reset_query_count!
      applier.apply_all(events)

      # 4 por evento (BEGIN + claim + upsert + COMMIT) contra 4 no total.
      expect(store.query_count).to eq(events.size * 4)
      expect(store.query_count).to be > 100
    end
  end

  describe "colapso do lote por entregador" do
    # Não é otimização — é requisito de corretude, e este exemplo é a prova.
    it "ON CONFLICT aborta a transação inteira se a mesma linha aparecer duas vezes" do
      driver_id = Factories.uuid
      rows = [
        { driver_id: driver_id, state: { "v" => 1 }, source_version: 1 },
        { driver_id: driver_id, state: { "v" => 2 }, source_version: 2 }
      ]

      # O adapter barra antes de chegar ao banco...
      expect { store.conditional_upsert_all(rows) }
        .to raise_error(ArgumentError, /repetido/)

      # ...e este é o erro que o Postgres daria se não barrasse.
      expect do
        store.exec_params(<<~SQL, [driver_id, "{}", 1, driver_id, "{}", 2])
          INSERT INTO driver_projections (driver_id, state, source_version)
          VALUES ($1, $2::jsonb, $3), ($4, $5::jsonb, $6)
          ON CONFLICT (driver_id) DO UPDATE SET source_version = EXCLUDED.source_version
        SQL
      end.to raise_error(PG::CardinalityViolation, /cannot affect row a second time/)
    end

    it "o BatchProcessor colapsa e aplica somente a maior versão de cada entregador" do
      driver_id = Factories.uuid
      events = [
        Factories.event(driver_id: driver_id, sequence: 1),
        Factories.event(driver_id: driver_id, sequence: 3),
        Factories.event(driver_id: driver_id, sequence: 2)
      ]

      result = UltraSync::BatchProcessor.new(store: store).process(events)

      expect(result.applied.map(&:sequence)).to eq([3])
      expect(store.fetch(driver_id).source_version).to eq(3)
    end
  end

  describe "prevenção de deadlock" do
    # Dois lotes com interseção, escritos em ordens opostas, formam ciclo de
    # lock e o Postgres aborta um deles. A ordem canônica por driver_id
    # elimina o ciclo — é a razão do sort_by em BatchProcessor#collapse.
    it "escrever em ordens opostas causa deadlock" do
      other = UltraSync.postgres_store!
      first, second = [Factories.uuid, Factories.uuid].sort

      [first, second].each { |id| store.conditional_upsert(driver_id: id, state: {}, source_version: 1) }

      store.exec("BEGIN")
      store.conditional_upsert(driver_id: first, state: { "a" => 1 }, source_version: 2)

      other.exec("BEGIN")
      other.conditional_upsert(driver_id: second, state: { "b" => 1 }, source_version: 2)

      # Cada uma agora quer a linha que a outra segura.
      thread = Thread.new do
        other.conditional_upsert(driver_id: first, state: { "b" => 2 }, source_version: 3)
        other.exec("COMMIT")
        :ok
      rescue PG::TRDeadlockDetected
        :deadlock
      end

      sleep 0.3
      outcome = begin
        store.conditional_upsert(driver_id: second, state: { "a" => 2 }, source_version: 3)
        store.exec("COMMIT")
        :ok
      rescue PG::TRDeadlockDetected
        :deadlock
      end

      expect([outcome, thread.value]).to include(:deadlock)
      other.close
    end

    it "a ordem canônica do BatchProcessor elimina o ciclo" do
      ids = Array.new(6) { Factories.uuid }
      events = ids.shuffle.map { |id| Factories.event(driver_id: id, sequence: 1) }

      collapsed = UltraSync::BatchProcessor.new(store: store).collapse(events)

      # Todo lote é escrito em ordem crescente de driver_id, então duas
      # transações com interseção adquirem os locks na mesma ordem e nunca
      # formam ciclo.
      expect(collapsed.map(&:driver_id)).to eq(collapsed.map(&:driver_id).sort)
    end
  end
end
