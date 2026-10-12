#!/bin/bash
# Remove Useful Voice from this Mac, leaving the user's data alone.
#
# Order matters: the launch-at-login registration is owned by the app bundle, so
# it must be turned off BEFORE the bundle is deleted. Delete first and the login
# item survives pointing at a path that no longer exists, which shows up as a
# silent failure at every login and cannot be cleared from inside the app.
set -uo pipefail

# The app was renamed from Sadaa (ai.karko.sadaa) to Useful Voice. Uninstalling
# covers both identities, since a Mac may still hold the old one.
SUPPORT_DIRS=("$HOME/Library/Application Support/UsefulVoice" "$HOME/Library/Application Support/Sadaa")
KEYCHAIN_SERVICES=(ai.useful.voice ai.karko.sadaa)
DEFAULTS_DOMAINS=(ai.useful.voice ai.karko.sadaa)
KEEP_DATA=0

for arg in "$@"; do
  case "$arg" in
    --purge) KEEP_DATA=1 ;;
    -h|--help)
      cat <<'EOF'
usage: uninstall.sh [--purge]

  (default)  Remove the app and its login item. Dictionary, history, notes and
             recordings are left in ~/Library/Application Support/UsefulVoice
             (and ~/Library/Application Support/Sadaa from before the rename).
  --purge    Also delete those folders, the stored Deepgram API key and the
             preferences, under both the current and the old app identity.
EOF
      exit 0 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 1. Turn off launch-at-login while the app still exists to do it. The app
#    exposes this through its own preference, so run the bundled build with a
#    flag; if that is unavailable, tell the user how to do it by hand.
echo "==> disabling launch at login"
if [ -x "$ROOT/.build/release/UsefulVoiceApp" ]; then
  "$ROOT/.build/release/UsefulVoiceApp" --disable-login-item >/dev/null 2>&1 \
    || echo "    (could not disable automatically)"
else
  echo "    app binary not built here; disable 'Useful Voice' by hand in"
  echo "    System Settings > General > Login Items if it is listed."
fi

# 2. Quit every running copy.
"$ROOT/scripts/stop-instances.sh"

# 3. Remove known install locations. Both are listed because a stale copy left
#    behind keeps the same bundle id and would still answer the hotkey.
echo "==> removing app bundles"
for target in "/Applications/Useful Voice.app" "$ROOT/dist/UsefulVoice.app" \
              "/Applications/Sadaa.app" "$HOME/Applications/Useful Voice.app"; do
  if [ -e "$target" ]; then
    rm -rf "$target" && echo "    removed $target"
  fi
done

# 4. Unregister the bundle id from LaunchServices so the login item and any
#    stale document associations go with it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$ROOT/dist/UsefulVoice.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "/Applications/Useful Voice.app" >/dev/null 2>&1 || true
fi

if [ "$KEEP_DATA" -eq 1 ]; then
  echo "==> purging user data"
  for dir in "${SUPPORT_DIRS[@]}"; do
    if [ -e "$dir" ]; then
      rm -rf "$dir" && echo "    removed $dir"
    fi
  done
  for service in "${KEYCHAIN_SERVICES[@]}"; do
    security delete-generic-password -s "$service" -a "deepgram-key" >/dev/null 2>&1 \
      || true
  done
  for domain in "${DEFAULTS_DOMAINS[@]}"; do
    defaults delete "$domain" >/dev/null 2>&1 || true
  done
  echo "    removed stored API key and preferences"
  echo
  echo "Done. Accessibility/Microphone grants for the app may still be listed in"
  echo "System Settings > Privacy & Security; remove them there if you like."
else
  echo
  echo "Done. Your dictionary, history, notes and recordings are still in:"
  for dir in "${SUPPORT_DIRS[@]}"; do
    if [ -e "$dir" ]; then echo "  $dir"; fi
  done
  echo "Re-run with --purge to delete them, or remove the app's entries from"
  echo "System Settings > Privacy & Security > Accessibility / Microphone."
fi
