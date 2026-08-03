# frozen_string_literal: true

require "json"

# Os números citados na documentação precisam bater com a realidade.
#
# POR QUE ISTO EXISTE
#
# Este SDD afirma que seus números vieram de execução, não de estimativa. Essa
# afirmação envelhece mal sem verificação: a suíte cresce, a documentação não
# acompanha, e um leitor que confere descobre que "60 invariantes" viraram 74.
#
# O dano não é o número errado — é a dúvida que ele lança sobre todos os
# outros. Um documento com uma cifra defasada perde a autoridade das que ainda
# estão certas, e não há como o leitor saber quais são quais.
#
# Encontrado na revisão final: CLAUDE.md dizia 118 exemplos quando eram 130, e
# 05-ai-harness dizia 51 invariantes quando eram 60. Ambos ficaram para trás
# quando os specs de reconciliação entraram.
RSpec.describe "Guardrails: números citados na documentação" do
  REPO = File.expand_path("../../..", __dir__)

  def read(*path) = File.read(File.join(REPO, *path))

  let(:invariant_count) do
    JSON.parse(read("harness/spec/guardrails/invariants.lock")).size
  end

  let(:golden_count) do
    cases = JSON.parse(read("harness/spec/golden/dispatch_cases.json"))
    cases.fetch("eligibility").size + cases.fetch("dispatch").size
  end

  let(:mutation_count) do
    read("harness/bin/mutate").scan(/^    file:/).size
  end

  let(:sabotage_count) do
    read("harness/bin/sabotage").scan(/^    title:/).size
  end

  # Onde cada número aparece. Manter a lista explícita é o que torna a
  # verificação legível — um regex genérico varrendo toda a documentação
  # produziria falso positivo em qualquer número que apareça por outro motivo.
  {
    "README.md"            => %w[invariantes],
    "docs/05-ai-harness.md" => %w[invariantes mutações sabotagens],
    "docs/07-repo-ai-native.md" => %w[sabotagens]
  }.each do |file, kinds|
    kinds.each do |kind|
      it "#{file} cita o número correto de #{kind}" do
        content = read(file)
        expected = case kind
                   when "invariantes" then invariant_count
                   when "mutações"    then mutation_count
                   when "sabotagens"  then sabotage_count
                   end

        pattern = /(\d+)\s+#{Regexp.escape(kind)}/i
        cited = content.scan(pattern).flatten.map(&:to_i).uniq
        next if cited.empty?

        wrong = cited.reject { |n| n == expected }
        expect(wrong).to be_empty,
                         "#{file} cita #{wrong.join(', ')} #{kind}, mas o valor real é #{expected}"
      end
    end
  end

  # Contagem de exemplos da suíte.
  #
  # Acrescentado depois de o próprio spec anterior mudar o total: ao entrar na
  # suíte, ele levou os exemplos de 130 para 136 e deixou os documentos
  # desatualizados. Um guardrail contra deriva que não cobre o número mais
  # citado do documento é exatamente o tipo de cobertura assimétrica que este
  # repositório argumenta contra.
  it "os documentos citam o número real de exemplos da suíte" do
    report = JSON.parse(
      `cd #{REPO}/harness && bundle exec rspec --dry-run --format json 2>/dev/null`[/\{.*\}/m].to_s
    )
    total = report.fetch("examples").size

    %w[README.md CLAUDE.md].each do |file|
      cited = read(file).scan(/(\d+) exemplos/).flatten.map(&:to_i)
      # Números menores que o total são a suíte rápida, legitimamente citada.
      wrong = cited.select { |n| n > total }
      expect(wrong).to be_empty,
                       "#{file} cita #{wrong.join(', ')} exemplos, mas a suíte tem #{total}"
    end
  end

  it "os casos golden citados batem com o arquivo" do
    cited = read("README.md").scan(/(\d+)\s+casos congelados/).flatten.map(&:to_i)

    expect(cited).to all(eq(golden_count)),
                     "README cita #{cited.inspect} casos golden, mas existem #{golden_count}"
  end
end
