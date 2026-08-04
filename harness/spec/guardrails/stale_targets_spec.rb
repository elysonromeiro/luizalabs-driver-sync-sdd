# frozen_string_literal: true

require_relative "support"

RSpec.describe "Guardrails: alvos de sabotagem e mutação existem" do

  def targets_from(script, key)
    File.read(File.join(GuardrailPaths.harness, "bin", script))
        .scan(/#{key}:\s*"([^"]+)"|#{key}:\s*'([^']+)'/)
        .flatten.compact
  end

  it "toda mutação aponta para um trecho que ainda existe" do
    source = File.read(File.join(GuardrailPaths.harness, "bin/mutate"))
    entries = source.scan(/file:\s*"([^"]+)".*?from:\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')/m)

    missing = entries.filter_map do |file, dq, sq|
      needle = (dq || sq).to_s.gsub('\\"', '"').gsub("\\\\", "\\")
      path = File.join(GuardrailPaths.harness, file)
      next unless File.exist?(path)
      next if File.read(path).include?(needle)

      "#{file}: #{needle[0, 60].inspect}"
    end

    expect(missing).to be_empty,
                       "mutação com alvo inexistente — reporta 'morta' sem ter testado nada:\n  " +
                       missing.join("\n  ")
  end

  it "toda sabotagem aponta para um trecho que ainda existe" do
    source = File.read(File.join(GuardrailPaths.harness, "bin/sabotage"))
    entries = source.scan(/file:\s*"([^"]+)".*?mutate:\s*\[\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')/m)

    missing = entries.filter_map do |file, dq, sq|
      needle = (dq || sq).to_s.gsub('\\"', '"')
      path = File.expand_path(file, GuardrailPaths.harness)
      next unless File.exist?(path)
      next if File.read(path).include?(needle)

      "#{file}: #{needle[0, 60].inspect}"
    end

    expect(missing).to be_empty,
                       "sabotagem com alvo inexistente — o roteiro deixa de cobrir a barreira:\n  " +
                       missing.join("\n  ")
  end
end
