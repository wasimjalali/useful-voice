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
#                         It must contain only regular files and folders: any symbolic
#                         link (or other special file) anywhere in it is refused, since
#                         a copied link could lead the app into real data.
#   <out dir>             where result.txt is written. The report holds counts and
#                         statuses only: no file names, paths or contents.
#
# Optional: E2E_LEGACY_DEFAULTS_DOMAIN=<domain> copies that preferences domain into
# the throwaway legacy domain (default: a small fixture).
#
# Isolation: the app runs with UV_MIGRATE_ONLY=1 in a scratch home (HOME and
# CFFIXED_USER_HOME), so files move inside the scratch home only. Preferences and
# Keychain are the real ones, but under a unique test prefix, with a DUMMY key that
# the app creates itself (no prompt). The Security framework finds the login keychain
# under HOME, so the scratch Library/Keychains links to the real one; only prefixed
# items are used. Everything prefixed is removed on exit, interrupt or failure, and a
# leftover makes the result non-zero.
#
# Exit status: 0 when every check passes and cleanup is complete, 1 when a check or
# the cleanup fails, 64 for bad usage or a refused setup.
set -uo pipefail

die() { echo "error: $*" >&2; exit 64; }
canon() { python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }

[ "$#" -eq 3 ] || die "usage: $0 <app bundle> <source data folder> <out dir>"
[ -L "$2" ] && die "the source data folder is a symbolic link"
[ -d "$2" ] || die "source data folder not found"
APP="$(canon "$1")" || die "cannot resolve the app bundle"
SRC="$(canon "$2")" || die "cannot resolve the source folder"
BIN="$APP/Contents/MacOS/UsefulVoice"
[ -x "$BIN" ] || die "no executable in the app bundle"
OUT="$(canon "$3")" || die "cannot resolve the out dir"
case "$OUT/" in "$SRC/"*) die "the out dir is the source folder or inside it" ;; esac
mkdir -p "$OUT" || die "cannot create the out dir"
RESULT="$OUT/result.txt"
[ -L "$RESULT" ] && die "result.txt is a symbolic link"

# Nothing in the source may be a link or a special file.
[ -z "$(find "$SRC" ! -type f ! -type d -print -quit)" ] \
  || die "the source folder contains a symbolic link or special file (refused)"
[ -n "$(find "$SRC" -type f -print -quit)" ] || die "the source folder has no files"

TMPROOT="$(canon "${TMPDIR:-/tmp}")" || die "cannot resolve the temp dir"
H="$(mktemp -d "$TMPROOT/uve2e.XXXXXX")" || die "mktemp failed"
H="$(canon "$H")" || die "cannot resolve the scratch home"
case "$H" in "$TMPROOT"/uve2e.*) ;; *) die "scratch home is not under the temp dir" ;; esac

P="uve2e$$."
LEGACY_DOMAIN="${P}ai.karko.sadaa"
NEW_DOMAIN="${P}ai.useful.voice"
LEGACY_SERVICE="${P}ai.karko.sadaa"
NEW_SERVICE="${P}ai.useful.voice"
AS="$H/Library/Application Support"
PLISTS="$HOME/Library/Preferences"

CHILD=""
CLEANED=0
CLEAN_FAILS=0

stop_child() {
  if [ -n "$CHILD" ]; then
    kill "$CHILD" 2>/dev/null
    wait "$CHILD" 2>/dev/null
    CHILD=""
  fi
}

