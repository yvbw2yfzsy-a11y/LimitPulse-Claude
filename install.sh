#!/usr/bin/env bash
# LimitPulse – Installer für den Raspberry Pi (Raspberry Pi OS 64 Bit / Debian mit systemd)
#
# Richtet einen Hintergrunddienst ein, der das 5-Stunden-Nutzungsfenster eines
# Claude-Abos (Pro/Max) in Gang hält: Sobald das Fenster zurückgesetzt ist, ruft er
# Claude Code (CLI, Print-Modus) mit der Nachricht „Hi“ auf. Erster Puls ist der
# nächste 08:00 Uhr (Europe/Berlin). Angemeldet wird ausschließlich mit einem
# Abo-Token aus „claude setup-token“, nie mit einem API-Schlüssel.
#
# Aufruf:  sudo bash install.sh
#
# Angelegt bzw. ersetzt werden ausschließlich:
#   Benutzer „limitpulse“ (Systembenutzer) mit Home /var/lib/limitpulse
#     darin: Claude Code (~/.local), Zeitplan (state), Protokoll (limitpulse.log)
#   /opt/limitpulse/limitpulse.sh           Programm
#   /etc/limitpulse/oauth-token             Abo-Token (nur für root lesbar)
#   /etc/systemd/system/limitpulse.service  systemd-Dienst
#   /usr/local/bin/limitpulse               Befehl (Verweis auf das Programm)
# Es werden keine Pakete installiert, keine Ports geöffnet und keine anderen
# Dienste verändert oder neu gestartet.

set -euo pipefail

readonly APP_USER=limitpulse
readonly APP_HOME=/var/lib/limitpulse
readonly APP_DIR=/opt/limitpulse
readonly APP=$APP_DIR/limitpulse.sh
readonly CONF_DIR=/etc/limitpulse
readonly TOKEN_FILE=$CONF_DIR/oauth-token
readonly UNIT=limitpulse.service
readonly UNIT_FILE=/etc/systemd/system/$UNIT
readonly BIN_LINK=/usr/local/bin/limitpulse
readonly MARKER="Verwaltet von LimitPulse"
readonly CLAUDE=$APP_HOME/.local/bin/claude
readonly CLAUDE_INSTALL_URL=https://claude.ai/install.sh
readonly MIN_CLAUDE_VERSION=2.1.293   # Haiku 5.5 braucht laut Doku Claude Code ab dieser Version
readonly MIN_MEM_KB=3300000           # „4 GB“-Pi meldet ca. 3,7–3,9 GB in /proc/meminfo
readonly SAFE_PATH=/usr/local/bin:/usr/bin:/bin

fresh=yes      # yes = nichts von LimitPulse war vorhanden; nur dann wird bei einem Fehler zurückgebaut
changed=no     # yes = der Installer hat bereits etwas verändert
finished=no

die() { printf '\nFEHLER: %s\n' "$*" >&2; exit 1; }

ask_yes() {  # $1 = Frage, $2 = Vorgabe (j/n)
  local answer
  read -rp "$1" answer </dev/tty || return 1
  answer=${answer:-$2}
  [[ $answer == [jJyY]* ]]
}

rollback() {
  set +e
  [[ $finished == yes || $changed != yes ]] && return
  if [[ $fresh != yes ]]; then
    echo "Die Installation ist fehlgeschlagen. Eine frühere LimitPulse-Installation war vorhanden und bleibt wie sie ist; sie kann unvollständig sein." >&2
    echo "Zum Aufräumen:  sudo limitpulse uninstall   und danach dieses Skript erneut starten." >&2
    return
  fi
  echo "Die Installation ist fehlgeschlagen. Alles, was dieses Skript angelegt hat, wird wieder entfernt …" >&2
  systemctl disable --now "$UNIT" 2>/dev/null
  rm -f "$UNIT_FILE" "$BIN_LINK"
  systemctl daemon-reload 2>/dev/null
  rm -rf "$APP_DIR" "$CONF_DIR"
  if getent passwd "$APP_USER" >/dev/null; then userdel "$APP_USER" 2>/dev/null; fi
  rm -rf --one-file-system "$APP_HOME"
  echo "Zurückgebaut. Es ist nichts von LimitPulse übrig geblieben." >&2
}
trap rollback EXIT

check_dir() {  # $1 = Verzeichnis, übrige Argumente = Namen, die darin vorkommen dürfen
  local dir=$1 entry name allowed a
  shift
  [[ -e $dir || -L $dir ]] || return 0
  [[ -d $dir && ! -L $dir ]] || die "$dir existiert bereits und ist kein Verzeichnis. Abbruch, nichts wurde verändert."
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    allowed=no
    for a in "$@"; do [[ $name == "$a" ]] && allowed=yes; done
    [[ $allowed == yes ]] || die "$dir enthält die fremde Datei \"$name\". Abbruch, nichts wurde verändert."
  done
}

# --- Voraussetzungen prüfen (noch keine Änderungen) ---------------------------

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausführen:  sudo bash install.sh"

arch=$(uname -m)
[[ $arch == aarch64 ]] \
  || die "Dieser Installer läuft nur auf 64-Bit-Raspberry-Pi-OS (uname -m = aarch64), hier ist es \"$arch\". Claude Code unterstützt laut Doku kein 32-Bit-ARM. Bitte das 64-Bit-Raspberry-Pi-OS verwenden."
[[ $(getconf LONG_BIT) == 64 ]] \
  || die "Der Kernel ist 64-Bit, das Betriebssystem aber 32-Bit. Claude Code unterstützt laut Doku kein 32-Bit-ARM. Bitte das 64-Bit-Raspberry-Pi-OS verwenden."

os_id=; os_ver=
if [[ -r /etc/os-release ]]; then
  read -r os_id os_ver < <(. /etc/os-release; echo "${ID:-x} ${VERSION_ID:-0}")
