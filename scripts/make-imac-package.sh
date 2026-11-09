#!/bin/bash
# make-imac-package.sh (MacBook) - baut das iMac-Paket.
# Einziger Installationsweg fuer den iMac ist die App "iMac Display Empfänger" (dist/iMac-Display-Empfaenger.dmg).
# Dieses Skript ist nur eine Abkuerzung fuer Receiver/build-dmg.sh (alle Optionen werden durchgereicht).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Receiver/build-dmg.sh" "$@"
