#!/bin/bash
# uninstall.command (MacBook) - "iMac Display" beenden, Anmeldeobjekt entfernen, App loeschen.
# Doppelklicken (oder im Terminal: scripts/macbook/uninstall.command).
# Empfohlen ist stattdessen in der App: Fenster "Einrichtung & Status" -> "Deinstallieren ..." - dort
# waehlt man jeden Punkt einzeln, und die Netzwerkeinstellung wird exakt auf den vorherigen Stand gesetzt.
# Dieses Skript ist der Notfallweg, falls die App nicht mehr startet. Die Netzwerkeinstellung (10.77.0.1)
# bleibt hier unveraendert; zuruecksetzen: App-Fenster "Einrichtung & Status" -> Zuruecksetzen, oder Systemeinstellungen -> Netzwerk

APP_NAME="iMac Display"
BUNDLE_ID="de.local.imac-display"

pause_exit() {
  echo
  read -r -p "Zum Schliessen Enter druecken ..." _ </dev/tty 2>/dev/null || true
  exit "${1:-0}"
}

ask_yes() {
  local a
  read -r -p "$1 (j/N) " a </dev/tty || return 1
  case "$a" in j|J|ja|Ja|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

app_running() {
  pgrep -f "/$APP_NAME.app/Contents/MacOS/imac-display" >/dev/null 2>&1
}

echo "=============================================="
echo " iMac Display - Deinstallation"
echo "=============================================="
echo

# 1. Beenden
if app_running; then
  echo "==> Beende \"$APP_NAME\" ..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
  i=0
  while app_running && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
  app_running && pkill -TERM -f "/$APP_NAME.app/Contents/MacOS/imac-display" 2>/dev/null
  sleep 1
  app_running && pkill -KILL -f "/$APP_NAME.app/Contents/MacOS/imac-display" 2>/dev/null
fi

FOUND=0
for app in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
  [ -d "$app" ] || continue
  FOUND=1
  # 2. Anmeldeobjekt abmelden (muss aus dem App-Bundle heraus geschehen)
  echo "==> Entferne Anmeldeobjekt ($app) ..."
  "$app/Contents/MacOS/imac-display" --unregister-login-item 2>/dev/null | sed 's/^/  /'
  # 3. Firewall-Eintrag (nur falls vorhanden)
  FW=/usr/libexec/ApplicationFirewall/socketfilterfw
  if [ -x "$FW" ] && "$FW" --listapps 2>/dev/null | grep -qF "$app"; then
    echo "  Firewall-Eintrag gefunden - entfernen braucht das Admin-Passwort (sudo)."
    sudo "$FW" --remove "$app" >/dev/null || echo "  (Firewall-Eintrag nicht entfernt)"
  fi
  # 4. App loeschen
  echo "==> Loesche $app ..."
  if ! rm -rf "$app" 2>/dev/null || [ -d "$app" ]; then
    echo "  Keine Schreibrechte - versuche mit sudo ..."
    sudo rm -rf "$app"
  fi
done
[ $FOUND -eq 0 ] && echo "\"$APP_NAME\" ist weder in /Applications noch in ~/Applications installiert."
echo

if ask_yes "Auch Einstellungen, Protokoll und die Bildschirmaufnahme-Freigabe entfernen?"; then
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1
  rm -f "$HOME/Library/Logs/iMacDisplay.log"
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1
  echo "  entfernt."
fi

echo
echo "Fertig. \"$APP_NAME\" wurde deinstalliert."
echo "Der Projektordner (und dist/) bleibt erhalten; die Netzwerkeinstellung ebenso"
echo "(zuruecksetzen: in der App -> Zuruecksetzen, oder Systemeinstellungen -> Netzwerk)."
pause_exit 0
