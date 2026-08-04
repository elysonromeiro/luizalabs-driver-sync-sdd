# frozen_string_literal: true

module UltraSync
  # Estado projetado de um entregador no consumidor.
  #
  # Vive fora dos adapters de propósito. Antes ficava dentro de
  # `Store::Memory`, e o adapter Postgres instanciava `Memory::Projection` —
  # ou seja, o adapter de produção dependia do de teste. Remover o adapter em
  # memória quebraria o Postgres, o que é o inverso da relação que se quer.
  #
  # Encontrado no segundo ciclo de revisão independente.
  Projection = Struct.new(:driver_id, :state, :source_version, keyword_init: true)
end
