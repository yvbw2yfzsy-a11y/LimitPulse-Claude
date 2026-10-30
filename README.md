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

## Bedienung

| Befehl | Wirkung |
|---|---|
| `limitpulse status` | Dienstzustand, letzter und nächster Puls, letzte Meldungen |
| `sudo limitpulse token` | Abo-Token ändern; war der letzte Puls fehlgeschlagen, wird er sofort wiederholt |
| `sudo limitpulse uninstall` | alles entfernen, einschließlich der Claude-Code-Installation des Dienstes |

Das vollständige Protokoll zeigt `sudo journalctl -u limitpulse`.

## Funktionsweise

- **Puls:** ein Aufruf `claude -p "Hi"` mit Haiku 5.5 (`claude-haiku-5-5`), Aufwand `low`,
  ersetztem Systemprompt („Reply with exactly one word: ok“), ohne Tools, ohne MCP,
  ohne Skills, ohne gespeicherte Sitzung. Danach beendet sich der Prozess.
  Erfolg heißt: Exit-Code 0 und nicht leere Antwort.
- **Nächster Puls:** Meldet Claude Code in der Ausgabe den Reset des 5-Stunden-Fensters
  (`rate_limit_event`, siehe Agent-SDK-Referenz), gilt dieser Zeitpunkt + 60 s. Sonst gilt:
  Zeitpunkt der letzten erfolgreichen Antwort + 5 Stunden + 60 s.
- **Fehler:** Bis zu 10 Versuche je Puls mit wachsenden Pausen (30 s bis 15 min, zusammen
  etwa 75 Minuten). Danach steht der Fehler im Protokoll, und der Dienst versucht es
  5 Stunden + 60 s nach Pulsbeginn erneut.
- **Wochenlimit:** Scheitert ein Puls, weil das Wochenlimit voll ist (Meldung „weekly limit“
  oder abgelehntes `seven_day`-Event), gibt es keine weiteren Versuche. Der Dienst wartet auf den
  Wochen-Reset, den der Betreiber als samstags 15:00 Uhr beobachtet hat (+ 60 s Puffer), und
  startet dann das neue Fenster. Die Uhrzeit ist eine Annahme, keine dokumentierte Zusage. Gilt das
  Limit beim Wochen-Termin noch, fällt der Dienst für 3 Tage auf den normalen 5-Stunden-Takt zurück.
  Das 5-Stunden-Limit löst diese Logik nicht aus.
- **Neustart/Stromausfall:** Der Zeitplan liegt in `/var/lib/limitpulse/state`. Ein verpasster
  Puls wird nach dem Start sofort nachgeholt.
- **Anmeldung:** Der Aufruf läuft mit leerem Environment. `ANTHROPIC_API_KEY`,
  `ANTHROPIC_AUTH_TOKEN` und alle anderen Variablen werden entfernt. Beide haben laut Doku
  Vorrang vor `CLAUDE_CODE_OAUTH_TOKEN` und würden über die API abgerechnet.
- **Updates:** Die automatischen Updates von Claude Code bleiben an.

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