# Idempotent, and checks that each removal took.
cleanup() {
  [ "$CLEANED" -eq 1 ] && return
  stop_child
  for service in "$NEW_SERVICE" "$LEGACY_SERVICE"; do
    security delete-generic-password -s "$service" -a deepgram-key >/dev/null 2>&1
    if security find-generic-password -s "$service" -a deepgram-key >/dev/null 2>&1; then
      CLEAN_FAILS=$((CLEAN_FAILS + 1))
    fi
  done
  for domain in "$LEGACY_DOMAIN" "$NEW_DOMAIN"; do
    defaults delete "$domain" >/dev/null 2>&1
  done
  rm -f "$PLISTS/${P}"*.plist
  if ls "$PLISTS" 2>/dev/null | grep -q "^${P}"; then CLEAN_FAILS=$((CLEAN_FAILS + 1)); fi
  for domain in "$LEGACY_DOMAIN" "$NEW_DOMAIN"; do
    if defaults read "$domain" >/dev/null 2>&1; then CLEAN_FAILS=$((CLEAN_FAILS + 1)); fi
  done
  rm -rf "$H"
  [ -e "$H" ] && CLEAN_FAILS=$((CLEAN_FAILS + 1))
  # Set only when finished: a signal that lands mid-cleanup runs it again from the top
  # (every step is idempotent) instead of leaving it half done.
  CLEANED=1
}
on_signal() { cleanup; echo "interrupted" >&2; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP

step() { "$@" || { echo "error: setup step failed: $1" >&2; cleanup; exit 64; }; }

mkdir_ok() { mkdir -p "$AS/UsefulVoice/models"; }
step mkdir_ok
step ln -s "$HOME/Library/Keychains" "$H/Library/Keychains"
step cp -Rp "$SRC" "$AS/Sadaa"                             # the copy; the source stays put
echo "placeholder" > "$AS/UsefulVoice/models/placeholder.bin" || { cleanup; exit 64; }   # models/ already there

# A manifest is content hashes of every regular file except the log the migration appends to.
manifest() {
  (cd "$1" && find . -type f -not -name diagnostics.log -not -path './models/*' -print0 \
    | sort -z | xargs -0 shasum -a 256)
}
# The tree's shape and metadata, for "the source was not touched".
shape() { (cd "$1" && find . -print0 | sort -z | xargs -0 stat -f '%N %p %z %m'); }

manifest "$SRC" >"$H/src.manifest" || { echo "error: hashing the source failed" >&2; cleanup; exit 64; }
manifest "$AS/Sadaa" >"$H/copy.manifest" || { echo "error: hashing the copy failed" >&2; cleanup; exit 64; }
cmp -s "$H/src.manifest" "$H/copy.manifest" || { echo "error: the copy differs from the source" >&2; cleanup; exit 64; }
shape "$SRC" >"$H/src.shape" || { echo "error: reading the source tree failed" >&2; cleanup; exit 64; }

# Preferences: a copy of a real domain if asked, else a fixture.
if [ -n "${E2E_LEGACY_DEFAULTS_DOMAIN:-}" ]; then
  defaults export "$E2E_LEGACY_DEFAULTS_DOMAIN" "$H/seed.plist" || { echo "error: reading the defaults domain failed" >&2; cleanup; exit 64; }
  defaults import "$LEGACY_DOMAIN" "$H/seed.plist" || { echo "error: defaults import failed" >&2; cleanup; exit 64; }
else
  step defaults write "$LEGACY_DOMAIN" uv.firstRunCompleted -bool true
  step defaults write "$LEGACY_DOMAIN" languagePin -string de
  step defaults write "$LEGACY_DOMAIN" appearance -string dark
  step defaults write "$LEGACY_DOMAIN" silenceTimeout -float 12.5
fi
defaults export "$LEGACY_DOMAIN" "$H/legacy.before.plist" || { echo "error: exporting the legacy domain failed" >&2; cleanup; exit 64; }

DUMMY="e2e-dummy-$(openssl rand -hex 8)" || { cleanup; exit 64; }

# Runs the app in the background, bounded, and reaps it. $1 = stdout file.
run_app() {
  local out="$1"; shift
  env "$@" "$BIN" >"$out" 2>/dev/null &
  CHILD=$!
  ( sleep 60; kill "$CHILD" 2>/dev/null ) &
  local watchdog=$!
  wait "$CHILD"
  APP_STATUS=$?
  CHILD=""
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
}
hook_env() { echo "HOME=$H" "CFFIXED_USER_HOME=$H" "UV_MIGRATE_ONLY=1" "UV_MIGRATION_TEST_PREFIX=$P"; }

FAILS=0
REPORT=()
check() { # name, yes|no
  if [ "$2" = yes ]; then REPORT+=("PASS  $1"); else REPORT+=("FAIL  $1"); FAILS=$((FAILS + 1)); fi
}
yn() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }
json_get() { # json, key, [len]: a key of the summary, or the length of a list in it
  python3 -I -c 'import json,sys
d = json.loads(sys.argv[1]); v = d.get(sys.argv[2])
print(len(v) if sys.argv[3] == "len" and v is not None else v)' "$1" "$2" "${3:-val}" 2>/dev/null
}

