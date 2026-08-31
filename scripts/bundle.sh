#!/bin/bash
# Builds the release binary and assembles a signed .app bundle in build/.
# A proper .app bundle (not a bare binary) is required for the macOS
# permission prompts (microphone, accessibility) to be attributed correctly.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Sprachacus.app"
KEYCHAIN="$HOME/Library/Keychains/diyspokenly.keychain-db"
# Local-only password for the dedicated keychain this script creates itself.
# It guards nothing but the self-signed dev certificate on this machine.
KC_PASS="diyspokenly-dev"
# The identity name is a purely internal keychain label; renaming it would
# only force re-granting TCC permissions, so it keeps its historical name.
IDENTITY="DIY Spokenly Dev"
BUNDLE_ID="com.marvinharst.sprachacus"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sprachacus "$APP/Contents/MacOS/Sprachacus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Finder metadata / resource forks on the copied files make codesign refuse to
# sign ("resource fork, Finder information, or similar detritus not allowed").
xattr -cr "$APP"

# Note: `find-identity -v` treats the untrusted self-signed cert as invalid,
# but codesign happily signs with it — so just try and fall back on failure.
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" 2>/dev/null || true
if codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
    echo "Signed with stable identity '$IDENTITY'."
elif [ "${FORCE_ADHOC:-0}" = "1" ]; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "WARNUNG: Ad-hoc signiert (FORCE_ADHOC=1). Alle Berechtigungen müssen neu erteilt werden."
else
    # Never fall back silently: an ad-hoc signature changes the code hash on
    # every build, which silently invalidates ALL TCC grants.
    echo "FEHLER: Signieren mit '$IDENTITY' fehlgeschlagen." >&2
    echo "Ohne stabile Signatur verliert Sprachacus bei jedem Rebuild sämtliche" >&2
    echo "Berechtigungen (Bedienungshilfen, Mikrofon, Bildschirmaufnahme)." >&2
    echo "Lösung:          ./scripts/setup-signing.sh" >&2
    echo "Notfall-Bypass:  FORCE_ADHOC=1 make install" >&2
    exit 1
fi

echo "Bundle: $APP"
