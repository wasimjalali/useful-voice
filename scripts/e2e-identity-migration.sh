#!/bin/bash
# End-to-end check of the one-time identity migration, run by the REAL built app
# binary against a COPY of a data folder.
#
# Usage: scripts/e2e-identity-migration.sh <app bundle> <source data folder> <out dir>
#
#   <app bundle>          e.g. dist/UsefulVoice.app (from `make bundle`)
#   <source data folder>  a folder shaped like ~/Library/Application Support/Sadaa
#                         (a fixture, or a copy of real data). It is only COPIED:
#                         the source is never moved, changed or deleted. There is no
#                         default, so the script cannot touch real data by accident.
#   <out dir>             where result.txt is written (no file names or contents)
#
# Optional: E2E_LEGACY_DEFAULTS_DOMAIN=<domain> copies that preferences domain into
# the throwaway legacy domain (default: a small fixture).
#
# Isolation: the app runs with UV_MIGRATE_ONLY=1 in a scratch home (HOME and
# CFFIXED_USER_HOME), so files move inside the scratch home only. Preferences and
# Keychain are the real ones, but under a unique test prefix, with a DUMMY key
# that the app creates itself (no prompt). The Security framework finds the login keychain under HOME,
# so the scratch Library/Keychains links to the real one; only prefixed items are
# used. Everything prefixed is removed on exit.
#
# Exit status: 0 when every check passes, 1 otherwise.
set -uo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <app bundle> <source data folder> <out dir>" >&2
  exit 64
fi
APP="$1"; SRC="$2"; OUT="$3"
BIN="$APP/Contents/MacOS/UsefulVoice"
[ -x "$BIN" ] || { echo "error: no executable at $BIN" >&2; exit 64; }
[ -d "$SRC" ] || { echo "error: source data folder not found: $SRC" >&2; exit 64; }
mkdir -p "$OUT"

P="uve2e$$."
H="$(mktemp -d)"
LEGACY_SERVICE="${P}ai.karko.sadaa"
NEW_SERVICE="${P}ai.useful.voice"

cleanup() {
  rm -rf "$H"
  security delete-generic-password -s "$NEW_SERVICE" -a deepgram-key >/dev/null 2>&1 || true
  security delete-generic-password -s "$LEGACY_SERVICE" -a deepgram-key >/dev/null 2>&1 || true
  defaults delete "${P}ai.karko.sadaa" >/dev/null 2>&1 || true
  defaults delete "${P}ai.useful.voice" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/${P}"*.plist
}
trap cleanup EXIT

AS="$H/Library/Application Support"
mkdir -p "$AS/UsefulVoice/models"
ln -s "$HOME/Library/Keychains" "$H/Library/Keychains"
cp -Rp "$SRC" "$AS/Sadaa"                                   # the copy; the source stays put
echo "placeholder" > "$AS/UsefulVoice/models/placeholder.bin" # models/ already there, like a real install
before_hashes() { (cd "$1" && find . -type f -not -name diagnostics.log -not -path './models/*' -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null); }
BEFORE="$(before_hashes "$AS/Sadaa")"
SRC_BEFORE="$(before_hashes "$SRC")"

# Preferences: a copy of a real domain if asked, else a fixture.
if [ -n "${E2E_LEGACY_DEFAULTS_DOMAIN:-}" ]; then
  defaults export "$E2E_LEGACY_DEFAULTS_DOMAIN" - | defaults import "${P}ai.karko.sadaa" -
else
  defaults write "${P}ai.karko.sadaa" uv.firstRunCompleted -bool true
  defaults write "${P}ai.karko.sadaa" languagePin -string de
  defaults write "${P}ai.karko.sadaa" appearance -string dark
