#!/usr/bin/env bash
# Hook PostToolUse — roda as invariantes logo após editar código crítico.
#
# POR QUE ISTO EXISTE
#
# O CI já roda estes testes. A diferença é o intervalo: aqui o retorno chega
# em dois segundos, com o contexto da mudança ainda na cabeça de quem a fez
# (ou na janela do agente). No CI chega minutos depois, quando o agente já
# construiu mais três coisas em cima da mudança quebrada.
#
# Não bloqueia — apenas reporta. Bloquear em PostToolUse seria tarde demais
# para impedir a escrita e cedo demais para julgar um trabalho em andamento.

set -uo pipefail

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

case "$FILE" in
  *harness/lib/ultra_sync/*) ;;
  *) exit 0 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/harness" || exit 0

OUTPUT=$(bundle exec rspec --tag invariant --tag ~pg --tag ~kafka --format progress 2>&1)
if printf '%s' "$OUTPUT" | grep -q "0 failures"; then
  exit 0
fi

echo "As invariantes quebraram após esta edição:" >&2
printf '%s\n' "$OUTPUT" | grep -E "examples,|rspec \./spec" >&2
echo "" >&2
echo "Lembre da regra em CLAUDE.md: se uma invariante falha, a mudança está" >&2
echo "errada — não o teste." >&2
exit 0
