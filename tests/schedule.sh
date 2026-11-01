#!/usr/bin/env bash
# Prüft die Zeitplanlogik des in install.sh eingebetteten Programms, ohne Netz und ohne Systemänderung:
# load_state, weekly_slot und run_pulse (Erfolg, volles Fenster, Wochenlimit, Fehlerserie, Abbruchgründe).
# Statt Claude Code läuft ein Nachbau, der vorbereitete stream-json-Ausgaben liefert; "sleep" ist ersetzt,
# damit die Pausen zwischen den Versuchen nicht ablaufen. Uhrzeiten sind relativ zur aktuellen Zeit.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Das Dienstprogramm steckt als Heredoc im Installer; zum Prüfen wird es herausgelöst.
# Die Befehlsverteilung am Ende (case ${1:-} in …) entfällt, damit das Sourcen nichts ausführt.
sed -n "/^cat >\"\$APP.new\" <<'LIMITPULSE_APP'\$/,/^LIMITPULSE_APP\$/p" install.sh | sed '1d;$d' \
  | sed '/^case \${1:-} in$/,$d' \
  | sed -e "s|^readonly APP_HOME=.*|readonly APP_HOME=$tmp/home|" \
        -e "s|^readonly CLAUDE=.*|readonly CLAUDE=$tmp/claude|" >"$tmp/limitpulse.sh"
grep -q "^readonly APP_HOME=$tmp/home\$" "$tmp/limitpulse.sh" || { echo "FEHLER: APP_HOME in install.sh nicht gefunden" >&2; exit 1; }
grep -q "^readonly CLAUDE=$tmp/claude\$" "$tmp/limitpulse.sh" || { echo "FEHLER: CLAUDE in install.sh nicht gefunden" >&2; exit 1; }
grep -q '^run_pulse() {$' "$tmp/limitpulse.sh" || { echo "FEHLER: run_pulse in install.sh nicht gefunden" >&2; exit 1; }

# Nachbau von Claude Code: "auth status" meldet die Abo-Anmeldung; jeder weitere Aufruf liefert Versuch N aus
# att/N.jsonl (Exit-Code aus att/N.rc, Standardfehler aus att/N.err); gibt es Versuch N nicht, gilt der letzte.
cat >"$tmp/claude" <<'FAKE'
#!/bin/bash
d=$(dirname "$0")
if [[ $1 == auth ]]; then
  echo '{"loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"}'
  exit 0
