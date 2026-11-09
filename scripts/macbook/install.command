#!/bin/bash
# install.command (MacBook) - Alternative zum Disk-Image: "iMac Display" aus dem Quelltext bauen und
# in den Ordner "Programme" kopieren. Doppelklicken (oder im Terminal: scripts/macbook/install.command).
#
#   1. prueft Swift / Command Line Tools
#   2. baut die App und das Disk-Image (scripts/macbook/build-app.sh -> dist/)
#   3. beendet eine laufende alte Version und kopiert die App nach /Applications
#      (falls dort nicht beschreibbar: ~/Applications)
#   4. startet die App
#
# Dieses Skript aendert sonst NICHTS am System (kein Netzwerk, keine Firewall, keine Berechtigungen,
# kein Autostart). Das alles erledigt man in der App im Fenster "Einrichtung & Status" per Knopfdruck -
# und kann es dort auch wieder zuruecknehmen (inkl. "Deinstallieren ...").

APP_NAME="iMac Display"
BUNDLE_ID="de.local.imac-display"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT" || exit 1

pause_exit() {
  echo
  read -r -p "Zum Schliessen Enter druecken ..." _ </dev/tty 2>/dev/null || true
  exit "${1:-0}"
}

app_running() {
  pgrep -f "/$APP_NAME.app/Contents/MacOS/imac-display" >/dev/null 2>&1
}

echo "=============================================="
echo " iMac Display - Installation"
echo "=============================================="
echo

# --- 1. Swift ----------------------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "FEHLER: Die Xcode Command Line Tools (Swift) fehlen."
  echo "Bitte installieren mit:   xcode-select --install"
  echo "(oder Xcode aus dem App Store) und danach dieses Skript erneut starten."
  pause_exit 1
fi
echo "Swift: $(swift --version 2>/dev/null | head -n 1)"
echo

# --- 2. Bauen ----------------------------------------------------------------
if ! "$SCRIPT_DIR/build-app.sh" "$@"; then
  echo
  echo "FEHLER: Der Build ist fehlgeschlagen (siehe Meldungen oben)."
  pause_exit 1
fi
SRC_APP="$ROOT/dist/$APP_NAME.app"
echo

# --- 3. Zielordner, alte Version beenden, kopieren ------------------------------
DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi
DEST_APP="$DEST_DIR/$APP_NAME.app"
UPGRADE=0
[ -d "$DEST_APP" ] && UPGRADE=1

if app_running; then
  echo "==> Beende laufendes \"$APP_NAME\" ..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
  i=0
  while app_running && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
  if app_running; then
    pkill -TERM -f "/$APP_NAME.app/Contents/MacOS/imac-display" 2>/dev/null
    i=0
    while app_running && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
  fi
  app_running && pkill -KILL -f "/$APP_NAME.app/Contents/MacOS/imac-display" 2>/dev/null
  sleep 0.5
fi

if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "WARNUNG: Port 8080 ist belegt - laeuft noch imac-display im Terminal (run.sh)?"
  lsof -nP -iTCP:8080 -sTCP:LISTEN | sed 's/^/  /'
  echo "  Bitte dieses Programm beenden (Ctrl+C), sonst kann die App nicht starten."
  echo
fi

echo "==> Kopiere nach \"$DEST_APP\" ..."
[ $UPGRADE -eq 1 ] && rm -rf "$DEST_APP"   # alte Version derselben App ersetzen
if ! ditto "$SRC_APP" "$DEST_APP"; then
  echo "FEHLER: Kopieren nach $DEST_DIR fehlgeschlagen."
  pause_exit 1
fi
if ! codesign --verify --deep --strict "$DEST_APP" 2>/dev/null; then
  echo "WARNUNG: Signaturpruefung der installierten App fehlgeschlagen."
fi
for other in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
  if [ "$other" != "$DEST_APP" ] && [ -d "$other" ]; then
    echo "Hinweis: Es gibt noch eine aeltere Kopie: $other (bitte bei Gelegenheit in den Papierkorb legen)."
  fi
done
echo

# --- 4. Starten ----------------------------------------------------------------
echo "==> Starte \"$APP_NAME\" ..."
open "$DEST_APP"
echo
echo "Fertig. \"$APP_NAME\" laeuft jetzt in der Menueleiste (Bildschirm-Symbol oben rechts)."
echo "Das Fenster \"Einrichtung & Status\" zeigt, was noch fehlt (rot/orange), und hat fuer jeden"
echo "Punkt einen Knopf - z. B. Bildschirmaufnahme erlauben, Netzwerkadresse 10.77.0.1 einrichten,"
echo "\"Bei Anmeldung starten\". Alles laesst sich dort auch wieder zuruecknehmen."
if [ $UPGRADE -eq 1 ]; then
  echo
  echo "Update-Hinweis: Nach einem Update steht \"Bildschirmaufnahme\" in den Systemeinstellungen oft noch"
  echo "auf \"ein\", wirkt aber nicht mehr. Dann im Fenster \"Eintrag zuruecksetzen\" und erneut \"Erlauben ...\"."
fi
echo "Protokoll: ~/Library/Logs/iMacDisplay.log"
pause_exit 0
