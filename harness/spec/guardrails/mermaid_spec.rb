# frozen_string_literal: true

require_relative "support"

RSpec.describe "Guardrails: diagramas Mermaid" do

  def mermaid_blocks
    Dir[File.join(GuardrailPaths.repo, "{README.md,docs/**/*.md}")].flat_map do |path|
      File.read(path).scan(/```mermaid\n(.*?)```/m).flatten.map { |body| [path, body] }
    end
  end

  it "existem diagramas para verificar" do
    expect(mermaid_blocks.size).to be >= 10
  end

  it "nenhum rótulo usa HTML além de <br/>" do
    offenders = mermaid_blocks.flat_map do |path, body|
      body.scan(%r{</?(\w+)[^>]*>}).flatten
          .reject { |tag| tag.casecmp("br").zero? }
          .map { |tag| "#{path.sub("#{GuardrailPaths.repo}/", '')}: <#{tag}>" }
    end

    expect(offenders.uniq).to be_empty,
                              "o GitHub renderiza mermaid com securityLevel strict — estas tags " \
                              "aparecem como texto literal no diagrama:\n  #{offenders.uniq.join("\n  ")}"
  end

  it "as cercas não têm espaço à direita, que impede o GitHub de reconhecer o bloco" do
    bad = Dir[File.join(GuardrailPaths.repo, "{README.md,docs/**/*.md}")].select do |path|
      File.read(path).match?(/^```mermaid[ \t]+$/)
    end

    expect(bad).to be_empty
  end
end
