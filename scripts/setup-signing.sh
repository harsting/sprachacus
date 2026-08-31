#!/bin/bash
# Creates a stable self-signed code-signing identity "DIY Spokenly Dev" in a
# dedicated keychain. A stable identity is required so that the macOS
# Accessibility permission (TCC) survives rebuilds — ad-hoc signatures change
# their hash on every build, which silently invalidates the grant.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/diyspokenly.keychain-db"
# Local-only password for the dedicated keychain this script creates itself.
# It guards nothing but the self-signed dev certificate on this machine.
KC_PASS="diyspokenly-dev"
IDENTITY="DIY Spokenly Dev"

# NOTE: check WITHOUT -v. A self-signed certificate is untrusted, so `-v`
# hides it — and the script would then delete and recreate the keychain,
# silently invalidating every TCC grant tied to the old signature.
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Signaturidentität '$IDENTITY' ist bereits vorhanden — nichts zu tun."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<'EOF'
[req]
distinguished_name = dn
[dn]
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY" -config "$TMP/ext.cnf" -extensions v3

# Legacy-compatible PBE/MAC algorithms — macOS `security import` cannot parse
# the modern OpenSSL 3 PKCS12 defaults.
openssl pkcs12 -export -out "$TMP/dev.p12" -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" -password pass:temp -name "$IDENTITY" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$TMP/dev.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign
security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1

# Append to the user keychain search list so codesign can find the identity.
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')
# shellcheck disable=SC2086
security list-keychains -d user -s $EXISTING "$KEYCHAIN"

echo "Created signing identity '$IDENTITY' in $KEYCHAIN"
