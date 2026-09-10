APP = dist/UsefulVoice.app
ENTITLEMENTS = bundle/UsefulVoice.entitlements

# Local development signing. Used by `bundle` / `run` / `install`.
#
# Sign with the stable self-signed identity if it exists (set up once via
# scripts/setup-signing.sh), otherwise fall back to ad-hoc. Ad-hoc signing
# changes the code hash every build, which makes macOS drop the Accessibility
# grant on each reinstall; the stable identity keeps the hotkey working.
#
# Do NOT switch this to a Developer ID: the TCC grant for the Accessibility tap
# is bound to the signing identity, so changing it forces every existing user to
# re-grant. Distribution signing is the separate `bundle-release` target below.
SIGN_IDENTITY = $(shell security find-identity -p codesigning 2>/dev/null | grep -q "Sadaa Local Signing" && echo "Sadaa Local Signing" || echo "-")

# Warn loudly when signing ad-hoc, which silently drops the Accessibility grant
# on every reinstall. Run scripts/setup-signing.sh once to fix it.
ifeq ($(SIGN_IDENTITY),-)
$(warning Signing ad-hoc: run ./scripts/setup-signing.sh once so the Accessibility grant survives reinstalls.)
endif

# Distribution signing. `make bundle-release` needs a real Developer ID; if one
# is not installed it fails with guidance rather than producing a bundle that
# silently cannot be notarized.
DEVID_IDENTITY = $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
NOTARY_PROFILE = useful-voice-notary

# Command Line Tools (no Xcode.app) don't put Testing.framework on the dyld
# search path. We compile against it with -F and copy it next to the test
# bundle (@loader_path/../../../ rpath) so the runner can load it. Installing
# full Xcode makes all of this unnecessary but harmless.
CLT_FRAMEWORKS = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_INTEROP = /Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib
DEBUG_DIR = $(shell swift build --show-bin-path --build-tests 2>/dev/null)
SWIFT_TEST_FLAGS = -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS)

MARKETING_VERSION ?= 1.0.0
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

.PHONY: build test bundle run install uninstall bundle-release notarize dmg clean

build:
	swift build -c release

test:
	./scripts/run-tests.sh

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/UsefulVoiceApp $(APP)/Contents/MacOS/Sadaa
	cp assets/branding/Sadaa.icns $(APP)/Contents/Resources/Sadaa.icns
	cp assets/branding/useful-voice-mark-dark.png $(APP)/Contents/Resources/SadaaLogo.png
	@# Stamp the version from a single source of truth so shipped binaries are
	@# distinguishable when triaging a report, and CFBundleVersion increases
	@# monotonically (required for updates to install cleanly).
	plutil -replace CFBundleShortVersionString -string "$(MARKETING_VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)
	@codesign -dv $(APP) 2>&1 | sed -n 's/^/    /p'

run: bundle
	open $(APP)

# Install into /Applications and (re)launch so it appears in Finder.
install: bundle
	@# Remove every previously-known location of the app, not just the one we are
	@# installing to. A stale copy left in dist/ shares this bundle id and this
	@# signature, so it also shares the Accessibility grant and installs a second
	@# event tap -- one hotkey press would then toggle dictation twice.
	@./scripts/stop-instances.sh
	rm -rf "/Applications/Useful Voice.app"
	cp -R $(APP) "/Applications/Useful Voice.app"
	open "/Applications/Useful Voice.app"

# Turn off launch-at-login BEFORE deleting the bundle: afterwards there is no app
# left to unregister the login item, and the user has to find it by hand in
# System Settings.
uninstall:
	@./scripts/uninstall.sh

# ---------------------------------------------------------------------------
# Distribution: hardened runtime + Developer ID + notarization.
# ---------------------------------------------------------------------------

bundle-release:
ifeq ($(DEVID_IDENTITY),)
	@echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
	@echo "       Distribution builds must be signed with a Developer ID and notarized," >&2
	@echo "       otherwise Gatekeeper blocks them on every other Mac." >&2
	@echo "       Install one, or use 'make bundle' for local development." >&2
	@exit 1
endif
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/UsefulVoiceApp $(APP)/Contents/MacOS/Sadaa
	cp assets/branding/Sadaa.icns $(APP)/Contents/Resources/Sadaa.icns
	cp assets/branding/useful-voice-mark-dark.png $(APP)/Contents/Resources/SadaaLogo.png
	plutil -replace CFBundleShortVersionString -string "$(MARKETING_VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" $(APP)/Contents/Info.plist
	@# No --deep: Apple documents it as unsuitable for distribution signing. The
	@# bundle has no nested code, so a single explicit sign is correct. The
	@# hardened runtime is required for notarization, and --timestamp is required
	@# for the signature to stay valid past the certificate's lifetime.
	codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(DEVID_IDENTITY)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	@echo "==> signed with $(DEVID_IDENTITY)"

# Requires a stored notarytool profile: 
#   xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id ... --team-id ... --password ...
notarize: bundle-release
	cd dist && zip -qry UsefulVoice.zip UsefulVoice.app
	xcrun notarytool submit dist/UsefulVoice.zip \
		--keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(APP)
	@# Verify what a user's Mac will actually see.
	spctl --assess --type execute --verbose=4 $(APP)
	@echo "==> notarized and stapled"

# Installer image for distribution.
dmg: bundle-release
	rm -f dist/UsefulVoice-$(MARKETING_VERSION).dmg
	hdiutil create -volname "Useful Voice" -srcfolder $(APP) -ov -format UDZO \
		dist/UsefulVoice-$(MARKETING_VERSION).dmg
	@# The dmg is signed code from the user's point of view; sign it too or it is
	@# the one Gatekeeper-blocked artifact in the release.
	@if [ -n "$(DEVID_IDENTITY)" ]; then \
		codesign --force --timestamp --sign "$(DEVID_IDENTITY)" \
			dist/UsefulVoice-$(MARKETING_VERSION).dmg; \
	fi

clean:
	rm -rf .build dist
