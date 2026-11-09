#!/bin/bash
# build-app.sh (MacBook) - baut imac-display (Release), setzt "iMac Display.app" zusammen und
# erzeugt das Disk-Image zum Installieren. Installiert selbst nichts. Wird von install.command benutzt.
#
#   scripts/macbook/build-app.sh                       # -> dist/iMac Display.app + dist/iMac-Display-MacBook.dmg
#   scripts/macbook/build-app.sh --out /pfad/ziel      # anderes Zielverzeichnis
#   scripts/macbook/build-app.sh --scratch-path DIR    # eigenes SwiftPM-Build-Verzeichnis (statt .build)
#   scripts/macbook/build-app.sh --no-dmg              # nur die App, kein Disk-Image
#   SIGN_IDENTITY="Apple Development: ..." scripts/macbook/build-app.sh   # statt Ad-hoc-Signatur
#
# Ergebnis:
#   dist/iMac Display.app
#     Contents/MacOS/imac-display     das Programm (gleiche Datei wie die Kommandozeilenversion)
#     Contents/Resources/index.html   die Webseite fuer den iMac
#     Contents/Info.plist             de.local.imac-display, LSUIElement (kein Dock-Symbol)
#   dist/iMac-Display-MacBook.dmg     Volume "iMac Display": die App + Verknuepfung "Programme"
#                                     (App auf "Programme" ziehen, dann starten)

set -e
set -o pipefail

APP_NAME="iMac Display"
VERSION="1.2.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$ROOT/dist"
SCRATCH=""
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MAKE_DMG=1
DMG_NAME="iMac-Display-MacBook.dmg"
VOL_NAME="iMac Display"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --scratch-path) SCRATCH="$2"; shift 2 ;;
    --no-dmg) MAKE_DMG=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  echo "FEHLER: 'swift' nicht gefunden. Bitte Xcode oder die Command Line Tools installieren: xcode-select --install" >&2
  exit 1
fi

SWIFT_ARGS="-c release"
if [ -n "$SCRATCH" ]; then
  SWIFT_ARGS="$SWIFT_ARGS --scratch-path $SCRATCH"
fi

echo "==> Baue imac-display (Release) ..."
# shellcheck disable=SC2086
swift build $SWIFT_ARGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build $SWIFT_ARGS --show-bin-path)"
BIN="$BIN_DIR/imac-display"
if [ ! -x "$BIN" ]; then
  echo "FEHLER: $BIN wurde nicht erzeugt." >&2
  exit 1
fi

HTML="$BIN_DIR/imac-display_imac-display.bundle/index.html"
[ -f "$HTML" ] || HTML="$ROOT/Sources/imac-display/Resources/index.html"
if [ ! -f "$HTML" ]; then
  echo "FEHLER: index.html nicht gefunden." >&2
  exit 1
fi

APP="$OUT/$APP_NAME.app"
echo "==> Setze \"$APP\" zusammen ..."
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/imac-display"
cp "$HTML" "$APP/Contents/Resources/index.html"
BUILD_NO="$(date +%Y%m%d%H%M)"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NO/" "$SCRIPT_DIR/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Erweiterte Attribute (Finder-Infos, Quarantaene) stoeren codesign ("resource fork ... not allowed").
xattr -cr "$APP" 2>/dev/null || true

echo "==> Signiere (${SIGN_IDENTITY}) ..."
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier de.local.imac-display "$APP"
codesign --verify --deep --strict "$APP"
echo "    Signatur OK: $(codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature)=' | tr '\n' ' ')"

echo "==> Fertig: $APP (Version $VERSION, Build $BUILD_NO)"

if [ "$MAKE_DMG" -eq 1 ]; then
  DMG="$OUT/$DMG_NAME"
  echo "==> Erzeuge Disk-Image \"$DMG\" ..."
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/imac-display-dmg.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Programme"
  rm -f "$DMG"
  hdiutil create -quiet -volname "$VOL_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
  hdiutil verify -quiet "$DMG"
  echo "==> Fertig: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
fi
