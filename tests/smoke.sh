#!/usr/bin/env bash
# Rauchtest gegen die installierte Claude-Code-Version, ohne Netzwerk nach außen und ohne Änderung am System.
#
# Führt pulse_once() aus dem in install.sh eingebetteten Programm unverändert aus (mit denselben Flags,
# derselben Umgebung und derselben Auswertung wie auf dem Pi). Nur drei Dinge sind ersetzt: das Home des
# Dienstes (Temp-Verzeichnis), der Pfad zu Claude Code (ein Wrapper, der ANTHROPIC_BASE_URL auf einen lokalen
# Stub setzt) und die Quelle des Tokens (Dummy). Der Stub beantwortet nur POST /v1/messages: erst mit Erfolg,
# danach mit den Fehlern, die den Zeitplan steuern (5-Stunden-Fenster voll, Wochenlimit, Anmeldung abgelehnt).
#
# Zweck: Auto-Updates sind an. Ändert eine neue Claude-Code-Version ein Flag oder das Format von
# "claude auth status" oder der Ausgabe, soll das hier auffallen und nicht erst auf dem Pi.
#
# Aufruf:  bash tests/smoke.sh        (claude muss im PATH liegen, oder CLAUDE_BIN=/pfad/zu/claude setzen)
# Grenze:  Der Stub prüft die Seite des CLI. Ob die echte API genau diese Anfrage annimmt, prüft er nicht.
set -euo pipefail
cd "$(dirname "$0")/.."

real=${CLAUDE_BIN:-$(command -v claude || true)}
[[ -n $real && -x $real ]] || { echo "FEHLER: claude nicht gefunden (Claude Code installieren oder CLAUDE_BIN setzen)" >&2; exit 1; }
real=$(readlink -f "$real")

tmp=$(mktemp -d)
srv=
# shellcheck disable=SC2317,SC2329  # Aufruf über trap
cleanup() {
  if [[ -n $srv ]]; then kill "$srv" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Das Dienstprogramm steckt als Heredoc im Installer; zum Prüfen wird es herausgelöst.
# Die Befehlsverteilung am Ende (case ${1:-} in …) entfällt, damit das Sourcen nichts ausführt.
sed -n "/^cat >\"\$APP.new\" <<'LIMITPULSE_APP'\$/,/^LIMITPULSE_APP\$/p" install.sh | sed '1d;$d' \
  | sed '/^case \${1:-} in$/,$d' \
  | sed -e "s|^readonly APP_HOME=.*|readonly APP_HOME=$tmp/home|" \
        -e "s|^readonly CLAUDE=.*|readonly CLAUDE=$tmp/claude|" >"$tmp/limitpulse.sh"
grep -q "^readonly APP_HOME=$tmp/home\$" "$tmp/limitpulse.sh" || { echo "FEHLER: APP_HOME in install.sh nicht gefunden" >&2; exit 1; }
grep -q "^readonly CLAUDE=$tmp/claude\$" "$tmp/limitpulse.sh" || { echo "FEHLER: CLAUDE in install.sh nicht gefunden" >&2; exit 1; }
grep -q '^pulse_once() {$' "$tmp/limitpulse.sh" || { echo "FEHLER: pulse_once in install.sh nicht gefunden" >&2; exit 1; }

# Stub starten. Was er antwortet, steht in $tmp/mode (fehlt die Datei: Erfolg).
reset=$(( $(date +%s) + 4 * 3600 ))
python3 -I tests/stub_server.py "$tmp/port" "$tmp/requests.jsonl" "$reset" "$tmp/mode" &
srv=$!
for _ in $(seq 1 50); do [[ -s $tmp/port ]] && break; sleep 0.1; done
[[ -s $tmp/port ]] || { echo "FEHLER: Stub-Server startet nicht" >&2; exit 1; }
port=$(<"$tmp/port")

# Wrapper statt Claude Code: setzt nur die Adresse des Stubs, alles andere bleibt wie im Dienst.
{
  echo '#!/bin/sh'
  printf 'export PATH=%q\n' "$PATH"
  echo "export ANTHROPIC_BASE_URL=http://127.0.0.1:$port"
  printf 'exec %q "$@"\n' "$real"
} >"$tmp/claude"
chmod 755 "$tmp/claude"

mkdir -p "$tmp/cred"
printf 'sk-ant-oat01-%s\n' "$(printf 'a%.0s' $(seq 1 40))" >"$tmp/cred/oauth-token"
export CREDENTIALS_DIRECTORY=$tmp/cred

# shellcheck source=/dev/null  # zur Laufzeit aus install.sh erzeugt
. "$tmp/limitpulse.sh"
set +e
mkdir -p "$WORK_DIR"

echo "Claude Code: $("$real" --version 2>&1 | head -n 1)"
pulse_once
rc=$?

fail=0
check() {  # $1 = Beschreibung, übrige Argumente = Bedingung
  local what=$1
  shift
  if "$@"; then echo "ok      $what"; else echo "FEHLER  $what"; fail=1; fi
}

check "pulse_once wertet den Aufruf aus (Rückgabe 0)" test "$rc" -eq 0
check "Puls gilt als erfolgreich (Antwort: \"$P_INFO\")" test "$P_OK" -eq 1
check "Antwort ist \"ok\"" test "$P_INFO" = ok
# shellcheck disable=SC2317,SC2329  # Aufruf über check()
not_api_source() {  # dieselben Quellen, die pulse_once als API-Abrechnung ablehnt
  case $1 in ANTHROPIC_API_KEY | apiKeyHelper | "/login managed key") return 1 ;; esac
}
check "Anmeldequelle ist keine API-Quelle (\"${P_KEYSRC:-}\")" not_api_source "${P_KEYSRC:-}"

