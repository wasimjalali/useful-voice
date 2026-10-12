#!/bin/bash
# Stop every running copy of Useful Voice, wherever it was launched from.
#
# Why not `pkill -x UsefulVoice`: two copies can be live at once (dist/ and
# /Applications) with the same bundle id and signature, so both are
# Accessibility-trusted and both install a session-wide event tap. Leaving one
# running while installing the other is exactly how a single hotkey press ends
# up toggling dictation twice.
set -uo pipefail

# The app was renamed from Sadaa (ai.karko.sadaa) to Useful Voice. A copy of
# either identity may still be running, so both are stopped.
EXECUTABLES=(UsefulVoice Sadaa)
BUNDLE_IDS=(ai.useful.voice ai.karko.sadaa)

# 1. Anything actually running an executable.
for executable in "${EXECUTABLES[@]}"; do
  pkill -x "$executable" 2>/dev/null && echo "stopped running $executable"
done

# 2. Ask LaunchServices too, in case the process name differs (a signed copy
#    re-exec'd by the system, or a renamed build).
if command -v osascript >/dev/null 2>&1; then
  for bundle_id in "${BUNDLE_IDS[@]}"; do
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  done
fi

# 3. Wait briefly for a clean exit instead of killing outright, so an in-flight
#    recording is finalized and the clipboard restore can run.
for _ in $(seq 1 20); do
  running=0
  for executable in "${EXECUTABLES[@]}"; do
    pgrep -x "$executable" >/dev/null 2>&1 && running=1
  done
  [ "$running" -eq 0 ] && exit 0
  sleep 0.1
done

echo "forcing exit (did not quit within 2s)"
for executable in "${EXECUTABLES[@]}"; do
  pkill -9 -x "$executable" 2>/dev/null || true
done
exit 0