# 0. The guards. Each uses `env -u CFFIXED_USER_HOME` where the variable must be absent,
#    so an inherited value cannot let the hook migrate.
env -u CFFIXED_USER_HOME HOME="$H" UV_MIGRATE_ONLY=1 UV_MIGRATION_TEST_PREFIX="$P" "$BIN" >/dev/null 2>&1
check "refuses without CFFIXED_USER_HOME (exit 2)" "$([ $? -eq 2 ] && echo yes || echo no)"
env HOME="$H" CFFIXED_USER_HOME="$H" UV_MIGRATE_ONLY=1 UV_MIGRATION_TEST_PREFIX= "$BIN" >/dev/null 2>&1
check "refuses without a test prefix (exit 2)" "$([ $? -eq 2 ] && echo yes || echo no)"
env -u UV_MIGRATION_TEST_PREFIX HOME="$H" CFFIXED_USER_HOME="$H" UV_MIGRATE_ONLY=1 "$BIN" >/dev/null 2>&1
check "refuses with no prefix variable at all (exit 2)" "$([ $? -eq 2 ] && echo yes || echo no)"
check "the refusals moved nothing" "$([ -d "$AS/Sadaa" ] && [ "$(ls -A "$AS/UsefulVoice" | wc -l | tr -d ' ')" = 1 ] && echo yes || echo no)"

# 1. First run moves everything, second run changes nothing.
run_app "$H/run1.json" $(hook_env) "UV_MIGRATION_TEST_SEED_KEY=$DUMMY"; S1=$APP_STATUS
run_app "$H/run2.json" $(hook_env) "UV_MIGRATION_TEST_EXPECT_KEY=$DUMMY"; S2=$APP_STATUS
R1="$(cat "$H/run1.json" 2>/dev/null)"
R2="$(cat "$H/run2.json" 2>/dev/null)"
check "run 1 exits 0" "$([ "$S1" -eq 0 ] && echo yes || echo no)"
check "run 2 exits 0" "$([ "$S2" -eq 0 ] && echo yes || echo no)"
check "run 1 keychain outcome is migrated" "$([ "$(json_get "$R1" keychain)" = migrated ] && echo yes || echo no)"
check "run 1 reports no failures" "$([ "$(json_get "$R1" failed len)" = 0 ] && echo yes || echo no)"
check "run 1 reports no clashes" "$([ "$(json_get "$R1" conflicts len)" = 0 ] && echo yes || echo no)"
check "run 2 moved nothing and found the preferences done" \
  "$([ "$(json_get "$R2" moved len)" = 0 ] && [ "$(json_get "$R2" defaultsAlreadyMigrated)" = True ] && echo yes || echo no)"
check "run 2 keychain outcome is alreadyPresent" "$([ "$(json_get "$R2" keychain)" = alreadyPresent ] && echo yes || echo no)"

