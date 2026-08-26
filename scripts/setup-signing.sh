#!/bin/bash
# One-time setup: create a stable self-signed code-signing identity so Useful Voice
# keeps its Accessibility (hotkey) and Microphone grants across reinstalls.
#
# Why: `make install` re-signs the app. With ad-hoc signing (codesign --sign -)
# every build has a different code hash, so macOS treats each build as a NEW app
# and silently drops the Accessibility grant. A stable identity fixes that: the
# signature's designated requirement stays constant across rebuilds.
#
# Run once:  ./scripts/setup-signing.sh
# The first `make install` afterwards shows a one-time "codesign wants to sign
# using key in your keychain" prompt - click "Always Allow".

set -euo pipefail

IDENTITY="Sadaa Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already exists. Nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing certificate '$IDENTITY'..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Use the system LibreSSL, not a Homebrew OpenSSL 3.x. OpenSSL 3 writes a PKCS12
# MAC that macOS `security import` cannot verify ("MAC verification failed").
OPENSSL=/usr/bin/openssl

cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Sadaa Local Signing
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

"$OPENSSL" pkcs12 -export -out "$TMP/cert.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:sadaa 2>/dev/null

# Import into the login keychain and allow codesign to use the key.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P sadaa \
    -T /usr/bin/codesign -T /usr/bin/security

echo ""
echo "Done. '$IDENTITY' is installed."
echo "Next: run 'make install'. On the first sign you'll get one macOS prompt"
echo "to use the key - click 'Always Allow'. After that, grant Useful Voice"
echo "Accessibility once and the hotkey will keep working across future updates."
