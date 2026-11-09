# iMac Display – iMac 4K als externer Bildschirm für das MacBook

Der iMac 4K (21,5", 4096×2304, macOS Monterey) wird über ein **direktes Ethernet-Kabel** zum zweiten Bildschirm
des MacBooks. Das funktioniert unabhängig vom WLAN, in dem das MacBook gerade ist.

## So funktioniert es

```
MacBook: „iMac Display“ (Menüleiste)                        iMac: „iMac Display Empfänger“
 1. virtueller Bildschirm 2048×1152 pt (= 4096×2304 px)      5. eigener Vollbild-Player (kein Browser)
 2. Bildschirmaufnahme (ScreenCaptureKit)                     6. H.264-Hardware-Dekodierung (VideoToolbox)
 3. H.264-Hardware-Encoder (VideoToolbox)                     7. Bild 1:1 pixelgenau
 4. Server :8080 ──── Ethernet-Kabel 10.77.0.1 ⇄ 10.77.0.2 ────
```

- Das MacBook legt den virtuellen Bildschirm **nur an, solange der iMac verbunden ist**. 10 s nach dem Trennen
  verschwindet er wieder, ohne Kabel bleibt kein „Geister-Bildschirm“ zurück.
- Der iMac zeigt **„Aktuell kein aktiver Monitor“**, solange nichts übertragen wird. Das Bild startet von selbst,
  sobald das MacBook sendet.
- Die Verbindung läuft nur über das Kabel. Feste Adressen ohne Router sorgen dafür, dass das WLAN weiter für das
  Internet zuständig bleibt. Der Server nimmt nur Verbindungen von 10.77.0.x, 169.254.x.x und dem MacBook selbst an.
  Im Café-WLAN kann also niemand den Bildschirm sehen.

## Installation

Du brauchst zwei Dateien aus `dist/`:

| Datei | Für |
|---|---|
| `iMac-Display-MacBook.dmg` | MacBook |
| `iMac-Display-Empfaenger.dmg` | iMac (Universal: Intel + Apple Silicon, ab macOS 12) |

### MacBook

1. DMG öffnen, **iMac Display** in „Programme“ ziehen und starten. Ein Bildschirm-Symbol erscheint in der Menüleiste.
2. Das Fenster **„Einrichtung & Status“** öffnet sich. Jede Zeile hat eine Ampel. Ist sie nicht grün, steht darunter
   „Was tun?“ mit einem passenden Knopf:
   - **Bildschirmaufnahme → Erlauben …**: Schalter bei „iMac Display“ einschalten, danach „Neu starten“.
   - **Netzwerkadresse 10.77.0.1 → Einrichten**: gibt nur dem Kabel-Adapter die feste Adresse, ohne Router.
     macOS fragt nach dem Admin-Passwort. Die vorherige Einstellung wird gespeichert, **Zurücksetzen** stellt sie
     exakt wieder her.
3. Optional: **Bei Anmeldung starten** einschalten.

### iMac

1. DMG auf den iMac kopieren (AirDrop/USB-Stick) und öffnen, **iMac Display Empfänger** in „Programme“ ziehen.
2. Beim ersten Start: **Rechtsklick → Öffnen** (die App ist nicht von Apple notarisiert).
3. Im Fenster **Netzwerkadresse 10.77.0.2 → Einrichten** und **Autostart einschalten**. Dann
   **Monitor-Modus starten**: Das Bild erscheint im Vollbild, danach ist nichts anderes mehr zu sehen.
   Ein Browser ist nicht nötig.
4. Empfehlung: automatische Anmeldung auf dem iMac aktivieren (*Systemeinstellungen → Benutzer:innen & Gruppen →
   Anmeldeoptionen*), dann startet nach dem Einschalten direkt der Monitor.

**Beenden:** Cmd+Q im Vollbild. Danach erscheint wieder das Statusfenster. Stürzt die App ab, startet der Autostart sie neu.

### Danach

Kabel einstecken, fertig. Das MacBook erkennt den iMac, legt den Bildschirm an, und der iMac zeigt das Bild.
Anordnen kannst du ihn unter *Systemeinstellungen → Displays*.
Menüleiste → **Testbild auf iMac anzeigen** zeigt ein Schärfe- und Bewegungstestbild auf dem iMac.

## Abschalten und Entfernen

Beide Apps greifen nur auf Knopfdruck ins System ein, und jede Änderung lässt sich im Fenster rückgängig machen.

| Was | Abschalten / Rückgängig |
|---|---|
| Übertragung (MacBook) | Schalter **Übertragung aktiv** (auch im Menü) |
| Bildschirmaufnahme | **Entziehen** |
| Feste Netzwerkadresse | **Zurücksetzen** (stellt die gespeicherte vorherige Einstellung her) |
| Start bei Anmeldung / Autostart | Schalter bzw. **Autostart ausschalten** |
| Alles | **Deinstallieren …**: Haken für jeden Teil, die App wandert in den Papierkorb |

Notfall, falls die MacBook-App nicht mehr startet: `scripts/macbook/uninstall.command`.

## Fehlerbehebung

Fast alles zeigen die Statusfenster direkt an, rote Zeile mit „Was tun?“. Zusätzlich:

- **Bild ruckelt:** Auf dem iMac im Vollbild `s` drücken: Statistik mit fps, Mbit/s und Fehlern. Im Statusfenster zeigt
  „Video-Dekodierung“, ob der iMac 4K per Hardware dekodiert. Sonst die Bildrate senken:
  `defaults write de.local.imac-display fps -int 30`, dann die App neu starten.
- **Bildschirmaufnahme ist erlaubt, geht aber nicht** (nach einem Update der App): im Fenster
  **Eintrag zurücksetzen**, dann erneut erlauben. Jede neue Version gilt für macOS als neue App.
- **iMac zeigt dauerhaft „Aktuell kein aktiver Monitor“:** Im MacBook-Fenster die Zeilen „Ethernet-Kabel“,
  „Netzwerkadresse“ und „iMac erreichbar“ prüfen. Ab macOS 15 gegebenenfalls *Lokales Netzwerk* für „iMac Display“ erlauben.
- **Protokolle:** MacBook `~/Library/Logs/iMacDisplay.log`, iMac über „Protokoll anzeigen“ im Fenster.

## Für Entwickler

```
Sources/imac-display/      MacBook-App (Swift): AppController, VirtualDisplay, ScreenCapture, H264Encoder,
                           SPSRewriter, StreamServer, Setup*, QualityLab; Resources/index.html = Browser-Player
                           (für Tests unter http://127.0.0.1:8080/)
Receiver/                  iMac-App (Swift, macOS 12, universal) mit eigenem Player (AVSampleBufferDisplayLayer)
scripts/macbook/           build-app.sh (App + DMG), install.command, uninstall.command, run.sh
scripts/make-imac-package.sh → Receiver/build-dmg.sh
docs/PROTOCOL.md           Wire-Protokoll und Architektur
```

- Bauen: `scripts/macbook/build-app.sh` und `Receiver/build-dmg.sh`
- Testen ohne Bildschirmaufnahme: `imac-display --test-pattern`, dann im Browser `http://127.0.0.1:8080/` öffnen
- Qualitätsmessung: `imac-display --selftest-quality`
- Kommandozeile: `imac-display --help`. Wichtige Optionen sind `--fps`, `--bitrate`, `--always-on`, `--demo-window`, `--dry-run`.