fi
case $os_id in
  debian | raspbian)
    [[ $os_ver =~ ^[0-9]+$ ]] || os_ver=99   # Testing/Sid ohne Versionsnummer
    (( os_ver >= 12 )) || die "Debian/Raspberry Pi OS $os_ver ist zu alt. Benötigt wird Bookworm (12) oder neuer."
    ;;
  *) echo "Hinweis: Das System meldet sich als \"${os_id:-unbekannt}\", nicht als Raspberry Pi OS/Debian. Der Installer läuft weiter, ist dafür aber nicht getestet." ;;
esac

mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
(( ${mem_kb:-0} >= MIN_MEM_KB )) \
  || die "Zu wenig Arbeitsspeicher: $(( ${mem_kb:-0} / 1024 )) MB. Claude Code benötigt laut Doku mindestens 4 GB RAM."

if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null; then
  die "systemd wird benötigt, läuft hier aber nicht."
fi
sd_version=$(systemctl --version | awk 'NR == 1 { print $2 }')
sd_version=${sd_version%%[!0-9]*}
(( ${sd_version:-0} >= 247 )) \
  || die "systemd ${sd_version:-?} ist zu alt (benötigt 247 oder neuer, also Raspberry Pi OS Bullseye oder neuer)."

missing=
for tool in curl python3 runuser useradd userdel getent timeout mktemp sort sed tail stat; do
  command -v "$tool" >/dev/null || missing+=" $tool"
done
[[ -z $missing ]] \
  || die "Es fehlen Programme:$missing. Der Installer installiert keine Pakete; bitte vorher selbst installieren (z. B. sudo apt install curl python3) und das Skript erneut starten."
[[ -f /usr/share/zoneinfo/Europe/Berlin ]] || die "Zeitzonendaten fehlen (Paket tzdata)."
[[ -r /dev/tty ]] || die "Keine Konsole für die Eingabe des Tokens gefunden."

# Nichts überschreiben, was nicht von LimitPulse stammt.
for f in "$APP" "$UNIT_FILE"; do
  if [[ -e $f ]] && ! grep -q "$MARKER" "$f"; then
    die "$f existiert bereits und stammt nicht von LimitPulse. Abbruch, nichts wurde verändert."
  fi
done
if [[ -e $BIN_LINK || -L $BIN_LINK ]] && [[ $(readlink "$BIN_LINK") != "$APP" ]]; then
  die "$BIN_LINK existiert bereits und gehört nicht zu LimitPulse. Abbruch, nichts wurde verändert."
fi
if [[ ! -e $UNIT_FILE ]] && systemctl list-unit-files --no-legend "$UNIT" 2>/dev/null | grep -q .; then
  die "Ein anderer Dienst namens $UNIT existiert bereits. Abbruch, nichts wurde verändert."
fi
check_dir "$APP_DIR" limitpulse.sh limitpulse.sh.new
check_dir "$CONF_DIR" oauth-token
if pw=$(getent passwd "$APP_USER"); then
  IFS=: read -r _ _ _ _ pw_gecos pw_home _ <<<"$pw"
  [[ $pw_gecos == "$MARKER" && $pw_home == "$APP_HOME" ]] \
    || die "Der Benutzer \"$APP_USER\" existiert bereits und gehört nicht zu LimitPulse. Abbruch, nichts wurde verändert."
else
  getent group "$APP_USER" >/dev/null \
    && die "Eine Gruppe \"$APP_USER\" existiert bereits und gehört nicht zu LimitPulse. Abbruch, nichts wurde verändert."
  [[ -e $APP_HOME || -L $APP_HOME ]] \
    && die "$APP_HOME existiert bereits und gehört nicht zu LimitPulse. Abbruch, nichts wurde verändert."
fi

for p in "$UNIT_FILE" "$BIN_LINK" "$APP_DIR" "$CONF_DIR" "$APP_HOME"; do
  [[ -e $p || -L $p ]] && fresh=no
done
getent passwd "$APP_USER" >/dev/null && fresh=no

state_kept=no
[[ -s $APP_HOME/state ]] && state_kept=yes

# Erster Puls: nächster 08:00 Uhr in Europe/Berlin.
now=$(date +%s)
anchor=$(TZ=Europe/Berlin date -d 'today 08:00' +%s)
(( anchor > now )) || anchor=$(TZ=Europe/Berlin date -d 'tomorrow 08:00' +%s)
anchor_text=$(TZ=Europe/Berlin date -d "@$anchor" '+%d.%m.%Y um %H:%M Uhr (%Z)')

cat <<EOF

LimitPulse – Installation
=========================
Folgendes wird eingerichtet:
  Systembenutzer "$APP_USER" mit Home $APP_HOME
  Claude Code im Home dieses Benutzers (offizieller Installer von claude.ai, Auto-Updates an)
  $APP
  $TOKEN_FILE   (nur für root lesbar)
  $UNIT_FILE
  $BIN_LINK
Andere Programme, Dienste und Einstellungen werden nicht verändert.

Ein Puls = ein Aufruf von Claude Code mit "Hi" (Haiku, Abo-Anmeldung, keine Sitzung gespeichert).
Danach folgt jeder Puls, sobald das 5-Stunden-Fenster zurückgesetzt ist (+ 60 s Puffer).
EOF
if [[ $state_kept == yes ]]; then
  echo "Hinweis: LimitPulse ist bereits installiert und wird aktualisiert; der gespeicherte Zeitplan bleibt erhalten."
else
  echo "Erster Puls:   $anchor_text"
fi
echo
ask_yes "Fortfahren? [J/n] " j || { echo "Abgebrochen, nichts wurde verändert."; exit 0; }

# --- Benutzer und Verzeichnisse -------------------------------------------------

