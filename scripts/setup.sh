#!/bin/bash
# Einrichtung in einem Befehl: prüft die Voraussetzungen, legt die stabile
# Signaturidentität an, baut die App, installiert sie nach /Applications
# und startet sie. Gefahrlos mehrfach ausführbar.
set -euo pipefail
cd "$(dirname "$0")/.."

bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n\n' "$1"; exit 1; }
step() { printf '\n%s%s%s\n' "$bold" "$1" "$reset"; }

printf '\n%sSprachacus — Einrichtung%s\n' "$bold" "$reset"

step "1/4  Voraussetzungen"

os_version=$(sw_vers -productVersion)
if [ "${os_version%%.*}" -lt 26 ]; then
    fail "macOS 26 (Tahoe) oder neuer nötig — gefunden: $os_version.
     Sprachacus baut auf dem SpeechAnalyzer-Framework aus macOS 26 auf."
fi
ok "macOS $os_version"

if [ "$(uname -m)" != "arm64" ]; then
    fail "Apple Silicon nötig — gefunden: $(uname -m)."
fi
ok "Apple Silicon"

command -v swift >/dev/null 2>&1 || fail "Xcode Command Line Tools fehlen.
     Installieren mit:  xcode-select --install"

sdk_version=$(xcrun --show-sdk-version 2>/dev/null || echo 0)
if [ "${sdk_version%%.*}" -lt 26 ]; then
    fail "macOS-SDK 26+ nötig — gefunden: $sdk_version.
     Die Command Line Tools sind zu alt. Verfügbare Versionen anzeigen:
       softwareupdate --list
     und dann z. B.:
       softwareupdate --install 'Command Line Tools for Xcode 26.6-26.6'"
fi
ok "Command Line Tools mit SDK $sdk_version"

step "2/4  Signatur"
echo "  Eine stabile, selbst signierte Identität sorgt dafür, dass die erteilten"
echo "  Berechtigungen jeden Rebuild überleben."
./scripts/setup-signing.sh 2>&1 | sed 's/^/  /'

step "3/4  Bauen und installieren"
./scripts/bundle.sh 2>&1 | sed 's/^/  /'
pkill -x Sprachacus 2>/dev/null || true
rm -rf "/Applications/Sprachacus.app"
cp -R "build/Sprachacus.app" "/Applications/Sprachacus.app"
ok "installiert nach /Applications/Sprachacus.app"
# LaunchServices braucht nach dem Ersetzen einen Moment, sonst scheitert `open`.
sleep 2
if open "/Applications/Sprachacus.app" 2>/dev/null; then
    ok "gestartet — das Mikrofon-Symbol erscheint in der Menüleiste"
else
    warn "Automatischer Start fehlgeschlagen — bitte Sprachacus aus /Applications öffnen."
fi

step "4/4  KI-Textkorrektur (optional)"
if command -v claude >/dev/null 2>&1; then
    ok "Claude CLI gefunden: $(command -v claude)"
    echo "     Falls noch nie angemeldet: einmal 'claude' im Terminal starten."
else
    warn "Claude CLI nicht gefunden — nötig für Assist und Meeting-Zusammenfassungen:"
    echo "       npm install -g @anthropic-ai/claude-code"
    echo "     danach einmal 'claude' starten und anmelden."
fi
echo "  Apple Intelligence (lokale Korrektur) einschalten:"
echo "     Systemeinstellungen → Apple Intelligence & Siri"

cat <<'NEXT'

Noch zu erledigen — Sprachacus fragt beides beim ersten Start selbst ab:

  1. Bedienungshilfen freigeben (für den Hotkey und das Einfügen)
     Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen
  2. Mikrofon erlauben

Dann: rechte Optionstaste drücken, sprechen, erneut drücken.
Status jederzeit prüfen über das Menüleisten-Symbol → „Berechtigungen prüfen…".

NEXT
