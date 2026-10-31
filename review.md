# Sicherheits- und Fehler-Review: `install.sh` + `README.md`

Dieses Dokument ist für eine andere KI (oder einen Menschen) gedacht, die die Funde beheben soll.
Es ist bewusst selbsterklärend: jeder Fund nennt Ort, Status, Szenario, Beleg und einen minimalen
Fix-Vorschlag. Dieses Review hat **keine** Code-Dateien geändert.

## Rahmen

- **Geprüft:** `install.sh` (inkl. des als Heredoc `LIMITPULSE_APP` eingebetteten Dienstprogramms) und `README.md`.
- **Basis-Commit:** `538b5e3` (main, PR #4 gemergt). Alle Zeilenangaben sind `install.sh`-Zeilen auf diesem Stand.
- **Hinweis zum eingebetteten Programm:** Das eigentliche Dienstprogramm steckt zwischen
  `cat >"$APP.new" <<'LIMITPULSE_APP'` und `LIMITPULSE_APP` (ca. Zeile 213–855). Die Zeilennummern unten
  beziehen sich auf die Position **in `install.sh`**, nicht auf die herausgelöste Datei.
- **Zweck des Dienstes:** Sobald das 5-Stunden-Nutzungsfenster eines Claude-Abos zurückgesetzt ist, ruft der
  Dienst einmal `claude -p Hi` (Haiku 5.5, `--effort low`) auf, damit sofort das nächste Fenster startet.
  Anmeldung nur über `CLAUDE_CODE_OAUTH_TOKEN` aus `claude setup-token`; API-Schlüssel dürfen nie wirken.
- **Prüfmethode:** vollständiges Lesen; `bash -n`; `shellcheck 0.11.0`; Ausführen des Parsers gegen die
  Fixtures; Nachstellen von Puls-Szenarien in einer Stub-Sandbox (`claude`/`systemctl`/`sleep` ersetzt, Pfade
  umgebogen, kein echtes System, kein Netz, kein echter Token); Offline-Aufrufe des echten `claude`-Binaries
  in einem Netzwerk-Namespace (`unshare -n`). Belege für Claude-Code-Verhalten stammen aus `code.claude.com/docs`.

## Vorprüfung (reproduziert vor dem Fixen)

```bash
bash tests/run.sh      # bash -n, shellcheck, Parser gegen Fixtures – muss grün sein
```

Die Fund-Zeilen auf diesem Stand (zur Kontrolle):

```
install.sh:436  Parser  five_hour-Zweig ohne status-Prüfung   (F1)
install.sh:655  run_pulse Fehlerpfad "Fenster voll"            (F1)
install.sh:85   check_dir exakter Namensvergleich              (F2)
install.sh:149  check_dir "$CONF_DIR" oauth-token              (F2)
install.sh:784  mktemp "$CONF_DIR/.oauth-token.XXXXXX"         (F2)
install.sh:305  scrub sed sk-ant-...                           (F6)
install.sh:327  load_state [[ -r $STATE_FILE ]]                (F4)
install.sh:799  cmd_token systemctl stop (ohne --no-restart-Schutz)  (F5)
```

---

## MITTEL

### F1 — Bug — Parser verwirft `status` des `five_hour`-Events; Fehlerpfad kann Wiederholungen unnötig abbrechen

- **Kategorie:** Bug (Logik)
- **Schwere:** mittel
- **Ort:** `install.sh:436` (Parser) und `install.sh:653–658` (run_pulse-Fehlerpfad)
- **Status:** Mechanismus **BESTÄTIGT** (reproduziert); schädlicher Auslöser in der Praxis **VERMUTUNG**

**Beschreibung.** Der Parser übernimmt die Reset-Zeit eines `five_hour`-Events **unabhängig vom Feld `status`**
(`if kind in (None, "five_hour") and num(r): resets = str(int(r))`). Im Fehlerpfad behandelt `run_pulse` jede
plausible `P_RESET` als „5-Stunden-Fenster läuft bereits und ist voll" und bricht alle weiteren Versuche ab.

Für `status == "rejected"` (Fenster wirklich voll) ist das korrekt. Der Code kann aber einen **transienten
Fehler** (z. B. HTTP 529 Overloaded), der zufällig ein `five_hour`-Event mit `status: allowed` und
routinemäßiger `resetsAt` mitliefert, nicht vom echten „Fenster voll" unterscheiden. Dann wartet der Dienst bis
zu ~5 Stunden auf den Reset, statt nach 30 s erneut zu versuchen — und verfehlt womöglich genau das
Fensterstarten, das der einzige Zweck des Dienstes ist.

**Szenario.** Ein geplanter Puls scheitert transient; die stream-json-Ausgabe enthält ein `five_hour`-Event mit
`status: allowed, resetsAt = jetzt + 3 h`. Folge: `P_RESET` gesetzt und plausibel → `NEXT_SRC=reset`, keine
Wiederholung, nächster Versuch erst in ~3 h.

**Beleg.** Der SDK-Typ belegt, dass das benötigte Feld existiert
(`code.claude.com/docs/en/agent-sdk/typescript#sdkratelimitevent`):

```
rate_limit_info: { status: "allowed" | "allowed_warning" | "rejected"; resetsAt?: number; … }
```

Python-Doku: „`rejected` means the limit was hit". Mechanismus in der Stub-Sandbox reproduziert (529-Fehler +
`five_hour status=allowed`, Reset in 3 h):

