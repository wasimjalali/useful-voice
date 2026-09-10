#!/usr/bin/env bash
#
# Verify the app's actual Deepgram request against the live endpoint.
#
# Why this exists: a stubbed HTTP test cannot tell you whether the service accepts
# what you send. The unit tests assert the request *shape*, and they all passed while
# every auto-detect dictation was failing with `400 Bad Request: Failed to parse
# query string`, because one value in the detection list (`nl-BE`) is documented by
# Deepgram but rejected by the API. Only a real request could have caught that.
#
# Usage:
#   DEEPGRAM_API_KEY=... ./Scripts/check-deepgram-request.sh
#   ./Scripts/check-deepgram-request.sh            # reads the key from the Keychain
#
# Exits non-zero on the first rejection, so it can gate a release.
set -uo pipefail

KEY="${DEEPGRAM_API_KEY:-}"
if [ -z "$KEY" ]; then
  KEY=$(security find-generic-password -s ai.karko.sadaa -a deepgram-key -w 2>/dev/null || true)
fi
if [ -z "$KEY" ]; then
  echo "No API key. Set DEEPGRAM_API_KEY or store one in the Keychain." >&2
  exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A minimal valid 16 kHz mono WAV. Nothing is transcribed; the point is whether the
# query string parses, and a 44-byte file makes each probe fast.
python3 - "$WORK/tiny.wav" <<'PY'
import struct, sys
open(sys.argv[1], 'wb').write(
    b'RIFF' + struct.pack('<I', 36) + b'WAVEfmt '
    + struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16)
    + b'data' + struct.pack('<I', 0))
PY

# The codes the app sends for auto-detection, read from the source of truth rather
# than duplicated here, so this script cannot drift from the app.
CODES=$(grep -A 6 'detectionCodes: \[String\] = \[' Sources/UsefulVoiceCore/Transcription/DeepgramLanguage.swift \
  | grep -o '"[a-zA-Z-]*"' | tr -d '"' | tr '\n' ' ')
if [ -z "$CODES" ]; then
  echo "Could not read detectionCodes from DeepgramLanguage.swift" >&2
  exit 2
fi

failures=0
probe() {
  local label="$1" url="$2"
  local code
  code=$(curl -s -o "$WORK/body" -w '%{http_code}' -X POST "$url" \
    -H "Authorization: Token $KEY" -H 'Content-Type: audio/wav' \
    --data-binary "@$WORK/tiny.wav")
  if [ "$code" = "200" ]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s -> HTTP %s  %s\n' "$label" "$code" "$(head -c 140 "$WORK/body")"
    failures=$((failures + 1))
  fi
}

echo "== auto-detection request (the whole set in one request, as the app sends it)"
URL="https://api.deepgram.com/v1/listen?model=nova-3"
for c in $CODES; do URL="$URL&detect_language=$c"; done
URL="$URL&smart_format=true&numerals=true&tag=useful-voice"
echo "   $(echo "$CODES" | wc -w | tr -d ' ') detection codes, URL ${#URL} characters"
probe "auto (full set)" "$URL"

echo "== every detection code on its own"
for c in $CODES; do
  probe "detect_language=$c" "https://api.deepgram.com/v1/listen?model=nova-3&detect_language=$c"
done

echo "== every code as an explicit pin, plus the modes"
for c in $CODES multi; do
  probe "language=$c" "https://api.deepgram.com/v1/listen?model=nova-3&language=$c"
done

# Regional forms are pinned only: the endpoint refuses at least one of them as a
# detection value, which is exactly why they are kept out of the detection list.
echo "== regional pins (accepted as language=, not as detect_language=)"
for c in nl-BE de-CH zh-HK zh-TW; do
  probe "language=$c" "https://api.deepgram.com/v1/listen?model=nova-3&language=$c"
done

echo
if [ "$failures" -eq 0 ]; then
  echo "PASS — every request the app can make was accepted."
else
  echo "FAIL — $failures request(s) rejected."
fi
exit $((failures > 0))