changed=yes
if ! getent passwd "$APP_USER" >/dev/null; then
  useradd --system --user-group --home-dir "$APP_HOME" --create-home \
    --shell /usr/sbin/nologin --comment "$MARKER" "$APP_USER"
fi
install -d -m 755 -o "$APP_USER" -g "$APP_USER" "$APP_HOME"
# Alles darin legt der Dienst-Benutzer selbst an, nicht root (Symlink-Schutz im Home des Dienstes).
( cd "$APP_HOME" && runuser -u "$APP_USER" -- mkdir -p work )
install -d -m 755 -o root -g root "$APP_DIR" "$CONF_DIR"

# --- Programm ------------------------------------------------------------------

cat >"$APP.new" <<'LIMITPULSE_APP'
#!/usr/bin/env bash
# Verwaltet von LimitPulse. Wird bei erneuter Installation ersetzt.
#
# Befehle:
#   limitpulse status          Dienstzustand, letzter und nächster Puls, letzte Meldungen
#   sudo limitpulse token      Abo-Token ändern
#   sudo limitpulse uninstall  LimitPulse vollständig entfernen
#   limitpulse daemon          Hintergrunddienst (startet systemd, nicht von Hand aufrufen)

set -uo pipefail
export TZ=Europe/Berlin
umask 022

readonly MARKER="Verwaltet von LimitPulse"
readonly APP_USER=limitpulse
readonly APP_HOME=/var/lib/limitpulse
readonly APP_DIR=/opt/limitpulse
readonly CONF_DIR=/etc/limitpulse
readonly TOKEN_FILE=$CONF_DIR/oauth-token
readonly UNIT=limitpulse.service
readonly UNIT_FILE=/etc/systemd/system/$UNIT
readonly BIN_LINK=/usr/local/bin/limitpulse
readonly STATE_FILE=$APP_HOME/state
readonly LOG_FILE=$APP_HOME/limitpulse.log
readonly WORK_DIR=$APP_HOME/work
readonly CLAUDE=$APP_HOME/.local/bin/claude

readonly PROMPT=Hi
readonly SYSTEM_PROMPT='Reply with exactly one word: ok'
readonly INTERVAL=$((5 * 3600))   # Länge des Nutzungsfensters
readonly BUFFER=60                # Puffer nach dem Reset (Sekunden)
readonly MAX_ATTEMPTS=10          # Versuche je Puls
readonly PAUSES=(30 60 120 240 480 900 900 900 900)   # Pausen zwischen den Versuchen (Sekunden)
readonly ATTEMPT_TIMEOUT=180      # Höchstdauer eines Aufrufs (Sekunden)
readonly LOG_MAX_BYTES=262144
# Wochenlimit: Der Reset kommt laut Beobachtung des Nutzers immer samstags um 15:00 Uhr (Europe/Berlin).
# Das ist eine Annahme, keine dokumentierte Zusage. Stimmt sie nicht, fällt der Dienst von selbst auf den 5-h-Takt zurück.
readonly WEEKLY_DOW=6             # Wochentag des Resets als "date +%u": 6 = Samstag
readonly WEEKLY_TIME=15:00
readonly WEEKLY_MISS_KEEP=259200  # so lange (3 Tage) gilt die Annahme nach einem Fehlschlag als widerlegt

# Ein Aufruf von Claude Code.
#   -p / --print   Print-Modus: ein Aufruf, dann beendet sich der Prozess
#   --model        feste Modell-ID statt Alias (der Alias "haiku" zeigt je nach Version auf ein anderes Modell)
#   --effort low   niedrigster Aufwand (Thinking lässt sich bei Haiku 5.5 laut Doku nicht abschalten)
#   --system-prompt ersetzt den gesamten Standard-Systemprompt
#   --tools ""     keine eingebauten Tools (kleinerer Kontext)
#   --setting-sources user  keine Projekt-/Local-Einstellungen; das Home des Dienstes enthält keine eigenen
# Bewusst NICHT --bare: es liest CLAUDE_CODE_OAUTH_TOKEN nicht.
readonly -a CLAUDE_ARGS=(
  -p "$PROMPT"
  --model claude-haiku-5-5
  --effort low
  --system-prompt "$SYSTEM_PROMPT"
  --tools ""
  --max-turns 1
  --no-session-persistence
  --strict-mcp-config
  --disable-slash-commands
  --setting-sources user
  --output-format stream-json --verbose
)

LP_TOKEN=
NEXT='' NEXT_SRC='' LAST_TIME='' LAST_OK='' LAST_INFO='' WEEKLY_MISS=''
P_OK=0 P_RESET='' P_INFO='' P_KEYSRC='' P_WEEKLY=0

fmt_time() {
  (( $1 == 0 )) && { printf 'sofort'; return; }
  printf '%(%d.%m.%Y %H:%M:%S %Z)T' "$1"
}

fmt_span() {
  local s=$1
  (( s < 0 )) && s=0
  printf '%d h %02d min' $(( s / 3600 )) $(( s % 3600 / 60 ))
}

# Abo-Token aus "claude setup-token": nur Buchstaben, Ziffern, "-" und "_".
# API-Schlüssel (sk-ant-api…) sind kein Abo-Token und werden abgelehnt.
valid_token() { [[ $1 =~ ^[A-Za-z0-9_-]{20,512}$ && $1 != sk-ant-api* ]]; }

# Token und alles, was wie ein Anthropic-Schlüssel aussieht, aus Texten entfernen.
scrub() {
  local s=$1
  [[ -n $LP_TOKEN ]] && s=${s//"$LP_TOKEN"/***}
  printf '%s' "$s" | sed -E 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-***/g'
}

log() {  # $1 = info|warn|err, übrige Argumente = Text
  local level=$1 prio line stamp size
  shift
  case $level in err) prio='<3>' ;; warn) prio='<4>' ;; *) prio='<6>' ;; esac
  line=$(scrub "$*")
  printf '%s%s\n' "$prio" "$line"   # Journal (systemd wertet <N> als Priorität aus)
  printf -v stamp '%(%d.%m.%Y %H:%M:%S)T' -1
  { printf '%s %s\n' "$stamp" "$line" >>"$LOG_FILE"; } 2>/dev/null || return 0
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null) || return 0
  if (( size > LOG_MAX_BYTES )); then
    tail -n 500 "$LOG_FILE" >"$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

