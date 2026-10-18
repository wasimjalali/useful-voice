#!/bin/bash
# Live E2E for "Pause media while dictating". Plays only silence, and refuses to run while any
# other app is outputting audio (the commands go to the Now Playing app, which could be the
# person's real music or video).
#
#   scripts/media-pause-e2e/run.sh [scenario|all]
#
# Writes the harness log and each scenario's player log to $OUT
# (default: <main checkout>/verify/pause-media). Exit codes: 0 pass, 1 a check failed,
# 3 skipped because something else was playing.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
MAIN_CHECKOUT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
OUT="${OUT:-$MAIN_CHECKOUT/verify/pause-media}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

MEDIA="$ROOT/Sources/UsefulVoiceCore/Media"
echo "building the test player and the harness..."
swiftc -O "$ROOT/scripts/media-pause-e2e/player.swift" -o "$WORK/player"
swiftc -O -parse-as-library \
  "$ROOT/scripts/media-pause-e2e/harness.swift" \
  "$MEDIA/MediaPausePolicy.swift" "$MEDIA/SystemMediaEffects.swift" \
  "$ROOT/Sources/UsefulVoiceCore/Diagnostics/Diagnostics.swift" \
  -o "$WORK/harness"

"$WORK/harness" "$WORK/player" "$OUT" "${1:-all}"
