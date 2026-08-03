# frozen_string_literal: true

# Executa TODOS os entrelaçamentos possíveis entre processos concorrentes.
#
# Teste de concorrência com threads e `sleep` passa por sorte: ele exercita um
# entrelaçamento arbitrário por execução, e o entrelaçamento que revela o bug
# pode não sair em mil rodadas. Quando sai, o teste vira "flaky" e alguém o
# desliga — e a proteção some junto.
#
# Aqui os processos são Fibers que cedem em pontos de preempção declarados. O
# enumerador percorre toda a árvore de escalonamentos possíveis. Dois processos
# de três passos dão 20 entrelaçamentos, verificados em milissegundos, sempre
# os mesmos. Determinístico por construção, não por sorte.
module Interleaving
  module_function

  # Todos os escalonamentos distintos de N processos com os passos indicados.
  # counts: [3, 3] → todas as sequências com três 0 e três 1.
  def schedules(counts)
    counts
      .each_with_index
      .flat_map { |count, index| [index] * count }
      .permutation
      .to_a
      .uniq
  end

  # Executa um escalonamento específico.
  #
  # Cada processo é um lambda que recebe `pause` e o chama nos pontos onde a
  # preempção deve ser possível. O escalonamento diz qual processo avança a
  # cada passo.
  def run(schedule, processes)
    fibers = processes.map do |process|
      Fiber.new { process.call(-> { Fiber.yield }) }
    end

    schedule.each { |index| fibers[index].resume if fibers[index].alive? }
    # Drena o que sobrou: um processo pode ter mais passos do que o
    # escalonamento previu se um ramo condicional não foi tomado.
    fibers.each { |fiber| fiber.resume while fiber.alive? }
  end

  # Executa todos os escalonamentos, chamando `setup` antes de cada um para
  # devolver os processos com estado limpo.
  #
  # @yield [Array<Proc>] processos daquele escalonamento
  # @return [Array<Object>] resultado de `after` para cada escalonamento
  def each_schedule(counts, &setup)
    schedules(counts).map do |schedule|
      processes = setup.call
      run(schedule, processes)
      { schedule: schedule, processes: processes }
    end
  end
end
