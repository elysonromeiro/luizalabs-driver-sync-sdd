# frozen_string_literal: true

RSpec.describe UltraSync::CircuitBreaker do
  # Relógio controlado. Testar breaker com `sleep` real seria lento e
  # intermitente; injetar o tempo torna a máquina de estados determinística.
  let(:now)     { [0.0] }
  let(:clock)   { -> { now[0] } }
  let(:breaker) { described_class.new(threshold: 3, reset_after: 30.0, clock: clock) }

  it "começa fechado" do
    expect(breaker).to be_closed
  end

  describe "abertura", :invariant do
    # Mutação que sobreviveu à suíte rápida: elevar o limiar de forma que o
    # breaker nunca abrisse. Sem breaker, o consumidor martela uma dependência
    # caída em vez de dar trégua — e frequentemente é o que impede a
    # recuperação.
    it "abre exatamente ao atingir o limiar de falhas" do
      2.times { breaker.record_failure }
      expect(breaker).to be_closed, "abriu antes do limiar"

      breaker.record_failure
      expect(breaker).to be_open, "não abriu ao atingir o limiar"
    end

    it "sucesso zera a contagem antes do limiar" do
      2.times { breaker.record_failure }
      breaker.record_success
      2.times { breaker.record_failure }

      expect(breaker).to be_closed
    end
  end

  describe "recuperação" do
    before { 3.times { breaker.record_failure } }

    it "não tenta probe antes da janela" do
      now[0] = 29.0
      expect(breaker.probe_due?).to be(false)
      expect(breaker).to be_open
    end

    it "passa por meio-aberto, nunca direto para fechado" do
      now[0] = 31.0

      expect(breaker.probe_due?).to be(true)
      expect(breaker).to be_half_open

      breaker.record_success
      expect(breaker).to be_closed

      # A transição intermediária existe para não retomar todo o backlog contra
      # uma dependência recém-recuperada.
      expect(breaker.transitions).to eq([%i[closed open], %i[open half_open], %i[half_open closed]])
    end

    it "volta a abrir se o probe falhar" do
      now[0] = 31.0
      breaker.probe_due?
      breaker.record_failure

      expect(breaker).to be_open
    end
  end

  describe "#call" do
    it "recusa a chamada enquanto estiver aberto" do
      3.times { breaker.record_failure }

      expect { breaker.call { :nunca_executa } }.to raise_error(described_class::Opened)
    end

    it "propaga o erro original e contabiliza a falha" do
      expect { breaker.call { raise IOError, "boom" } }.to raise_error(IOError, "boom")
      expect(breaker.failure_count).to eq(1)
    end

    it "não contabiliza a própria recusa como falha de dependência" do
      3.times { breaker.record_failure }
      count_before = breaker.failure_count

      expect { breaker.call { :x } }.to raise_error(described_class::Opened)
      expect(breaker.failure_count).to eq(count_before)
    end
  end
end
