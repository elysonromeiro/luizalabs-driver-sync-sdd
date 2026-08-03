# frozen_string_literal: true

require_relative "generators"

# O framework de propriedades testado a si mesmo.
#
# POR QUE ISTO FALTAVA E POR QUE IMPORTA
#
# O README justifica escrever property-based testing próprio em vez de usar
# uma gem com um argumento específico: **encolhimento**. Bibliotecas genéricas
# minimizam bem escalares e mal sequências de eventos de domínio.
#
# Só que o encolhedor nunca tinha sido testado. A justificativa inteira para a
# decisão apoiava-se numa capacidade não verificada — e se `shrink` estivesse
# quebrado, ninguém saberia, porque ele só roda quando uma propriedade falha.
#
# Encontrado na segunda passada de revisão adversarial.
RSpec.describe PropertyCheck do
  describe ".shrink" do
    it "reduz à menor subsequência que ainda falsifica" do
      events = (1..10).map { Factories.event(driver_id: Factories.uuid, sequence: _1) }
      culprit = events[6]

      # "Falha" se o culpado estiver presente.
      minimal = described_class.shrink(events) { |candidate| candidate.include?(culprit) }

      expect(minimal).to eq([culprit]),
                         "encolheu para #{minimal.size} eventos em vez de 1"
    end

    it "preserva mais de um evento quando a falha exige mais de um" do
      events = (1..8).map { Factories.event(driver_id: Factories.uuid, sequence: _1) }
      pair = [events[2], events[5]]

      minimal = described_class.shrink(events) { |c| pair.all? { |e| c.include?(e) } }

      expect(minimal.size).to eq(2)
      expect(minimal).to match_array(pair)
    end

    it "não encolhe o que já é mínimo" do
      single = [Factories.event(driver_id: Factories.uuid, sequence: 1)]

      expect(described_class.shrink(single) { true }).to eq(single)
    end

    it "devolve a entrada quando nada falsifica" do
      events = (1..5).map { Factories.event(driver_id: Factories.uuid, sequence: _1) }

      # Nenhum candidato reduzido falsifica, então nada é removido.
      expect(described_class.shrink(events) { |c| c.size == events.size }).to eq(events)
    end
  end

  describe "reprodutibilidade" do
    # A afirmação do README: a seed é reportada e reproduz a falha exata.
    # Testada porque afirmação sobre diagnóstico é a que menos se percebe
    # quando quebra — ela só é exercida no dia em que algo dá errado.
    it "a mesma seed produz exatamente os mesmos casos" do
      captured = []
      2.times do
        seen = []
        begin
          described_class.forall(iterations: 5, seed: 4242) do |events|
            seen << events.map { |e| [e.driver_id, e.sequence] }
            raise "parar" if seen.size == 5
          end
        rescue described_class::Falsified
          nil
        end
        captured << seen
      end

      expect(captured[0]).to eq(captured[1]), "a mesma seed produziu casos diferentes"
    end

    it "a mensagem de falha reporta a seed e o contraexemplo minimizado" do
      error = nil
      begin
        described_class.forall(iterations: 20, seed: 777) do |events|
          raise "falha proposital" if events.size > 1
        end
      rescue described_class::Falsified => e
        error = e
      end

      expect(error).not_to be_nil, "forall não levantou Falsified"
      aggregate_failures do
        expect(error.seed).to eq(777)
        expect(error.message).to include("777")
        expect(error.message).to include("SEED=777")
        expect(error.counterexample.size).to be <= error.original.size
      end
    end

    it "`generator:` mantém seed e encolhimento" do
      error = nil
      begin
        described_class.forall(
          iterations: 10, seed: 31,
          generator: ->(rng) { Generators.colliding_versions(rng: rng) }
        ) { |events| raise "falha proposital" if events.size > 1 }
      rescue described_class::Falsified => e
        error = e
      end

      expect(error.seed).to eq(31)
      expect(error.counterexample).not_to be_empty
    end
  end

  describe "detecção" do
    it "não reporta falha quando a propriedade vale" do
      expect { described_class.forall(iterations: 10, seed: 1) { |_| true } }.not_to raise_error
    end

    it "reporta a iteração em que falhou" do
      error = nil
      begin
        described_class.forall(iterations: 50, seed: 5) { |_| raise "sempre falha" }
      rescue described_class::Falsified => e
        error = e
      end

      expect(error.iteration).to eq(1), "não falhou na primeira iteração como esperado"
    end
  end
end