# 2. Files.
check "old folder removed" "$([ -e "$AS/Sadaa" ] && echo no || echo yes)"
manifest "$AS/UsefulVoice" >"$H/after.manifest" 2>/dev/null
check "every file arrived with identical content" "$(cmp -s "$H/src.manifest" "$H/after.manifest" && echo yes || echo no)"
check "models/ kept" "$([ -f "$AS/UsefulVoice/models/placeholder.bin" ] && echo yes || echo no)"
check "new folder is owner-only (700)" "$([ "$(stat -f %Lp "$AS/UsefulVoice")" = 700 ] && echo yes || echo no)"
LOOSE=$(find "$AS/UsefulVoice" -not -path '*/models*' -not -name diagnostics.log \( -type f -perm +077 -o -type d -perm +077 \) | wc -l | tr -d ' ')
check "moved entries are owner-only (loose entries: $LOOSE)" "$([ "$LOOSE" = 0 ] && echo yes || echo no)"
shape "$SRC" >"$H/src.shape.after" 2>/dev/null
check "source folder untouched" "$(cmp -s "$H/src.shape" "$H/src.shape.after" && echo yes || echo no)"

# 3. Preferences: every legacy key present with an equal value of the same type, and the
#    legacy domain byte-equal before and after.
defaults export "$NEW_DOMAIN" "$H/new.plist" 2>/dev/null
defaults export "$LEGACY_DOMAIN" "$H/legacy.after.plist" 2>/dev/null
PREF_RESULT="$(python3 -I - "$H/legacy.before.plist" "$H/new.plist" <<'PY'
import plistlib, sys
legacy = plistlib.load(open(sys.argv[1], "rb"))
new = plistlib.load(open(sys.argv[2], "rb"))
bad = [k for k, v in legacy.items() if k not in new or type(new[k]) is not type(v) or new[k] != v]
print("ok" if not bad and new.get("uv.identityMigrated") is True else "bad %d" % len(bad))
PY
)"
check "every legacy preference copied with equal value and type" "$([ "$PREF_RESULT" = ok ] && echo yes || echo no)"
check "legacy preferences domain byte-equal before and after" "$(cmp -s "$H/legacy.before.plist" "$H/legacy.after.plist" && echo yes || echo no)"

# 4. Keychain. The new item is guarded for the app only, so the app answers (as a boolean)
#    whether it holds the dummy.
check "new Keychain item holds the dummy key" "$([ "$(json_get "$R2" newKeyMatches)" = True ] && echo yes || echo no)"
check "new Keychain item exists (attributes only)" "$(yn security find-generic-password -s "$NEW_SERVICE" -a deepgram-key)"
check "old Keychain item removed" "$(security find-generic-password -s "$LEGACY_SERVICE" -a deepgram-key >/dev/null 2>&1 && echo no || echo yes)"

# 5. Cleanup is part of the result.
cleanup
check "cleanup complete (leftovers: $CLEAN_FAILS)" "$([ "$CLEAN_FAILS" -eq 0 ] && echo yes || echo no)"

REPORT_TEXT="$(
  printf '%s\n' "${REPORT[@]}"
  echo
  echo "run 1: exit $S1, keychain $(json_get "$R1" keychain), moved $(json_get "$R1" moved len), conflicts $(json_get "$R1" conflicts len), discarded $(json_get "$R1" discarded len), failed $(json_get "$R1" failed len), preferences copied $(json_get "$R1" defaultsCopied), login signal $(json_get "$R1" loginItemSignal)"
  echo "run 2: exit $S2, keychain $(json_get "$R2" keychain), moved $(json_get "$R2" moved len)"
  echo
  if [ "$FAILS" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: $FAILS check(s) FAILED"; fi
)"

# Write the report next to the result without following a link, then print it.
TMP_RESULT="$(mktemp "$OUT/.result.XXXXXX")" || { echo "error: cannot write the report" >&2; exit 1; }
printf '%s\n' "$REPORT_TEXT" >"$TMP_RESULT" && mv -f "$TMP_RESULT" "$RESULT" || { rm -f "$TMP_RESULT"; echo "error: cannot write the report" >&2; exit 1; }
printf '%s\n' "$REPORT_TEXT"

[ "$FAILS" -eq 0 ]
