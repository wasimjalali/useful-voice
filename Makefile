APP = dist/UsefulVoice.app
ENTITLEMENTS = bundle/UsefulVoice.entitlements

# Local development signing. Used by `bundle` / `run` / `install`.
#
# Sign with the stable "Useful Voice Release" identity if it is in the login
# keychain (imported once from the password manager; see scripts/setup-signing.sh),
# otherwise fall back to ad-hoc. Ad-hoc signing changes the code hash every build,
# which makes macOS drop the Accessibility grant on each reinstall; the stable
# identity keeps the hotkey working.
#
# Do NOT create a new certificate or switch this to another identity: the TCC
# grant for the Accessibility tap and the Microphone is bound to the signing
# identity, so changing it forces every existing user to re-grant. Distribution
# signing is the separate `bundle-release` target below.
SIGN_IDENTITY = $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"Useful Voice Release"' && echo "Useful Voice Release" || echo "-")

# Warn loudly when signing ad-hoc, which silently drops the Accessibility grant
# on every reinstall. Run scripts/setup-signing.sh to see how to import the identity.
ifeq ($(SIGN_IDENTITY),-)
$(warning Signing ad-hoc: import the "Useful Voice Release" identity (scripts/setup-signing.sh) so the Accessibility grant survives reinstalls.)
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

MARKETING_VERSION ?= 0.1.0
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# App icon. Xcode's actool compiles the Icon Composer bundle (assets/branding/UsefulVoice.icon,
# light and dark appearances) into Assets.car, which CFBundleIconName points at. It needs
# Xcode.app, so on Command Line Tools only the bundle falls back to the light UsefulVoice.icns
# that CFBundleIconFile names. The icns is copied after actool so it is never overwritten.
define compile_icon
	@if xcrun --find actool >/dev/null 2>&1; then \
		xcrun actool "$(CURDIR)/assets/branding/UsefulVoice.icon" --compile "$(CURDIR)/$(APP)/Contents/Resources" \
			--output-format human-readable-text --notices --warnings --errors \
			--output-partial-info-plist "$$(mktemp)" --app-icon UsefulVoice \
			--platform macosx --minimum-deployment-target 14.0 --target-device mac; \
	else \
		echo "warning: actool not found (needs Xcode.app); shipping the light icon only" >&2; \
	fi
	cp assets/branding/UsefulVoice.icns $(APP)/Contents/Resources/UsefulVoice.icns
	cp assets/branding/StatusItem*.png $(APP)/Contents/Resources/
endef

# Sparkle, for in-app updates. The framework ships signed by its authors and ditto
# keeps that signature (and the framework's symlinks). The updater only runs when a
# release build passes its feed and public key (scripts/release-mac.mjs sets
# SU_FEED_URL and SU_PUBLIC_ED_KEY); a local build carries neither and never updates.
SU_FEED_URL ?=
SU_PUBLIC_ED_KEY ?=
define embed_sparkle
	rm -rf $(APP)/Contents/Frameworks/Sparkle.framework
	ditto .build/release/Sparkle.framework $(APP)/Contents/Frameworks/Sparkle.framework
	@if [ -n '$(SU_FEED_URL)$(SU_PUBLIC_ED_KEY)' ]; then \
		[ -n '$(SU_FEED_URL)' ] && [ -n '$(SU_PUBLIC_ED_KEY)' ] || { echo "error: SU_FEED_URL and SU_PUBLIC_ED_KEY go together" >&2; exit 1; }; \
		plutil -insert SUFeedURL -string '$(SU_FEED_URL)' $(APP)/Contents/Info.plist && \
		plutil -insert SUPublicEDKey -string '$(SU_PUBLIC_ED_KEY)' $(APP)/Contents/Info.plist && \
		plutil -insert SUEnableAutomaticChecks -bool YES $(APP)/Contents/Info.plist; \
	fi
endef

.PHONY: build test bundle run install uninstall bundle-release notarize dmg clean

build:
	swift build -c release

test:
	./scripts/run-tests.sh

# SPM stages the whisper.cpp XCFramework next to the built binary as a dynamic
# framework. The app bundle must embed it under Contents/Frameworks, with an
# rpath so @rpath/whisper.framework resolves there.
FRAMEWORK = whisper.framework

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/UsefulVoiceApp $(APP)/Contents/MacOS/UsefulVoice
	$(call compile_icon)
	cp assets/branding/useful-voice-mark-dark.png $(APP)/Contents/Resources/UsefulVoiceLogo.png
	cp -R .build/release/$(FRAMEWORK) $(APP)/Contents/Frameworks/
	$(call embed_sparkle)
	@# The binary's own rpaths point at SPM's build/artifact dirs; inside the
	@# bundle the framework lives at ../Frameworks relative to the executable.
	install_name_tool -add_rpath "@executable_path/../Frameworks" \
		$(APP)/Contents/MacOS/UsefulVoice 2>/dev/null || true
	@# Stamp the version from a single source of truth so shipped binaries are
	@# distinguishable when triaging a report, and CFBundleVersion increases
	@# monotonically (required for updates to install cleanly).
	plutil -replace CFBundleShortVersionString -string "$(MARKETING_VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" $(APP)/Contents/Info.plist
	@# Nested code is signed inside-out: the framework gets its own signature
	@# (the upstream XCFramework is only ad-hoc signed), then the bundle.
	@# Sparkle keeps its authors' signature: without the hardened runtime there is
	@# no library validation, so the app loads it as signed.
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)/Contents/Frameworks/$(FRAMEWORK)
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
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/UsefulVoiceApp $(APP)/Contents/MacOS/UsefulVoice
	$(call compile_icon)
	cp assets/branding/useful-voice-mark-dark.png $(APP)/Contents/Resources/UsefulVoiceLogo.png
	cp -R .build/release/$(FRAMEWORK) $(APP)/Contents/Frameworks/
	$(call embed_sparkle)
	install_name_tool -add_rpath "@executable_path/../Frameworks" \
		$(APP)/Contents/MacOS/UsefulVoice 2>/dev/null || true
	plutil -replace CFBundleShortVersionString -string "$(MARKETING_VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" $(APP)/Contents/Info.plist
	@# No --deep: Apple documents it as unsuitable for distribution signing.
	@# Nested code is signed inside-out with the hardened runtime on each
	@# signature; the --timestamp keeps them valid past the certificate's life.
	codesign --force --options runtime --timestamp \
		--sign "$(DEVID_IDENTITY)" \
		$(APP)/Contents/Frameworks/$(FRAMEWORK)
	@# The hardened runtime's library validation only loads code from the same
	@# team, so Sparkle is re-signed in the order its docs give
	@# (sparkle-project.org/documentation/sandboxing).
	codesign -f -s "$(DEVID_IDENTITY)" -o runtime --timestamp $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	codesign -f -s "$(DEVID_IDENTITY)" -o runtime --timestamp --preserve-metadata=entitlements $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	codesign -f -s "$(DEVID_IDENTITY)" -o runtime --timestamp $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign -f -s "$(DEVID_IDENTITY)" -o runtime --timestamp $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	codesign -f -s "$(DEVID_IDENTITY)" -o runtime --timestamp $(APP)/Contents/Frameworks/Sparkle.framework
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
