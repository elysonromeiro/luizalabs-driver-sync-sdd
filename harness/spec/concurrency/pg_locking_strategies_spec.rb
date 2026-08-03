# frozen_string_literal: true

# Compara as quatro estratégias de ADR-004 contra Postgres real.
#
# A ADR afirma que a escrita condicional vence; este arquivo é a verificação.
# As asserções são sobre COMPORTAMENTO observável (linhas afetadas, abortos,
# bloqueio), não sobre tempo — medir latência num teste é receita de flaky.
RSpec.describe "Postgres: estratégias de locking", :pg do
  let(:a)         { UltraSync.postgres_store! }
  let(:b)         { UltraSync.postgres_store! }
  let(:driver_id) { Factories.uuid }

  before do
    a.reset!
    a.conditional_upsert(driver_id: driver_id, state: { "v" => 5 }, source_version: 5)
  end

  after do
    a.close
    b.close
  end

  describe "escrita condicional (escolhida)" do
    it "resolve em uma instrução, sem leitura prévia" do
      before_count = a.query_count
      rows = a.conditional_upsert(driver_id: driver_id, state: { "v" => 9 }, source_version: 9)

      expect(rows).to eq(1)
      expect(a.query_count - before_count).to eq(1)
    end
  end

  describe "SELECT ... FOR UPDATE (pessimista)" do
    it "funciona, mas custa uma instrução a mais e segura o lock durante o processamento" do
      a.exec("BEGIN")
      locked = a.exec_params(
        "SELECT source_version FROM driver_projections WHERE driver_id = $1 FOR UPDATE", [driver_id]
      ).first["source_version"].to_i

      # A segunda conexão fica bloqueada enquanto A segura o lock — inclusive
      # durante a avaliação de elegibilidade, que faz I/O. É esse intervalo
      # que a escrita condicional não paga.
      waiter = Thread.new do
        b.exec("BEGIN")
        b.exec_params(
          "SELECT source_version FROM driver_projections WHERE driver_id = $1 FOR UPDATE", [driver_id]
        )
        b.exec("ROLLBACK")
        :desbloqueou
      end

      sleep 0.2
      expect(waiter).to be_alive              # comprovadamente bloqueado

      a.exec_params("UPDATE driver_projections SET source_version = $2 WHERE driver_id = $1",
                    [driver_id, locked + 1])
      a.exec("COMMIT")

      expect(waiter.value).to eq(:desbloqueou)
    end
  end

  describe "SERIALIZABLE" do
    it "transforma a colisão em erro 40001 que a aplicação precisa capturar e reexecutar" do
      a.exec("BEGIN ISOLATION LEVEL SERIALIZABLE")
      b.exec("BEGIN ISOLATION LEVEL SERIALIZABLE")

      # Ambas leem o mesmo conjunto e depois escrevem nele — a dependência
      # cruzada que o SERIALIZABLE detecta.
      a.exec("SELECT count(*) FROM driver_projections WHERE source_version < 100")
      b.exec("SELECT count(*) FROM driver_projections WHERE source_version < 100")

      a.exec_params("INSERT INTO driver_projections (driver_id, state, source_version) VALUES ($1,'{}',1)",
                    [Factories.uuid])
      b.exec_params("INSERT INTO driver_projections (driver_id, state, source_version) VALUES ($1,'{}',1)",
                    [Factories.uuid])

      a.exec("COMMIT")

      aborted = begin
        b.exec("COMMIT")
        false
      rescue PG::TRSerializationFailure => e
        expect(e.result.error_field(PG::PG_DIAG_SQLSTATE)).to eq("40001")
        true
      end

      # O aborto é o custo: correto, porém exige laço de retentativa na
      # aplicação para uma invariante que cabe num WHERE.
      # Não há ROLLBACK aqui: o COMMIT que falhou já encerrou a transação.
      expect(aborted).to be(true)
    end
  end

  describe "advisory lock" do
    it "serializa por chave arbitrária, útil fora do modelo de linhas" do
      key = driver_id.gsub("-", "")[0, 15].to_i(16)

      a.exec("BEGIN")
      a.exec_params("SELECT pg_advisory_xact_lock($1)", [key])

      acquired = b.exec_params("SELECT pg_try_advisory_xact_lock($1) AS got", [key]).first["got"]
      expect(acquired).to eq("f")           # não conseguiu — A está com o lock

      a.exec("COMMIT")

      b.exec("BEGIN")
      after_release = b.exec_params("SELECT pg_try_advisory_xact_lock($1) AS got", [key]).first["got"]
      b.exec("COMMIT")

      expect(after_release).to eq("t")
    end
  end

  # A afirmação central de ADR-004, verificada: dois entregadores DIFERENTES
  # nunca contendem. É o que permite 300 mil entidades independentes escalarem
  # sem coordenação.
  it "entregadores distintos não bloqueiam um ao outro" do
    other_id = Factories.uuid
    a.conditional_upsert(driver_id: other_id, state: { "v" => 1 }, source_version: 1)

    a.exec("BEGIN")
    a.conditional_upsert(driver_id: driver_id, state: { "v" => 6 }, source_version: 6)

    # B escreve outro entregador enquanto A segura a transação aberta.
    rows = nil
    thread = Thread.new do
      b.exec("BEGIN")
      rows = b.conditional_upsert(driver_id: other_id, state: { "v" => 2 }, source_version: 2)
      b.exec("COMMIT")
    end

    expect(thread.join(3)).not_to be_nil, "escrita em outro entregador bloqueou — houve contenção"
    expect(rows).to eq(1)

    a.exec("COMMIT")
  end
end
