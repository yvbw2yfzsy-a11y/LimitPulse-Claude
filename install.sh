#!/usr/bin/env bash
# LimitPulse – Installer für den Raspberry Pi (Raspberry Pi OS / Debian mit systemd)
#
# Richtet einen eigenständigen Hintergrunddienst ein, der alle 5 Stunden eine
# minimale Anfrage an die offizielle Anthropic API sendet. Erster Termin ist der
# nächste 08:00 Uhr (Europe/Berlin), danach exakt alle 5 Stunden.
#
# Aufruf:  sudo bash install.sh
#
# Angelegt bzw. ersetzt werden ausschließlich diese Dateien:
#   /opt/limitpulse/limitpulse.sh           Programm
#   /etc/limitpulse/limitpulse.conf         Einstellungen (erster Termin, Modell)
#   /etc/limitpulse/api-key                 API-Schlüssel (nur für root lesbar)
#   /etc/systemd/system/limitpulse.service  systemd-Dienst
#   /usr/local/bin/limitpulse               Befehl (Verweis auf das Programm)
# Es werden keine Pakete installiert, keine Benutzer angelegt, keine Ports
# geöffnet und keine anderen Dienste verändert oder neu gestartet.

set -euo pipefail

readonly APP_DIR=/opt/limitpulse
readonly APP=$APP_DIR/limitpulse.sh
readonly CONF_DIR=/etc/limitpulse
readonly CONF_FILE=$CONF_DIR/limitpulse.conf
readonly KEY_FILE=$CONF_DIR/api-key
readonly UNIT=limitpulse.service
readonly UNIT_FILE=/etc/systemd/system/$UNIT
readonly BIN_LINK=/usr/local/bin/limitpulse
readonly MARKER="Verwaltet von LimitPulse"
readonly MODEL=claude-haiku-5-5

die() { printf '\nFEHLER: %s\n' "$*" >&2; exit 1; }

ask_yes() {  # $1 = Frage, $2 = Vorgabe (j/n)
  local answer
  read -rp "$1" answer </dev/tty || return 1
  answer=${answer:-$2}
  [[ $answer == [jJyY]* ]]
}

# --- Voraussetzungen prüfen (noch keine Änderungen) ---------------------------

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausführen:  sudo bash install.sh"
if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null; then
  die "systemd wird benötigt, läuft hier aber nicht."
fi
sd_version=$(systemctl --version | awk 'NR == 1 { print $2 }')
sd_version=${sd_version%%[!0-9]*}
(( ${sd_version:-0} >= 247 )) \
  || die "systemd ${sd_version:-?} ist zu alt (benötigt 247 oder neuer, also Raspberry Pi OS Bullseye oder neuer)."
command -v curl >/dev/null \
  || die "curl fehlt. Bitte zuerst installieren:  sudo apt install curl  – danach dieses Skript erneut starten."
[[ -f /usr/share/zoneinfo/Europe/Berlin ]] || die "Zeitzonendaten fehlen (Paket tzdata)."
[[ -r /dev/tty ]] || die "Keine Konsole für die Eingabe des API-Schlüssels gefunden."

# Nichts überschreiben, was nicht von LimitPulse stammt.
for f in "$APP" "$CONF_FILE" "$UNIT_FILE"; do
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

# Erster Termin: nächster 08:00 Uhr in Europe/Berlin.
now=$(date +%s)
anchor=$(TZ=Europe/Berlin date -d 'today 08:00' +%s)
(( anchor > now )) || anchor=$(TZ=Europe/Berlin date -d 'tomorrow 08:00' +%s)
anchor_text=$(TZ=Europe/Berlin date -d "@$anchor" '+%d.%m.%Y um %H:%M Uhr (%Z)')

reinstall=no
[[ -e $UNIT_FILE ]] && reinstall=yes

cat <<EOF

LimitPulse – Installation
=========================
Folgendes wird eingerichtet:
  $APP
  $CONF_FILE
  $KEY_FILE   (nur für root lesbar)
  $UNIT_FILE
  $BIN_LINK
Andere Programme, Dienste und Einstellungen werden nicht verändert.

Modell:          $MODEL
Erster Termin:   $anchor_text, danach alle 5 Stunden
EOF
[[ $reinstall == yes ]] && echo "Hinweis: LimitPulse ist bereits installiert und wird aktualisiert; der 5-Stunden-Rhythmus beginnt neu."
echo
ask_yes "Fortfahren? [J/n] " j || { echo "Abgebrochen, nichts wurde verändert."; exit 0; }

# --- Programm ------------------------------------------------------------------

install -d -m 755 -o root -g root "$APP_DIR" "$CONF_DIR"

