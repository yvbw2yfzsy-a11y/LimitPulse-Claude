# LimitPulse-Claude

Kleiner Hintergrunddienst für den Raspberry Pi. Er hält das 5-Stunden-Nutzungsfenster
eines Claude-Abos (Pro/Max) lückenlos in Gang: Sobald das Fenster zurückgesetzt ist,
ruft er Claude Code (CLI, Print-Modus) mit der Nachricht „Hi“ auf, damit sofort das
nächste Fenster beginnt. Der erste Puls kommt um 08:00 Uhr (Europe/Berlin).

Angemeldet wird mit einem Abo-Token aus `claude setup-token`, nicht mit einem
API-Schlüssel. API-Nutzung zählt nicht auf das Abo.

## Voraussetzungen

- Raspberry Pi OS 64 Bit (Bookworm oder neuer) mit systemd. `uname -m` muss `aarch64` zeigen.
- mindestens 4 GB RAM (Anforderung von Claude Code)
- `curl` und `python3` (bei Raspberry Pi OS normalerweise vorhanden; der Installer prüft das und installiert nichts)
- ein Abo-Token. Erzeugen mit `claude setup-token` (geht auch auf einem anderen Rechner,
  der Token gilt laut Doku ein Jahr).

## Installation

```bash
scp install.sh pi@raspberrypi.local:~
ssh pi@raspberrypi.local
sudo bash install.sh
```

Der Installer fragt den Token verdeckt ab, richtet einen eigenen Systembenutzer
`limitpulse` ein, installiert Claude Code in dessen Home und startet den Dienst.
Er braucht ein Terminal: Wer ihn per SSH in einem Schritt startet, nimmt `ssh -t`.

Der Installer lässt sich erneut ausführen, zum Beispiel für eine neue Skriptversion. Er ersetzt dann das
Programm und die Unit; der Zeitplan bleibt erhalten, der Token auf Wunsch. Eine vorhandene Claude-Code-Installation,
die läuft und neu genug ist, rührt er nicht an und lädt dafür nichts von claude.ai. Fehlt Claude Code, ist es
defekt oder zu alt, installiert er es wie beim ersten Mal. Aktuell hält es der Dienst selbst (siehe „Updates“).

## Bedienung

| Befehl | Wirkung |
|---|---|
| `limitpulse status` | Dienstzustand, letzter und nächster Puls, letzte Meldungen |
| `sudo limitpulse token` | Abo-Token ändern; war der letzte Puls fehlgeschlagen, wird er sofort wiederholt (außer beim Wochenlimit) |
| `sudo limitpulse uninstall` | alles entfernen, einschließlich der Claude-Code-Installation des Dienstes |

Das vollständige Protokoll zeigt `sudo journalctl -u limitpulse`.

## Funktionsweise

- **Puls:** ein Aufruf `claude -p "Hi"` mit Haiku 5.5 (`claude-haiku-5-5`), Aufwand `low`,
  ersetztem Systemprompt („Reply with exactly one word: ok“), ohne Tools, ohne MCP,
  ohne Skills, ohne gespeicherte Sitzung, ohne Telemetrie und Fehlerberichte. Danach beendet
  sich der Prozess. Erfolg heißt: Exit-Code 0 und nicht leere Antwort.
- **Nächster Puls:** Meldet Claude Code in der Ausgabe den Reset des 5-Stunden-Fensters
  (`rate_limit_event`, siehe Agent-SDK-Referenz), gilt dieser Zeitpunkt + 60 s. Sonst gilt:
  Zeitpunkt der letzten erfolgreichen Antwort + 5 Stunden + 60 s.
- **Fenster schon voll:** Läuft beim Puls bereits ein ausgeschöpftes 5-Stunden-Fenster (`rate_limit_event`
  mit Status `rejected`) und meldet Claude Code dessen Reset, gibt es keine weiteren Versuche; der nächste Puls
  kommt 60 s nach diesem Reset. Meldet Claude Code bei einem Fehler nur einen Reset mit Status `allowed` (Fenster
  nicht voll, Fehlerursache also etwas anderes, z. B. HTTP 529), gelten die normalen Wiederholungen.