# --- Zeitplan --------------------------------------------------------------------

load_state() {
  local k v
  NEXT='' NEXT_SRC='' LAST_TIME='' LAST_OK='' LAST_INFO='' WEEKLY_MISS=''
  [[ -r $STATE_FILE ]] || return 1
  while IFS='=' read -r k v || [[ -n $k ]]; do
    case $k in
      NEXT) NEXT=$v ;;
      NEXT_SRC) NEXT_SRC=$v ;;
      LAST_TIME) LAST_TIME=$v ;;
      LAST_OK) LAST_OK=$v ;;
      LAST_INFO) LAST_INFO=$v ;;
      WEEKLY_MISS) WEEKLY_MISS=$v ;;
    esac
  done <"$STATE_FILE"
  [[ $NEXT =~ ^[0-9]{1,12}$ ]] || return 1
  [[ $LAST_TIME =~ ^[0-9]{1,12}$ ]] || LAST_TIME=
  [[ $WEEKLY_MISS =~ ^[0-9]{1,12}$ ]] || WEEKLY_MISS=
  [[ $NEXT_SRC =~ ^(first|reset|fallback|retry|weekly)$ ]] || NEXT_SRC=
  return 0
}

save_state() {
  local info
  info=$(scrub "$LAST_INFO" | tr -d '\r\n' | head -c 300)
  {
    printf 'NEXT=%s\nNEXT_SRC=%s\n' "$NEXT" "$NEXT_SRC"
    printf 'LAST_TIME=%s\nLAST_OK=%s\n' "$LAST_TIME" "$LAST_OK"
    printf 'LAST_INFO=%s\nWEEKLY_MISS=%s\n' "$info" "$WEEKLY_MISS"
  } >"$STATE_FILE.tmp" 2>/dev/null && mv -f "$STATE_FILE.tmp" "$STATE_FILE" \
    || { log warn "Zeitplan konnte nicht nach $STATE_FILE geschrieben werden."; return 1; }
}

# Erster Puls: nächster 08:00 Uhr Europe/Berlin.
first_slot() {
  local now t
  printf -v now '%(%s)T' -1
  t=$(date -d 'today 08:00' +%s)
  (( t > now )) || t=$(date -d 'tomorrow 08:00' +%s)
  echo "$t"
}

# Nächster Wochen-Reset (samstags 15:00 Uhr Europe/Berlin) + BUFFER, der nach Zeitpunkt $1 liegt.
weekly_slot() {
  local now=$1 dow day days t
  dow=$(date -d "@$now" +%u)
  day=$(date -d "@$now" +%F)
  days=$(( (WEEKLY_DOW - dow + 7) % 7 ))
  t=$(date -d "$day $days days $WEEKLY_TIME" +%s)
  (( t + BUFFER > now )) || t=$(date -d "$day $(( days + 7 )) days $WEEKLY_TIME" +%s)
  echo $(( t + BUFFER ))
}

src_text() {
  case $1 in
    weekly) echo "Wochenlimit erreicht, Reset laut Annahme samstags $WEEKLY_TIME Uhr (+ ${BUFFER} s Puffer)" ;;
    first) echo "erster Puls um 08:00 Uhr" ;;
    reset) echo "Reset des 5-Stunden-Fensters laut Claude Code (+ ${BUFFER} s Puffer)" ;;
    fallback) echo "letzte erfolgreiche Antwort + 5 h + ${BUFFER} s" ;;
    retry) echo "Pulsbeginn + 5 h + ${BUFFER} s (nach $MAX_ATTEMPTS Fehlversuchen)" ;;
    *) echo "unbekannt" ;;
  esac
}

# --- Ein Aufruf von Claude Code ----------------------------------------------------

# Wertet die stream-json-Ausgabe aus. Erfolg = Ergebnismeldung ohne Fehlerkennzeichen mit nicht leerer Antwort.
# Reset-Zeit nur aus einem rate_limit_event des 5-Stunden-Fensters (Agent-SDK-Referenz: SDKRateLimitEvent).
PARSER=$(cat <<'PY'
import json, sys

def one(s):
    return " ".join(str(s).split())[:200]

res = None
resets = ""
keysrc = ""
weekly = 0
try:
    f = open(sys.argv[1], encoding="utf-8", errors="replace")
except OSError:
    f = []
for line in f:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if not isinstance(m, dict):
        continue
    t = m.get("type")
    if t == "result":
        res = m
    elif t == "system" and m.get("subtype") == "init":
        keysrc = one(m.get("apiKeySource", ""))
    elif t == "rate_limit_event":
        i = m.get("rate_limit_info")
        if isinstance(i, dict):
            kind = i.get("rateLimitType", i.get("rate_limit_type"))
            if kind == "seven_day" and i.get("status") == "rejected":
                weekly = 1
            r = i.get("resetsAt", i.get("resets_at"))
            if kind in (None, "five_hour") and isinstance(r, (int, float)) and not isinstance(r, bool):
                resets = str(int(r))

ok = 0
info = "keine Ergebnismeldung in der Ausgabe"
if res is not None:
    text = res.get("result")
    text = text.strip() if isinstance(text, str) else ""
    if "weekly limit" in text.lower():
        weekly = 1
    if res.get("is_error"):
        info = one(text or res.get("subtype") or "Fehler")
    elif not text:
        info = "leere Antwort"
    else:
        ok = 1
        info = one(text)[:40]
print("OK=%d" % ok)
print("RESET=%s" % resets)
print("KEYSRC=%s" % keysrc)
print("WEEKLY=%d" % weekly)
print("INFO=%s" % info)
PY
)