cat >"$APP.new" <<'LIMITPULSE_APP'
#!/usr/bin/env bash
# Verwaltet von LimitPulse. Wird bei erneuter Installation ersetzt.
#
# Befehle:
#   limitpulse status          Status, nächste Termine und letzte Meldungen
#   sudo limitpulse key        API-Schlüssel ändern oder ersetzen
#   sudo limitpulse uninstall  LimitPulse vollständig entfernen
#   limitpulse daemon          Hintergrunddienst (startet systemd, nicht von Hand aufrufen)

set -uo pipefail
export TZ=Europe/Berlin

readonly CONF_DIR=/etc/limitpulse
readonly CONF_FILE=$CONF_DIR/limitpulse.conf
readonly KEY_FILE=$CONF_DIR/api-key
readonly APP_DIR=/opt/limitpulse
readonly BIN_LINK=/usr/local/bin/limitpulse
readonly UNIT=limitpulse.service
readonly UNIT_FILE=/etc/systemd/system/$UNIT

readonly API_URL=https://api.anthropic.com/v1/messages
readonly API_VERSION=2026-10-21
readonly INTERVAL=$((5 * 3600))  # Rhythmus: 5 Stunden
readonly GRACE=120               # Start bis 2 min nach einem Termin gilt noch als pünktlich
readonly STOP_BEFORE_NEXT=300    # Wiederholungen enden 5 min vor dem nächsten Termin
readonly FIRST_DELAY=30          # erste Pause vor einem erneuten Versuch (Sekunden)
readonly MAX_DELAY=900           # längste Pause zwischen zwei Versuchen (15 min)

LP_ANCHOR=
LP_MODEL=

fmt_time() { printf '%(%d.%m.%Y %H:%M %Z)T' "$1"; }

# Nur Buchstaben, Ziffern, "-" und "_": so kann der Schlüssel nichts in die
# curl-Konfiguration einschleusen.
valid_key() { [[ $1 =~ ^[A-Za-z0-9_-]{20,}$ ]]; }

load_conf() {
  local name value
  [[ -r $CONF_FILE ]] || { echo "Einstellungsdatei $CONF_FILE fehlt." >&2; return 1; }
  while IFS='=' read -r name value; do
    case $name in
      LP_ANCHOR) LP_ANCHOR=$value ;;
      LP_MODEL) LP_MODEL=$value ;;
    esac
  done <"$CONF_FILE"
  [[ $LP_ANCHOR =~ ^[0-9]+$ ]] || { echo "LP_ANCHOR in $CONF_FILE ist ungültig." >&2; return 1; }
  [[ $LP_MODEL =~ ^[a-z0-9.-]+$ ]] || { echo "LP_MODEL in $CONF_FILE ist ungültig." >&2; return 1; }
}

# Erster Termin, der nicht vor Zeitpunkt $1 liegt.
next_slot() {
  local t=$1
  if (( t <= LP_ANCHOR )); then
    echo "$LP_ANCHOR"
  else
    echo $(( LP_ANCHOR + (t - LP_ANCHOR + INTERVAL - 1) / INTERVAL * INTERVAL ))
  fi
}