- **Fehler:** Bis zu 10 Versuche je Puls mit wachsenden Pausen (30 s bis 15 min, zusammen
  etwa 75 Minuten). Danach steht der Fehler im Protokoll, und der Dienst versucht es
  5 Stunden + 60 s nach Pulsbeginn erneut.
- **Token abgelaufen oder widerrufen:** Lehnt die API die Anmeldung ab (HTTP 401, z. B. wenn der Token
  nach einem Jahr abgelaufen ist), gibt es keine weiteren Versuche; Protokoll und `limitpulse status` nennen
  `sudo limitpulse token`. Ist der neue Token gespeichert, wird der Puls sofort wiederholt. Ohne neuen Token
  versucht es der Dienst 5 Stunden + 60 s nach Pulsbeginn erneut.
- **Wochenlimit:** Scheitert ein Puls, weil das Wochenlimit voll ist (Meldung „weekly limit“
  oder abgelehntes `seven_day`-Event), gibt es keine weiteren Versuche. Der Dienst wartet auf den
  Wochen-Reset, den Claude Code im `rate_limit_event` meldet (+ 60 s Puffer), und startet dann das
  neue Fenster. Meldet Claude Code keinen Zeitpunkt, gilt der vom Betreiber beobachtete Reset samstags
  15:00 Uhr; das ist eine Annahme, keine dokumentierte Zusage. Gilt das Limit zu diesem angenommenen
  Termin noch, fällt der Dienst für 3 Tage auf den normalen 5-Stunden-Takt zurück.
  Das 5-Stunden-Limit löst diese Logik nicht aus.
- **Neustart/Stromausfall:** Der Zeitplan liegt in `/var/lib/limitpulse/state`. Ein verpasster
  Puls wird nach dem Start sofort nachgeholt.
- **Anmeldung:** Der Aufruf läuft mit leerem Environment. `ANTHROPIC_API_KEY`,
  `ANTHROPIC_AUTH_TOKEN` und alle anderen Variablen werden entfernt. Beide haben laut Doku
  Vorrang vor `CLAUDE_CODE_OAUTH_TOKEN` und würden über die API abgerechnet.
  Einstellungsdateien können solche Variablen trotzdem setzen (`env`, `apiKeyHelper`); Managed
  Settings unter `/etc/claude-code/` gelten immer. Deshalb prüft der Dienst vor jedem Puls
  `/etc/claude-code/managed-settings.json`, `/etc/claude-code/managed-settings.d/*.json` und
  `/var/lib/limitpulse/.claude/settings.json` sowie `claude auth status` (ohne API-Aufruf).
  Deutet etwas auf API-Schlüssel, anderen Anbieter oder anderen Endpunkt, sendet er nichts und
  nennt den Grund im Protokoll.
- **Updates:** Die automatischen Updates von Claude Code bleiben an. Weil nicht dokumentiert ist,
  ob sie in den nur Sekunden laufenden Pulsen greifen, ruft der Dienst zusätzlich nach dem Start
  und danach einmal täglich `claude update` auf.
- **Proxy:** nicht vorgesehen. Installer und Dienst geben keine Proxy-Variablen weiter.

## Was die Installation verändert

```
Benutzer limitpulse (Systembenutzer), Home /var/lib/limitpulse
  darin: Claude Code (~/.local), Zeitplan (state), Protokoll (limitpulse.log)
/opt/limitpulse/limitpulse.sh           Programm
/etc/limitpulse/oauth-token             Abo-Token (nur für root lesbar)
/etc/systemd/system/limitpulse.service  systemd-Dienst
/usr/local/bin/limitpulse               Befehl (Verweis auf das Programm)
```

