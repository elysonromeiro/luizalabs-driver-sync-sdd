# frozen_string_literal: true

RSpec.describe UltraSync::Reconciliation do
  def projection(driver_id, version)
    UltraSync::Store::Memory::Projection.new(
      driver_id: driver_id, state: {}, source_version: version
    )
  end

  def population(size, rng: Random.new(7))
    Array.new(size) { projection(Factories.uuid(rng), rng.rand(1..50)) }
  end

  describe "checksum" do
    it "é independente da ordem — é isso que dispensa ordenar os dois lados", :invariant do
      base = population(200)

      expect(described_class.checksums(base.shuffle))
        .to eq(described_class.checksums(base))
    end

    it "muda quando qualquer versão muda", :invariant do
      base = population(200)
      before = described_class.checksums(base)

      target = base.first
      altered = base.drop(1) + [projection(target.driver_id, target.source_version + 1)]

      expect(described_class.checksums(altered)).not_to eq(before)
    end

    it "distribui os entregadores pelas faixas sem concentrar" do
      buckets = 64
      sums = described_class.checksums(population(5_000), buckets: buckets)

      expect(sums.keys.size).to be > (buckets * 0.9),
                                "faixas usadas: #{sums.keys.size} de #{buckets} — distribuição ruim"

      counts = sums.values.map { _1[:count] }
      # Nenhuma faixa com mais que o triplo da média: hash mal distribuído
      # faria a reconciliação transferir muito mais do que o necessário.
      expect(counts.max).to be < (counts.sum.to_f / counts.size * 3)
    end
  end

  describe "detecção de divergência" do
    it "aponta exatamente a faixa divergente, e só ela", :invariant do
      source = population(1_000)
      replica = source.dup

      # Um único entregador com versão atrasada na réplica.
      drifted = source.sample(1, random: Random.new(3)).first
      replica = replica.reject { _1.driver_id == drifted.driver_id } +
                [projection(drifted.driver_id, drifted.source_version - 1)]

      divergent = described_class.divergent_buckets(source: source, replica: replica, buckets: 256)
      expected  = described_class.bucket_for(drifted.driver_id, buckets: 256)

      expect(divergent).to eq([expected])
    end

    it "não acusa divergência quando os dois lados estão em dia", :invariant do
      base = population(1_000)

      expect(described_class.divergent_buckets(source: base, replica: base.shuffle)).to be_empty
    end

    it "detecta registro faltando na réplica" do
      source  = population(500)
      missing = source.first
      replica = source.drop(1)

      divergent = described_class.divergent_buckets(source: source, replica: replica, buckets: 128)

      expect(divergent).to eq([described_class.bucket_for(missing.driver_id, buckets: 128)])
    end

    # O ganho que justifica a técnica, em números.
    it "reduz drasticamente o volume a transferir" do
      total   = 5_000
      buckets = 512
      source  = population(total)

      drifted = source.sample(5, random: Random.new(11))
      replica = source.reject { |p| drifted.any? { |d| d.driver_id == p.driver_id } } +
                drifted.map { projection(_1.driver_id, _1.source_version - 1) }

      divergent = described_class.divergent_buckets(source: source, replica: replica, buckets: buckets)
      to_transfer = source.count do |p|
        divergent.include?(described_class.bucket_for(p.driver_id, buckets: buckets))
      end

      expect(divergent.size).to be <= 5
      expect(to_transfer).to be < (total * 0.05),
                             "#{to_transfer} de #{total} registros para achar 5 divergências"
    end
  end
end