# Eine Anfrage senden. Ergebnis in RESULT (ok|retry|fatal), DETAIL, RETRY_AFTER.
send_request() {
  local key='' tmp code rc name value
  local key_file=${CREDENTIALS_DIRECTORY:-/nonexistent}/api-key
  RESULT=fatal DETAIL='' RETRY_AFTER=0

  [[ -r $key_file ]] && key=$(<"$key_file")
  key=${key//[[:space:]]/}
  if ! valid_key "$key"; then
    DETAIL="API-Schlüssel fehlt oder ist ungültig (ändern mit: sudo limitpulse key)"
    return
  fi

  tmp=$(mktemp -d) || { RESULT=retry DETAIL="kein temporäres Verzeichnis"; return; }
  # Der Schlüssel geht über stdin an curl und erscheint so nicht in der Prozessliste.
  code=$(printf 'header = "x-api-key: %s"\n' "$key" |
    curl --silent --show-error --config - \
      --connect-timeout 15 --max-time 60 \
      --header 'content-type: application/json' \
      --header "anthropic-version: $API_VERSION" \
      --data-binary "$PAYLOAD" \
      --output "$tmp/body" --dump-header "$tmp/headers" --write-out '%{http_code}' \
      "$API_URL" 2>"$tmp/err")
  rc=$?

  if (( rc != 0 )); then
    RESULT=retry
    DETAIL="Verbindungsfehler (curl $rc): $(tr -d '\r\n' <"$tmp/err" | head -c 200)"
  else
    DETAIL="HTTP $code: $(tr -d '\r\n' <"$tmp/body" | head -c 500)"
    case $code in
      2??) RESULT=ok ;;
      408 | 409 | 429 | 5??) RESULT=retry ;;  # vorübergehend (u. a. 429 Rate-Limit, 529 überlastet)
      *) RESULT=fatal ;;                     # z. B. 400, 401 ungültiger Schlüssel, 403, 404
    esac
    while IFS=: read -r name value; do
      if [[ ${name,,} == retry-after ]]; then
        value=${value//[!0-9]/}
        [[ -n $value ]] && RETRY_AFTER=$(( 10#${value:0:6} ))
      fi
    done <"$tmp/headers"
  fi
  rm -rf "$tmp"
}

# Anfrage für einen Termin senden; bei vorübergehenden Fehlern so lange erneut
# versuchen, bis sie durchgeht (längstens bis kurz vor dem nächsten Termin).
run_slot() {
  local slot=$1 attempt=0 delay=$FIRST_DELAY pause now
  local give_up=$(( slot + INTERVAL - STOP_BEFORE_NEXT ))

  echo "Termin $(fmt_time "$slot"): sende Anfrage ($LP_MODEL)"
  while :; do
    attempt=$(( attempt + 1 ))
    send_request
    case $RESULT in
      ok)
        echo "Erfolgreich (Versuch $attempt). $DETAIL"
        return 0 ;;
      fatal)
        echo "<3>Fehlgeschlagen, kein erneuter Versuch (Fehler ist nicht vorübergehend). $DETAIL"
        return 1 ;;
    esac
    pause=$delay
    (( RETRY_AFTER > pause )) && pause=$RETRY_AFTER
    printf -v now '%(%s)T' -1
    if (( now + pause > give_up )); then
      echo "<3>Versuch $attempt fehlgeschlagen, keine weiteren Versuche für diesen Termin. $DETAIL"
      return 1
    fi
    echo "<4>Versuch $attempt vorübergehend fehlgeschlagen, neuer Versuch in ${pause}s. $DETAIL"
    sleep "$pause"
    delay=$(( delay * 2 > MAX_DELAY ? MAX_DELAY : delay * 2 ))
  done
}

cmd_daemon() {
  local now cur next wait last_done=0 announced=0
  load_conf || exit 1
  # Minimale Anfrage: kürzeste Eingabe, 1 Ausgabe-Token, kein Thinking.
  PAYLOAD=$(printf '{"model":"%s","max_tokens":1,"thinking":{"type":"disabled"},"messages":[{"role":"user","content":"Hi"}]}' "$LP_MODEL")
  echo "LimitPulse gestartet. Erster Termin: $(fmt_time "$LP_ANCHOR"), danach alle 5 Stunden."

  while :; do
    printf -v now '%(%s)T' -1
    if (( now >= LP_ANCHOR )); then
      cur=$(( LP_ANCHOR + (now - LP_ANCHOR) / INTERVAL * INTERVAL ))
      if (( cur > last_done && now - cur <= GRACE )); then
        last_done=$cur
        run_slot "$cur"
        continue
      fi
      next=$(( cur + INTERVAL ))
    else
      next=$LP_ANCHOR
    fi
    if (( next != announced )); then
      echo "Nächster Termin: $(fmt_time "$next")"
      announced=$next
    fi
    # Höchstens 60 s am Stück schlafen, damit Zeitkorrekturen (NTP) sofort greifen.
    wait=$(( next - now ))
    (( wait > 60 )) && wait=60
    sleep "$wait"
  done
}

cmd_status() {
  local now next i
  load_conf || return 1
  printf -v now '%(%s)T' -1
  next=$(next_slot $(( now + 1 )))
  echo "Dienst:           $(systemctl is-active "$UNIT" 2>/dev/null)"
  echo "Modell:           $LP_MODEL"
  echo "Erster Termin:    $(fmt_time "$LP_ANCHOR")"
  echo "Nächste Termine:  $(fmt_time "$next")"
  for i in 1 2 3; do
    echo "                  $(fmt_time $(( next + i * INTERVAL )))"
  done
  if [[ -e $KEY_FILE ]]; then
    echo "API-Schlüssel:    gespeichert in $KEY_FILE"
  else
    echo "API-Schlüssel:    FEHLT – eintragen mit: sudo limitpulse key"
  fi
  echo
  echo "Letzte Meldungen:"
  if [[ $EUID -eq 0 ]] || id -nG | grep -qwE 'adm|systemd-journal'; then
    journalctl --unit "$UNIT" --lines 20 --no-pager --quiet
  else
    echo "  (nur mit sudo sichtbar: sudo limitpulse status)"
  fi
}

