#!/usr/bin/env bash
# Hook Stop — impede a sessão de terminar num estado inconsistente.
#
# POR QUE ISTO EXISTE
#
# O modo de falha específico desta camada é o agente encerrar deixando drift:
# editou o código gerado sem tocar no contrato, ou uma invariante ficou
# marcada como pendente. Nada disso quebra a suíte imediatamente; aparece
# depois, no CI, sem contexto de quem fez.
#
# Verifica o que é BARATO e SILENCIOSO quando está tudo certo. Um hook de fim
# de sessão que fala demais é um hook que se desliga.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/harness" || exit 0

PROBLEMS=""

if ! OUT=$(bin/generate --check 2>&1); then
  PROBLEMS="${PROBLEMS}\n  [drift] o código gerado divergiu do contrato\n$(printf '%s' "$OUT" | sed 's/^/    /')"
fi

if ! OUT=$(bin/test_inventory --check 2>&1); then
  PROBLEMS="${PROBLEMS}\n  [invariantes]\n$(printf '%s' "$OUT" | grep -E 'REMOVIDA|DESABILITADA' | sed 's/^/    /')"
fi

if ! OUT=$(bin/check_docs 2>&1); then
  PROBLEMS="${PROBLEMS}\n  [docs] link quebrado\n$(printf '%s' "$OUT" | grep -E 'inexistente' | head -5 | sed 's/^/    /')"
fi

[ -z "$PROBLEMS" ] && exit 0

echo "A sessão está terminando com pendências:" >&2
printf '%b\n' "$PROBLEMS" >&2
echo "" >&2
echo "Nenhuma delas quebra a suíte agora — todas quebram o CI depois." >&2
exit 2
