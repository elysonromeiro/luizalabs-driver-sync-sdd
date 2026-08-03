# frozen_string_literal: true

RSpec.describe UltraSync::Reconciliation do
  def projection(driver_id, version)
    UltraSync::Projection.new(
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

# Acrescentado na terceira passada de revisão.
#
# A mutação que troca XOR por soma SOBREVIVEU à suíte rápida, e o motivo é
# instrutivo: **soma também é comutativa e associativa**, então a propriedade
# de independência de ordem não distingue as duas.
#
# O que distingue é a AUTO-INVERSÃO. `a ^ a == 0`; `a + a == 2a`. É essa
# propriedade que faz o checksum cancelar contribuições idênticas — e é ela
# que precisa bater com o `bit_xor` do Postgres.
#
# Sem este exemplo, a divergência só apareceria no spec de paridade, que é
# `:pg` e não roda em cada PR. Guardrail que só age com Docker no ar protege
# menos do que parece.
RSpec.describe "#{UltraSync::Reconciliation} — semântica do agregador", :invariant do
  def projection(id, version)
    UltraSync::Projection.new(driver_id: id, state: {}, source_version: version)
  end

  it "o agregador é auto-inverso — é XOR, não soma" do
    id = Factories.uuid
    single = [projection(id, 7)]
    doubled = single * 2

    checksum = UltraSync::Reconciliation.checksums(doubled).values.first[:checksum]

    # Com XOR, a contribuição duplicada se cancela e sobra zero.
    # Com soma, sobraria o dobro da impressão digital.
    expect(checksum).to eq(0),
                        "o agregador não cancelou a contribuição duplicada — " \
                        "não é XOR, e vai divergir do bit_xor do Postgres"
  end

  it "quatro ocorrências da mesma impressão digital também cancelam" do
    id = Factories.uuid
    checksum = UltraSync::Reconciliation.checksums([projection(id, 3)] * 4).values.first[:checksum]

    expect(checksum).to eq(0)
  end

  # `canonical` é no-op no caminho Ruby puro — o XOR de valores de 64 bits
  # nunca excede 64 bits. Ele existe para a FRONTEIRA com o Postgres, cujo
  # `bigint` tem sinal.
  #
  # Sem este exemplo, remover a máscara sobrevive à suíte rápida e só quebra
  # no spec de paridade, que é :pg. É o valor exato que a reconciliação
  # produziu na primeira execução, com o sinal que o Postgres devolveu.
  it "normaliza o bigint com sinal do Postgres para 64 bits sem sinal" do
    from_postgres = -2_650_426_647_071_125_052   # como o pg devolve
    from_ruby     = 15_796_317_426_638_426_564   # os mesmos bits, sem sinal

    expect(UltraSync::Reconciliation.canonical(from_postgres)).to eq(from_ruby),
                                                                 "sem normalização, a reconciliação acusa divergência em TODA faixa, sempre"
    expect(UltraSync::Reconciliation.canonical(from_ruby)).to eq(from_ruby)
  end

  it "a forma de transporte é hexadecimal de 16 caracteres, como o contrato declara" do
    hex = UltraSync::Reconciliation.hex(-2_650_426_647_071_125_052)

    expect(hex).to match(/\A[0-9a-f]{16}\z/)
    expect(hex).to eq(UltraSync::Reconciliation.hex(15_796_317_426_638_426_564))
  end

  it "o resultado cabe em 64 bits sem sinal, como o bigint do Postgres" do
    sums = UltraSync::Reconciliation.checksums(
      Array.new(200) { projection(Factories.uuid, rand(1..99)) }
    )

    sums.each_value do |entry|
      expect(entry[:checksum]).to be >= 0
      expect(entry[:checksum]).to be <= UltraSync::Reconciliation::MASK64
    end
  end
end