cmd_key() {
  local key tmp
  [[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen: sudo limitpulse key" >&2; return 1; }
  while :; do
    read -rsp "Anthropic-API-Schlüssel einfügen (Eingabe bleibt unsichtbar), dann Enter: " key </dev/tty || return 1
    echo
    key=${key//[[:space:]]/}
    if [[ -z $key ]]; then
      echo "Keine Eingabe, bitte erneut."
    elif ! valid_key "$key"; then
      echo "Ungültiges Format (nur Buchstaben, Ziffern, - und _), bitte erneut."
    else
      break
    fi
  done
  [[ $key == sk-ant-* ]] || echo "Hinweis: Anthropic-API-Schlüssel beginnen normalerweise mit \"sk-ant-\"."

  tmp=$(mktemp "$CONF_DIR/.api-key.XXXXXX") || return 1
  if ! { printf '%s\n' "$key" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$KEY_FILE"; }; then
    rm -f "$tmp"
    echo "Schlüssel konnte nicht gespeichert werden." >&2
    return 1
  fi
  echo "Schlüssel gespeichert (…${key: -4}) in $KEY_FILE, nur für root lesbar."

  if [[ ${1:-} != --no-restart ]] && systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
    systemctl restart "$UNIT" && echo "Dienst neu gestartet, der neue Schlüssel gilt ab sofort."
  fi
}

cmd_uninstall() {
  local answer
  [[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen: sudo limitpulse uninstall" >&2; return 1; }
  read -rp "LimitPulse vollständig entfernen, einschließlich gespeichertem API-Schlüssel? [j/N] " answer </dev/tty || return 1
  [[ $answer == [jJyY]* ]] || { echo "Abgebrochen."; return 0; }
  systemctl disable --now "$UNIT" 2>/dev/null
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$UNIT" 2>/dev/null
  [[ -L $BIN_LINK ]] && rm -f "$BIN_LINK"
  rm -rf "$CONF_DIR" "$APP_DIR"
  echo "LimitPulse wurde vollständig entfernt."
}

case ${1:-} in
  daemon) cmd_daemon ;;
  status) cmd_status ;;
  key) cmd_key "${2:-}" ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "LimitPulse – Befehle:"
    echo "  limitpulse status          Status, nächste Termine und letzte Meldungen"
    echo "  sudo limitpulse key        API-Schlüssel ändern oder ersetzen"
    echo "  sudo limitpulse uninstall  LimitPulse vollständig entfernen"
    ;;
esac
LIMITPULSE_APP
chmod 755 "$APP.new"
mv -f "$APP.new" "$APP"
ln -sfn "$APP" "$BIN_LINK"

# --- Einstellungen -------------------------------------------------------------

cat >"$CONF_FILE" <<EOF
# $MARKER. Wird bei erneuter Installation ersetzt.
# Erster Termin als Unix-Zeit: $anchor_text. Danach alle 5 Stunden.
LP_ANCHOR=$anchor
# Günstigstes verfügbares Modell (Stand Oktober 2026). Die Anfrage schaltet
# Thinking ab; das akzeptiert nicht jedes Modell.
LP_MODEL=$MODEL
EOF
chmod 644 "$CONF_FILE"

# --- systemd-Dienst ------------------------------------------------------------

cat >"$UNIT_FILE" <<EOF
# $MARKER. Wird bei erneuter Installation ersetzt.
[Unit]
Description=LimitPulse - minimale Anthropic-API-Anfrage alle 5 Stunden
After=network-online.target

[Service]
Type=simple
ExecStart=$APP daemon
Restart=always
RestartSec=30
# Schlüssel wird von systemd bereitgestellt; die Datei selbst bleibt nur für root lesbar.
LoadCredential=api-key:$KEY_FILE
# Eigener, kurzlebiger Benutzer ohne Rechte; kein Zugriff auf andere Projekte.
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT_FILE"

# --- API-Schlüssel -------------------------------------------------------------

echo
if [[ -s $KEY_FILE ]] && ask_yes "Ein API-Schlüssel ist bereits gespeichert. Beibehalten? [J/n] " j; then
  echo "Vorhandener Schlüssel bleibt erhalten."
else
  "$APP" key --no-restart || die "Kein API-Schlüssel gespeichert. Installation bitte erneut starten."
fi

# --- Starten -------------------------------------------------------------------

systemctl daemon-reload
systemctl enable --quiet "$UNIT"
systemctl restart "$UNIT"
sleep 2
systemctl is-active --quiet "$UNIT" \
  || die "Der Dienst ist nicht gestartet. Details: sudo journalctl -u $UNIT -n 50"

cat <<EOF

LimitPulse ist installiert und läuft im Hintergrund, auch nach einem Neustart.
Erster Termin:  $anchor_text
Danach alle 5 Stunden.

Bedienung:
  limitpulse status          Status, nächste Termine und letzte Meldungen
  sudo limitpulse key        API-Schlüssel ändern oder ersetzen
  sudo limitpulse uninstall  LimitPulse vollständig entfernen
EOF