```
Aufrufe -p: 1   Pausen: (keine)
NEXT_SRC=reset
LAST_INFO=5-Stunden-Fenster läuft bereits und ist voll: Exit-Code 1; API Error: 529 Overloaded
NEXT in: 181 min
```

Zum Vergleich: dasselbe 529 **ohne** rate_limit_event → 10 Versuche, 9 Pausen, dann regulärer 5-h-Retry (korrekt).

**Warum nur VERMUTUNG beim Auslöser.** Ob Claude Code bei einem fehlgeschlagenen Puls je ein `allowed`-`five_hour`-
Event mit `resetsAt` ausgibt, ist offline nicht beweisbar. In den Fixtures tragen transiente Fehler
(`serverfehler`) kein rate_limit_event; nur `fenster-voll` trägt eins, dort mit `status: rejected`. Trifft das
immer zu, kann F1 nicht auslösen. Die Korrektur ist trotzdem sinnvoll, weil sie die Fehlklassifikation
prinzipiell ausschließt.

**Fix (minimal).** Nur dann „Fenster voll, keine Wiederholung" schließen, wenn das `five_hour`-Fenster wirklich
`rejected` ist. Der Erfolgspfad (`install.sh:628`) bleibt unverändert — dort ist das Nutzen eines `allowed`-Resets
zum Planen korrekt.

Parser — Rejection des 5-h-Fensters mitführen:

```diff
             if kind in (None, "five_hour") and num(r):
                 resets = str(int(r))
+                if i.get("status") == "rejected":
+                    five_rejected = 1
             …
             w5 = w.get("five_hour") if isinstance(w, dict) else None
             if not resets and isinstance(w5, dict) and num(w5.get("resetsAt")):
                 resets = str(int(w5["resetsAt"]))
+                if isinstance(w5, dict) and w5.get("status") == "rejected":
+                    five_rejected = 1
```

Dazu `five_rejected = 0` bei den übrigen Akkumulatoren initialisieren und ausgeben:

```diff
+print("FIVEREJ=%d" % five_rejected)
```

Reader in `pulse_once` (bei `OK)`, `RESET)` … im `case`, ca. `install.sh:550`):

```diff
       RESET) P_RESET=$v ;;
+      FIVEREJ) P_FIVEREJ=$v ;;
```

und `P_FIVEREJ=0` dort initialisieren, wo `P_OK=0 P_RESET='' …` gesetzt wird (ca. `install.sh:474`).

Fehlerpfad (`install.sh:653`):

```diff
-    if [[ $P_RESET =~ ^[0-9]{1,12}$ ]] && (( P_RESET > now && P_RESET <= now + INTERVAL + 300 )); then
+    if [[ $P_FIVEREJ == 1 && $P_RESET =~ ^[0-9]{1,12}$ ]] && (( P_RESET > now && P_RESET <= now + INTERVAL + 300 )); then
```

