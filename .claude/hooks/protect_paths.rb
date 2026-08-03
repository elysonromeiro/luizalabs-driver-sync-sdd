#!/usr/bin/env ruby
# frozen_string_literal: true

# Hook PreToolUse — bloqueia escrita em caminhos protegidos ANTES da edição.
#
# POR QUE UM HOOK E NÃO UMA INSTRUÇÃO NO CLAUDE.md
#
# CLAUDE.md é lido pelo modelo, que decide se obedece. Este script é executado
# pelo harness: o agente não participa da decisão. É a diferença entre uma
# placa de "não entre" e uma porta trancada, e é a razão de esta ser a camada
# mais confiável dos guardrails, apesar de a mais simples.
#
# Protocolo: recebe JSON em stdin com tool_name e tool_input. Sair com código
# 2 bloqueia a chamada e devolve o stderr ao agente como motivo — ou seja, a
# mensagem abaixo é o que o agente lê e usa para se corrigir. Por isso ela
# explica ONDE a mudança provavelmente deveria estar, em vez de só recusar.

require "json"

PROTECTED = [
  { pattern: %r{\Acontracts/schemas/},        reason: "São a fonte da verdade. O código é derivado deles, e uma mudança incompatível quebra consumidores que este repositório não conhece." },
  { pattern: %r{\Aharness/spec/properties/},  reason: "São as invariantes que definem a corretude do sistema. Se um teste daqui está vermelho, o código é que está errado." },
  { pattern: %r{\Aharness/spec/golden/},      reason: "Congelam as regras de despacho caso a caso. Regenerá-los para casar com o comportamento novo transforma regressão em expectativa." },
  { pattern: %r{\Aharness/spec/guardrails/},  reason: "São os meta-testes. Quem pode desativá-los sem revisão não está protegido por eles." },
  { pattern: %r{\Aharness/bin/},              reason: "São as próprias ferramentas de proteção." },
  { pattern: %r{generated/},                  reason: "Arquivo gerado. Mude contracts/schemas/ e rode bin/generate." }
].freeze

WRITE_TOOLS = %w[Edit Write NotebookEdit MultiEdit].freeze

input = begin
  JSON.parse($stdin.read)
rescue JSON::ParserError
  exit 0 # entrada inesperada não é motivo para travar o trabalho
end

tool = input["tool_name"].to_s
exit 0 unless WRITE_TOOLS.include?(tool)

path = input.dig("tool_input", "file_path").to_s
exit 0 if path.empty?

# Caminho relativo à raiz do repositório, para as regras não dependerem de
# onde o clone está.
root = File.expand_path("../..", __dir__)
relative = path.start_with?(root) ? path.sub("#{root}/", "") : path

rule = PROTECTED.find { |r| relative.match?(r[:pattern]) }
exit 0 unless rule

# Escotilha deliberada. Ela existe porque proteção sem saída legítima é
# proteção que alguém acaba removendo por inteiro — e o uso dela fica visível
# no PR, que é o objetivo.
if ENV["ULTRASYNC_ALLOW_PROTECTED"] == "1"
  warn "[protect_paths] AVISO: escrevendo em caminho protegido (#{relative}) " \
       "com ULTRASYNC_ALLOW_PROTECTED=1. Explique a razão no PR."
  exit 0
end

warn <<~MESSAGE
  BLOQUEADO: #{relative} é um caminho protegido.

  #{rule[:reason]}

  Se a mudança que você quer fazer é de COMPORTAMENTO, ela provavelmente
  pertence a outro lugar — veja a regra fundamental em CLAUDE.md: a
  especificação é a fonte da verdade e o código é derivado dela.

  Se a mudança genuinamente pertence a este caminho, ela exige revisão humana
  (CODEOWNERS). Para prosseguir de forma deliberada nesta sessão:

      export ULTRASYNC_ALLOW_PROTECTED=1

  e explique a razão no Pull Request.
MESSAGE

exit 2