# Ergebnis in P_OK, P_RESET, P_INFO, P_KEYSRC, P_WEEKLY (1 = Wochenlimit als Fehlerursache erkannt).
# Rückgabe: 0 = Aufruf ausgewertet, 2 = dauerhaftes Problem (Token fehlt, oder Claude Code meldet
# eine API-Anmeldequelle), Wiederholen sinnlos.
pulse_once() {
  local tmp rc k v err token_file=${CREDENTIALS_DIRECTORY:-/nonexistent}/oauth-token
  P_OK=0 P_RESET='' P_INFO='' P_KEYSRC='' P_WEEKLY=0

  LP_TOKEN=''
  [[ -r $token_file ]] && LP_TOKEN=$(<"$token_file")
  LP_TOKEN=${LP_TOKEN//[[:space:]]/}
  if ! valid_token "$LP_TOKEN"; then
    LP_TOKEN=
    P_INFO="Abo-Token fehlt oder ist ungültig (neu setzen mit: sudo limitpulse token)"
    return 2
  fi

  tmp=$(mktemp -d) || { LP_TOKEN=; P_INFO="kein temporäres Verzeichnis"; return 0; }

  # Eigene Untershell mit leerem Environment: Alles außer PATH, HOME und LANG wird entfernt,
  # damit weder ANTHROPIC_API_KEY noch ANTHROPIC_AUTH_TOKEN (noch eine andere ANTHROPIC_*-,
  # CLAUDE_CODE_USE_*- oder Proxy-Variable) zu Claude Code durchkommt. Beide haben laut Doku
  # Vorrang vor CLAUDE_CODE_OAUTH_TOKEN und würden über die API abgerechnet statt über das Abo.
  # Der Token wird per export (Shell-Builtin) übergeben und steht so nie in einer Argumentliste.
  (
    cd "$WORK_DIR" || exit 97
    for k in $(compgen -e); do
      case $k in PATH | HOME | LANG) ;; *) unset "$k" 2>/dev/null ;; esac
    done
    export HOME=$APP_HOME LANG=C.UTF-8 PATH=/usr/local/bin:/usr/bin:/bin
    export CLAUDE_CODE_OAUTH_TOKEN=$LP_TOKEN
    export CLAUDE_CODE_MAX_OUTPUT_TOKENS=4096      # Obergrenze; die Kürze kommt vom Systemprompt
    export CLAUDE_CODE_MAX_RETRIES=2               # Wiederholungen übernimmt LimitPulse selbst
    export CLAUDE_CODE_SKIP_PROMPT_HISTORY=1
    export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
    export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
    exec timeout --kill-after=10 "$ATTEMPT_TIMEOUT" "$CLAUDE" "${CLAUDE_ARGS[@]}"
  ) >"$tmp/out" 2>"$tmp/err" </dev/null
  rc=$?

  while IFS='=' read -r k v; do
    case $k in
      OK) P_OK=$v ;;
      RESET) P_RESET=$v ;;
      KEYSRC) P_KEYSRC=$v ;;
      WEEKLY) P_WEEKLY=$v ;;
      INFO) P_INFO=$v ;;
    esac
  done < <(python3 -I -c "$PARSER" "$tmp/out" 2>/dev/null)

  # Zweite Sicherung: meldet Claude Code (system/init, SDK-Referenz "ApiKeySource") eine API-Quelle,
  # zählt der Puls nicht, und es gibt keine Wiederholung. Das Environment oben schließt das schon aus.
  case $P_KEYSRC in
    ANTHROPIC_API_KEY | apiKeyHelper | "/login managed key")
      rm -rf "$tmp"
      LP_TOKEN=''
      P_OK=0
      P_INFO="Claude Code meldet die Anmeldequelle \"$P_KEYSRC\": das würde über die API abgerechnet statt über das Abo. Puls nicht gewertet"
      return 2 ;;
  esac

  if (( rc == 0 )) && [[ $P_OK == 1 ]]; then
    P_OK=1
  else
    P_OK=0
    err=$(tr '\r\n' '  ' <"$tmp/err" | head -c 300)
    [[ ${err,,} == *"weekly limit"* ]] && P_WEEKLY=1
    case $rc in
      124 | 137) P_INFO="Zeitüberschreitung nach ${ATTEMPT_TIMEOUT} s" ;;
      *) P_INFO="Exit-Code $rc${P_INFO:+; $P_INFO}${err:+; stderr: $err}" ;;
    esac
  fi
  rm -rf "$tmp"
  P_INFO=$(scrub "$P_INFO")   # landet in Protokoll und Zeitplan-Datei (für alle lesbar)
  LP_TOKEN=''
  return 0
}

# Das Wochenlimit ist voll: Wiederholen bringt bis zum Reset nichts. Der Dienst wartet auf den
# Wochen-Reset (samstags 15:00 Uhr + Puffer), damit der erste Puls danach das neue Fenster startet.
# War dieser Termin selbst schon der Wochen-Termin und das Limit gilt noch, stimmt die Annahme
# nicht (oder das Limit wurde sofort wieder verbraucht): dann gilt für 3 Tage der normale 5-h-Takt.
weekly_limit_hit() {
  local started=$1 now
  printf -v now '%(%s)T' -1
  LAST_TIME=$now LAST_OK=0
  if [[ $NEXT_SRC == weekly ]] || { [[ -n $WEEKLY_MISS ]] && (( now - WEEKLY_MISS < WEEKLY_MISS_KEEP )); }; then
    [[ $NEXT_SRC == weekly ]] && WEEKLY_MISS=$now
    NEXT=$(( started + INTERVAL + BUFFER )); NEXT_SRC=retry
    LAST_INFO="Wochenlimit besteht weiter, der Reset kam nicht wie angenommen; normaler 5-h-Takt"
    save_state
    log warn "Wochenlimit besteht weiter, obwohl der Wochen-Reset (samstags $WEEKLY_TIME Uhr) angenommen war. Annahme prüfen. Nächster Versuch: $(fmt_time "$NEXT")."
  else
    NEXT=$(weekly_slot "$now"); NEXT_SRC=weekly
    LAST_INFO="Wochenlimit erreicht, wartet auf den Wochen-Reset"
    save_state
    log warn "Wochenlimit erreicht. Keine weiteren Versuche bis zum Wochen-Reset. Nächster Puls: $(fmt_time "$NEXT")."
  fi
}