Fixtures ergänzen: ein Fall „transienter Fehler (is_error) + `five_hour status=allowed` mit resetsAt" soll
`FIVEREJ=0` liefern; `fenster-voll` soll `FIVEREJ=1` liefern.

---

## NIEDRIG

### F2 — Bug — Zurückgebliebene Token-Tempdatei blockiert eine erneute Installation

- **Kategorie:** Bug
- **Schwere:** niedrig
- **Ort:** `install.sh:85` und `:149` (check_dir) gegen `:784` (mktemp)
- **Status:** **BESTÄTIGT** (reproduziert)

**Beschreibung.** `cmd_token` legt mit `mktemp "$CONF_DIR/.oauth-token.XXXXXX"` eine Tempdatei in
`/etc/limitpulse` an und verschiebt sie per `mv` auf `oauth-token`. Stirbt der Prozess zwischen `mktemp` und
`mv` (Strg-C, Kill, Stromausfall), bleibt `.oauth-token.XXXXXX` liegen. Die Vorabprüfung
`check_dir "$CONF_DIR" oauth-token` erlaubt nur den Namen `oauth-token` und vergleicht **exakt**
(`[[ $name == "$a" ]]`). Die Tempdatei gilt damit als fremde Datei, und der nächste `install.sh` bricht ab —
wegen einer Datei, die LimitPulse selbst erzeugt hat.

**Szenario.** `sudo limitpulse token` wird zur falschen Millisekunde abgebrochen →
`/etc/limitpulse/.oauth-token.ab12cd` (root, 600) bleibt → `sudo bash install.sh` bricht ab mit
„`$CONF_DIR enthält die fremde Datei \".oauth-token.ab12cd\". Abbruch, nichts wurde verändert.`"

**Beleg (reproduziert, check_dir isoliert nachgebaut):**

```
Tempdatei: .oauth-token.YRGfX1
DIE: … enthält die fremde Datei ".oauth-token.YRGfX1".
(ohne Tempdatei: rc=0, ok)
```

**Fix (minimal, glob-tolerant).** `check_dir` die Temp-Namen als Muster erlauben. Dazu den Vergleich
unquoten (dann wirkt `$a` als Glob; die bestehenden Literalnamen matchen weiter, da sie keine Glob-Zeichen
enthalten):

```diff
-    for a in "$@"; do [[ $name == "$a" ]] && allowed=yes; done
+    for a in "$@"; do [[ $name == $a ]] && allowed=yes; done
```

```diff
-check_dir "$CONF_DIR" oauth-token
+check_dir "$CONF_DIR" oauth-token '.oauth-token.??????'
```

Alternativ oder zusätzlich: in `cmd_token` zu Beginn `rm -f "$CONF_DIR"/.oauth-token.* 2>/dev/null` als
Aufräumen (hilft aber nicht der Installer-Vorabprüfung, die vor `cmd_token` läuft).

### F3 — Sicherheit — `state` und `limitpulse.log` sind weltlesbar (644)

- **Kategorie:** Sicherheit (Informationsabfluss)
- **Schwere:** niedrig
- **Ort:** `install.sh:315` (Log-Schreiben), `:353` (save_state); systemd-Unit `StateDirectory=limitpulse` ohne `StateDirectoryMode`
- **Status:** VERMUTUNG (geringes Risiko)

