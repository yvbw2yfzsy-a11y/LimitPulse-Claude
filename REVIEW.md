# Optimierungs-Review: install.sh und README.md

Stand: 31.10.2026. Geprüft wurden `install.sh` (Installer und eingebettetes Programm `LIMITPULSE_APP`) und `README.md`.
Dies ist ein Review. Dieser Pull Request ändert weder den Installer noch den Dienst, sondern fügt nur diese Datei hinzu.

Kennzeichnung: **Belegt** heißt, es steht in der Doku (code.claude.com/docs) oder wurde hier ohne Netzwerk ausprobiert.
**Vermutung** heißt, es ist begründet, aber nicht belegt.

Gesamteindruck (belegt, soweit unten genannt): Ich habe keinen Fehler gefunden, der das beschriebene Verhalten bricht,
und keinen Fehler in den bewussten Entscheidungen. Der Dienst ist schon sparsam. Lohnend sind nur die drei Punkte unten.

## Vorschläge, sortiert nach Nutzen im Verhältnis zum Aufwand

### 1. Rauchtest gegen die jeweils aktuelle Claude-Code-Version in der CI

- **Nutzen: hoch. Aufwand: mittel. Risiko für den Dienst: keines, es wird kein Dienstcode geändert.**
- Problem (belegt): Die Auto-Updates von Claude Code bleiben bewusst an, und der Dienst täglich zusätzlich `claude update` auf.
  Gleichzeitig hängt der Dienst an Kommandozeilen-Flags (`--effort`, `--tools ""`, `--max-turns`, `--setting-sources`,
  `--strict-mcp-config`, `--disable-slash-commands`, `--output-format stream-json --verbose`) und an dem JSON-Format von
  `claude auth status`, das `pulse_once` mit zwei Regexen liest. Ändert eine neue Claude-Code-Version eines davon, merkt der
  Pi das erst, wenn ein Puls fehlschlägt. Der Dienst wiederholt dann bis zu zehnmal (rund 75 Minuten) und versucht es
  erst fünf Stunden nach Pulsbeginn wieder. Bis dahin bleibt das Fenster ungenutzt. `tests/parser.sh` prüft nur gespeicherte Beispielausgaben, nicht die
  aktuelle Version.
- Belegt, dass das offline machbar ist: Ich habe den vollständigen Aufruf aus `CLAUDE_ARGS` mit den Variablen aus `pulse_once` gegen einen
  lokalen Stub-Server (`ANTHROPIC_BASE_URL` auf 127.0.0.1) mit Claude Code 2.1.316 ausgeführt. Ergebnis: Exit-Code 0, Laufzeit rund 1 s,
  über die Basis-URL genau eine Anfrage (`POST /v1/messages`, 1957 Byte) mit `tools: []`, `thinking: adaptive`, `effort: low`,
  `max_tokens: 4096`. Der Parser aus `install.sh` liefert darauf `OK=1`, `KEYSRC=none`. `claude auth status --json` brauchte 0,4 s,
  schickte nichts an die Basis-URL und passt zu den Regexen (`authMethod: oauth_token`, `apiProvider: firstParty`).
- Vorschlag: Ein Test, der das automatisiert (kleiner Stub, rund 40 Zeilen) und ein wöchentlicher CI-Lauf (`schedule`), der die
  neueste Claude-Code-Version installiert und den Test ausführt. Schlägt er fehl, weiß man es vor dem Pi.
- Grenze: Der Stub prüft nur die Seite des CLI. Ob die echte API genau diese Anfrage akzeptiert, zeigt er nicht (siehe unten).

### 2. Claude Code beim erneuten Ausführen des Installers nicht neu installieren, wenn es schon passt

