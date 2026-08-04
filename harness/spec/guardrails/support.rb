# frozen_string_literal: true

require "json"
require "open3"
require "yaml"

# Caminhos compartilhados pelos meta-testes.
#
# Constantes de nível de arquivo em Ruby são GLOBAIS: uma `HARNESS` definida
# num spec vaza para todos os outros, e a colisão é silenciosa — o segundo
# `HARNESS = ...` emite um warning que ninguém lê. Com sete grupos de
# guardrails num arquivo só, havia nove dessas.
#
# Métodos de módulo não têm esse problema, e o acoplamento fica explícito.
module GuardrailPaths
  module_function

  def harness = File.expand_path("../..", __dir__)
  def repo    = File.expand_path("../../..", __dir__)
  def in_harness(*parts) = File.join(harness, *parts)
  def in_repo(*parts)    = File.join(repo, *parts)
  def read_repo(*parts)  = File.read(in_repo(*parts))
end
