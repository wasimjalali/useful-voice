#!/bin/bash
# Stop every running copy of Useful Voice, wherever it was launched from.
#
# Why not `pkill -x Sadaa`: two copies can be live at once (dist/ and
# /Applications) with the same bundle id and signature, so both are
# Accessibility-trusted and both install a session-wide event tap. Leaving one
# running while installing the other is exactly how a single hotkey press ends
# up toggling dictation twice.
set -uo pipefail

EXECUTABLE=Sadaa
BUNDLE_ID=ai.karko.sadaa

# 1. Anything actually running the executable.
pkill -x "$EXECUTABLE" 2>/dev/null && echo "stopped running $EXECUTABLE"

# 2. Ask LaunchServices too, in case the process name differs (a signed copy
#    re-exec'd by the system, or a renamed build).
if command -v osascript >/dev/null 2>&1; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
fi

# 3. Wait briefly for a clean exit instead of killing outright, so an in-flight
#    recording is finalized and the clipboard restore can run.
for _ in $(seq 1 20); do
  pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || exit 0
  sleep 0.1
done

echo "forcing exit (did not quit within 2s)"
pkill -9 -x "$EXECUTABLE" 2>/dev/null || true
exit 0
