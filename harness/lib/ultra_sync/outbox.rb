# frozen_string_literal: true

require "securerandom"

module UltraSync
  # Transactional Outbox do lado do Portal (ADR-002).
  #
  # POR QUE ISTO EXISTE COMO CÓDIGO
  #
  # Estava só como prosa na primeira versão deste repositório. A decisão mais
  # importante do lado produtor — a que elimina a janela do dual-write — era a
  # única sem prova executável, enquanto as do consumidor tinham 130 exemplos.
  # Encontrado em revisão.
  #
  # O QUE ELE GARANTE
  #
  # Estado e evento nascem na MESMA transação. Não existe instante em que o
  # Portal registre uma aprovação que o log desconheça, nem em que o log
  # anuncie um fato que não foi commitado.
  #
  # O relay é at-least-once por desenho: pode republicar sob falha. Isso é
  # seguro porque o `event_id` é estável e o consumidor deduplica por
  # (source, id) — a garantia de entrega exatamente-uma-vez não existe de
  # ponta a ponta, e fingir que existe é como se constroem sistemas que
  # perdem dado silenciosamente.
  class Outbox
    SOURCE = "/magalu/logistica/portal-entregadores"

    # Classificação de canal por criticidade (ADR-005). Não é sobre volume:
    # a pergunta é se o evento, preso duas horas atrás de um backlog,
    # prejudica alguém de forma irreversível naquele dia.
    FAST_LANE = "drivers.status.v1"
    BULK_LANE = "drivers.profile.v1"
    SNAPSHOT  = "drivers.snapshot.v1"

    CHANNEL_BY_KIND = {
      created:        BULK_LANE,
      updated:        BULK_LANE,
      status_changed: FAST_LANE
    }.freeze

    Entry = Struct.new(:id, :event_id, :driver_id, :sequence, :kind, :channel,
                       :snapshot_channel, :payload, :published_at, keyword_init: true) do
      def published? = !published_at.nil?

      # Todo evento vai para DOIS tópicos: o canal de ciclo de vida e o
      # snapshot compactado (ADR-009).
      def channels = [channel, snapshot_channel]
    end

    def initialize(store:)
      @store = store
      @entries = []
      @next_id = 0
      @mutex = Mutex.new
    end

    # Registra a mudança do entregador E o evento, atomicamente.
    #
    # O `sequence` é incrementado DENTRO da transação, junto com a mudança de
    # estado. É por isso que dois writers concorrentes para o mesmo entregador
    # recebem versões distintas sem lock explícito: o UPDATE toma o lock da
    # linha (ADR-003).
    #
    # @return [Entry] a linha do outbox, ainda não publicada
    def record!(driver_id:, state:, kind:)
      @store.transaction do
        # Incremento ATÔMICO. A versão anterior lia, calculava em Ruby e
        # escrevia — o mesmo read-modify-write que docs/02-concorrencia.md
        # condena. Passava nos testes porque o adapter em memória serializa
        # sob monitor; contra Postgres real, 7 de 8 escritores concorrentes
        # falhavam.
        sequence = @store.advance_version!(driver_id: driver_id, state: state)

        enqueue(driver_id: driver_id, sequence: sequence, kind: kind, state: state)
      end
    end

    # O que o relay ainda precisa publicar, em ordem de inserção.
    #
    # A ordem por `id` importa: publicar fora dela produziria mais eventos
    # descartados como stale no consumidor. Não é questão de corretude — a
    # ordenação por versão cobre isso — é de não desperdiçar trabalho.
    def pending = @mutex.synchronize { @entries.reject(&:published?).sort_by(&:id) }

    def all = @mutex.synchronize { @entries.dup }

    # Marca como publicado. Só é chamado DEPOIS do produce ter sido
    # confirmado pelo broker; marcar antes reintroduziria a janela que o
    # outbox existe para fechar, só que do outro lado.
    def mark_published!(entry)
      @mutex.synchronize { entry.published_at = Time.now.utc }
      entry
    end

    # Idade da linha não publicada mais antiga — a métrica de alerta do
    # produtor (docs/03-resiliencia.md). Nil quando não há pendência.
    def oldest_pending_age(now: Time.now.utc)
      oldest = pending.first
      return nil unless oldest

      now - oldest.enqueued_at
    end

    private

    def enqueue(driver_id:, sequence:, kind:, state:)
      @mutex.synchronize do
        @next_id += 1
        # ADR-009: o relay publica no canal de ciclo de vida E no snapshot
        # compactado, com a mesma chave. Sem a segunda publicação o tópico de
        # snapshot fica vazio e o bootstrap de consumidor novo — que é a
        # premissa do fan-out — não funciona.
        entry = Entry.new(
          id:        @next_id,
          event_id:  SecureRandom.uuid,
          driver_id: driver_id,
          sequence:  sequence,
          kind:      kind,
          channel:   CHANNEL_BY_KIND.fetch(kind),
          snapshot_channel: SNAPSHOT,
          payload:   state,
          published_at: nil
        )
        entry.define_singleton_method(:enqueued_at) { @enqueued_at ||= Time.now.utc }
        entry.enqueued_at
        @entries << entry
        entry
      end
    end
  end
end
