#!/bin/bash
# Receiver/build-dmg.sh (MacBook) - baut die Empfaenger-App fuer den iMac und das Disk-Image.
#
# Ergebnis:
#   dist/iMac Display Empfänger.app     (Universal: Intel + Apple Silicon, ab macOS 12, ad-hoc signiert)
#   dist/iMac-Display-Empfaenger.dmg    (App + Verknuepfung "Programme" + LIESMICH.txt)
#
# Das DMG auf den iMac kopieren, oeffnen, App nach "Programme" ziehen, beim ersten Mal per
# Rechtsklick > Oeffnen starten und der Checkliste folgen.
#
# Optionen:  --scratch-path <dir>   Build-Ordner (Standard: $TMPDIR/imac-display-receiver-build,
#                                   damit im Projektordner kein .build entsteht)
# Die App zeigt das Bild selbst an (VideoToolbox) - kein Browser, keine player.html.

set -eu

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$PKG/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="iMac Display Empfänger"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/iMac-Display-Empfaenger.dmg"
EXE="iMacDisplayReceiver"
VERSION="1.0"
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}/imac-display-receiver-build"

while [ $# -gt 0 ]; do
  case "$1" in
    --scratch-path) SCRATCH="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "==> Baue $EXE (Universal arm64 + x86_64, macOS 12+) ..."
(cd "$PKG" && swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH")
BIN="$SCRATCH/apple/Products/Release/$EXE"
[ -x "$BIN" ] || { echo "FEHLER: $BIN nicht gefunden" >&2; exit 1; }
lipo -info "$BIN"
for a in x86_64 arm64; do
  lipo "$BIN" -verify_arch "$a" || { echo "FEHLER: Architektur $a fehlt" >&2; exit 1; }
  minos="$(vtool -arch "$a" -show-build "$BIN" | awk '/minos/{print $2}')"
  [ "$minos" = "12.0" ] || { echo "FEHLER: $a minos=$minos (erwartet 12.0)" >&2; exit 1; }
done
echo "    x86_64 + arm64, minos 12.0"

echo "==> Erzeuge App-Bundle ..."
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>de</string>
	<key>CFBundleExecutable</key><string>$EXE</string>
	<key>CFBundleIdentifier</key><string>de.local.imac-display-receiver</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>LSUIElement</key><false/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHumanReadableCopyright</key><string>Empfänger für iMac Display (Ethernet-Direktverbindung)</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key><true/>
		<key>NSAllowsArbitraryLoads</key><true/>
	</dict>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signiere (ad-hoc) ..."
xattr -cr "$APP"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Erzeuge DMG ..."
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/imac-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
cat > "$STAGE/LIESMICH.txt" <<'TXT'
iMac Display Empfänger
======================

So wird der iMac zum Bildschirm für das MacBook. Die App zeigt das Bild selbst an –
ein Browser (Google Chrome o. ä.) ist NICHT nötig.

1. Die App „iMac Display Empfänger“ auf „Programme“ ziehen.
2. WICHTIG beim ersten Start: Im Ordner Programme mit RECHTSKLICK (oder ctrl-Klick) auf die App
   > „Öffnen“ > im Dialog nochmals „Öffnen“.
   Die App ist nur „ad-hoc“ signiert (nicht von Apple beglaubigt). Ein normaler Doppelklick wird
   beim ersten Mal mit „kann nicht geöffnet werden“ blockiert – das ist erwartet. Danach startet sie normal.
3. Der Checkliste im Fenster folgen. Jede Zeile wird grün, sobald alles passt; bei Rot/Orange steht
   direkt darunter „Was tun?“:
   - Video-Dekodierung: prüft beim Start mit einem Probebild, ob dieser Mac das 4K-Videoformat
     (H.264, 4096×2304) in der Grafik-Hardware dekodieren kann
   - Ethernet-Kabel steckt
   - Netzwerkadresse 10.77.0.2 („Einrichten …“, Admin-Passwort; ändert nur den Ethernet-Dienst,
     WLAN/Internet bleiben; die alte Einstellung wird gesichert, „Zurücksetzen“ stellt sie exakt wieder her)
   - MacBook erreichbar (dort die App starten und „Übertragung aktiv“ einschalten)
   - Monitor-Modus: das Bild des MacBooks im Vollbild, startet von selbst.
     Ohne Übertragung steht dort „Aktuell kein aktiver Monitor“.
   - Bild vom MacBook: zeigt im Monitor-Modus, ob ein Bild ankommt (z. B. „Läuft · 52 fps“)
   - Autostart: startet den Monitor-Modus bei jeder Anmeldung (jederzeit wieder ausschaltbar).

Vollbild beenden: Cmd+Q – dann erscheint das Fenster mit der Checkliste wieder
(nochmals Cmd+Q beendet die App). Esc beendet bewusst nichts.
Taste „s“ im Vollbild: Messwerte (Bildrate, Datenrate, Fehler) ein-/ausblenden.
Stürzt die App ab, startet der Autostart sie nach ein paar Sekunden neu.

Was die App am System ändert – nur nach einem Klick, alles umkehrbar:
   - Netzwerk: nur „Einrichten …“ (Admin-Passwort) / „Zurücksetzen“
   - Autostart: nur die Datei ~/Library/LaunchAgents/de.local.imac-display-receiver.plist (kein Admin)
   - Einstellungen unter ~/Library/Application Support/iMacDisplay
   - Protokoll: ~/Library/Logs/iMacDisplayReceiver.log
   - Solange der Monitor-Modus läuft, schläft der Rechner nicht automatisch ein (der Bildschirm schon,
     solange kein MacBook da ist). Wird beim Beenden sofort freigegeben; keine Energie-Einstellung wird geändert.

Entfernen: In der App unten „Deinstallieren …“ – Autostart, Netzwerk, Daten und App einzeln wählbar.
Protokoll: In der App unten „Protokoll anzeigen“.

Voraussetzungen: macOS 12 Monterey oder neuer (Intel oder Apple Silicon),
Ethernet-Kabel direkt zum MacBook.
TXT
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "==> Pruefe DMG ..."
MNT="$(mktemp -d "${TMPDIR:-/tmp}/imac-dmg-mnt.XXXXXX")"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
ok=1
[ -x "$MNT/$APP_NAME.app/Contents/MacOS/$EXE" ] || ok=0
[ ! -e "$MNT/$APP_NAME.app/Contents/Resources/player.html" ] || { echo "FEHLER: alte player.html im Paket" >&2; ok=0; }
[ -L "$MNT/Programme" ] && [ "$(readlink "$MNT/Programme")" = /Applications ] || ok=0
[ -f "$MNT/LIESMICH.txt" ] || ok=0
grep -q "Version 94" "$MNT/LIESMICH.txt" && { echo "FEHLER: LIESMICH verlangt noch Chrome" >&2; ok=0; }
lipo "$MNT/$APP_NAME.app/Contents/MacOS/$EXE" -verify_arch x86_64 arm64 || ok=0
codesign --verify --deep --strict "$MNT/$APP_NAME.app" || ok=0
ls -la "$MNT" | sed '1d; s/^/    /'
hdiutil detach "$MNT" >/dev/null
rmdir "$MNT" 2>/dev/null || true
[ $ok -eq 1 ] || { echo "FEHLER: DMG-Inhalt unvollstaendig" >&2; exit 1; }

echo
echo "Fertig:"
echo "  $APP"
echo "  $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "Auf den iMac kopieren, öffnen, App nach „Programme“ ziehen, per Rechtsklick > Öffnen starten."
