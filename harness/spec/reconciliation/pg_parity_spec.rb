# frozen_string_literal: true

# A reconciliação só funciona se os dois lados calcularem o MESMO número.
#
# O Portal computa o checksum em SQL, agregado no banco; o consumidor computa
# em Ruby, sobre a própria projeção. Se as duas expressões divergirem — por
# um substr de tamanho diferente, por um separador distinto, por um cast que
# trunca — a reconciliação passa a acusar divergência onde não há.
#
# Esse modo de falha é pior que não ter reconciliação: gera transferência de
# dado do OLTP, no meio de uma recuperação, sem que exista problema real. E é
# silencioso, porque "os checksums não batem" é exatamente o que se espera ver
# quando há drift.
#
# Este arquivo é a única coisa que impede isso.
RSpec.describe "Reconciliação: paridade entre Ruby e SQL", :pg, :invariant do
  let(:store) { UltraSync.postgres_store! }

  before { store.reset! }
  after  { store.close }

  def populate(count, rng: Random.new(42))
    Array.new(count) do
      driver_id = Factories.uuid(rng)
      version   = rng.rand(1..1_000)
      store.conditional_upsert(driver_id: driver_id, state: { "v" => version }, source_version: version)
      UltraSync::Store::Memory::Projection.new(
        driver_id: driver_id, state: {}, source_version: version
      )
    end
  end

  def sql_checksums(buckets:)
    store.exec(UltraSync::Reconciliation.checksum_sql(buckets: buckets)).to_h do |row|
      # canonical() reconcilia bigint com sinal do Postgres e Integer do Ruby.
      [row["bucket"].to_i,
       { count: row["driver_count"].to_i,
         checksum: UltraSync::Reconciliation.canonical(row["checksum"].to_i) }]
    end
  end

  it "a expressão SQL produz o mesmo checksum que o cálculo em Ruby" do
    buckets = 64
    projections = populate(500)

    from_sql   = sql_checksums(buckets: buckets)
    from_ruby  = UltraSync::Reconciliation.checksums(projections, buckets: buckets)

    aggregate_failures do
      expect(from_sql.keys.sort).to eq(from_ruby.keys.sort),
                                    "as duas implementações agruparam em faixas diferentes"

      divergent = from_sql.keys.reject { |bucket| from_sql[bucket] == from_ruby[bucket] }
      expect(divergent).to be_empty,
                           divergent.first(3).map { |b|
                             "faixa #{b}: sql=#{from_sql[b].inspect} ruby=#{from_ruby[b].inspect}"
                           }.join("; ")
    end
  end

  it "as faixas coincidem entregador a entregador" do
    buckets = 128
    projections = populate(200)

    mismatched = projections.reject do |projection|
      ruby_bucket = UltraSync::Reconciliation.bucket_for(projection.driver_id, buckets: buckets)
      sql_bucket = store.exec_params(
        "SELECT (('x' || substr(md5($1::text), 1, 8))::bit(32)::bigint % $2) AS b",
        [projection.driver_id, buckets]
      ).first["b"].to_i
      ruby_bucket == sql_bucket
    end

    expect(mismatched).to be_empty,
                          "entregadores em faixas diferentes nos dois lados: #{mismatched.size}"
  end

  it "drift real aparece como divergência de faixa, e só nela" do
    buckets = 64
    projections = populate(300)

    # Um entregador avança no Portal e não na réplica.
    drifted = projections.first
    store.exec_params(
      "UPDATE driver_projections SET source_version = source_version + 1 WHERE driver_id = $1",
      [drifted.driver_id]
    )

    from_sql  = sql_checksums(buckets: buckets)
    from_ruby = UltraSync::Reconciliation.checksums(projections, buckets: buckets)
    divergent = from_sql.keys.reject { |b| from_sql[b] == from_ruby[b] }

    expect(divergent).to eq([UltraSync::Reconciliation.bucket_for(drifted.driver_id, buckets: buckets)])
  end

  describe "keyset pagination" do
    it "percorre a base inteira sem repetir nem pular registro" do
      populate(250)

      seen = []
      cursor = nil
      pages = 0

      loop do
        rows = store.exec_params(
          UltraSync::Reconciliation.keyset_page_sql(limit: 40),
          [cursor&.first, cursor&.last]
        ).to_a
        break if rows.empty?

        pages += 1
        seen.concat(rows.map { _1["driver_id"] })
        cursor = [rows.last["updated_at"], rows.last["driver_id"]]
        raise "paginação não converge" if pages > 20
      end

      expect(seen.size).to eq(250)
      expect(seen.uniq.size).to eq(250), "a paginação repetiu registros"
    end

    # O plano é o que separa keyset de OFFSET. Com o índice composto, a página
    # é resolvida por busca no índice; com OFFSET, o banco produz e descarta
    # tudo que veio antes.
    it "usa o índice em vez de varrer a tabela" do
      populate(500)
      store.exec("CREATE INDEX IF NOT EXISTS idx_recon ON driver_projections (updated_at, driver_id)")
      store.exec("ANALYZE driver_projections")

      plan = store.exec_params(<<~SQL, [Time.now.utc - 3600, Factories.uuid]).map { _1["QUERY PLAN"] }.join("\n")
        EXPLAIN #{UltraSync::Reconciliation.keyset_page_sql(limit: 40)}
      SQL

      expect(plan).to match(/Index/i),
                      "a página de reconciliação não usou índice:\n#{plan}"
    end
  end
end