- **Nutzen: gering bis mittel. Aufwand: gering (wenige Zeilen). Risiko: gering.**
- Beobachtung (aus dem Code): `install.sh` Zeilen 869 bis 893 laden bei jedem Lauf den Installer von claude.ai und installieren
  Claude Code neu, auch wenn `$CLAUDE` schon vorhanden und neu genug ist. Der Installer kennt den Fall ausdrücklich
  (Meldung "bereits installiert und wird aktualisiert", Zeile 192): Ein erneuter Lauf ersetzt das Programm. Fällt claude.ai oder das Netz dann aus, bricht der Lauf mit `die` ab,
  nachdem Programm (und gegebenenfalls Token) schon ersetzt wurden. Ein Rückbau findet bei einer bestehenden Installation
  bewusst nicht statt.
- Vorschlag: Ist `$CLAUDE` ausführbar und liefert `--version` eine Version von mindestens `MIN_CLAUDE_VERSION`, den Download und die
  Installation überspringen. Aktuell bleibt Claude Code durch die Auto-Updates und das tägliche `claude update` (belegt:
  setup.md, Abschnitt Auto-updates).
- Nicht belegt: wie groß der Download ist. Ich habe ihn nicht geladen, den Gewinn also nicht gemessen.
- Gegenposition: Wer den Installer gerade deshalb erneut startet, um eine defekte Claude-Code-Installation zu reparieren, würde
  durch die Abkürzung nichts reparieren. Deshalb muss die Bedingung `--version` wirklich ausführen und nicht nur prüfen, ob die
  Datei existiert.

### 3. `tests/run.sh` gibt ohne `shellcheck` einen unklaren Abbruch

- **Nutzen: klein. Aufwand: minimal.**
- Beobachtung (belegt): In dieser Umgebung ist `shellcheck` nicht installiert. `bash tests/run.sh` bricht wegen `set -e` an dieser
  Stelle ab, und der Parser-Test läuft nicht mehr mit. `bash tests/parser.sh` allein läuft (8 von 8 ok). Die README nennt
  `shellcheck` bei den Prüfungen nicht als Voraussetzung (die CI hat es auf `ubuntu-latest`).
- Vorschlag: In der README `shellcheck` als Voraussetzung nennen, oder in `run.sh` vorher mit `command -v shellcheck` prüfen und
  eine klare Meldung ausgeben.

## Nicht geprüft oder nicht prüfbar

- **Echte API:** Ob Haiku 5.5 die Anfrage mit adaptivem Thinking, `effort: low` und `max_tokens: 4096` so annimmt, ob "Hi" das
  Fenster tatsächlich startet und wie die echten `rate_limit_event`-Felder (`resetsAt`, `unifiedWindows`) aussehen.
  Alle Beispielausgaben in `tests/fixtures` stammen laut `tests/parser.sh` ebenfalls von einem Stub. `unifiedWindows` ist
  laut Kommentar im Code nicht dokumentiert; ich habe es nicht in der Doku gefunden.
- **Vermutung, nicht belegt:** Ob 4096 Ausgabe-Tokens mit unabschaltbarem Thinking immer für das Wort "ok" reichen. Bei `effort: low`
  und diesem Systemprompt ist das plausibel. Gemessen habe ich es nicht (der Stub denkt nicht).
- **Echte Hardware:** Laufzeit und Speicherbedarf von Claude Code auf einem Raspberry Pi. Meine Messung (1 s) stammt von x86, die
  `ATTEMPT_TIMEOUT` von 180 s kann ich für den Pi weder bestätigen noch widerlegen.
- **Nicht ausgeführt, weil es das System ändert:** der Installer selbst (Benutzer, systemd-Unit, `LoadCredential`,
  `ProtectSystem=strict` zusammen mit Claude Code), `claude update` (würde die Claude-Code-Installation dieser Umgebung verändern;
  auch das Verhalten ohne Token ist deshalb ungeprüft), `limitpulse token` und `uninstall`.
