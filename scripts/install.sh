#!/bin/sh
# Installs Useful Voice on a Mac:
#   curl -fsSL https://github.com/wasimjalali/useful-voice-releases/releases/latest/download/install.sh | sh
#
# Ported from Useful Bot (scripts/install.sh). The app has no Apple Developer ID:
# it is signed with the self-signed "Useful Voice Release" certificate (UV-004),
# so this clears its quarantine flag to skip the "unidentified developer" stop.
# What it trusts instead: the release this copy was published with.
# scripts/release-mac.mjs writes that release's zip URL and SHA-256 below, and a
# download that does not match is refused. Updates then arrive in the app,
# checked against its EdDSA key.
set -eu

# Everything runs from main on the last line, so `curl | sh` cut off mid-script
# runs nothing rather than half of it.
main() {
URL="@@ZIP_URL@@"
SHA256="@@ZIP_SHA256@@"
DEST="${UV_INSTALL_DIR:-/Applications}"
APP="$DEST/Useful Voice.app"

say() { printf '%s\n' "$*"; }
die() { printf 'Useful Voice install failed: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS. On Windows, download the installer from the releases page."
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] || die "Useful Voice needs a Mac with Apple silicon (M1 or later)."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "Useful Voice needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."
# A folder of the user's own that is not there yet (~/Applications) is made.
case "$DEST" in "$HOME"/*) [ -d "$DEST" ] || mkdir -p "$DEST" 2>/dev/null || true ;; esac
[ -d "$DEST" ] && [ -w "$DEST" ] || die "$DEST is not a writable folder. Run with UV_INSTALL_DIR=\"\$HOME/Applications\" to install for this user only (it is created if it is missing)."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Downloading Useful Voice…"
case "$URL$SHA256" in *@@*) die "this is the unreleased template; install from a release's install.sh." ;; esac
# HTTPS only; plain HTTP just for a local test server.
case "$URL" in http://127.0.0.1:*) proto='=http' ;; *) proto='=https' ;; esac
curl -fL --proto "$proto" --progress-bar -o "$tmp/Useful-Voice-macOS.zip" "$URL" || die "the download did not complete."
got="$(shasum -a 256 "$tmp/Useful-Voice-macOS.zip" | cut -d' ' -f1)"
[ "$got" = "$SHA256" ] || die "the download does not match this release (sha256 $got, expected $SHA256)."
ditto -x -k "$tmp/Useful-Voice-macOS.zip" "$tmp/unpacked" || die "the download is not a valid zip."
[ -d "$tmp/unpacked/Useful Voice.app" ] || die "the download does not contain Useful Voice.app."
codesign --verify --strict "$tmp/unpacked/Useful Voice.app" || die "the app's code signature does not verify."

# Quit every running copy first: two copies would fight over the hotkey.
if pgrep -x UsefulVoice >/dev/null 2>&1; then
  say "Quitting the running Useful Voice…"
  osascript -e 'tell application id "ai.useful.voice" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -x UsefulVoice >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
  pgrep -x UsefulVoice >/dev/null 2>&1 && die "Useful Voice is still running. Quit it from the menu bar and run this again."
fi

# Staged beside the old copy and checked there, so a copy cut short (a full
# disk) leaves the installed app as it was.
NEW="$DEST/.Useful Voice.app.installing"
rm -rf "$NEW"
ditto "$tmp/unpacked/Useful Voice.app" "$NEW" || { rm -rf "$NEW"; die "could not copy the app into $DEST."; }
xattr -cr "$NEW" || { rm -rf "$NEW"; die "could not clear the download's quarantine flag."; }
codesign --verify --strict "$NEW" || { rm -rf "$NEW"; die "the copied app does not verify."; }
# The old copy steps aside until the new one is in place, and comes back if
# the move fails.
OLD="$DEST/.Useful Voice.app.previous"
rm -rf "$OLD"
if [ -e "$APP" ]; then mv "$APP" "$OLD" || { rm -rf "$NEW"; die "could not move the old app aside."; }; fi
if ! mv "$NEW" "$APP"; then
  rm -rf "$NEW"
  if [ -e "$OLD" ] && ! mv "$OLD" "$APP"; then die "could not move the new app into place, nor the old one back: it is at $OLD."; fi
  die "could not move the new app into place; the old one is back."
fi
rm -rf "$OLD"

say "Installed $APP"
[ -n "${UV_INSTALL_NO_OPEN:-}" ] || open "$APP"
}

main "$@"
