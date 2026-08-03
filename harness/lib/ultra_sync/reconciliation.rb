# frozen_string_literal: true

require "digest"

module UltraSync
  # Detecção de divergência por checksum agregado, e reconciliação apenas do
  # que divergiu.
  #
  # O PROBLEMA QUE ISTO RESOLVE
  #
  # Depois de uma indisponibilidade longa, é preciso responder "o consumidor
  # está em dia com o Portal?". A forma ingênua compara os 300 mil registros —
  # transfere a base inteira para descobrir que 50 divergem, e faz isso no
  # momento em que o sistema está mais frágil.
  #
  # A forma barata divide a base em faixas e compara um número por faixa.
  # Comparar 1024 números é trivial; só as faixas que não baterem exigem
  # transferência de dado.
  #
  # A PROPRIEDADE QUE TORNA ISSO POSSÍVEL
  #
  # O checksum precisa ser INDEPENDENTE DE ORDEM, senão os dois lados teriam
  # de ordenar antes de comparar — e ordenar 300 mil registros no OLTP é
  # justamente a carga que se quer evitar. XOR tem essa propriedade: é
  # comutativo e associativo, então `a ^ b ^ c == c ^ a ^ b`.
  #
  # É também auto-inverso (`a ^ a == 0`), o que significa que um registro
  # contado duas vezes se cancela. Isso é aceitável aqui porque `driver_id` é
  # chave primária nos dois lados — não existe duplicata a mascarar. Registrar
  # a limitação importa: XOR não seria adequado para conjunto com repetição.
  module Reconciliation
    # Faixa de um driver_id, derivada do próprio identificador. Precisa dar o
    # mesmo resultado em Ruby e em SQL — por isso md5, e não `hash` do Ruby,
    # que varia entre processos por causa da randomização de seed.
    def self.bucket_for(driver_id, buckets:)
      Digest::MD5.hexdigest(driver_id.to_s)[0, 8].to_i(16) % buckets
    end

    MASK64 = 0xFFFF_FFFF_FFFF_FFFF

    # Contribuição de um registro para o checksum da sua faixa.
    def self.fingerprint(driver_id, source_version)
      Digest::MD5.hexdigest("#{driver_id}:#{source_version}")[0, 16].to_i(16)
    end

    # Normaliza para 64 bits sem sinal.
    #
    # NECESSÁRIO, e por um motivo que só aparece quando se compara os dois
    # lados de verdade: `bigint` do Postgres é 64 bits COM SINAL, enquanto
    # Integer do Ruby é ilimitado. O mesmo XOR produz -2650426647071125052 de
    # um lado e 15796317426638426564 do outro — os mesmos bits, representações
    # diferentes.
    #
    # Sem esta normalização, a reconciliação acusaria divergência em TODA
    # faixa, sempre. E o modo de falha é silencioso, porque "os checksums não
    # batem" é exatamente o que se espera ver quando há drift de verdade.
    #
    # Foi encontrado pelo spec de paridade, que existe só para isso.
    def self.canonical(value) = value & MASK64

    # Forma de transporte: hexadecimal de 16 caracteres, como declarado em
    # contracts/openapi.yaml. Texto evita que a representação numérica de
    # qualquer linguagem consumidora reintroduza o problema acima.
    def self.hex(value) = format("%016x", canonical(value))

    # Checksum de uma coleção de projeções, agrupado por faixa.
    # Devolve { bucket => { count:, checksum: } }
    def self.checksums(projections, buckets: 1024)
      projections.each_with_object({}) do |projection, acc|
        bucket = bucket_for(projection.driver_id, buckets: buckets)
        entry  = (acc[bucket] ||= { count: 0, checksum: 0 })
        entry[:count]    += 1
        entry[:checksum] ^= fingerprint(projection.driver_id, projection.source_version)
      end.transform_values { |e| { count: e[:count], checksum: canonical(e[:checksum]) } }
    end

    # Faixas em que os dois lados discordam.
    #
    # Compara contagem E checksum: contagens iguais com checksums diferentes
    # significam versão divergente; contagens diferentes significam registro
    # faltando ou sobrando. As duas situações exigem reconciliação, mas a
    # distinção ajuda o diagnóstico.
    def self.divergent_buckets(source:, replica:, buckets: 1024)
      source_sums  = checksums(source,  buckets: buckets)
      replica_sums = checksums(replica, buckets: buckets)

      (source_sums.keys | replica_sums.keys).select do |bucket|
        source_sums[bucket] != replica_sums[bucket]
      end.sort
    end

    # SQL equivalente, para o lado do Portal. Roda agregado no banco, em
    # réplica de leitura, e NÃO transfere dado de entregador — só um número
    # por faixa.
    #
    # A expressão precisa produzir exatamente o mesmo valor que `fingerprint`
    # acima. Há um spec que verifica isso contra Postgres real; sem ele, os
    # dois lados divergiriam silenciosamente e a reconciliação acusaria
    # divergência onde não há — o que é pior que não ter reconciliação, porque
    # gera carga sem motivo.
    def self.checksum_sql(buckets: 1024, table: "driver_projections")
      <<~SQL
        SELECT
          (('x' || substr(md5(driver_id::text), 1, 8))::bit(32)::bigint % #{buckets}) AS bucket,
          count(*) AS driver_count,
          bit_xor(('x' || substr(md5(driver_id::text || ':' || source_version::text), 1, 16))::bit(64)::bigint) AS checksum
        FROM #{table}
        GROUP BY 1
        ORDER BY 1
      SQL
    end

    # Página de reconciliação por KEYSET, nunca por OFFSET.
    #
    # OFFSET degrada para varredura a cada página: para chegar à página N o
    # banco precisa produzir e descartar todas as anteriores, então o custo
    # total da travessia cresce quadraticamente. Num cenário de recuperação —
    # o único em que este caminho é usado — isso é exatamente o oposto do que
    # se quer.
    #
    # O cursor codifica o último par lido. A comparação de tupla
    # `(a, b) > (x, y)` usa o índice composto diretamente.
    def self.keyset_page_sql(limit: 200, table: "driver_projections")
      <<~SQL
        SELECT driver_id, source_version, updated_at
        FROM #{table}
        WHERE ($1::timestamptz IS NULL OR (updated_at, driver_id) > ($1, $2))
        ORDER BY updated_at, driver_id
        LIMIT #{limit}
      SQL
    end
  end
end
