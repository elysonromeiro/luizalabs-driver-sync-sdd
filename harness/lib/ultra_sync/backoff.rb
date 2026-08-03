# frozen_string_literal: true

module UltraSync
  # Backoff exponencial com FULL JITTER, conforme docs/03-resiliencia.md.
  #
  # Backoff sem aleatoriedade sincroniza os clientes: cinquenta consumidores
  # que falham no mesmo instante retentam juntos em 100 ms, depois em 200 ms,
  # em rebanho. Cada onda bate no banco que está tentando se levantar, e com
  # frequência é a onda que o derruba de novo.
  #
  # Sortear no intervalo [0, teto] — em vez de teto ± variação — espalha as
  # tentativas por toda a janela. É a variante que minimiza contenção.
  class Backoff
    attr_reader :base, :cap, :max_attempts

    def initialize(base: 0.1, cap: 30.0, max_attempts: 5, rng: Random.new, sleeper: ->(s) { sleep(s) })
      @base         = base
      @cap          = cap
      @max_attempts = max_attempts
      @rng          = rng
      @sleeper      = sleeper
    end

    def ceiling_for(attempt) = [@cap, @base * (2**attempt)].min

    def delay_for(attempt) = @rng.rand * ceiling_for(attempt)

    def wait(attempt) = @sleeper.call(delay_for(attempt))

    # Backoff que não espera. Usado pelos specs: a corretude do consumidor não
    # depende de quanto tempo se espera entre tentativas, e fazer a suíte
    # dormir 3 s por exemplo tornaria os testes de resiliência os mais lentos
    # do repositório — que é como se garante que ninguém os rode.
    def self.immediate(max_attempts: 5)
      new(max_attempts: max_attempts, sleeper: ->(_) {})
    end
  end
end