fi
n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$d/n"
f=$d/att/$n
[[ -e $f.jsonl ]] || f=$(ls "$d"/att/*.jsonl | sort -V | tail -n 1 | sed 's/\.jsonl$//')
cat "$f.jsonl"
[[ ! -e $f.err ]] || cat "$f.err" >&2
exit "$(cat "$f.rc" 2>/dev/null || echo 0)"
FAKE
chmod 755 "$tmp/claude"

mkdir -p "$tmp/cred"
printf 'sk-ant-oat01-%s\n' "$(printf 'a%.0s' $(seq 1 40))" >"$tmp/cred/oauth-token"
export CREDENTIALS_DIRECTORY=$tmp/cred

# shellcheck source=/dev/null  # zur Laufzeit aus install.sh erzeugt
. "$tmp/limitpulse.sh"
set +e
mkdir -p "$WORK_DIR"
SLEPT=()
# shellcheck disable=SC2317,SC2329  # Aufruf aus dem eingelesenen Programm
sleep() { SLEPT+=("$1"); }

fail=0
expect() {  # $1 = Beschreibung, $2 = erwartet, $3 = erhalten
  if [[ $2 == "$3" ]]; then echo "ok      $1"; else echo "FEHLER  $1: erwartet \"$2\", erhalten \"$3\""; fail=1; fi
}
expect_between() {  # $1 = Beschreibung, $2 = untere Grenze, $3 = obere Grenze, $4 = erhalten
  if (( $4 >= $2 && $4 <= $3 )); then echo "ok      $1"; else echo "FEHLER  $1: erwartet $2 bis $3, erhalten $4"; fail=1; fi
}

# --- load_state --------------------------------------------------------------------------------

state() { printf '%s\n' "$@" >"$STATE_FILE"; }
load() { load_state && echo "ja NEXT=$NEXT LAST_TIME=$LAST_TIME" || echo "nein"; }

state NEXT=1793516400 NEXT_SRC=first LAST_TIME=1793490000 LAST_OK=1 'LAST_INFO=a=b' WEEKLY_MISS=
expect "load_state: gültiger Zeitplan" "ja NEXT=1793516400 LAST_TIME=1793490000" "$(load)"
state NEXT=0 NEXT_SRC=retry
expect "load_state: NEXT=0 (sofort) ist gültig" "ja NEXT=0 LAST_TIME=" "$(load)"
state NEXT=08 NEXT_SRC=retry
expect "load_state: NEXT mit führender Null wird abgelehnt (bash läse eine Oktalzahl)" nein "$(load)"
state NEXT=1793516400 LAST_TIME=09
expect "load_state: LAST_TIME mit führender Null wird verworfen" "ja NEXT=1793516400 LAST_TIME=" "$(load)"
state NEXT=abc
expect "load_state: NEXT keine Zahl" nein "$(load)"
rm -f "$STATE_FILE"
expect "load_state: Datei fehlt" nein "$(load)"
state NEXT=1793516400
mv "$STATE_FILE" "$tmp/fremd"
ln -s "$tmp/fremd" "$STATE_FILE"
expect "load_state: Symlink wird nicht gelesen" nein "$(load)"
rm -f "$STATE_FILE"
mkfifo "$STATE_FILE"
# Ein Lesen der FIFO hinge ewig; die Untershell mit Zeitgrenze zeigt das als Fehler statt als Hänger.
got=$(timeout 10 bash -c ". '$tmp/limitpulse.sh'; load_state && echo ja || echo nein" 2>&1 || echo hing)
expect "load_state: FIFO wird nicht gelesen" nein "$got"
rm -f "$STATE_FILE"

# --- weekly_slot (Samstag 15:00 Uhr Europe/Berlin + 60 s, strikt nach "jetzt") ----------------------

slot() {  # $1 = Zeitpunkt in Europe/Berlin
  date -d "@$(weekly_slot "$(date -d "$1" +%s)")" '+%Y-%m-%d %H:%M:%S'
}
expect "weekly_slot: Sonntag -> kommender Samstag"          "2026-11-07 15:01:00" "$(slot '2026-11-01 12:00')"
expect "weekly_slot: Samstag vor dem Reset"                  "2026-11-07 15:01:00" "$(slot '2026-11-07 14:59:59')"
expect "weekly_slot: Samstag im Puffer"                      "2026-11-07 15:01:00" "$(slot '2026-11-07 15:00:59')"
expect "weekly_slot: Samstag genau nach dem Puffer"          "2026-11-14 15:01:00" "$(slot '2026-11-07 15:01:00')"
expect "weekly_slot: Sonntag nach dem Reset"                 "2026-11-14 15:01:00" "$(slot '2026-11-08 00:00:00')"
expect "weekly_slot: über das Ende der Sommerzeit hinweg"    "2026-10-31 15:01:00" "$(slot '2026-10-25 12:00')"
expect "weekly_slot: über den Beginn der Sommerzeit hinweg"  "2027-04-03 15:01:00" "$(slot '2027-03-27 16:00')"

# --- run_pulse ---------------------------------------------------------------------------------

init='{"type":"system","subtype":"init","apiKeySource":"none"}'
ok='{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
rl() {  # $1 = Status, $2 = Reset, $3 = Fenster (five_hour|seven_day)
  printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","resetsAt":%s,"rateLimitType":"%s"}}\n' "$1" "$2" "$3"
}
err() {  # $1 = Meldung
  printf '{"type":"result","subtype":"success","is_error":true,"result":"%s","api_error_status":429}\n' "$1"
}

# Führt einen Puls in einer Untershell aus und gibt aus: Quelle, Erfolg, Versuche, Pausen, NEXT relativ zum Start.
# $1 = Quelle des Zeitplans vor dem Puls, $2 = WEEKLY_MISS vor dem Puls
pulse() {
  (
    # shellcheck disable=SC2034  # LAST_INFO und LAST_TIME liest das eingelesene Programm
    NEXT=$t0 NEXT_SRC=${1:-first} LAST_TIME='' LAST_OK='' LAST_INFO='' WEEKLY_MISS=${2:-}
    SLEPT=()
    run_pulse >/dev/null
    echo "SRC=$NEXT_SRC OK=$LAST_OK TRIES=$(cat "$tmp/n" 2>/dev/null || echo 0) SLEEPS=${SLEPT[*]} NEXT=$NEXT MISS=${WEEKLY_MISS:+ja}"
  )
}
# Dieselbe Uhr wie im Programm (printf %()T, nicht date): beide können an Sekundengrenzen um 1 s auseinanderliegen.
prepare() { rm -rf "$tmp/att" "$tmp/n"; mkdir -p "$tmp/att"; printf -v t0 '%(%s)T' -1; }
field() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$2"; }   # Wert eines Feldes aus der Zeile von pulse()
pauses='30 60 120 240 480 900 900 900 900'

prepare
reset=$(( t0 + 17000 ))
{ echo "$init"; rl allowed "$reset" five_hour; echo "$ok"; } >"$tmp/att/1.jsonl"
r=$(pulse)
expect "Erfolg mit Reset: Zeitpunkt, Quelle, ein Versuch" \
  "SRC=reset OK=1 TRIES=1 SLEEPS= NEXT=$(( reset + 60 )) MISS=" "$r"

prepare
{ echo "$init"; echo "$ok"; } >"$tmp/att/1.jsonl"
r=$(pulse)
expect "Erfolg ohne Reset: Rückfall auf 5 h + 60 s" "fallback" "$(field SRC "$r")"
expect_between "Erfolg ohne Reset: Zeitpunkt" $(( t0 + 18060 )) $(( t0 + 18090 )) "$(field NEXT "$r")"

prepare
{ echo "$init"; rl allowed $(( t0 + 30 * 3600 )) five_hour; echo "$ok"; } >"$tmp/att/1.jsonl"
r=$(pulse)
expect "Erfolg mit unplausiblem Reset (30 h): Rückfall" "fallback" "$(field SRC "$r")"

prepare
reset=$(( t0 + 3600 ))
{ echo "$init"; rl rejected "$reset" five_hour; err "You've hit your 5-hour limit"; } >"$tmp/att/1.jsonl"
echo 1 >"$tmp/att/1.rc"
r=$(pulse)
expect "Volles 5-h-Fenster: keine Wiederholung, nächster Puls nach dem Reset" \
  "SRC=reset OK=0 TRIES=1 SLEEPS= NEXT=$(( reset + 60 )) MISS=" "$r"

prepare
{ echo "$init"; rl allowed $(( t0 + 3600 )) five_hour; err "API Error: 529 Overloaded"; } >"$tmp/att/1.jsonl"
echo 1 >"$tmp/att/1.rc"
r=$(pulse)
expect "Serverfehler bei freiem Fenster: 10 Versuche mit wachsenden Pausen" "retry 0 10 $pauses" \
  "$(field SRC "$r") $(field OK "$r") $(field TRIES "$r") $(sed -n 's/.*SLEEPS=\(.*\) NEXT=.*/\1/p' <<<"$r")"
expect_between "Serverfehler: nächster Versuch Pulsbeginn + 5 h + 60 s" $(( t0 + 18060 )) $(( t0 + 18090 )) "$(field NEXT "$r")"

prepare
{ echo "$init"; err "API Error: 529 Overloaded"; } >"$tmp/att/1.jsonl"
echo 1 >"$tmp/att/1.rc"
{ echo "$init"; echo "$ok"; } >"$tmp/att/2.jsonl"
r=$(pulse)
expect "Fehler, dann Erfolg: eine Pause, Erfolg im zweiten Versuch" "fallback 1 2 30" \
  "$(field SRC "$r") $(field OK "$r") $(field TRIES "$r") $(sed -n 's/.*SLEEPS=\(.*\) NEXT=.*/\1/p' <<<"$r")"

prepare
wreset=$(( t0 + 3 * 86400 ))
{ echo "$init"
  printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"seven_day"}}\n' "$wreset"
  err "You've hit your weekly limit"; } >"$tmp/att/1.jsonl"
