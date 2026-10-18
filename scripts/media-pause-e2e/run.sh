#!/bin/bash
# Live E2E for "Pause media while dictating". Plays only silence, and refuses to run while any
# other app is outputting audio (the commands go to the Now Playing app, which could be the
# person's real music or video).
#
#   scripts/media-pause-e2e/run.sh [scenario|all]
#   UV_E2E_AUDIO_ONLY=1 OUT=... scripts/media-pause-e2e/run.sh   # the audio-list fallback alone
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
echo "building the test player, the Now Playing helper and the harness..."
swiftc -O "$ROOT/scripts/media-pause-e2e/player.swift" -o "$WORK/player"
# The helper exactly as `make bundle` builds it (this machine's slices are enough here).
mkdir -p "$WORK/MediaRemote"
clang -dynamiclib -arch arm64 -arch arm64e -arch x86_64 -mmacosx-version-min=14.0 \
  -framework CoreFoundation -Wall -Werror \
  -o "$WORK/MediaRemote/libuvnowplaying.dylib" "$ROOT/bundle/mediaremote/uv_nowplaying.c"
cp "$ROOT/bundle/mediaremote/uv-nowplaying.pl" "$WORK/MediaRemote/"
swiftc -O -parse-as-library \
  "$ROOT/scripts/media-pause-e2e/harness.swift" \
  "$MEDIA/MediaPausePolicy.swift" "$MEDIA/SystemMediaEffects.swift" "$MEDIA/NowPlayingReader.swift" \
  "$ROOT/Sources/UsefulVoiceCore/Diagnostics/Diagnostics.swift" \
  -o "$WORK/harness"

"$WORK/harness" "$WORK/player" "$OUT" "${1:-all}" "$WORK/MediaRemote"
