#!/bin/bash
# run.sh (MacBook) - baut imac-display (Release) und startet es.
#
#   ./run.sh                      # Standard: 4096x2304, 60 fps, Port 8080
#   ./run.sh --fps 30 --bitrate 40
#   ./run.sh --always-on          # virtuelles Display sofort und dauerhaft (sonst erst, wenn der iMac verbindet)
#   ./run.sh --demo-window        # zusaetzlich Schaerfe-/Bewegungs-Testbild auf dem virtuellen Display
#   ./run.sh --help
#
# Das virtuelle Display entsteht standardmaessig erst, wenn sich der iMac verbindet, und verschwindet
# 10 s nach dem Trennen wieder. Fuer den Dauerbetrieb ohne Terminal: install.command (Menueleisten-App).
#
# Beim ersten Start fragt macOS nach "Bildschirm- & Systemaudioaufnahme":
#   Systemeinstellungen -> Datenschutz & Sicherheit -> Bildschirm- & Systemaudioaufnahme
#   -> Terminal (bzw. iTerm/VS Code, je nachdem woraus du startest) aktivieren,
#   dann das Programm neu starten (ggf. Terminal neu oeffnen).
# Beim ersten Start kann ausserdem die Firewall fragen: "Eingehende Verbindungen erlauben" -> Erlauben.

set -e

# Projektwurzel = zwei Ebenen ueber diesem Skript
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  echo "FEHLER: 'swift' nicht gefunden. Bitte Xcode oder die Command Line Tools installieren:"
  echo "  xcode-select --install"
  exit 1
fi

echo "==> Baue imac-display (Release) ..."
swift build -c release

BIN="$ROOT/.build/release/imac-display"
if [ ! -x "$BIN" ]; then
  echo "FEHLER: $BIN wurde nicht erzeugt."
  exit 1
fi

echo
echo "==> Starte imac-display (Beenden mit Ctrl+C)"
echo "    Hinweis: Beim ersten Start die Berechtigung 'Bildschirm- & Systemaudioaufnahme' fuer Terminal erteilen"
echo "    (Systemeinstellungen -> Datenschutz & Sicherheit) und danach neu starten."
echo "    Auf dem iMac: start-display.command doppelklicken. Adresse: http://10.77.0.1:8080/"
echo
exec "$BIN" "$@"
