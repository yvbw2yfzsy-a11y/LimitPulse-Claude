# LimitPulse-Claude

Kleiner Hintergrunddienst für den Raspberry Pi. Er sendet alle 5 Stunden eine
minimale Anfrage über die offizielle Anthropic API. Der erste Termin ist der
nächste 08:00 Uhr (Europe/Berlin), danach folgt die Anfrage exakt alle 5 Stunden
(08:00, 13:00, 18:00, 23:00, 04:00, 09:00 …).

## Voraussetzungen

- Raspberry Pi OS Bullseye oder neuer (oder ein anderes Debian mit systemd ≥ 247)
- `curl` (bei Raspberry Pi OS in der Regel vorinstalliert; der Installer prüft das)
- ein Anthropic-API-Schlüssel mit Guthaben (https://console.anthropic.com)

## Installation

1. `install.sh` auf den Raspberry Pi kopieren, zum Beispiel vom PC aus:

   ```bash
   scp install.sh pi@raspberrypi.local:~
   ```

2. Auf dem Raspberry Pi ausführen:

   ```bash
   sudo bash install.sh
   ```

3. Den API-Schlüssel einfügen, wenn das Skript danach fragt. Die Eingabe bleibt
   unsichtbar.

Danach läuft der Dienst im Hintergrund und startet nach einem Neustart des Pi
von selbst.

## Bedienung

| Befehl | Wirkung |
|---|---|
| `limitpulse status` | Status, nächste Termine und letzte Meldungen anzeigen |
| `sudo limitpulse key` | API-Schlüssel ändern oder ersetzen |
| `sudo limitpulse uninstall` | LimitPulse vollständig entfernen |

Das vollständige Protokoll zeigt `sudo journalctl -u limitpulse`.

## Funktionsweise

- **Anfrage:** Modell `claude-haiku-5-5` (das günstigste verfügbare Modell,
  Stand Oktober 2026), Eingabe `Hi`, `max_tokens: 1`, Thinking abgeschaltet.
- **Wiederholungen:** Bei vorübergehenden Fehlern (Netzwerkfehler, HTTP 408,
  409, 429, 5xx, 529) versucht der Dienst es erneut. Die Pausen beginnen bei
  30 s und verdoppeln sich bis höchstens 15 min. Eine `retry-after`-Vorgabe der
  API hat Vorrang. Die Versuche laufen, bis die Anfrage durchgeht, längstens bis
  5 min vor dem nächsten Termin.
- **Keine Wiederholung** bei dauerhaften Fehlern wie 400 (z. B. kein Guthaben)
  oder 401 (ungültiger Schlüssel). Der Fehler steht im Protokoll, der nächste
  Termin versucht es erneut.
- **Zeitplan:** Die Termine werden aus dem ersten Termin und echten 5-Stunden-
  Abständen berechnet. Bei der Umstellung auf Sommer- bzw. Winterzeit
  verschieben sich die Uhrzeiten daher um eine Stunde. Ein verpasster Termin
  (Pi ausgeschaltet) wird nicht nachgeholt.

## Was die Installation verändert

Nur diese Dateien werden angelegt:

```
/opt/limitpulse/limitpulse.sh           Programm
/etc/limitpulse/limitpulse.conf         Einstellungen (erster Termin, Modell)
/etc/limitpulse/api-key                 API-Schlüssel (nur für root lesbar)
/etc/systemd/system/limitpulse.service  systemd-Dienst
/usr/local/bin/limitpulse               Befehl (Verweis auf das Programm)
```

Der Installer installiert keine Pakete, legt keine Benutzer an, öffnet keine
Ports und verändert oder startet keine anderen Dienste. Existiert eine dieser
Dateien bereits und stammt sie nicht von LimitPulse, bricht er ab, ohne etwas zu
ändern.

Der Dienst läuft unter einem eigenen, kurzlebigen Benutzer ohne Rechte
(`DynamicUser`). Er hat keinen Zugriff auf Home-Verzeichnisse und kann das
System nicht verändern. Den API-Schlüssel stellt ihm systemd bereit. Die
Schlüsseldatei selbst kann nur root lesen, und der Schlüssel taucht nicht in der
Prozessliste auf.