# Was der Stub tatsächlich empfangen hat.
report=$(python3 -I - "$tmp/requests.jsonl" <<'PY'
import json, sys
msgs, other = [], []
for line in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(line)
    (msgs if e["method"] == "POST" and e["path"].startswith("/v1/messages") else other).append(e)
print("MESSAGES=%d" % len(msgs))
print("OTHER=%s" % ",".join(sorted({e["method"] + " " + e["path"].split("?")[0] for e in other})))
b = (msgs[0].get("body") or {}) if msgs else {}
print("MODEL=%s" % b.get("model"))
print("TOOLS=%d" % len(b.get("tools") or []))
print("EFFORT=%s" % (b.get("output_config") or {}).get("effort"))
print("MAXTOKENS=%s" % b.get("max_tokens"))
PY
)
declare -A got=()
while IFS='=' read -r k v; do got[$k]=$v; done <<<"$report"

check "genau eine Anfrage an /v1/messages (${got[MESSAGES]:-?})" test "${got[MESSAGES]:-}" = 1
check "Modell claude-haiku-5-5 (${got[MODEL]:-?})" test "${got[MODEL]:-}" = claude-haiku-5-5
check "keine Tools gesendet (Anzahl: ${got[TOOLS]:-?})" test "${got[TOOLS]:-}" = 0
check "Aufwand low (${got[EFFORT]:-?})" test "${got[EFFORT]:-}" = low
check "Ausgabegrenze 4096 (${got[MAXTOKENS]:-?})" test "${got[MAXTOKENS]:-}" = 4096
[[ -z ${got[OTHER]:-} ]] || echo "Hinweis: weitere Anfragen an die Basis-URL: ${got[OTHER]}"

if [[ -n $P_RESET ]]; then
  check "Reset-Zeit des 5-Stunden-Fensters wird übernommen ($P_RESET)" test "$P_RESET" = "$reset"
else
  echo "Hinweis: Claude Code meldet bei diesem Stub keinen Reset; der Dienst würde den Fallback (+ 5 h) nehmen."
fi

# Fehlerfälle, die den Zeitplan steuern: Ändert Claude Code deren Ausgabe, soll das hier auffallen.
echo five >"$tmp/mode"
pulse_once
rc=$?
check "5-Stunden-Fenster voll: ausgewertet, kein Erfolg (Rückgabe $rc, Antwort: \"$P_INFO\")" test "$rc-$P_OK" = 0-0
check "5-Stunden-Fenster voll: als abgelehnt erkannt, Reset übernommen ($P_FIVEREJ, ${P_RESET:-?})" \
  test "$P_FIVEREJ-$P_RESET-$P_WEEKLY" = "1-$reset-0"

echo week >"$tmp/mode"
pulse_once
rc=$?
check "Wochenlimit: ausgewertet, kein Erfolg (Rückgabe $rc, Antwort: \"$P_INFO\")" test "$rc-$P_OK" = 0-0
check "Wochenlimit: erkannt, Wochen-Reset übernommen ($P_WEEKLY, ${P_WRESET:-?})" \
  test "$P_WEEKLY-$P_WRESET" = "1-$(( reset + 3 * 86400 ))"

echo auth >"$tmp/mode"
pulse_once
rc=$?
check "Anmeldung abgelehnt: dauerhafter Fehler (Rückgabe $rc, Erfolg $P_OK)" test "$rc-$P_OK-$P_AUTH" = 2-0-1
check "Anmeldung abgelehnt: Meldung nennt \"sudo limitpulse token\" ($P_INFO)" \
  grep -qF "sudo limitpulse token" <<<"$P_INFO"

exit "$fail"