**Beschreibung.** `umask 022` erzeugt `state` und `limitpulse.log` als `-rw-r--r--`; `/var/lib/limitpulse` ist
755. Jeder lokale Nutzer (auf dem Pi laufen andere Webprojekte) kann Zeitplan und Protokoll lesen. Der Inhalt
ist durch `scrub` und `head -c 300` entschärft, kann aber Fehlertexte von Claude Code enthalten (z. B. interne
Hosts/Pfade). Kein Token (siehe „Geprüft ohne Befund").

**Zielkonflikt.** `limitpulse status` soll ohne root laufen und liest beide Dateien. Strengere Rechte
(640 `root:limitpulse`) würden das für normale Nutzer brechen. Bewusst abwägen.

**Fix (falls nur root `status` braucht).** In der Unit `StateDirectoryMode=0750` setzen und Log/State auf 640,
Gruppe `limitpulse`. Andernfalls als akzeptiertes Rest-Risiko dokumentieren.

### F4 — Sicherheit — `load_state` liest `$STATE_FILE` ohne Typprüfung (FIFO/Symlink)

- **Kategorie:** Sicherheit (lokaler DoS / Härtung)
- **Schwere:** niedrig
- **Ort:** `install.sh:327`
- **Status:** VERMUTUNG (schwaches Angriffsmodell)

**Beschreibung.** `load_state` prüft nur `[[ -r $STATE_FILE ]]` und liest dann `while … <"$STATE_FILE"`.
`state` gehört dem Dienstbenutzer. Ein kompromittierter `limitpulse`-Prozess könnte die Datei durch eine FIFO
ohne Schreiber ersetzen; dann hängt `sudo limitpulse token` / `status` beim Lesen (lokaler DoS gegen den
Admin). Ein Symlink auf eine Fremddatei ließe root lesen, gibt aber nichts preis (Werte werden nur geparst und
für Verzweigungen genutzt, nicht ausgegeben; nicht passende Zeilen → `return 1`). Setzt einen bereits
kompromittierten Dienstbenutzer voraus.

**Fix (minimal).**

```diff
-  [[ -r $STATE_FILE ]] || return 1
+  [[ -f $STATE_FILE && ! -L $STATE_FILE && -r $STATE_FILE ]] || return 1
```

### F5 — Bug — `--no-restart` unterdrückt den `systemctl stop` im retry-now-Zweig nicht

- **Kategorie:** Bug
- **Schwere:** niedrig (kosmetisch)
- **Ort:** `install.sh:798–805`
- **Status:** **BESTÄTIGT** (aus Code)

**Beschreibung.** Der Block, der bei zuletzt fehlgeschlagenem Puls `systemctl stop "$UNIT"` und `retry-now`
ausführt, steht **vor** der `[[ ${1:-} != --no-restart ]]`-Schranke und ignoriert sie. Der Installer ruft beim
Einrichten `"$APP" token --no-restart` (`install.sh:866`) auf; bei einer erneuten Installation mit zuvor
fehlgeschlagenem Puls stoppt dieser Zweig den laufenden Dienst trotz `--no-restart` (der Installer startet ihn
am Ende wieder). Kein Datenschaden, der Rollback startet den Dienst bei Bedarf neu; nur unnötig frühe
Unterbrechung.

**Fix.** Den `systemctl stop` + `retry-now`-Teil ebenfalls unter die `--no-restart`-Schranke ziehen, oder bei
`--no-restart` nur `NEXT=0` als Dienstbenutzer setzen, ohne zu stoppen. Beispiel:

```diff
-  if load_state && [[ $LAST_OK == 0 && $NEXT_SRC != weekly ]]; then
+  if [[ ${1:-} != --no-restart ]] && load_state && [[ $LAST_OK == 0 && $NEXT_SRC != weekly ]]; then
     systemctl stop "$UNIT" 2>/dev/null
     runuser -u "$APP_USER" -- "$(readlink -f "$0")" retry-now \
       && echo "Der letzte Puls war fehlgeschlagen und wird nach dem Start sofort wiederholt."
   fi
```

(Prüfen: der Installer verlässt sich derzeit nicht darauf, dass `--no-restart` auch den retry-now-NEXT=0 setzt;
beim Erstlauf existiert noch kein `state`, der Zweig läuft dann ohnehin nicht.)

### F6 — Bug — `scrub` maskiert nur den vollen Token und `sk-ant-*`

- **Kategorie:** Bug/Sicherheit (Härtung)
- **Schwere:** niedrig
- **Ort:** `install.sh:302–306`
- **Status:** VERMUTUNG (kein Beleg, dass der Auslöser auftritt)

**Beschreibung.** `scrub` ersetzt exakt `$LP_TOKEN` und per Regex `sk-ant-[A-Za-z0-9_-]+`. Ein
**prefix-gestripptes** Fragment (`oat01-…` ohne `sk-ant-`) oder ein abgeschnittener Token würde weder von der
Ganzstring-Ersetzung noch von der Regex erfasst und landete unmaskiert im weltlesbaren Protokoll (vgl. F3).

**Einschränkung.** Kein Nachweis, dass Claude Code je ein prefix-loses Token-Fragment ausgibt. Rein
vorsorglich.

**Fix (minimal).**

```diff
   local s=$1
-  [[ -n $LP_TOKEN ]] && s=${s//"$LP_TOKEN"/***}
+  [[ -n $LP_TOKEN ]] && s=${s//"$LP_TOKEN"/***} && s=${s//"${LP_TOKEN#sk-ant-}"/***}
   printf '%s' "$s" | sed -E 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-***/g'
```

---

## Geprüft ohne Befund (mit Beleg)

- **Billing-Abwehr wirksam und mehrschichtig.** Der Env-Strip in der Puls-Untershell (`compgen -e` + `unset`)
  entfernt `ANTHROPIC_API_KEY` **und** das laut Doku höherrangige `ANTHROPIC_AUTH_TOKEN` samt aller
  Nicht-Whitelist-Variablen (reproduziert: „ANTHROPIC_* im Puls-Env: 0"). Der managed-settings-grep blockt
  `apiKeyHelper|ANTHROPIC_|CLAUDE_CODE_USE_|_BASE_URL` (rc=2 reproduziert). Der `claude auth status`-Precheck
  blockt `api_key`/`bedrock` vor dem abgerechneten Aufruf (rc=2 reproduziert). Der apiKeySource-Postcheck prüft
  `ANTHROPIC_API_KEY | apiKeyHelper | "/login managed key"` — laut SDK-Doku exakt die abrechnungsrelevanten
  Werte; ein Abo-Puls meldet `none` (empirisch bestätigt). Doku bestätigt die Präzedenz
  `ANTHROPIC_AUTH_TOKEN > ANTHROPIC_API_KEY > apiKeyHelper > CLAUDE_CODE_OAUTH_TOKEN` und „In non-interactive
  mode (-p), the key is always used when present" — der Env-Strip ist also tragend.
- **Symlink in `cmd_token` (Hauptverdacht) bereits entschärft.** root schreibt nicht mehr nach `$APP_HOME`;
  `retry-now` läuft als Dienstbenutzer (Vergleich mit git `d2e373b`). `TOKEN_FILE` ist 600 `root` in
  `/etc/limitpulse` (755, root) — der Dienstbenutzer kann dort nicht schreiben.
- **Abgelehnte Limits werden ausgewertet (Verdacht widerlegt).** `five_hour`+`rejected` → Fenster-voll-Pfad;
  `seven_day`+`rejected` → `WEEKLY=1`/`WRESET`. Beleg: Fixtures `fenster-voll`, `wochenlimit`, Parser `:432/:436`.
  `allowed_warning` löst korrekt kein Wochenlimit aus. Nebenpunkt: Der Parser erkennt strukturell nur
  `kind == "seven_day"`, nicht die laut Python-Doku ebenfalls möglichen `seven_day_opus`/`seven_day_sonnet`; für
  den reinen Haiku-Puls praktisch irrelevant, und der Text-Backstop `"weekly limit" in text.lower()` (`:450`)
  plus stderr-Prüfung (`:576`) fängt die Meldung ohnehin.
- **Token nicht at-rest.** Claude Code mit nur `CLAUDE_CODE_OAUTH_TOKEN` (env) schreibt den Token in keine
  Datei (grep über Wegwerf-HOME leer; `.claude.json` enthält keinen Token).
- **Parser robust.** `resetsAt` in Millisekunden (zu groß → Plausibilitätsgrenze `<= now+INTERVAL+300` greift →
  Fallback), Float (`int()`), ISO-String (`num()`=false → leer), Steuerzeichen, kaputtes JSON — alle graceful
  (Fixtures + eigene Tests). Einheit Sekunden ist mit der Statusline-Doku konsistent (`resets_at` Unix epoch
  seconds).
- **Sommerzeit.** `weekly_slot`/`first_slot` liefern über CET/CEST-Wechsel korrekte Zeiten (GNU date 9.4 getestet).
- **Rollback-EXIT-Falle** läuft bei SIGINT/SIGHUP/SIGTERM (Ctrl-C, SSH-Abbruch) — getestet.
- **Retry-Takt.** `PAUSES` (9 Elemente) vs `MAX_ATTEMPTS=10`: kein Array-Overflow, 9 Pausen `30→900`, dann
  5-h-Retry (reproduziert).
- **Installer-Parsing.** RAM (4-GB-Pi ~3792 MB ≥ 3300000 kB ok; 3-GB-Gerät fällt korrekt durch), systemd-Version,
  os-release — korrekt. `claude_ok`/`sort -V`-Vergleich und der neue „skip reinstall"-Pfad (`:869–915`) laufen als
  Dienstbenutzer mit `env -i`, Fallback bei fehlender/alter/defekter Version — kein Fund.
- **Deliberate Entscheidungen doku-konform.** `MIN_CLAUDE_VERSION=2.1.293` (Doku: „Use v2.1.293 or later with
  Haiku 5.5"); `--effort low` von Haiku 5.5 unterstützt (Default medium); Thinking bei Haiku 5.5 nicht
  abschaltbar (Kommentar `:263` korrekt); `CLAUDE_CODE_MAX_RETRIES=2` (Default 10); der Verzicht auf
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` ist richtig, weil diese Variable laut Doku auch Auto-Updates
  abschaltet.
- **State-Injektion.** Newlines in `LAST_INFO` werden via `tr -d '\r\n'` gestrippt; kein Einschleusen gefälschter
  `KEY=`-Zeilen.
- `bash -n` + `shellcheck` default sauber (auch für die neuen Testdateien); `-o all` nur Stil/Info.

## Nicht geprüft oder nicht prüfbar

- **Auto-Update-Atomarität / halbfertige Installation** bei gekilltem `claude update` (`timeout --kill-after=10`,
  `:680`) oder bei einem Puls, der ein Hintergrund-Update unterbricht: in der Doku nicht belegt (Setup-Seite sagt
  nur „Updates download and install in the background, then take effect the next time you start Claude Code"),
  offline ohne echten Installer/Netz nicht reproduzierbar.
- **`CLAUDE_CODE_MAX_OUTPUT_TOKENS=4096` × Thinking.** Ob die bei Haiku 5.5 nicht abschaltbaren Thinking-Tokens
  in die 4096 zählen und so „ok" abschneiden könnten — NICHT IN DER DOKU (model-config nennt keinen
  Thinking-Bezug; SDK nur zur Abrechnung: „`outputTokens` already includes [thinking]"). Mit `--effort low` und
  Ein-Wort-Systemprompt praktisch unkritisch; ein leeres Ergebnis würde als Fehlschlag gewertet und wiederholt.
- **F1-Auslöser in der Praxis.** Ob Claude Code bei einem fehlgeschlagenen Puls je ein `allowed`-`five_hour`-Event
  mit `resetsAt` ausgibt — nur gegen echte API / echtes Limit beweisbar.
- **`claude auth status --json` und `apiProvider`.** Laut Doku sind `--json` (dokumentiert ist nur `--text`) und
  das Feld `apiProvider` **nicht dokumentiert** (dokumentiert nur `authMethod`). Der Code stützt sich auf beides;
  empirisch ok auf Claude Code 2.1.316, aber undokumentiert = potenziell fragil bei künftigen Versionen. Kein
  aktueller Fehler, nur Hinweis.
- **Realer Installer-Lauf** auf echtem Pi (useradd, systemd-Unit, echter claude-Install): absichtlich nicht
  ausgeführt.
- **Neue Testdateien** (`tests/smoke.sh`, `tests/stub_server.py`, `tests/claude-version.sh`,
  `tests/claude-install-step.sh`): nur oberflächlich geprüft (shellcheck/parse sauber), nicht inhaltlich im
  Detail — sie laufen in CI, nicht auf dem Pi.
