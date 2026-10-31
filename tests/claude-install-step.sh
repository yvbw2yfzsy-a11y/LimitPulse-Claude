#!/usr/bin/env bash
# Prüft den Schritt "Claude Code für den Dienst-Benutzer" aus install.sh, ohne Netz und ohne Systemänderung:
# Eine vorhandene, neu genug Version bleibt unberührt (kein Download); fehlt Claude Code, ist es defekt oder
# zu alt, läuft der Download an. runuser, curl und die Meldungen sind durch Stubs ersetzt.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Abschnitt von der Überschrift bis vor dem nächsten ("--- Zeitplan"), samt Konstanten, die er braucht.
{
  sed -n 's/^readonly \(MIN_CLAUDE_VERSION=[0-9.]*\).*/\1/p' install.sh
  sed -n '/^# --- Claude Code für den Dienst-Benutzer/,/^# --- Zeitplan/p' install.sh | sed '$d'
} >"$tmp/step.sh"
grep -q '^claude_ok() {' "$tmp/step.sh" || { echo "Abschnitt in install.sh nicht gefunden" >&2; exit 1; }

# Läuft in einer Untershell je Fall; gibt die Ausgabe zurück und lässt den Download-Versuch erkennen.
run_case() {  # $1 = Ausgabe von "claude --version" ("" = Datei fehlt, "kaputt" = Exit-Code 1)
  rm -rf "${tmp:?}/case" && mkdir -p "$tmp/case/home" "$tmp/case/bin"
  if [[ $1 == kaputt ]]; then
    printf '#!/bin/sh\necho kaputt >&2\nexit 1\n' >"$tmp/case/home/claude"
  elif [[ -n $1 ]]; then
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" >"$tmp/case/home/claude"
  fi
  [[ -e $tmp/case/home/claude ]] && chmod 755 "$tmp/case/home/claude"
  # shellcheck disable=SC2034,SC2329  # Variablen und Funktionen nutzt der eingelesene Abschnitt
  (
    APP_HOME=$tmp/case/home APP_USER=x SAFE_PATH=/usr/bin:/bin CLAUDE=$tmp/case/home/claude
    CLAUDE_INSTALL_URL=http://invalid.example/install.sh
    runuser() { shift 3; "$@"; }                       # -u BENUTZER -- BEFEHL
    curl() { echo "DOWNLOAD"; return 22; }             # Download "schlägt fehl": beendet den Abschnitt
    die() { echo "ABBRUCH: $*"; exit 1; }
    # shellcheck source=/dev/null  # zur Laufzeit aus install.sh erzeugt
    . "$tmp/step.sh"
  ) 2>&1 || true
}

fail=0
expect() {  # $1 = Beschreibung, $2 = erwartetes Muster, $3 = Ausgabe, $4 = ja|nein (soll vorkommen)
  if [[ $3 == *$2* ]]; then got=ja; else got=nein; fi
  if [[ $got == "$4" ]]; then echo "ok      $1"; else echo "FEHLER  $1"; printf '%s\n' "$3" | sed 's/^/        /'; fail=1; fi
}

out=$(run_case 2.1.316)
expect "neu genug: kein Download" DOWNLOAD "$out" nein
expect "neu genug: Version wird gemeldet" "2.1.316 ist bereits installiert" "$out" ja

out=$(run_case 2.1.100)
expect "zu alt: Download läuft an" DOWNLOAD "$out" ja

out=$(run_case "")
expect "fehlt: Download läuft an" DOWNLOAD "$out" ja

out=$(run_case kaputt)
expect "defekt: Download läuft an" DOWNLOAD "$out" ja

exit "$fail"
