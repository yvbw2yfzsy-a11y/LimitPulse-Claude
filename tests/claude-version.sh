#!/usr/bin/env bash
# Prüft die Versionsprüfung claude_ok() aus install.sh: Sie entscheidet, ob eine vorhandene
# Claude-Code-Installation bleibt (neu genug) oder neu installiert wird (fehlt, defekt oder zu alt).
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

{
  sed -n 's/^readonly \(MIN_CLAUDE_VERSION=[0-9.]*\).*/\1/p' install.sh
  sed -n '/^claude_ok() {/,/^}/p' install.sh
} >"$tmp/claude_ok.sh"
grep -q '^MIN_CLAUDE_VERSION=' "$tmp/claude_ok.sh" || { echo "MIN_CLAUDE_VERSION in install.sh nicht gefunden" >&2; exit 1; }
grep -q '^claude_ok() {' "$tmp/claude_ok.sh" || { echo "claude_ok in install.sh nicht gefunden" >&2; exit 1; }
# shellcheck source=/dev/null  # zur Laufzeit aus install.sh erzeugt
. "$tmp/claude_ok.sh"

fail=0
expect() {  # $1 = ja|nein, $2 = Version
  local got=nein
  claude_ok "$2" && got=ja
  if [[ $got == "$1" ]]; then echo "ok      \"$2\" -> $got"; else echo "FEHLER  \"$2\": erwartet $1, erhalten $got"; fail=1; fi
}

echo "Mindestversion: $MIN_CLAUDE_VERSION"
expect ja "$MIN_CLAUDE_VERSION"
expect ja 2.1.316
expect ja 2.1.1000   # numerisch, nicht als Text verglichen
expect ja 2.2.0
expect ja 3.0.0
expect nein 2.1.292
expect nein 2.0.999
expect nein 1.9.9
expect nein ""       # keine erkennbare Version: neu installieren
exit "$fail"
