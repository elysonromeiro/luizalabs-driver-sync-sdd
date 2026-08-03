# frozen_string_literal: true

require_relative "../support/interleaving"

# INVARIANTE — não remova, não marque skip, não relaxe a asserção.
#
# Demonstra o lost update e sua correção percorrendo TODOS os entrelaçamentos
# possíveis entre dois consumidores, em vez de torcer para que threads colidam.
RSpec.describe "Invariante: ausência de lost update", :invariant do
  let(:driver_id) { Factories.uuid }

  # Read-modify-write ingênuo — o anti-padrão documentado em
  # docs/02-concorrencia.md. A decisão é tomada em Ruby, então existe uma
  # janela entre ler e escrever.
  def naive_process(store, event)
    lambda do |pause|
      current = store.fetch(event.driver_id)&.source_version || 0
      pause.call                      # ← outro consumidor pode escrever aqui
      next unless event.sequence > current

      pause.call                      # ← ou aqui
      store.unsafe_write(
        driver_id: event.driver_id, state: event.state, source_version: event.sequence
      )
    end
  end

  # Escrita condicional — a decisão vai para dentro do WHERE, e o banco a
  # executa atomicamente. Não há janela porque não há decisão em Ruby.
  def conditional_process(store, event)
    lambda do |pause|
      pause.call
      pause.call
      store.conditional_upsert(
        driver_id: event.driver_id, state: event.state, source_version: event.sequence
      )
    end
  end

  # Consumidor A traz a versão 7 (um bloqueio de segurança); B traz a 6.
  # O estado final correto é 7, em qualquer entrelaçamento.
  def scenario(strategy)
    store = UltraSync::Store::Memory.new
    store.conditional_upsert(driver_id: driver_id, state: { "status" => "active" }, source_version: 5)

    high = Factories.event(driver_id: driver_id, sequence: 7,
                           state: Factories.driver_state(driver_id: driver_id, status: "blocked"))
    low  = Factories.event(driver_id: driver_id, sequence: 6,
                           state: Factories.driver_state(driver_id: driver_id, status: "active"))

    processes = [send(strategy, store, high), send(strategy, store, low)]
    [store, processes]
  end

  it "o read-modify-write ingênuo perde a atualização em ao menos um entrelaçamento" do
    lost = Interleaving.schedules([3, 3]).count do |schedule|
      store, processes = scenario(:naive_process)
      Interleaving.run(schedule, processes)
      store.fetch(driver_id).source_version != 7
    end

    # Este exemplo existe para provar que o teste abaixo testa alguma coisa.
    # Se o cenário nunca perdesse a atualização, a versão condicional passaria
    # trivialmente e não estaria demonstrando nada.
    #
    # 9 dos 20 entrelaçamentos perdem a versão 7. Quase metade — o que
    # contradiz a intuição de que race condition é evento raro. Ela é rara em
    # produção porque a janela é curta em tempo, não porque seja improvável em
    # estrutura; e a janela aqui inclui a avaliação de elegibilidade, que faz
    # I/O e portanto a alarga bastante.
    expect(lost).to eq(9)
  end

  it "a escrita condicional preserva a versão maior em TODOS os entrelaçamentos" do
    results = Interleaving.schedules([3, 3]).map do |schedule|
      store, processes = scenario(:conditional_process)
      Interleaving.run(schedule, processes)
      [schedule, store.fetch(driver_id).source_version]
    end

    expect(results.size).to eq(20)

    failures = results.reject { |_schedule, version| version == 7 }
    expect(failures).to be_empty,
                        "entrelaçamentos que perderam a versão 7: #{failures.map(&:first).inspect}"
  end
end
