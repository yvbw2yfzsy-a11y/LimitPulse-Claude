#!/usr/bin/env bash
# Alle Prüfungen ohne Netzwerk und ohne Systemänderung: Syntax, shellcheck, Parser.
# Aufruf: bash tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Das Dienstprogramm steckt als Heredoc im Installer; zum Prüfen wird es herausgelöst.
sed -n "/^cat >\"\$APP.new\" <<'LIMITPULSE_APP'\$/,/^LIMITPULSE_APP\$/p" install.sh | sed '1d;$d' >"$tmp/limitpulse.sh"
[[ -s $tmp/limitpulse.sh ]] || { echo "Eingebettetes Programm in install.sh nicht gefunden" >&2; exit 1; }

bash -n install.sh
bash -n "$tmp/limitpulse.sh"
echo "ok      bash -n"

shellcheck install.sh "$tmp/limitpulse.sh" tests/*.sh
echo "ok      shellcheck"

bash tests/parser.sh
