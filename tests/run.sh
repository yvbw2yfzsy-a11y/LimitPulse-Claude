#!/usr/bin/env bash
# Alle Prüfungen ohne Netzwerk und ohne Systemänderung: Syntax, Parser, Claude-Code-Installationsschritt, Zeitplanlogik, shellcheck.
# Der Rauchtest gegen eine installierte Claude-Code-Version (tests/smoke.sh) läuft getrennt, weil er Claude Code braucht.
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

bash tests/parser.sh
bash tests/claude-version.sh
bash tests/claude-install-step.sh
bash tests/schedule.sh

# Das Programm shellcheck kommt zuletzt und mit klarer Meldung: Alle anderen Prüfungen sind dann schon gelaufen.
if ! command -v shellcheck >/dev/null; then
  echo "FEHLER  shellcheck fehlt (z. B. sudo apt install shellcheck) – die übrigen Prüfungen oben sind bestanden" >&2
  exit 1
fi
shellcheck install.sh "$tmp/limitpulse.sh" tests/*.sh
echo "ok      shellcheck"