Der Installer installiert keine Pakete, öffnet keine Ports und verändert oder startet
keine anderen Dienste. Existiert eine dieser Dateien oder der Benutzer bereits und stammt
nicht von LimitPulse, bricht er ab, ohne etwas zu ändern. Schlägt die Installation auf
einem frischen System fehl, baut er seine Änderungen wieder zurück.

Der Dienst läuft als `limitpulse` mit systemd-Härtung (`ProtectSystem=strict`, nur das
eigene Home schreibbar, keine Capabilities, `NoNewPrivileges`). Den Token stellt systemd
über `LoadCredential` bereit; er steht weder in der Prozessliste noch im Protokoll.

Bekanntes Restrisiko: `/var/lib/limitpulse/state` und `limitpulse.log` sind für alle lokalen Benutzer lesbar (644),
damit `limitpulse status` ohne `sudo` läuft. Sie enthalten Zeitplan und gekürzte Meldungen von Claude Code (Token und
Schlüssel sind maskiert), aber keinen Token. Auf einem Rechner mit weiteren, nicht vertrauenswürdigen lokalen Benutzern
lässt sich das einschränken: `sudo systemctl edit limitpulse.service` und darin `[Service]` mit
`StateDirectoryMode=0750` eintragen (die Ergänzung überlebt eine erneute Installation, die Unit selbst nicht; `sudo limitpulse uninstall`
entfernt sie mit). Dann
kommen nur `limitpulse` und root an das Verzeichnis, und auch `limitpulse status` braucht `sudo`. Dateirechte einzeln zu
ändern hilft nicht: Der Dienst legt `state` bei jedem Speichern neu an. Diese Einschränkung ist nicht getestet.

## Prüfungen

`bash tests/run.sh` prüft ohne Netzwerk und ohne Änderungen am System:

- Syntax (`bash -n`) für Installer und eingebettetes Programm,
- den Parser gegen Beispielausgaben von Claude Code (`tests/fixtures`),
- die Versionsprüfung und den Installationsschritt für Claude Code (`tests/claude-version.sh`, `tests/claude-install-step.sh`),
- die Zeitplanlogik gegen einen Nachbau von Claude Code (`tests/schedule.sh`): Zeitplan-Datei, Wochen-Reset, Erfolg, volles Fenster,
  Wochenlimit, Fehlerserie mit Pausen, Abbruchgründe (auch abgelehnte Anmeldung), sofortige Wiederholung nach neuem Token,
- `shellcheck` für Installer, eingebettetes Programm und Tests. `shellcheck` muss installiert sein
  (`sudo apt install shellcheck`); fehlt es, laufen die übrigen Prüfungen trotzdem und der Aufruf endet danach mit einer klaren Meldung.

Dieselben Prüfungen laufen bei jedem Push als GitHub Action (`Prüfung`).

`bash tests/smoke.sh` ist der Rauchtest gegen die **installierte** Claude-Code-Version (`claude` im `PATH` oder `CLAUDE_BIN=…`).
Er führt `pulse_once` aus `install.sh` unverändert aus, mit denselben Flags und derselben Umgebung wie der Dienst. Nur Home,
Pfad zu Claude Code und Token sind ersetzt; ein Wrapper richtet `ANTHROPIC_BASE_URL` auf einen lokalen Stub
(`tests/stub_server.py`). Er prüft, dass der Aufruf klappt, genau eine Anfrage an `/v1/messages` geht (Modell
`claude-haiku-5-5`, keine Tools, Aufwand `low`, Ausgabegrenze 4096), die Antwort als Erfolg zählt und die Reset-Zeit
übernommen wird. Danach antwortet der Stub mit den Fehlern, die den Zeitplan steuern (5-Stunden-Fenster voll, Wochenlimit,
Anmeldung abgelehnt), und der Test prüft, dass `pulse_once` sie erkennt. Wegen der Auto-Updates läuft er außerdem
jeden Montag als GitHub Action (`Rauchtest Claude Code`) gegen die jeweils neueste Version. Er sagt nichts darüber, ob die echte API genau diese Anfrage annimmt.
