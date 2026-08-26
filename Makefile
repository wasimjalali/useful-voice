APP = dist/UsefulVoice.app

# Sign with the stable self-signed identity if it exists (set up once via
# scripts/setup-signing.sh), otherwise fall back to ad-hoc. Ad-hoc signing
# changes the code hash every build, which makes macOS drop the Accessibility
# grant on each reinstall; the stable identity keeps the hotkey working.
SIGN_IDENTITY = $(shell security find-identity -p codesigning 2>/dev/null | grep -q "Sadaa Local Signing" && echo "Sadaa Local Signing" || echo "-")

# Warn loudly when signing ad-hoc, which silently drops the Accessibility grant
# on every reinstall. Run scripts/setup-signing.sh once to fix it.
ifeq ($(SIGN_IDENTITY),-)
$(warning Signing ad-hoc: run ./scripts/setup-signing.sh once so the Accessibility grant survives reinstalls.)
endif

# Command Line Tools (no Xcode.app) don't put Testing.framework on the dyld
# search path. We compile against it with -F and copy it next to the test
# bundle (@loader_path/../../../ rpath) so the runner can load it. Installing
# full Xcode makes all of this unnecessary but harmless.
CLT_FRAMEWORKS = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_INTEROP = /Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib
DEBUG_DIR = $(shell swift build --show-bin-path --build-tests 2>/dev/null)
SWIFT_TEST_FLAGS = -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS)

.PHONY: build test bundle run install clean

build:
	swift build -c release

test:
	swift build --build-tests $(SWIFT_TEST_FLAGS)
	cp -R $(CLT_FRAMEWORKS)/Testing.framework $(DEBUG_DIR)/ 2>/dev/null || true
	cp $(CLT_INTEROP) $(DEBUG_DIR)/ 2>/dev/null || true
	swift test --skip-build $(SWIFT_TEST_FLAGS)

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/UsefulVoiceApp $(APP)/Contents/MacOS/Sadaa
	cp assets/branding/Sadaa.icns $(APP)/Contents/Resources/Sadaa.icns
	cp assets/branding/sadaa-icon-b-navy-on-cream.svg.png $(APP)/Contents/Resources/SadaaLogo.png
	codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP)

run: bundle
	open $(APP)

# Install into /Applications and (re)launch so it appears in Finder.
install: bundle
	pkill -x Sadaa || true
	rm -rf "/Applications/Useful Voice.app"
	cp -R $(APP) "/Applications/Useful Voice.app"
	open "/Applications/Useful Voice.app"

clean:
	rm -rf .build dist
