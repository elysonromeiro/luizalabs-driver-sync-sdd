# frozen_string_literal: true

require "json"

# Regressão caso a caso das regras de elegibilidade e despacho.
#
# Golden tests protegem contra mudança de comportamento, incluindo a
# bem-intencionada. Se um agente de IA "simplifica" a política, estes casos
# quebram. O buraco conhecido dessa técnica é o agente regenerar os esperados
# para casar com o novo comportamento — fechado pelo CODEOWNERS sobre
# spec/golden/ e pelo guardrail de mudança desacoplada.
RSpec.describe "Golden: regras de elegibilidade e despacho", :invariant do
  CASES = JSON.parse(File.read(File.expand_path("dispatch_cases.json", __dir__))).freeze

  # A data é fixa para que casos com validade documental não passem a falhar
  # sozinhos com o tempo. Um golden que muda de resultado conforme o calendário
  # é um teste flaky com outro nome.
  let(:today)  { Date.new(2026, 8, 3) }
  let(:policy) { UltraSync::EligibilityPolicy.new(today: today) }

  def state_for(overrides)
    Factories.driver_state(rng: Random.new(42), **overrides.transform_keys(&:to_sym))
  end

  describe "elegibilidade" do
    CASES.fetch("eligibility").each do |kase|
      it kase.fetch("name") do
        result = policy.evaluate(state_for(kase.fetch("overrides")))
        expected = kase.fetch("expected")

        aggregate_failures kase.fetch("why") do
          expect(result.eligible?).to eq(expected.fetch("eligible"))
          expect(result.reasons.map(&:to_s)).to eq(expected.fetch("reasons"))
        end
      end
    end
  end

  describe "despacho" do
    CASES.fetch("dispatch").each do |kase|
      it kase.fetch("name") do
        offer = UltraSync::DispatchRules::Offer.new(
          segment:     kase.dig("offer", "segment"),
          weight_kg:   kase.dig("offer", "weight_kg"),
          distance_km: kase.dig("offer", "distance_km")
        )
        decision = UltraSync::DispatchRules.new(policy: policy)
                                          .decide(state_for(kase.fetch("overrides")), offer)
        expected = kase.fetch("expected")

        aggregate_failures kase.fetch("why") do
          expect(decision.accepted?).to eq(expected.fetch("accepted"))
          expect(decision.reasons.map(&:to_s)).to eq(expected.fetch("reasons"))
        end
      end
    end
  end

  # Um caso golden sem justificativa é indistinguível de um erro que virou
  # expectativa. Este exemplo impede que se adicione um sem explicar por quê.
  it "todo caso golden declara sua intenção" do
    %w[eligibility dispatch].each do |group|
      CASES.fetch(group).each do |kase|
        expect(kase["why"]).to be_a(String).and(satisfy { |w| w.to_s.length > 20 }),
                               "caso '#{kase['name']}' em #{group} não explica sua intenção"
      end
    end
  end
end