# Ein Puls: bis zu MAX_ATTEMPTS Versuche mit wachsenden Pausen, danach Fehler protokollieren.
run_pulse() {
  local started now attempt=0 rc pause
  printf -v started '%(%s)T' -1
  log info "Puls startet (geplant: $(fmt_time "$NEXT"))."

  while (( attempt < MAX_ATTEMPTS )); do
    attempt=$(( attempt + 1 ))
    pulse_once
    rc=$?
    if (( rc == 0 )) && [[ $P_OK == 1 ]]; then
      printf -v now '%(%s)T' -1
      if [[ $P_RESET =~ ^[0-9]{1,12}$ ]] && (( P_RESET > now && P_RESET <= now + INTERVAL + 300 )); then
        NEXT=$(( P_RESET + BUFFER )); NEXT_SRC=reset
      else
        [[ -n $P_RESET ]] && log warn "Gemeldete Reset-Zeit \"$P_RESET\" ist unplausibel und wird ignoriert."
        NEXT=$(( now + INTERVAL + BUFFER )); NEXT_SRC=fallback
      fi
      LAST_TIME=$now LAST_OK=1 LAST_INFO="Antwort \"$P_INFO\" (Versuch $attempt von $MAX_ATTEMPTS)"
      WEEKLY_MISS=''
      save_state
      log info "Puls erfolgreich (Versuch $attempt/$MAX_ATTEMPTS, Antwort: \"$P_INFO\", Anmeldequelle laut Claude Code: ${P_KEYSRC:-unbekannt})."
      log info "Nächster Puls: $(fmt_time "$NEXT") – $(src_text "$NEXT_SRC")."
      return
    fi
    if (( rc == 2 )); then
      log err "$P_INFO. Kein weiterer Versuch."
      break
    fi
    log warn "Versuch $attempt/$MAX_ATTEMPTS fehlgeschlagen: $P_INFO"
    if [[ $P_WEEKLY == 1 ]]; then
      weekly_limit_hit "$started"
      return
    fi
    if (( attempt < MAX_ATTEMPTS )); then
      pause=${PAUSES[attempt - 1]}
      log info "Neuer Versuch in $pause s."
      sleep "$pause"
    fi
  done

  printf -v now '%(%s)T' -1
  NEXT=$(( started + INTERVAL + BUFFER )); NEXT_SRC=retry
  LAST_TIME=$now LAST_OK=0 LAST_INFO="Puls fehlgeschlagen: $P_INFO"
  save_state
  log err "FEHLER: Puls ohne Erfolg beendet (Versuche: $attempt von $MAX_ATTEMPTS). Letzte Meldung: $P_INFO"
  log err "Nächster Versuch zum planmäßigen Zeitpunkt: $(fmt_time "$NEXT")."
}

cmd_daemon() {
  local now wait
  mkdir -p "$WORK_DIR" 2>/dev/null
  if ! load_state; then
    NEXT=$(first_slot); NEXT_SRC=first
    LAST_TIME='' LAST_OK='' LAST_INFO=''
    save_state
  fi
  log info "LimitPulse gestartet. Nächster Puls: $(fmt_time "$NEXT")."

  while :; do
    printf -v now '%(%s)T' -1
    if (( now >= NEXT )); then
      (( NEXT > 0 && now - NEXT > 300 )) && log info "Geplanter Puls ($(fmt_time "$NEXT")) wurde verpasst, zum Beispiel durch einen Neustart. Er wird jetzt nachgeholt."
      run_pulse
      continue
    fi
    # Höchstens 60 s am Stück schlafen, damit Zeitkorrekturen (NTP) sofort greifen.
    wait=$(( NEXT - now ))
    (( wait > 60 )) && wait=60
    sleep "$wait"
  done
}

# --- Befehle für den Benutzer ---------------------------------------------------------

cmd_status() {
  local now active
  printf -v now '%(%s)T' -1
  active=$(systemctl is-active "$UNIT" 2>/dev/null)
  echo "Dienst:         ${active:-unbekannt}"
  if load_state; then
    if [[ -z $LAST_TIME ]]; then
      echo "Letzter Puls:   noch keiner"
    elif [[ $LAST_OK == 1 ]]; then
      echo "Letzter Puls:   $(fmt_time "$LAST_TIME") – erfolgreich: $LAST_INFO"
    else
      echo "Letzter Puls:   $(fmt_time "$LAST_TIME") – FEHLGESCHLAGEN: $LAST_INFO"
    fi
    if (( NEXT > now )); then
      echo "Nächster Puls:  $(fmt_time "$NEXT") (in $(fmt_span $(( NEXT - now ))))"
    else
      echo "Nächster Puls:  $(fmt_time "$NEXT") (fällig)"
    fi
    echo "Quelle:         $(src_text "$NEXT_SRC")"
  else
    echo "Zeitplan:       noch nicht angelegt (Dienst nicht gestartet?)"
  fi
  if [[ -e $TOKEN_FILE ]]; then
    echo "Abo-Token:      gespeichert in $TOKEN_FILE (nur für root lesbar)"
  else
    echo "Abo-Token:      FEHLT – eintragen mit: sudo limitpulse token"
  fi
  echo
  echo "Letzte Meldungen:"
  if [[ -r $LOG_FILE ]]; then
    tail -n 15 "$LOG_FILE"
  else
    echo "  (noch keine)"
  fi
}