fi
LEGACY_KEYS=$(defaults export "${P}ai.karko.sadaa" - | plutil -convert json -o - - \
  | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')

# Keychain: a DUMMY key under the prefixed legacy service (never a real key). The app
# itself creates it (UV_MIGRATION_TEST_SEED_KEY, run 1 only): an item made by the
# `security` tool is guarded by a partition list and would raise a prompt.
DUMMY="e2e-dummy-$(openssl rand -hex 8)"

run() {
  HOME="$H" CFFIXED_USER_HOME="$H" UV_MIGRATE_ONLY=1 UV_MIGRATION_TEST_PREFIX="$P" "$BIN"
}

FAILS=0
check() { # name, condition result (yes/no)
  if [ "$2" = yes ]; then echo "PASS  $1"; else echo "FAIL  $1"; FAILS=$((FAILS + 1)); fi
}

{
# 0. The guard: without a scratch CFFIXED_USER_HOME the hook refuses and moves nothing.
HOME="$H" UV_MIGRATE_ONLY=1 UV_MIGRATION_TEST_PREFIX="$P" "$BIN" >/dev/null 2>&1
REFUSED=$?
check "refuses without CFFIXED_USER_HOME (exit 2)" "$([ "$REFUSED" -eq 2 ] && echo yes || echo no)"
check "refusal moved nothing" "$([ -d "$AS/Sadaa" ] && echo yes || echo no)"

# 1. First run moves everything, second run changes nothing.
R1="$(UV_MIGRATION_TEST_SEED_KEY="$DUMMY" run)"; S1=$?
R2="$(UV_MIGRATION_TEST_EXPECT_KEY="$DUMMY" run)"; S2=$?
echo "run 1: $R1"
echo "run 2: $R2"
check "run 1 exits 0" "$([ $S1 -eq 0 ] && echo yes || echo no)"
check "run 2 exits 0" "$([ $S2 -eq 0 ] && echo yes || echo no)"
check "run 1 keychain migrated" "$(echo "$R1" | grep -q '"keychain":"migrated"' && echo yes || echo no)"
check "run 1 reports no failures" "$(echo "$R1" | grep -q '"failed":\[\]' && echo yes || echo no)"
check "run 2 is a no-op" "$(echo "$R2" | grep -q '"moved":\[\]' && echo "$R2" | grep -q '"defaultsAlreadyMigrated":true' && echo yes || echo no)"

# 2. Files.
check "old folder removed" "$([ -e "$AS/Sadaa" ] && echo no || echo yes)"
AFTER="$(before_hashes "$AS/UsefulVoice")"
check "every file arrived with identical content" "$([ "$BEFORE" = "$AFTER" ] && echo yes || echo no)"
check "models/ kept" "$([ -f "$AS/UsefulVoice/models/placeholder.bin" ] && echo yes || echo no)"
check "new folder is owner-only (700)" "$([ "$(stat -f %Lp "$AS/UsefulVoice")" = 700 ] && echo yes || echo no)"
LOOSE=$(find "$AS/UsefulVoice" -not -path '*/models*' -not -name diagnostics.log \( -type f -perm +077 -o -type d -perm +077 \) | wc -l | tr -d ' ')
LOOSE_LIST=$(find "$AS/UsefulVoice" -not -path '*/models*' -not -name diagnostics.log \( -type f -perm +077 -o -type d -perm +077 \) | sed "s|$AS/||" | head -5)
[ "$LOOSE" = 0 ] || echo "      loose: $LOOSE_LIST"
check "moved entries are owner-only" "$([ "$LOOSE" = 0 ] && echo yes || echo no)"
check "source folder untouched" "$([ "$SRC_BEFORE" = "$(before_hashes "$SRC")" ] && echo yes || echo no)"

# 3. Preferences.
NEW_JSON="$(defaults export "${P}ai.useful.voice" - | plutil -convert json -o - -)"
NEW_COUNT=$(echo "$NEW_JSON" | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')
check "migrated flag set" "$(echo "$NEW_JSON" | grep -q '"uv.identityMigrated":true' && echo yes || echo no)"
check "every legacy key copied (legacy $LEGACY_KEYS, new $NEW_COUNT incl. flags)" "$([ "$NEW_COUNT" -ge "$LEGACY_KEYS" ] && echo yes || echo no)"
check "legacy domain untouched" "$([ "$(defaults export "${P}ai.karko.sadaa" - | plutil -convert json -o - - | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')" = "$LEGACY_KEYS" ] && echo yes || echo no)"

# 4. Keychain.
# The new item is guarded for the app only, so the app answers (as a boolean) whether it holds the dummy.
check "new Keychain item holds the dummy key" "$(echo "$R2" | grep -q '"newKeyMatches":true' && echo yes || echo no)"
check "new Keychain item exists (attributes only)" "$(security find-generic-password -s "$NEW_SERVICE" -a deepgram-key >/dev/null 2>&1 && echo yes || echo no)"
check "old Keychain item removed" "$(security find-generic-password -s "$LEGACY_SERVICE" -a deepgram-key >/dev/null 2>&1 && echo no || echo yes)"

echo
if [ "$FAILS" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: $FAILS check(s) FAILED"; fi
} 2>&1 | tee "$OUT/result.txt"

# `tee` hides the subshell status; read it back from the file.
grep -q '^RESULT: all checks passed' "$OUT/result.txt"
