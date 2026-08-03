# frozen_string_literal: true

# O bug e a correção no mesmo arquivo, contra Postgres real.
#
# A versão que FALHA é a única prova de que a versão que passa está testando
# alguma coisa. Sem ela, a escrita condicional passaria trivialmente e o
# arquivo não demonstraria nada.
RSpec.describe "Postgres: lost update sob READ COMMITTED", :pg, :invariant do
  let(:store)     { UltraSync.postgres_store! }
  let(:other)     { UltraSync.postgres_store! }
  let(:driver_id) { Factories.uuid }

  before do
    store.reset!
    store.conditional_upsert(driver_id: driver_id, state: { "status" => "active" }, source_version: 5)
  end

  after do
    store.close
    other.close
  end

  # Duas conexões distintas, transações intercaladas à mão para reproduzir
  # exatamente a tabela de docs/02-concorrencia.md.
  it "read-modify-write ingênuo PERDE a versão maior" do
    # t1 — conexão A lê a versão corrente
    store.exec("BEGIN")
    read_a = store.exec_params(
      "SELECT source_version FROM driver_projections WHERE driver_id = $1", [driver_id]
    ).first["source_version"].to_i

    # t2 — conexão B lê a mesma versão
    other.exec("BEGIN")
    read_b = other.exec_params(
      "SELECT source_version FROM driver_projections WHERE driver_id = $1", [driver_id]
    ).first["source_version"].to_i

    expect(read_a).to eq(5)
    expect(read_b).to eq(5)

    # t3 — A decide em Ruby (7 > 5) e escreve
    store.exec_params(
      "UPDATE driver_projections SET source_version = $2 WHERE driver_id = $1", [driver_id, 7]
    )
    store.exec("COMMIT")

    # t4 — B decide com o valor que leu ANTES (6 > 5) e sobrescreve
    other.exec_params(
      "UPDATE driver_projections SET source_version = $2 WHERE driver_id = $1", [driver_id, 6]
    )
    other.exec("COMMIT")

    final = store.fetch(driver_id).source_version

    # A versão 7 — que no cenário real seria um bloqueio de segurança — foi
    # perdida. Ninguém errou; o READ COMMITTED fez exatamente o que promete.
    expect(final).to eq(6)
  end

  it "a escrita condicional PRESERVA a versão maior no mesmo entrelaçamento" do
    store.exec("BEGIN")
    other.exec("BEGIN")

    # Sem leitura prévia: o predicado vai no WHERE, e quem decide é o banco.
    store.conditional_upsert(driver_id: driver_id, state: { "status" => "blocked" }, source_version: 7)
    store.exec("COMMIT")

    rows = other.conditional_upsert(
      driver_id: driver_id, state: { "status" => "active" }, source_version: 6
    )
    other.exec("COMMIT")

    expect(rows).to eq(0)                                   # :stale
    expect(store.fetch(driver_id).source_version).to eq(7)
    expect(store.fetch(driver_id).state["status"]).to eq("blocked")
  end

  it "o UPDATE condicional serializa escritores concorrentes pelo lock de linha" do
    # Ambas as transações escrevem o MESMO entregador ao mesmo tempo. A
    # segunda bloqueia no lock de linha até a primeira commitar, e então
    # reavalia o predicado contra o valor já atualizado.
    store.exec("BEGIN")
    store.conditional_upsert(driver_id: driver_id, state: { "v" => 7 }, source_version: 7)

    blocked = Thread.new do
      other.exec("BEGIN")
      result = other.conditional_upsert(driver_id: driver_id, state: { "v" => 6 }, source_version: 6)
      other.exec("COMMIT")
      result
    end

    # Dá tempo de a thread alcançar o UPDATE e bloquear. Não é sincronização
    # por sleep no sentido ruim: o teste não depende deste valor para estar
    # correto, apenas para exercitar o caminho de bloqueio.
    sleep 0.2
    store.exec("COMMIT")

    expect(blocked.value).to eq(0)
    expect(store.fetch(driver_id).source_version).to eq(7)
  end
end