# Token verdeckt abfragen und in NEW_TOKEN ablegen.
NEW_TOKEN=
read_token() {
  local tok
  while :; do
    read -rsp "Abo-Token einfügen (Eingabe bleibt unsichtbar), dann Enter: " tok </dev/tty || return 1
    echo
    tok=${tok//[[:space:]]/}
    if [[ -z $tok ]]; then
      echo "Keine Eingabe, bitte erneut."
    elif [[ $tok == sk-ant-api* ]]; then
      echo "Das ist ein API-Schlüssel, kein Abo-Token. API-Schlüssel zählen nicht auf das Abo. Bitte den Token aus \"claude setup-token\" verwenden."
    elif ! valid_token "$tok"; then
      echo "Ungültiges Format (nur Buchstaben, Ziffern, - und _, mindestens 20 Zeichen), bitte erneut."
    else
      break
    fi
  done
  [[ $tok == sk-ant-oat* ]] || echo "Hinweis: Abo-Token beginnen üblicherweise mit \"sk-ant-oat\"."
  NEW_TOKEN=$tok
}

cmd_token() {
  local tmp
  [[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen: sudo limitpulse token" >&2; return 1; }
  read_token || return 1
  tmp=$(mktemp "$CONF_DIR/.oauth-token.XXXXXX") || return 1
  if ! { printf '%s\n' "$NEW_TOKEN" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$TOKEN_FILE"; }; then
    rm -f "$tmp"
    NEW_TOKEN=
    echo "Token konnte nicht gespeichert werden." >&2
    return 1
  fi
  NEW_TOKEN=
  echo "Token gespeichert in $TOKEN_FILE, nur für root lesbar."

  # Ist der letzte Puls gescheitert (meist wegen des alten Tokens), wird der Puls jetzt sofort
  # fällig statt erst zum nächsten Termin, sonst bliebe das Fenster bis zu 5 Stunden ungenutzt.
  # Nicht beim Wochenlimit: Dort hilft ein neuer Token nicht. Die Zeitplan-Datei gehört dem
  # Dienst-Benutzer, deshalb ändert sie nicht root, sondern ein Aufruf als dieser Benutzer.
  if load_state && [[ $LAST_OK == 0 && $NEXT_SRC != weekly ]]; then
    systemctl stop "$UNIT" 2>/dev/null
    runuser -u "$APP_USER" -- "$(readlink -f "$0")" retry-now \
      && echo "Der letzte Puls war fehlgeschlagen und wird nach dem Start sofort wiederholt."
  fi
  if [[ ${1:-} != --no-restart ]] && systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
    systemctl restart "$UNIT" && echo "Dienst neu gestartet, der neue Token gilt ab sofort. Der Zeitplan bleibt erhalten."
  fi
}

cmd_uninstall() {
  local answer entry
  [[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen: sudo limitpulse uninstall" >&2; return 1; }
  read -rp "LimitPulse vollständig entfernen, einschließlich Token, Benutzer \"$APP_USER\" und der darin installierten Claude-Code-Version? [j/N] " answer </dev/tty || return 1
  [[ $answer == [jJyY]* ]] || { echo "Abgebrochen."; return 0; }

  systemctl disable --now "$UNIT" 2>/dev/null
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$UNIT" 2>/dev/null
  [[ -L $BIN_LINK ]] && rm -f "$BIN_LINK"
  rm -rf "$CONF_DIR" "$APP_DIR"

  entry=$(getent passwd "$APP_USER")
  if [[ -z $entry ]]; then
    rm -rf --one-file-system "$APP_HOME"
  elif [[ $(cut -d: -f5 <<<"$entry") == "$MARKER" && $(cut -d: -f6 <<<"$entry") == "$APP_HOME" ]]; then
    userdel "$APP_USER" 2>/dev/null || echo "Hinweis: Benutzer \"$APP_USER\" konnte nicht gelöscht werden." >&2
    rm -rf --one-file-system "$APP_HOME"
  else
    echo "Hinweis: Der Benutzer \"$APP_USER\" stammt nicht von LimitPulse und wurde nicht entfernt." >&2
  fi
  echo "LimitPulse wurde vollständig entfernt, einschließlich der Claude-Code-Installation des Dienstes."
  echo "Der Abo-Token bleibt bei Anthropic gültig, bis er abläuft oder in deinem Konto widerrufen wird."
}

# Intern: "limitpulse token" ruft das als Dienst-Benutzer auf. Macht den nächsten Puls sofort fällig.
cmd_retry_now() {
  load_state && [[ $LAST_OK == 0 ]] || return 1
  NEXT=0 NEXT_SRC=retry
  save_state
}

case ${1:-} in
  daemon) cmd_daemon ;;
  status) cmd_status ;;
  retry-now) cmd_retry_now ;;
  token) cmd_token "${2:-}" ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "LimitPulse – Befehle:"
    echo "  limitpulse status          Dienstzustand, letzter und nächster Puls, letzte Meldungen"
    echo "  sudo limitpulse token      Abo-Token ändern"
    echo "  sudo limitpulse uninstall  LimitPulse vollständig entfernen"
    ;;
esac
LIMITPULSE_APP
chmod 755 "$APP.new"
mv -f "$APP.new" "$APP"
ln -sfn "$APP" "$BIN_LINK"

# --- Abo-Token -----------------------------------------------------------------

echo
echo "Den Abo-Token erzeugst du mit \"claude setup-token\" (das geht auch auf einem anderen Rechner); er gilt laut Doku ein Jahr."
if [[ -s $TOKEN_FILE ]] && ask_yes "Ein Token ist bereits gespeichert. Beibehalten? [J/n] " j; then
  echo "Vorhandener Token bleibt erhalten."
else
  "$APP" token --no-restart || die "Kein Token gespeichert. Installation bitte erneut starten."
fi

# --- Claude Code für den Dienst-Benutzer ----------------------------------------------

echo
echo "Lade den offiziellen Claude-Code-Installer von claude.ai …"
dl=$(mktemp -d)
curl -fsSL --connect-timeout 20 --max-time 120 -o "$dl/claude-install.sh" "$CLAUDE_INSTALL_URL" \
  || { rm -rf "$dl"; die "Der Claude-Code-Installer konnte nicht von $CLAUDE_INSTALL_URL geladen werden (Netzwerk?)."; }
[[ $(head -c 2 "$dl/claude-install.sh") == '#!' ]] \
  || { rm -rf "$dl"; die "Von $CLAUDE_INSTALL_URL kam kein Installationsskript."; }
echo "Installiere Claude Code für den Benutzer \"$APP_USER\" (kann einige Minuten dauern) …"
# Erst vollständig laden, dann ausführen (statt "curl | bash"): ein abgebrochener Download läuft so nie halb.
# Leeres Environment: nichts aus root's Umgebung gelangt in den Installer.
( cd "$APP_HOME" && runuser -u "$APP_USER" -- env -i HOME="$APP_HOME" PATH="$SAFE_PATH" LANG=C.UTF-8 \
    timeout 900 bash <"$dl/claude-install.sh" ) \
  || { rm -rf "$dl"; die "Die Installation von Claude Code ist fehlgeschlagen."; }
rm -rf "$dl"

[[ -x $CLAUDE ]] || die "Claude Code wurde nicht nach $CLAUDE installiert."
claude_out=$(cd "$APP_HOME" && runuser -u "$APP_USER" -- env -i HOME="$APP_HOME" PATH="$SAFE_PATH" LANG=C.UTF-8 \
  "$CLAUDE" --version 2>&1) || die "\"claude --version\" schlägt fehl: $claude_out"
[[ $claude_out =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || die "Die Claude-Code-Version ist nicht erkennbar: $claude_out"
claude_version=${BASH_REMATCH[1]}
[[ $(printf '%s\n%s\n' "$MIN_CLAUDE_VERSION" "$claude_version" | sort -V | head -n 1) == "$MIN_CLAUDE_VERSION" ]] \
  || die "Claude Code $claude_version ist zu alt für Haiku 5.5 (benötigt $MIN_CLAUDE_VERSION oder neuer)."
echo "Claude Code $claude_version installiert."

# --- Zeitplan -----------------------------------------------------------------

if [[ ! -s $APP_HOME/state ]]; then
  # Als Dienst-Benutzer schreiben, nicht als root: so kann kein Symlink im Home root-Dateien überschreiben.
  # shellcheck disable=SC2016  # "$1" und "$2" soll erst die innere Shell auswerten
  ( cd "$APP_HOME" && runuser -u "$APP_USER" -- bash -c \
      'umask 022; printf "NEXT=%s\nNEXT_SRC=first\nLAST_TIME=\nLAST_OK=\nLAST_INFO=\nWEEKLY_MISS=\n" "$1" >"$2"' \
      _ "$anchor" "$APP_HOME/state" )
fi

# --- systemd-Dienst ------------------------------------------------------------

cat >"$UNIT_FILE" <<EOF
# $MARKER. Wird bei erneuter Installation ersetzt.
[Unit]
Description=LimitPulse - schickt Claude Code "Hi", sobald das 5-Stunden-Fenster zurueckgesetzt ist
After=network-online.target time-sync.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
ExecStart=$APP daemon
Restart=always
RestartSec=30
# Das Token liest systemd als root und legt es nur diesem Dienst offen; die Datei bleibt root-only.
LoadCredential=oauth-token:$TOKEN_FILE
# Gegen API-Abrechnung: diese Variablen dürfen nie im Dienst ankommen (Claude Code zieht sie dem Abo-Token vor).
UnsetEnvironment=ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_PROFILE
# Schreibbar ist nur $APP_HOME (Home des Dienst-Benutzers mit Claude Code, Zeitplan, Protokoll).
StateDirectory=limitpulse
# Rücksicht auf die anderen Projekte auf dem Pi.
Nice=10
OOMScoreAdjust=500
# Härtung. Bewusst NICHT gesetzt: MemoryDenyWriteExecute (Claude Code nutzt vermutlich JIT-Speicher)
# und SystemCallFilter (ein zu enger Filter könnte Claude Code unbemerkt brechen; nicht getestet).
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RemoveIPC=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT_FILE"

# --- Starten -------------------------------------------------------------------

systemctl daemon-reload
systemctl enable --quiet "$UNIT"
systemctl restart "$UNIT"
sleep 2
systemctl is-active --quiet "$UNIT" \
  || die "Der Dienst ist nicht gestartet. Details: sudo journalctl -u $UNIT -n 50"

finished=yes
echo
echo "LimitPulse ist installiert und läuft im Hintergrund, auch nach einem Neustart."
if [[ $state_kept == yes ]]; then
  echo "Der bisherige Zeitplan bleibt erhalten (Stand: limitpulse status)."
else
  echo "Erster Puls:  $anchor_text"
  echo "Danach:       jeweils kurz nach dem Reset des 5-Stunden-Fensters."
fi
cat <<EOF

Bedienung:
  limitpulse status          Dienstzustand, letzter und nächster Puls, letzte Meldungen
  sudo limitpulse token      Abo-Token ändern
  sudo limitpulse uninstall  LimitPulse vollständig entfernen
EOF
