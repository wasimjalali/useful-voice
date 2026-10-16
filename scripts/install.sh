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
LOCK="$DEST/.Useful Voice.install.lock"
have_lock=0   # this run made $LOCK
STAGE=""      # this run's private folder in $DEST (on the same volume, so the final mv is a rename)
OLD=""        # where the installed app steps aside during the swap
aside=0       # 1 while the old app is at $OLD and the new one is not yet at $APP
keep_stage=0  # 1 when $STAGE holds the only copy of the old app
cleanup() {
  # A swap cut short (Ctrl-C, closed terminal, failed move) puts the old app back.
  if [ "$aside" = 1 ] && [ ! -e "$APP" ] && [ -e "$OLD" ]; then
    mv "$OLD" "$APP" 2>/dev/null || { keep_stage=1; printf 'The previous Useful Voice is at %s\n' "$OLD" >&2; }
  fi
  if [ "$keep_stage" != 1 ] && [ -n "$STAGE" ]; then rm -rf "$STAGE" || true; fi
  rm -rf "$tmp" || true
  if [ "$have_lock" = 1 ]; then rmdir "$LOCK" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# One install at a time in a folder: two at once would share the staged and
# swapped copies. mkdir is atomic, so the second run finds the lock and stops.
mkdir "$LOCK" 2>/dev/null || die "another install is running in $DEST. If none is, delete \"$LOCK\" and run this again."
have_lock=1
# Leftovers of a run that was killed outright (the lock is ours, so nothing else
# is using them): an old copy that never came back is put back first.
for stale in "$DEST"/.Useful\ Voice.installing.*; do
  [ -d "$stale" ] || continue
  if [ -d "$stale/previous" ] && [ ! -e "$APP" ]; then mv "$stale/previous" "$APP" 2>/dev/null || continue; fi
  rm -rf "$stale"
done
rm -rf "$DEST/.Useful Voice.app.installing" "$DEST/.Useful Voice.app.previous"

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
running() { pgrep -x UsefulVoice >/dev/null 2>&1; }
wait_quit() { i=0; while running && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done; }
if running; then
  say "Quitting the running Useful Voice…"
  osascript -e 'tell application id "ai.useful.voice" to quit' >/dev/null 2>&1 || true
  wait_quit
  if running; then
    # The Automation prompt behind osascript can be denied. Then ask the installed
    # copy to stop directly: TERM, and only the process whose executable is the
    # one under $APP (the path escaped, since pgrep -f takes a regular expression).
    pattern="^$(printf '%s' "$APP/Contents/MacOS/UsefulVoice" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
    pkill -TERM -f "$pattern" >/dev/null 2>&1 || true
    wait_quit
  fi
  running && die "Useful Voice is still running. Quit it from the menu bar and run this again."
fi

# Staged beside the old copy, in a folder of this run's own, and checked there,
# so a copy cut short (a full disk) leaves the installed app as it was.
STAGE="$(mktemp -d "$DEST/.Useful Voice.installing.XXXXXX")" || die "could not make a working folder in $DEST."
NEW="$STAGE/Useful Voice.app"
ditto "$tmp/unpacked/Useful Voice.app" "$NEW" || die "could not copy the app into $DEST."
xattr -cr "$NEW" || die "could not clear the download's quarantine flag."
codesign --verify --strict "$NEW" || die "the copied app does not verify."
# The old copy steps aside until the new one is in place, and comes back if
# the move fails or this run is interrupted (cleanup above).
OLD="$STAGE/previous"
if [ -e "$APP" ]; then mv "$APP" "$OLD" || die "could not move the old app aside."; aside=1; fi
if ! mv "$NEW" "$APP"; then
  if [ -e "$OLD" ] && ! mv "$OLD" "$APP"; then keep_stage=1; die "could not move the new app into place, nor the old one back: it is at $OLD."; fi
  aside=0
  die "could not move the new app into place; the old one is back."
fi
aside=0

say "Installed $APP"
[ -n "${UV_INSTALL_NO_OPEN:-}" ] || open "$APP"
}

main "$@"