echo 1 >"$tmp/att/1.rc"
r=$(pulse)
expect "Wochenlimit mit Reset von Claude Code: keine Wiederholung, Puls nach dem Wochen-Reset" \
  "SRC=weekly OK=0 TRIES=1 SLEEPS= NEXT=$(( wreset + 60 )) MISS=" "$r"

prepare
{ echo "$init"; err "You've hit your weekly limit"; } >"$tmp/att/1.jsonl"
echo 1 >"$tmp/att/1.rc"
r=$(pulse first)
expect "Wochenlimit ohne Reset: Annahme samstags 15:01 Uhr" "weekly 6-15:01" \
  "$(field SRC "$r") $(date -d "@$(field NEXT "$r")" +%u-%H:%M)"
r=$(pulse weekly)
expect "Wochenlimit gilt am angenommenen Termin noch: 5-h-Takt, Annahme vermerkt" "retry ja" \
  "$(field SRC "$r") $(sed -n 's/.*MISS=\(.*\)/\1/p' <<<"$r")"
r=$(pulse retry "$t0")
expect "Wochenlimit kurz nach einem Fehlschlag der Annahme: weiter 5-h-Takt" "retry" "$(field SRC "$r")"
r=$(pulse retry $(( t0 - 4 * 86400 )))
expect "Wochenlimit lange nach einem Fehlschlag der Annahme: Annahme gilt wieder" "weekly" "$(field SRC "$r")"

prepare
rm -f "$tmp/cred/oauth-token"
r=$(pulse)
expect "Token fehlt: kein Aufruf von Claude Code, kein Wiederholen" "retry 0 0" \
  "$(field SRC "$r") $(field OK "$r") $(field TRIES "$r")"
printf 'sk-ant-oat01-%s\n' "$(printf 'a%.0s' $(seq 1 40))" >"$tmp/cred/oauth-token"

prepare
{ echo '{"type":"system","subtype":"init","apiKeySource":"ANTHROPIC_API_KEY"}'; echo "$ok"; } >"$tmp/att/1.jsonl"
r=$(pulse)
expect "API-Schlüssel als Anmeldequelle: Puls zählt nicht, keine Wiederholung" "retry 0 1 " \
  "$(field SRC "$r") $(field OK "$r") $(field TRIES "$r") $(sed -n 's/.*SLEEPS=\(.*\) NEXT=.*/\1/p' <<<"$r")"

exit "$fail"
