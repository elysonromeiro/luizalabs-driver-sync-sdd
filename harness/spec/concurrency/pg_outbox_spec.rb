# frozen_string_literal: true

# O teste que faltava, e a razão de ele faltar.
#
# O Outbox tinha specs de concorrência — mas só contra o adapter em memória,
# cujo `transaction` é um monitor que serializa tudo. Passavam por construção.
#
# Contra Postgres real, a implementação anterior falhava em 7 de 8 escritores
# concorrentes, porque fazia leitura-cálculo-escrita: exatamente o
# anti-padrão que docs/02-concorrencia.md dedica um capítulo a condenar.
#
# A lição vale mais que a correção: **um adapter de teste que é mais forte que
# a produção esconde bugs em vez de encontrá-los.** O monitor do adapter em
# memória dava atomicidade que o Postgres só dá se você pedir.
RSpec.describe "Postgres: geração de versão no produtor", :pg, :invariant do
  let(:driver_id) { Factories.uuid }

  def store = UltraSync.postgres_store!

  before do
    @stores = []
    primary.reset!
  end

  after { @stores.each { _1.close rescue nil } } # rubocop:disable Style/RescueModifier

  def primary = @primary ||= tracked(store)

  def tracked(s)
    @stores ||= []
    @stores << s
    s
  end

  it "escritores concorrentes no MESMO entregador recebem versões distintas" do
    writers = 8
    outboxes = Array.new(writers) { UltraSync::Outbox.new(store: tracked(store)) }
    barrier  = Concurrent::CyclicBarrier.new(writers)

    sequences = Concurrent::Array.new
    failures  = Concurrent::Array.new

    outboxes.map do |outbox|
      Thread.new do
        barrier.wait
        sequences << outbox.record!(
          driver_id: driver_id, state: Factories.driver_state(driver_id: driver_id), kind: :updated
        ).sequence
      rescue StandardError => e
        failures << "#{e.class}: #{e.message}"
      end
    end.each(&:join)

    aggregate_failures do
      expect(failures).to be_empty, "escritas falharam: #{failures.uniq.first(3)}"
      expect(sequences.size).to eq(writers)
      expect(sequences.sort).to eq((1..writers).to_a),
                                "versões duplicadas ou puladas: #{sequences.sort.inspect}"
      expect(primary.fetch(driver_id).source_version).to eq(writers)
    end
  end

  it "o incremento não vaza entre entregadores distintos" do
    other = Factories.uuid
    outbox = UltraSync::Outbox.new(store: primary)

    3.times { outbox.record!(driver_id: driver_id, state: Factories.driver_state(driver_id: driver_id), kind: :updated) }
    entry = outbox.record!(driver_id: other, state: Factories.driver_state(driver_id: other), kind: :created)

    expect(entry.sequence).to eq(1), "o contador é global, não por entregador"
    expect(primary.fetch(driver_id).source_version).to eq(3)
  end

  it "a primeira escrita de um entregador é sempre a versão 1" do
    entry = UltraSync::Outbox.new(store: primary)
             .record!(driver_id: driver_id, state: Factories.driver_state(driver_id: driver_id), kind: :created)

    # `driver.created` tem `sequence` const "1" no contrato. Se o incremento
    # partisse de outro lugar, o evento de criação violaria o schema.
    expect(entry.sequence).to eq(1)
  end

  # Demonstra POR QUE a implementação anterior falhava, para que a correção
  # não pareça arbitrária.
  it "o read-modify-write que isto substituiu perde escritas sob concorrência" do
    primary.advance_version!(driver_id: driver_id, state: {})

    a = tracked(store)
    b = tracked(store)

    # Dois produtores leem a mesma versão corrente...
    read_a = a.fetch(driver_id).source_version
    read_b = b.fetch(driver_id).source_version
    expect(read_a).to eq(read_b)

    # ...e ambos calculam a "próxima" em Ruby.
    expect(a.conditional_upsert(driver_id: driver_id, state: {}, source_version: read_a + 1)).to eq(1)
    expect(b.conditional_upsert(driver_id: driver_id, state: {}, source_version: read_b + 1)).to eq(0)

    # A segunda escrita foi rejeitada: um fato do Portal não foi registrado.
    expect(primary.fetch(driver_id).source_version).to eq(2)
  end
end
