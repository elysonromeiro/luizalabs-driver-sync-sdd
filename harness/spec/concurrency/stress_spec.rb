# frozen_string_literal: true

require "concurrent"

# Colisão real com threads, complementando a enumeração determinística.
#
# A enumeração prova a lógica; o stress prova que a implementação real, com o
# GVL e o agendador do Ruby no meio, se comporta como a lógica prevê. Nenhum
# dos dois basta sozinho.
#
# Sem `sleep` em lugar nenhum: a sincronização é por barreira, o que torna a
# colisão determinística no ponto que interessa em vez de provável.
RSpec.describe "Concorrência: colisão real com threads", :invariant do
  let(:driver_id) { Factories.uuid }

  it "N threads escrevendo o mesmo entregador convergem para a maior versão" do
    store   = UltraSync::Store::Memory.new
    applier = UltraSync::EventApplier.new(store: store)

    thread_count = 16
    barrier = Concurrent::CyclicBarrier.new(thread_count)

    events = (1..thread_count).map do |sequence|
      Factories.event(driver_id: driver_id, sequence: sequence)
    end.shuffle

    outcomes = Concurrent::Array.new

    threads = events.map do |event|
      Thread.new do
        barrier.wait                # todas partem no mesmo instante
        outcomes << applier.apply(event)
      end
    end
    threads.each(&:join)

    expect(store.fetch(driver_id).source_version).to eq(thread_count)
    expect(outcomes.size).to eq(thread_count)
    expect(outcomes.uniq.sort).to eq(%i[applied stale])
    expect(outcomes.count(:duplicate)).to eq(0)
  end

  it "aplica cada evento exatamente uma vez sob reentrega concorrente" do
    store   = UltraSync::Store::Memory.new
    applier = UltraSync::EventApplier.new(store: store)

    event = Factories.event(driver_id: driver_id, sequence: 1)
    thread_count = 24
    barrier = Concurrent::CyclicBarrier.new(thread_count)
    outcomes = Concurrent::Array.new

    threads = Array.new(thread_count) do
      Thread.new do
        barrier.wait
        outcomes << applier.apply(event)
      end
    end
    threads.each(&:join)

    # Exatamente uma thread reivindica; as demais veem duplicata. Se a
    # deduplicação tivesse janela de leitura-antes-de-escrita, mais de uma
    # passaria — e é justamente por isso que ela é INSERT ... ON CONFLICT e
    # não SELECT seguido de INSERT.
    expect(outcomes.count(:applied)).to eq(1)
    expect(outcomes.count(:duplicate)).to eq(thread_count - 1)
  end

  it "entregadores distintos não contendem entre si" do
    store   = UltraSync::Store::Memory.new
    applier = UltraSync::EventApplier.new(store: store)

    drivers = Array.new(32) { Factories.uuid }
    barrier = Concurrent::CyclicBarrier.new(drivers.size)

    threads = drivers.map do |id|
      Thread.new do
        barrier.wait
        5.times { |i| applier.apply(Factories.event(driver_id: id, sequence: i + 1)) }
      end
    end
    threads.each(&:join)

    expect(store.all.size).to eq(drivers.size)
    expect(store.all.map(&:source_version).uniq).to eq([5])
  end
end
