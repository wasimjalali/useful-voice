#!/bin/bash
# Run the UsefulVoiceCore test suite with a Command Line Tools-only toolchain
# (no Xcode.app installed).
#
# Swift Testing's dynamic libraries live inside the CLT framework directory,
# which swiftpm does not add to the test runner's runtime search path. So:
#   1. build the tests with -F pointing at the CLT frameworks,
#   2. copy Testing.framework + lib_TestingInterop.dylib next to the test binary,
#   3. run with --skip-build so the copied libraries are found by its rpath.
set -euo pipefail

cd "$(dirname "$0")/.."

CF=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
FW="$CF/Testing.framework"

# lib_TestingInterop.dylib does NOT live beside Testing.framework. Depending on the
# toolchain it is either in the CLT's Developer/usr/lib or in the Xcode toolchain's
# usr/lib, so search instead of assuming one path. Previously this script looked
# only in Frameworks/, never found it, and the `[ -f ... ] &&` guard swallowed the
# miss -- so it appeared to work purely because a stale copy happened to be sitting
# in an existing .build directory, and failed for anyone running a clean build.
INTEROP=""
for candidate in \
  "$CF/../usr/lib/lib_TestingInterop.dylib" \
  "/Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib" \
  "/Library/Developer/CommandLineTools/usr/lib/lib_TestingInterop.dylib" \
  "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/lib_TestingInterop.dylib" \
  "$(xcrun --find swift 2>/dev/null | xargs -I{} dirname {}/../lib 2>/dev/null)/lib_TestingInterop.dylib"
do
  if [ -f "$candidate" ]; then
    INTEROP="$candidate"
    break
  fi
done

if [ ! -d "$FW" ]; then
  echo "error: Testing.framework not found at $FW" >&2
  echo "       install Xcode or the Swift toolchain that provides swift-testing" >&2
  exit 1
fi

if [ -z "$INTEROP" ]; then
  echo "error: lib_TestingInterop.dylib not found in any known location." >&2
  echo "       searched:" >&2
  echo "         $CF/../usr/lib/" >&2
  echo "         /Library/Developer/CommandLineTools/usr/lib/" >&2
  echo "       the test runner cannot start without it; refusing to continue" >&2
  exit 1
fi

echo "==> building tests"
swift build --build-tests -Xswiftc -F -Xswiftc "$CF" "$@"

BIN="$(swift build --show-bin-path --build-tests)"
echo "==> staging test runtime into $BIN"
rm -rf "$BIN/Testing.framework"
cp -R "$FW" "$BIN/"
cp -f "$INTEROP" "$BIN/"

# Verify the staging actually happened, so a silent copy failure cannot produce a
# "library not loaded" error at run time (or, worse, a false pass).
if [ ! -f "$BIN/lib_TestingInterop.dylib" ]; then
  echo "error: failed to stage lib_TestingInterop.dylib into $BIN" >&2
  exit 1
fi

echo "==> running tests"
swift test --skip-build -Xswiftc -F -Xswiftc "$CF"
