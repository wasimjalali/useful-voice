#!/bin/bash
# Check that the stable "Useful Voice Release" code-signing identity is installed.
#
# Why this exists: `make bundle` re-signs the app. With ad-hoc signing
# (codesign --sign -) every build has a different code hash, so macOS treats each
# build as a NEW app and silently drops the Accessibility and Microphone grants.
# A stable identity keeps the signature's designated requirement constant.
#
# This script NEVER creates a certificate. A freshly generated certificate is a
# different identity, so every user's Accessibility and Microphone grants would
# be dropped again. The one identity lives in the password manager as a .p12;
# import that file instead.
#
# Usage:  ./scripts/setup-signing.sh
# Exit 0 when the identity is installed, 1 when it is missing.

set -euo pipefail

IDENTITY="Useful Voice Release"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "Signing identity '$IDENTITY' is installed. Nothing to do."
    exit 0
fi

cat >&2 <<MSG
Signing identity '$IDENTITY' is not in the login keychain.

Do not generate a new certificate: a new identity drops every user's
Accessibility and Microphone grants. Import the existing one instead:

  1. Get the '$IDENTITY' .p12 from the password manager and save it somewhere
     temporary (delete it after the import).
  2. Import it into the login keychain and let codesign use the key:

       security import <file.p12> -k "$KEYCHAIN" \\
           -T /usr/bin/codesign -T /usr/bin/security

  3. Re-run ./scripts/setup-signing.sh to confirm.

The first 'make bundle' afterwards shows a one-time "codesign wants to sign
using key" prompt: click 'Always Allow'.
MSG
exit 1
