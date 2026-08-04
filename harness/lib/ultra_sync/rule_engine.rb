# frozen_string_literal: true

require "yaml"
require "date"

module UltraSync
  # Interpretador dos predicados declarativos de contracts/behavior/.
  #
  # POR QUE ISTO EXISTE
  #
  # O SDD afirma, desde o começo, que "a especificação é a fonte da verdade e o
  # código é derivado dela". Isso valia apenas para enums e limites — 26 linhas
  # geradas contra 1.504 escritas, 1,7%. As REGRAS, que é onde mora o valor,
  # viviam só em Ruby.
  #
  # Com este interpretador, elegibilidade e despacho passam a ser dados. Mudar
  # um critério é editar YAML; o Ruby não sabe quais são as regras, apenas como
  # avaliá-las.
  #
  # O TESTE QUE ISSO PRECISA PASSAR
  #
  # Apagar `eligibility_policy.rb` e pedir a um agente que o reconstrua a
  # partir de `contracts/` deve produzir o mesmo comportamento. Antes, não
  # produziria: as regras não estavam escritas em lugar nenhum que ele pudesse
  # ler.
  class RuleEngine
    class UnknownPredicate < StandardError; end
    class InvalidSpec < StandardError; end

    # Predicados suportados. A lista é fechada de propósito: um predicado novo
    # é uma decisão de desenho, não uma conveniência de quem escreve a regra.
    # Predicado arbitrário em spec vira código disfarçado de configuração.
    PREDICATES = %i[
      equals not_equals in not_in empty absent
      lt lte gt gte date_before
      not_included_in_driver_field greater_than_driver_field
    ].freeze

    def self.load(path)
      spec = YAML.safe_load_file(path, permitted_classes: [Date])
      raise InvalidSpec, "#{path}: sem `version`" unless spec["version"]

      spec
    end

    def initialize(today: Time.now.utc.to_date)
      @today = today
    end

    # Avalia uma regra contra o estado. `true` significa que a regra FOI
    # violada — o motivo entra na lista.
    def violated?(rule, state, offer: nil)
      predicate, argument = single_predicate(rule.fetch("when"))

      if rule["offer_field"]
        evaluate_offer(predicate, rule, state, offer)
      else
        evaluate_state(predicate, argument, dig(state, rule.fetch("field")))
      end
    end

    private

    def single_predicate(clause)
      raise InvalidSpec, "`when` precisa ter exatamente um predicado" unless clause.size == 1

      name, argument = clause.first
      predicate = name.to_sym
      raise UnknownPredicate, name unless PREDICATES.include?(predicate)

      [predicate, argument]
    end

    # Navega `a.b.c` no estado. Devolve nil para caminho inexistente, o que os
    # predicados tratam explicitamente — nil não é o mesmo que ausente para
    # todas as regras, e a distinção é deliberada.
    def dig(state, path)
      path.split(".").reduce(state) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    end

    def evaluate_state(predicate, argument, value)
      case predicate
      when :equals      then value == argument
      when :not_equals  then value != argument
      when :in          then Array(argument).include?(value)
      when :not_in      then !Array(argument).include?(value)
      when :empty       then value.nil? || (value.respond_to?(:empty?) && value.empty?)
      when :absent      then value.nil?
      when :lt          then numeric?(value) && value < argument
      when :lte         then !numeric?(value) || value <= argument
      when :gt          then numeric?(value) && value > argument
      when :gte         then numeric?(value) && value >= argument
      when :date_before then date_before?(value, argument)
      else raise UnknownPredicate, predicate
      end
    end

    def evaluate_offer(predicate, rule, state, offer)
      offer_value  = offer&.public_send(rule.fetch("offer_field"))
      driver_value = dig(state, rule.fetch("driver_field"))

      case predicate
      when :not_included_in_driver_field
        !Array(driver_value).include?(offer_value)
      when :greater_than_driver_field
        driver_value.nil? || offer_value.nil? || offer_value > driver_value
      else
        raise UnknownPredicate, predicate
      end
    end

    def numeric?(value) = value.is_a?(Numeric)

    # Campo ausente NÃO está vencido. Significa que não há documento com
    # validade aplicável — a distinção está declarada em eligibility.yaml e é
    # o tipo de interpretação que uma refatoração inverte com facilidade.
    def date_before?(value, reference)
      return false if value.nil?

      limit = reference == "today" ? @today : Date.parse(reference.to_s)
      Date.parse(value.to_s) < limit
    end
  end
end