- **`shellcheck`:** nicht ausgeführt (nicht installiert). `bash -n install.sh` ist ok.
- **Weitere Hosts:** Mein Stub sieht nur Verkehr über `ANTHROPIC_BASE_URL`. Ob Claude Code mit `DISABLE_TELEMETRY` und
  `DISABLE_ERROR_REPORTING` zu anderen Hosts nichts mehr sendet, habe ich nicht beobachtet; dazu stützt sich die Aussage nur auf die Doku (env-vars.md).
- **Vermutung:** Verwaltete Einstellungen, die eine Organisation über den Server verteilt, kann die lokale Dateiprüfung in
  `pulse_once` nicht sehen. Ich habe nicht nachgeschlagen, ob und was sie setzen können; die Prüfung von `claude auth status`
  und `apiKeySource` sichert die API-Abrechnung trotzdem ab (belegt für den lokalen Fall).

## Geprüft ohne Befund

- **Belege aus der Doku, die zu Installer und README passen:** Der Token aus `claude setup-token` gilt ein Jahr
  (authentication.md). Haiku 5.5 braucht Claude Code ab 2.1.293 (model-config.md). Claude Code verlangt 4 GB RAM und
  x64 oder ARM64 (setup.md). Thinking lässt sich bei Haiku 5.5 nicht abschalten, der Standardaufwand ist `medium`, also ist
  `--effort low` sinnvoll (model-config.md). `CLAUDE_CODE_MAX_RETRIES` hat den Standard 10 (env-vars.md). `--max-turns` endet
  mit Fehler, wenn das Limit erreicht wird (cli-reference.md); bei einer Antwort ohne Tools tritt das nicht ein (belegt im Stub-Lauf).
  Die Meldung "You've hit your weekly limit" und die Felder und Statuswerte von `RateLimitInfo` entsprechen dem, was der Parser
  auswertet (errors.md, Agent-SDK-Referenz). `claude update` meldet "Successfully updated" (setup.md). Die Auto-Updates laufen
  laut Doku beim Start und periodisch; ob sie in kurzen Print-Aufrufen greifen, ist nicht dokumentiert, so wie es der Code sagt.
- **Stub-Lauf (siehe Punkt 1):** Exit-Code 0, eine Anfrage über die Basis-URL, keine Tools, `apiKeySource` ist `none` und wird vom Dienst
  akzeptiert. Der Parser liefert darauf das erwartete Ergebnis. Alle 8 Beispiele in `tests/fixtures` bestehen.
- **Bewusste Entscheidungen:** Eigener Systembenutzer, Auto-Updates, feste Modell-ID, Thinking an mit `--effort low`,
  Ausgabegrenze 4096, 10 Versuche mit wachsenden Pausen (summiert 4530 s, passt zu "rund 75 Minuten" in der README) und der Fallback
  "letzte Antwort + 5 h + 60 s": kein Fehler gefunden. Die Abfolge der Prüfungen vor dem Aufruf entspricht der README.
- **Nicht lohnend, deshalb kein Vorschlag:**
  - Die Vorabprüfungen in `pulse_once` (Einstellungsdateien, `python3`, `claude auth status`) laufen bei jedem Versuch statt einmal
    je Puls. Sie kosten 0,4 s ohne Netzwerkzugriff und fallen nur im Fehlerfall mehrfach an.
  - Das Aufwachen alle 60 s im Hauptschleifenkörper (gewollt wegen NTP-Korrekturen, rund 1440 `sleep` am Tag, vernachlässigbar).
  - Doppeltes Protokollieren in Journal und Datei (das Journal kann der Dienst-Benutzer nicht lesen; `limitpulse status` braucht die Datei).
  - Die Anfrage kleiner machen: Sie ist rund 2 KB groß. Ein Teil davon ist ein Umgebungsblock, den Claude Code selbst anhängt.
    `--exclude-dynamic-system-prompt-sections` würde ihn nach `claude --help` nur bei Standard-Systemprompt verschieben und wirkt mit
    `--system-prompt` nicht. Ein Weg, ihn zu entfernen, ist mir nicht bekannt.
