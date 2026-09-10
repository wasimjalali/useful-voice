# Audit 02 — Global Hotkey Capture, App Lifecycle, Menu Bar, HUD Window, Login Item, Window Management

**Target:** `/Users/wasimjalali/Desktop/Personal Project/useful-voice`
**Method:** read-only static audit. No files outside this report were modified; `swift build` / `swift test` were not run (blocked by sandbox).
**Files read in full:** `Sources/UsefulVoiceApp/AppDelegate.swift`, `HotkeyManager.swift`, `main.swift`, `LoginItem.swift`, `MainWindowController.swift`, `HUD/HUDPanel.swift`, `HUD/HUDView.swift`, `UsefulVoiceViewModel.swift`, `RootView.swift`, `Sources/UsefulVoiceCore/Hotkey/RightOptionTapRecognizer.swift`, `Sources/UsefulVoiceCore/Layout/ResponsiveLayoutRules.swift`, `bundle/Info.plist`, `Makefile`, `scripts/setup-signing.sh`, `Tests/UsefulVoiceCoreTests/{RightOptionTapRecognizerTests,ResponsiveLayoutRulesTests}.swift`.
**Supporting reads (for cross-checks):** `Sources/UsefulVoiceCore/Settings/AppSettings.swift`, `Settings/Keychain.swift`, `DictationController.swift`, `Pages/SettingsPage.swift`, `Package.swift`, `.github/workflows/ci.yml`, `README.md`, plus `codesign`/`plutil`/`file`/`lipo` inspection of the already-built `dist/UsefulVoice.app`.

**Bundle-consistency question (answered up front, details in HOOK-08/HOOK-09):** `make bundle` *is* internally consistent and launchable. `bundle/Info.plist` declares `CFBundleExecutable = Sadaa` (line 8), the Makefile copies the binary to `Contents/MacOS/Sadaa` (line 39), `CFBundleIconFile = Sadaa` (line 9) matches the copied `Contents/Resources/Sadaa.icns` (line 40), and `assets/branding/Sadaa.icns` **does exist** (106 801 bytes, `file` → "Mac OS X icon, ic12"; `iconutil`-generated `Sadaa.iconset` also present). `dist/UsefulVoice.app` on disk matches `bundle/Info.plist` byte-for-byte (`diff` → identical), contains `Contents/MacOS/Sadaa`, both resources, and a valid `_CodeSignature`. So there is **no executable-name/icon mismatch defect**. The "Sadaa vs Useful Voice" split is cosmetic (`CFBundleName`/`CFBundleDisplayName` are "Useful Voice", identifier is `ai.karko.sadaa`, executable is `Sadaa`) — it works, but it is confusing for distribution and for support (see HOOK-08/HOOK-09). Apple has an existing `/Applications/Useful Voice.app` and it is currently running from there (`ps` shows PID 979 `/Applications/Useful Voice.app/Contents/MacOS/Sadaa`), which makes HOOK-06 reproducible on this machine.

---

## Findings

| ID | Title | Severity | File : lines | Effort |
|----|-------|----------|--------------|--------|
| HOOK-01 | CGEvent tap runs on the **main run loop**; a main-thread block freezes system-wide keyboard input | **Critical** | `HotkeyManager.swift:88–90`; `DictationController.swift:197`; `Keychain.swift:56–61` | M |
| HOOK-02 | Accessibility revocation while running silently kills the hotkey; UI keeps claiming "Hotkeys active" | **High** | `AppDelegate.swift:465–482, 487–497`; `HotkeyManager.swift:111–115` | S |
| HOOK-03 | Modifier taps are invalidated only by other `keyDown`s — Cmd-click / Shift-click fire spurious toggles | **High** | `HotkeyManager.swift:72–78, 142–148`; `AppSettings.swift:92` | S |
| HOOK-04 | Key down/up state is read from the shared modifier flag, so the "other side" modifier corrupts the tap | Medium | `HotkeyManager.swift:48–57, 121–136` | S |
| HOOK-05 | Every launch (including launch-at-login) opens the main window, switches to `.regular` and steals focus | **High** | `AppDelegate.swift:67–78`; `MainWindowController.swift:31–34` | S |
| HOOK-06 | No single-instance guard: two copies install two taps (double-toggle) and two HUDs | **High** | `Makefile:47–52`; `main.swift:3–9` (no guard anywhere) | S |
| HOOK-07 | `fatalError` on app-support failure = invisible crash loop for a login-item app | Medium | `AppDelegate.swift:129–135` | S |
| HOOK-08 | `Info.plist` is minimal: no app category, no copyright, no dev region, hardcoded version | Low | `bundle/Info.plist:5–18` | S |
| HOOK-09 | Not distributable/notarizable: self-signed identity, no hardened runtime, no timestamp, no entitlements, arm64-only | **High** | `Makefile:7, 42`; verified signature of `dist/UsefulVoice.app` | M |
| HOOK-10 | HUD swallows mouse clicks in its rectangle over the target app | Medium | `HUDPanel.swift:109–115` | S |
| HOOK-11 | HUD is invisible to VoiceOver: no announcement, no accessibility element | Medium | `HUDView.swift:22–51`; `HUDPanel.swift:100–118` | S |
| HOOK-12 | HUD re-creates the SwiftUI root view **and** forces synchronous layout 30×/s on the main thread | Medium | `HUDPanel.swift:38–57`; `AppDelegate.swift:541–548` | M |
| HOOK-13 | No screen-parameter observer; the pill's screen comes from `NSScreen.main` | Medium | `HUDPanel.swift:133–153` | S |
| HOOK-14 | HUD hide/recording timers use default run-loop mode, so they stall during menu tracking / window drags | Low | `HUDPanel.swift:84–87`; `AppDelegate.swift:472–482, 541–548` | S |
| HOOK-15 | Window frame is never persisted and is re-centered on every open; no state restoration; no `applicationSupportsSecureRestorableState` | Low | `MainWindowController.swift:24–35` | S |
| HOOK-16 | Menu bar is missing a Window menu (⌘W/⌘M dead) and "Settings…"/⌘, does not open Settings | Medium | `AppDelegate.swift:90–120, 617–621`; `RootView.swift:38` | S |
| HOOK-17 | Microphone state is checked only at launch; a revoked mic is only discovered after a failed dictation; denial text has no deep link | Medium | `AppDelegate.swift:666–678` | M |
| HOOK-18 | Accessibility prompt re-shown on **every** launch; the only in-app guidance is a 6-second toast | Medium | `AppDelegate.swift:469–482, 676–678` | S |
| HOOK-19 | Login item: `.requiresApproval` treated as "off", no `openSystemSettingsLoginItems()`, no path validation after the app moves | Medium | `LoginItem.swift:6–22`; `SettingsPage.swift:285–300` | S |
| HOOK-20 | No termination hooks: quitting mid-recording loses the recording; no teardown of tap/timers | Low | `AppDelegate.swift` (no `applicationWillTerminate`/`applicationShouldTerminate`) | S |
| HOOK-21 | Esc `keyDown` is consumed but its `keyUp` is not (mask lacks `.keyUp`) | Low | `HotkeyManager.swift:72–73, 137–141` | S |
| HOOK-22 | `AppDelegate` is only referenced by a **weak** `NSApplication.delegate` from a local `let` | Medium *(flagged: latent)* | `main.swift:3–9`; `NSApplication.h:194` | S |
| HOOK-23 | `AppleShowScrollBars` is written into the user's global defaults domain on every launch | Low | `main.swift:4` | S |
| HOOK-24 | Fn/Globe (`63`) as a hotkey option conflicts with the system Globe key | Low *(flagged: uncertain)* | `HotkeyManager.swift:17, 54` | S |

---

## Details

### HOOK-01 — CGEvent tap runs on the main run loop; a main-thread block freezes keyboard input
**Severity: Critical · Effort: M**

**File/lines:** `Sources/UsefulVoiceApp/HotkeyManager.swift:88–90` (installation), corroborated by `Sources/UsefulVoiceCore/DictationController.swift:196–197` and `Sources/UsefulVoiceCore/Settings/Keychain.swift:56–61`.

**Evidence** — `HotkeyManager.swift:87–90`:
```swift
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
```
The tap is active (`.defaultTap`, `.headInsertEventTap`, mask = all `flagsChanged` + all `keyDown`), so the callback is on the synchronous path of **every keystroke in the session**. The callback is therefore executed by the main run loop (`handle(type:event:)`, lines 109–150), i.e. it shares a thread with all UI, SwiftUI layout, and any blocking call. This codebase contains a verified blocking main-thread call *inside the dictation path*:

`DictationController.swift:196–197` (a `@MainActor` class; reached from `Task { await stopAndProcess() }`, line 103, which inherits the main actor):
```swift
        let formattingContext = presetContext ?? context()
        let chain = providers()
```
`AppDelegate.swift:408–411` → `Keychain.get(account: "deepgram-key")` → `SecItemCopyMatching(..., kSecReturnData: true)`. The repo itself documents why that is dangerous, `Keychain.swift:56–61`:
```swift
    /// True if an item exists for `account`, WITHOUT returning (decrypting) its
    /// data. This matters on the main thread: get(), with kSecReturnData, can
    /// make securityd put up a keychain authorization prompt that blocks the
    /// caller until the user answers it (which happens after a re-signed
    /// reinstall). An existence check decrypts nothing, so it never prompts and
```
and `UsefulVoiceViewModel.swift:61–65`:
```swift
        // exists() not get(): refreshConfig runs on the main thread (init, and
        // after every settings/language change), and get() can trigger a
        // blocking keychain authorization prompt that freezes the app, and with
        // it the HUD. An existence check is all "configured?" needs and never
```
So the team already knows a specific call blocks the main thread indefinitely — it was removed from `refreshConfig` but it still runs, per dictation, on the main thread at `DictationController.swift:197`, while a system-wide default tap is installed on that same thread.

**Why it matters in production:** The WindowServer delivers an event to a session tap and waits for the tap to answer; a tap that does not return fast is punished with `kCGEventTapDisabledByTimeout` (and, in practice, keystrokes stall for the whole machine). Concrete scenario: after an update, the ad-hoc/self-signed re-sign invalidates the keychain item's ACL as described above, so at the first dictation of the session `providers()` triggers the "Sadaa wants to use your confidential information stored in…" prompt. That prompt blocks the main thread until the user answers. During that window **every app on the Mac stops receiving keystrokes**, and the tap is then disabled — so the dictation hotkey is also dead until something re-enables it. A second, weaker variant: the HUD path itself (HOOK-12) does synchronous layout 30×/s on this thread.

**Recommended fix:** Move the tap off the main thread. Create the tap on a dedicated thread that owns its own run loop, e.g. a `Thread` whose body does `runLoopSource = CFMachPortCreateRunLoopSource(...); CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes); CGEvent.tapEnable(...); CFRunLoopRun()`, and keep the tap's shutdown via `CFRunLoopPerformBlock`/`perform` on that thread. That requires the callback to stop calling main-actor state directly: replace `isRecordingActive: (() -> Bool)` with an atomic/lock-protected flag (`OSAllocatedUnfairLock<Bool>`) that the app updates when the dictation state changes, and deliver `onToggle`/`onCancel` via `DispatchQueue.main.async` (already done). Independently, move the blocking `Keychain.get` at `DictationController.swift:197` off the main actor (e.g. build providers inside a detached task, or add `kSecUseDataProtectionKeychain`/cache the key in memory after first successful read).

---

### HOOK-02 — Accessibility revocation while running silently kills the hotkey; UI keeps claiming "Hotkeys active"
**Severity: High · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:465–482` and `487–497`; `Sources/UsefulVoiceApp/HotkeyManager.swift:111–115`.

**Evidence** — `AppDelegate.swift:471–482`:
```swift
        axPollTimer?.invalidate()
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0,
                                           repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard AXIsProcessTrusted() else { return }
                if self.tryStartHotkeys() {
                    self.axPollTimer?.invalidate()
                    self.axPollTimer = nil
                }
            }
        }
```
The poll exists **only while untrusted** and is permanently invalidated on the first success (line 478–479). Combined with `HotkeyManager.swift:111–115`:
```swift
        // macOS disables taps that stall; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
```
The `kCGEventTapDisabledByUserInput` branch (which is what macOS sends when the Accessibility grant is revoked, or when the user toggles the app off in Privacy & Security → Accessibility) blindly re-enables the tap. When the process is no longer trusted, re-enabling is a no-op and the tap stays inert. `viewModel.hotkeyActive` was set to `true` (line 491) and is never re-evaluated, so `RootView.swift:106–108` keeps showing a green "Hotkeys active" dot forever.

**Why it matters in production:** A user who revokes Accessibility (or an admin/MDM-managed TCC reset, or a macOS update that resets TCC) gets an app that looks healthy, shows "Hotkeys active", and whose primary feature silently does nothing. There is no relaunch prompt, no error, no toast — the only cure is to guess that a relaunch is required. The README explicitly advertises that granting works without a relaunch, so the inverse (revocation) is an unhandled state.

**Recommended fix:** In `HotkeyManager.handle`, on `.tapDisabledByUserInput` first ask for trust: if `!AXIsProcessTrusted()`, call `stop()` and invoke a new `onTapLost` callback. In `AppDelegate`, implement `onTapLost` as "set `hotkeyActive = false`, tear down the tap, show a HUD error, and restart the exact poll block from `startHotkeys()`", and also re-arm the poll from `applicationDidBecomeActive(_:)` (which returns after the user leaves System Settings). The poll body is already idempotent, so it can be extracted into `startAccessibilityPoll()` and called from both places.

---

### HOOK-03 — Modifier taps are invalidated only by other `keyDown`s: Cmd-click / Shift-click fire spurious toggles
**Severity: High · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/HotkeyManager.swift:72–78` (mask), `131–145` (invalidation); `Sources/UsefulVoiceCore/Settings/AppSettings.swift:92` (default language-switch key = 60, Right Shift).

**Evidence** — `HotkeyManager.swift:72–73` and `142–148`:
```swift
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
```
```swift
        case .keyDown:
            // Any other key invalidates a pending tap on every tap-key.
            _ = activationRecognizer.handle(.otherKeyDown)
            _ = languageSwitchRecognizer.handle(.otherKeyDown)
```
Mouse events and other modifiers are absent from the mask, so nothing can invalidate a pending modifier tap except a key press. `RightOptionTapRecognizer` (lines 22–36) then fires on any down→up pair within `maxTapDuration = 0.6`.

**Why it matters in production:** The default language-switch key is Right Shift (`AppSettings.swift:92` → `60`, matching `HotkeyManager.swift:40`). A user who selects text with **Shift + click** or drags with the right Shift held for under 600 ms, with no intervening key press, flips the dictation language and gets an unexpected "German" HUD toast — and the change is silently written to settings (`AppDelegate.swift:48–56`), so the next dictation transcribes in the wrong language. With the default dictation key (Right Command, `AppSettings.swift:81` → `54`) the same mechanism makes **Right Cmd + click** start or stop a recording: the user opens a link in a new tab and the app starts recording (or, mid-dictation, stops it early). Every mouse gesture that combines a modifier with a click is a false-positive generator.

**Recommended fix:** Broaden the tap mask to `(1 << .keyDown) | (1 << .flagsChanged) | (1 << .leftMouseDown) | (1 << .rightMouseDown) | (1 << .otherMouseDown) | (1 << .leftMouseDragged)` and route all of those types to `recognizer.handle(.otherKeyDown)` (optionally rename the case to `.invalidatingInput`). Also invalidate on `.scrollWheel`, and consider invalidating when any *other* modifier flag changes (see HOOK-04) so a `Shift`-tap cannot complete while `Command` is added mid-gesture. `RightOptionTapRecognizer` is pure and already covered by tests, so this is a 3-line change plus tests.

---

### HOOK-04 — Key down/up state is read from the shared modifier flag, so the other side of the modifier corrupts the tap
**Severity: Medium · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/HotkeyManager.swift:48–57` and `121–136`.

**Evidence** — `HotkeyManager.swift:121–130`:
```swift
        case .flagsChanged where keycode == activationKeycode:
            // The mask is set when EITHER side of the modifier is down. We have
            // already filtered to the specific keycode, so this is our key.
            // Edge case (unchanged): holding the other side of the same modifier
            // keeps the mask set, so the up event won't register. Acceptable.
            let isDown = event.flags.contains(Self.flagMask(for: keycode))
            if activationRecognizer.handle(isDown ? .rightOptionDown(at: now)
                                                  : .rightOptionUp(at: now)) {
```
with `flagMask` mapping both sides to one bit (`HotkeyManager.swift:50`):
```swift
        case 61, 58: return .maskAlternate     // right / left option
```

**Why it matters in production:** The `flagsChanged` event for keycode 54 tells you *which* key changed, but `event.flags` only tells you whether *any* Command key is down. Failure sequence: user holds Left Command (Cmd-tab muscle memory, Cmd-click, Cmd-drag), taps Right Command → `flags` already contains `.maskCommand`, so this reads as a *down*; the recorder now believes a down is pending and the user's intended tap is treated as a hold, so nothing fires. Worse, if the tap's down was registered and Left Command is still held when Right Command is released, the release also reads as "down", so the recognizer can be left with a stale `downAt` that expires silently. The comment calls this "acceptable", but for a dictation app whose default key is Right Command it means the hotkey intermittently does nothing in exactly the modifier-rich moments where users press it.

**Recommended fix:** Track per-keycode state instead of deriving it from the shared flag: keep `private var lastDown: [Int64: Bool]`, compute `let down = event.flags.contains(mask)`, ignore the event when `down == lastDown[keycode]`, otherwise store and forward. That distinguishes "the key actually changed state" from "the flag is set by the other side". (For full fidelity use IOKit `IOHIDManager` with per-element `kIOHIDElementUsage` values, but the state-machine fix is a few lines and covers the reported case.) Add unit tests for the "other side held" sequence.

---

### HOOK-05 — Every launch (including launch-at-login) opens the main window, switches to `.regular` and steals focus
**Severity: High · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:67–78`; `Sources/UsefulVoiceApp/MainWindowController.swift:31–34`.

**Evidence** — `AppDelegate.swift:67–78`:
```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThinScrollbar.install()
        installMainMenu()
        chimes.isEnabled = { [settings] in settings.soundEffectsEnabled }
        setUpStatusItem()
        setUpController()
        requestPermissions()
        startHotkeys()
        if let viewModel {
            mainWindow.show(viewModel: viewModel, settings: settings)
        }
    }
```
and `MainWindowController.swift:31–34`:
```swift
        NSApp.setActivationPolicy(.regular)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
```
There is no launch-reason check anywhere: `applicationDidFinishLaunching` is the only unconditional path and it always calls `show(...)`, which activates the app with `ignoringOtherApps: true`. The app is an `LSUIElement` accessory (`bundle/Info.plist:14`) and `LoginItem` registers it via `SMAppService.mainApp` (`LoginItem.swift:15`), so login-item launches take this path too.

**Why it matters in production:** With "Launch at login" enabled, every login produces a ~1080×720 window that takes focus with `ignoringOtherApps: true` and a Dock icon that appears/disappears (`MainWindowController.swift:39`). The user who logs in and immediately starts typing into another app has their first keystrokes delivered to Useful Voice instead. It also contradicts the product's own framing (a quiet menu-bar utility) and looks like malware behavior to a new user.

**Recommended fix:** Only open the window when the launch was interactive. Gate line 75–77 on a launch-reason check, e.g. `let launchedByUser = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier` evaluated after a `DispatchQueue.main.async` hop, or compare the parent PID against `launchd` (`getppid() == 1` for login-item launches) — then open the window only for user launches and rely on `applicationShouldHandleReopen` (`AppDelegate.swift:80–84`) for the rest. Keep `activate(ignoringOtherApps:)` only on the reopen path, and call `NSApp.setActivationPolicy(.regular)` only when the window is actually shown.

---

### HOOK-06 — No single-instance guard: two copies install two taps (double-toggle) and two HUDs
**Severity: High · Effort: S**

**File/lines:** `Makefile:47–52`; `Sources/UsefulVoiceApp/main.swift:3–9` (no guard exists anywhere — `grep` for `NSRunningApplication`/`runningApplications` over `Sources/` returns nothing).

**Evidence** — `Makefile:47–52`:
```make
# Install into /Applications and (re)launch so it appears in Finder.
install: bundle
	pkill -x Sadaa || true
	rm -rf "/Applications/Useful Voice.app"
	cp -R $(APP) "/Applications/Useful Voice.app"
	open "/Applications/Useful Voice.app"
```
`install` only removes `/Applications/Useful Voice.app`, and `make run` (`Makefile:44–45`) leaves a second live bundle at `dist/UsefulVoice.app` with the **same** `CFBundleIdentifier` (`ai.karko.sadaa`) and the same signature (`codesign -dvvv` → `Authority=Sadaa Local Signing`). The launch-at-login registration made through `SMAppService.mainApp` (`LoginItem.swift:15`) records whichever copy was running when the user enabled it.

**Why it matters in production:** Both copies share a TCC grant (same bundle id + same designated requirement), so both are Accessibility-trusted. If the login item points at `dist/UsefulVoice.app` while the user double-clicks `/Applications/Useful Voice.app` (or vice versa), two processes each create a session-wide `flagsChanged` tap: **one hotkey tap toggles dictation twice** — recording starts and immediately stops, transcription never happens, and two HUD pills render. This is reproducible on this machine right now: an instance is running from `/Applications/Useful Voice.app` (PID 979) while a stale `dist/UsefulVoice.app` also exists. Note the honest caveat: LaunchServices usually de-duplicates a plain `open` of a second copy with the same bundle id, so the trigger is a *launchd* (login-item) launch racing an `open`, or running `Contents/MacOS/Sadaa` directly — both are realistic.

**Recommended fix:** Add an explicit single-instance guard in `applicationDidFinishLaunching`: enumerate `NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)`, and if another instance exists, activate it (`activate(options: [.activateIgnoringOtherApps])`) and `NSApp.terminate(nil)` (or `exit(0)`) *before* `startHotkeys()`. Alternatively take an exclusive lock — `open(O_CREAT|O_EXCL)` on a file in `~/Library/Application Support/Sadaa/` with `flock`, or an `NSDistributedLock` — and quit if it cannot be acquired. Also make `make install` remove any previously-known copies (`dist/UsefulVoice.app`, `/Applications/Sadaa.app`) and add a `make uninstall` that unregisters the login item (`LoginItem.setEnabled(false)`) before deleting the bundle.

---

### HOOK-07 — `fatalError` on app-support failure = invisible crash loop for a login-item app
**Severity: Medium · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:129–135`.

**Evidence:**
```swift
        let appSupport = sadaaDir.appendingPathComponent("Recordings")
        guard let store = try? RecordingStore(directory: appSupport) else {
            fatalError("Cannot create recordings directory at \(appSupport.path)")
        }
```

**Why it matters in production:** This runs during `applicationDidFinishLaunching`. If the directory cannot be created (full disk, a restrictive sandbox/MDM profile, a permissions problem in `~/Library/Application Support`, or a corrupted `Sadaa` directory), the app traps. Because `LSUIElement` is true and the login item is registered, the crash happens on **every** launch and every login, with no window, no menu bar item and no message — the user sees only repeated crash reports and cannot disable the login item from inside the app (they must find it in System Settings → General → Login Items). A `fatalError` in a shipping GUI app also cannot be reported with a user-facing message.

**Recommended fix:** Replace the trap with a recoverable path: fall back to `FileManager.default.temporaryDirectory` (or `NSTemporaryDirectory()`), surface a clear HUD error/`NSAlert` ("Useful Voice cannot write its recordings folder …"), mark the app as degraded (disable dictation), and — critically — still install the status item so the user can open Settings and turn off "Launch at login". Reserve `fatalError`/`preconditionFailure` for programmer errors, not filesystem outcomes.

---

### HOOK-08 — `Info.plist` is minimal: no app category, no copyright, no dev region, hardcoded version
**Severity: Low · Effort: S**

**File/lines:** `bundle/Info.plist:5–18`.

**Evidence:**
```xml
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Useful Voice records your voice while dictating so it can be transcribed.</string>
</dict>
```

**Why it matters in production:** Version numbers are hand-edited and never derived from the build, so shipped binaries can be indistinguishable (no way to tell which build a user is running when triaging a crash, and `CFBundleVersion` must increase monotonically for updates to install/notarize cleanly). `LSApplicationCategoryType` is required for App Store submission and is what Finder/Launchpad use to categorise the app; `NSHumanReadableCopyright` appears in the About panel and in the Finder Get Info window; `CFBundleDevelopmentRegion` selects the default localization lookup. None of these break launching — they are the standard production metadata Apple's own "Bundle Resources" checklist asks for. `NSMicrophoneUsageDescription` is present and correct, and `LSUIElement` is correct for a menu-bar app, so nothing here is a functional defect.

**Recommended fix:** Add `LSApplicationCategoryType` (`public.app-category.productivity`), `NSHumanReadableCopyright`, `CFBundleDevelopmentRegion` (`en`), and `CFBundleInfoDictionaryVersion` (`6.0`) to `bundle/Info.plist`; generate `CFBundleShortVersionString`/`CFBundleVersion` from a single source of truth by substituting `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` in the Makefile (`plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" dist/.../Info.plist`) rather than editing the plist by hand.

---

### HOOK-09 — Not distributable/notarizable: self-signed identity, no hardened runtime, no timestamp, no entitlements, arm64-only
**Severity: High · Effort: M**

**File/lines:** `Makefile:7` and `Makefile:42`.

**Evidence** — `Makefile:7` and `42`:
```make
SIGN_IDENTITY = $(shell security find-identity -p codesigning 2>/dev/null | grep -q "Sadaa Local Signing" && echo "Sadaa Local Signing" || echo "-")
```
```make
	codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP)
```
Verified against the built bundle:
```
$ codesign -dvvv dist/UsefulVoice.app
Identifier=ai.karko.sadaa
CodeDirectory v=20400 size=8967 flags=0x0(none) hashes=274+3 location=embedded
Authority=Sadaa Local Signing
TeamIdentifier=not set
$ codesign -d --entitlements - dist/UsefulVoice.app   # → no entitlements
$ lipo -info dist/UsefulVoice.app/Contents/MacOS/Sadaa
Non-fat file: ... is architecture: arm64
```

**Why it matters in production:** `flags=0x0(none)` means no hardened runtime; there is no `--timestamp` (required for notarization) and no `--entitlements`; the signing identity is a locally generated self-signed certificate (`scripts/setup-signing.sh:38`) with no Team ID. `xcrun notarytool submit` will reject this bundle outright, so it cannot be shipped to anyone outside the developer's machine without the user bypassing Gatekeeper ("Apple cannot check it for malicious software", right-click → Open, or clearing `com.apple.quarantine`), and the `.p12`-imported cert is not trusted on other Macs. The build is also host-arch only (`swift build -c release`), so Intel Macs — which `Package.swift`'s `.macOS(.v14)` platform target otherwise supports — cannot run the app at all. `--deep` is documented by Apple as unsuitable for distribution signing (it signs nested code with the same options and cannot express entitlements per nested item).

**Recommended fix:** For distribution: sign with a Developer ID Application certificate, ad-hoc-verified with `codesign --force --options runtime --timestamp --entitlements bundle/UsefulVoice.entitlements --sign "Developer ID Application: …" dist/UsefulVoice.app`, where the entitlements file includes `com.apple.security.device.audio-input` (hardened runtime blocks microphone access without it), then `xcrun notarytool submit … --wait` and `xcrun stapler staple dist/UsefulVoice.app`. Build a universal binary with `swift build -c release --arch arm64 --arch x86_64` (or `xcodebuild -create-xcframework`-free `lipo` of two builds). Keep the self-signed identity only for the local `make run` path and say so explicitly in the Makefile (e.g. two targets: `bundle-local` vs `bundle-release`). Drop `--deep` once there is no nested code, and sign inner code first if there ever is.

---

### HOOK-10 — HUD swallows mouse clicks in its rectangle over the target app
**Severity: Medium · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/HUD/HUDPanel.swift:105–115`.

**Evidence:**
```swift
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the SwiftUI pill draws its own soft shadow
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Draggable: accept mouse and let the user move it by its body.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
```
The panel is sized to `hosting.fittingSize` plus a 22 pt transparent inset on all sides (`HUDView.swift:45`), so its live rect is noticeably larger than the visible capsule.

**Why it matters in production:** While dictating, the pill sits at bottom-center of the active screen (`HUDPanel.swift:145–147`) at `.statusBar` level and accepts mouse events. Any click landing in its rect — including the transparent padding — is consumed by the panel and instead starts a window drag, so the click never reaches the app being dictated into. Concrete failure: dictating into a bottom-center control (a terminal prompt, a video player's timestamp bar, a chat input) and the user clicks there to place the cursor — the app they are dictating into never sees the click, and the pill moves instead.

**Recommended fix:** Default to `panel.ignoresMouseEvents = true` so the pill is a pure overlay, and offer moving it another way (a "Move HUD" mode toggled from the status menu, or reposition presets). If drag-to-move must stay, enable mouse events only while a dedicated modifier is held (poll `NSEvent.modifierFlags` in the existing 30 Hz timer and flip `ignoresMouseEvents` accordingly), and shrink the hit area by dropping the 22 pt `.padding(22)` inset in favour of a real shadow inset that does not extend the window (e.g. draw the shadow inside a larger but mouse-transparent region using `panel.contentView?.hitTest` returning nil outside the capsule).

---

### HOOK-11 — HUD is invisible to VoiceOver: no announcement, no accessibility element
**Severity: Medium · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/HUD/HUDView.swift:22–51`; `Sources/UsefulVoiceApp/HUD/HUDPanel.swift:100–118`.

**Evidence** — `HUDView.swift:27–31` (the whole body has zero accessibility modifiers):
```swift
    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
```
For contrast, the status item *does* get a description — `AppDelegate.swift:558–559`:
```swift
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: "Useful Voice")
```
so the pattern was considered for the menu bar but never applied to the HUD, which is the only feedback channel for recording state.

**Why it matters in production:** This is a voice-dictation product; a meaningful share of its users run VoiceOver. The pill is ordered front on every state change but is never announced, is a borderless nonactivating panel with no accessibility role/label, and `orderFrontRegardless()` does not move VoiceOver focus. A blind user therefore gets no confirmation that recording started, that it is still running, that transcription started, or that delivery failed — the error HUD (`AppDelegate.swift:526–531`) is equally silent, meaning failed dictations look like the app ignoring input.

**Recommended fix:** Add an accessibility announcement on every state transition in `HUDPanel.show(_:)`, e.g. `NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [.announcement: plainText(display), .priority: NSAccessibilityPriorityLevel.high.rawValue])`, with a `plainText` mapping per `HUDDisplay` case ("Recording", "Recording, 12 seconds", "Transcribing", "Inserted", the error string, "Language: German"). Also set `panel.contentView?.setAccessibilityElement(true)`, `setAccessibilityRole(.staticText)` and a matching `setAccessibilityLabel`, and keep the existing `.accessibilityReduceMotion` handling (already correct).

---

### HOOK-12 — HUD re-creates the SwiftUI root view and forces synchronous layout 30×/s on the main thread
**Severity: Medium · Effort: M**

**File/lines:** `Sources/UsefulVoiceApp/HUD/HUDPanel.swift:38–57`; `Sources/UsefulVoiceApp/AppDelegate.swift:541–548`.

**Evidence** — `HUDPanel.swift:42–51`:
```swift
        let view = HUDView(display: display)
        if let hosting {
            hosting.rootView = view
        } else {
            buildPanel(with: view)
        }
        guard let panel, let hosting else { return }

        hosting.layout()
        let size = pillSize(hosting.fittingSize)
```
driven by `AppDelegate.swift:541–548`:
```swift
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                              repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(self.recordingStartedAt ?? Date()))
                self.hud.show(.recording(seconds: elapsed, level: self.currentLevel))
            }
        }
```
Note also that the level is *already* pushed at 30 Hz from `AppDelegate.swift:126–128`, and that `HUDView` runs its own `TimelineView(.animation)` at display rate (`HUDView.swift:146–151, 225–228`), so the visible animation does not need 30 Hz root-view replacement at all.

**Why it matters in production:** Every tick replaces the hosting view's `rootView`, invalidating the whole SwiftUI tree (`TimelineView`, `ProgressView`, shadow/capsule layers) and then forces a synchronous layout pass with `hosting.layout()`/`fittingSize` on the main thread, 30 times a second for the entire (potentially minutes-long) recording. That is steady main-thread work competes with the same thread that hosts the CGEvent tap and the audio-level callback, which is the exact coupling described in HOOK-01. On older Macs this shows up as a hot CPU during long dictations and as an input-tap stall risk; it also means the pill's own size animation fights the layout pass. Memory-wise the pattern is not a leak (the panel, hosting view and timer are all reused, `hideTimer` is invalidated on every `show`, and the animation completion handler captures `self` weakly), so this is a cost problem, not a leak problem.

**Recommended fix:** Stop rebuilding the view on ticks. Make `HUDView` observe a small `@Observable`/`ObservableObject` "HUD model" (`level`, `seconds`, `display`) and mutate those fields, so SwiftUI diffs instead of rebuilding; keep `display` (the discrete state) as the only `rootView`-level change. Reduce the level push rate to ~20 Hz and drive the elapsed time inside SwiftUI (`TimelineView`) instead of from a `Timer`. Keep panel resizing tied to a discrete state change rather than every tick, or use `panel.setContentSize` only when `size != panel.frame.size` (it mostly already does) but skip `reposition` on ticks when `userOrigin == nil` and the screen is unchanged.

---

### HOOK-13 — No screen-parameter observer; the pill's screen comes from `NSScreen.main`
**Severity: Medium · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/HUD/HUDPanel.swift:133–153`. There is no `didChangeScreenParametersNotification` observer anywhere in `Sources/` (`grep` for `NSWorkspace.shared.notificationCenter` / `didChangeScreenParameters` returns nothing).

**Evidence:**
```swift
    /// The screen the user is currently working on. NSScreen.main follows the
    /// active window's screen, which is where a dictation target lives.
    private var activeScreen: NSScreen {
        NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
    }
```
```swift
    private func reposition(_ panel: NSPanel, size: CGSize) {
        let visible = activeScreen.visibleFrame
```
(`NSScreen.screens[0]` is also a hard index — unreachable today because `.first` already covers the empty case, but it should be a safe unwrap.)

**Why it matters in production:** (a) Multi-monitor: `NSScreen.main` is the screen containing the key window; Useful Voice is an accessory app that deliberately never becomes active, so the "key window" is usually another app's window — the lookup happens to work most of the time but is not a guarantee, and the documented replacement is `NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }` (follow the pointer) or the frontmost app's window screen via `CGWindowListCopyWindowInfo`. When it picks the wrong display the pill appears on a monitor the user is not looking at, and they get no feedback that the hotkey worked. (b) Display changes: with no observer, a pill that is mid-fade or being read stays at coordinates on a display that has just been unplugged (or moves with the mirrored/rearranged geometry) until the next `show()`. Clamping on the next `show()` (`HUDPanel.swift:142–143`) does recover the position, so this half is only a transient artifact — I flag it as the lower-confidence half of this finding.

**Recommended fix:** Observe `NSApplication.didChangeScreenParametersNotification` (and `NSWorkspace.didActivateApplicationNotification` if you want to follow focus) in `HUDPanel`, and on change re-run `reposition` for the live panel and drop `userOrigin` if its screen is gone. Replace `activeScreen` with "screen containing the mouse" (`NSEvent.mouseLocation`) or the frontmost app's screen, keeping `NSScreen.main` only as a last-resort fallback; replace `NSScreen.screens[0]` with a guard/`return`.

---

### HOOK-14 — HUD hide/recording timers use default run-loop mode, so they stall during menu tracking and window drags
**Severity: Low · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/HUD/HUDPanel.swift:84–87`; `Sources/UsefulVoiceApp/AppDelegate.swift:472–482, 541–548`.

**Evidence** — `HUDPanel.swift:84–88`:
```swift
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
```
and `AppDelegate.swift:472–473`:
```swift
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0,
                                           repeats: true) { [weak self] _ in
```
`Timer.scheduledTimer` installs on the current run loop in `.default` mode only.

**Why it matters in production:** While the status menu is open (tracking mode) or the user is dragging a window, the run loop runs in `.eventTracking`, so these timers do not fire: the recording pill's elapsed time and level freeze during a drag (the same drag that HOOK-10 says the pill itself intercepts), and a `hide(after: 6)` error HUD lingers well past its intended lifetime. The Accessibility poll also pauses, delaying hotkey startup if the user is holding a menu open while granting permission. Cosmetic/UX only, no data loss.

**Recommended fix:** Create the timers with `Timer(timeInterval:repeats:block:)` and add them to `.common` explicitly: `let t = Timer(timeInterval: …) { … }; RunLoop.main.add(t, forMode: .common)`. (Or drive the recording HUD from a `SwiftUI.TimelineView`, which removes the timer entirely — see HOOK-12.)

---

### HOOK-15 — Window frame is never persisted and is re-centered on every open; no state restoration
**Severity: Low · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/MainWindowController.swift:24–35`. `grep` for `setFrameAutosaveName`, `restorable`, `restoration` across `Sources/` and `bundle/` returns nothing.

**Evidence:**
```swift
            window.setContentSize(Self.defaultContentSize(on: NSScreen.main))
            window.minSize = NSSize(width: 960, height: 640)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.center()
```
`window.center()` is called both when the window is created *and* on every subsequent `show()`, and `RootView`'s `@State private var selection: SidebarSection = .home` (`RootView.swift:38`) is a default, not a restored value.

**Why it matters in production:** A user who moves the window to their second display, resizes it, and closes it gets it re-centered on the main screen the next time they open it from the menu bar — every single time. Because the same path is used unconditionally at launch (HOOK-05), the position churn is constant. Since `NSWindow.isRestorable` defaults to `true` and the app implements no restoration delegate method, macOS 14 also logs `WARNING: Secure coding is not enabled for restorable state! … applicationSupportsSecureRestorableState:` on each launch (noisy console/crash-log triage; I have not run the app to confirm the log line, so treat the log claim as indicative rather than verified).

**Recommended fix:** Call `window.setFrameAutosaveName("MainWindow")` once at creation (which persists frame and cascading position and re-applies it on reopen), and remove the unconditional `window?.center()` from the `show()` path — center only when there is no saved frame (`window.setFrameUsingName("MainWindow") == false → window.center()`). Persist the selected sidebar section in `UserDefaults` (or move `selection` into `UsefulVoiceViewModel`), and implement `func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }` on `AppDelegate`.

---

### HOOK-16 — Menu bar is missing a Window menu (⌘W/⌘M dead) and "Settings…"/⌘, does not open Settings
**Severity: Medium · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:90–120` (only App + Edit menus) and `617–621`; `Sources/UsefulVoiceApp/RootView.swift:38`.

**Evidence** — `AppDelegate.swift:617–621`:
```swift
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openMainWindow),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
```
```swift
    @objc private func openMainWindow() {
        if let viewModel {
            mainWindow.show(viewModel: viewModel, settings: settings)
        }
    }
```
`openMainWindow` cannot select a page: `RootView.swift:38` holds `@State private var selection: SidebarSection = .home` and nothing outside the view can change it.

**Why it matters in production:** (a) "Settings…" and ⌘, bring the window forward on whatever page was last shown — on a fresh install that is "Dictate", not Settings — so the primary configuration entry point (where the Deepgram key and hotkeys are set) does not do what it says; a user who has never opened the sidebar will think there is no settings page. (b) The main menu has no `Window` menu, so AppKit has no `performClose:`/`performMiniaturize:` items and **⌘W and ⌘M do nothing** in the app's own window even though the window has `.titled, .closable, .miniaturizable` (`MainWindowController.swift:18`). Since the window is the app's only means of configuration, a user who expects ⌘W to close it will instead leave it open in front of the app they are dictating into. There is also no `About Useful Voice` item, so version/copyright is unreachable from inside the app (see HOOK-08).

**Recommended fix:** Add a Window menu with the standard items (`Close` → `performClose:` ⌘W, `Minimize` → `performMiniaturize:` ⌘M, `Zoom`, `Bring All to Front`), and an About item (`orderFrontStandardAboutPanel:`) in the app menu. For "Settings…", route through an explicit navigation hook: add `@Published var selectedSection: SidebarSection` to `UsefulVoiceViewModel` (or post a `Notification` name like `.usefulVoiceOpenSettings` that `RootView` observes with `.onReceive`), set it to `.settings` in a new `openSettings()` action, and point the menu item (and any Home-page "Grant access" affordance) at it.

---

### HOOK-17 — Microphone state is checked only at launch; a revoked mic is only discovered after a failed dictation; denial text has no deep link
**Severity: Medium · Effort: M**

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:666–678`.

**Evidence:**
```swift
    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async { [weak self] in
                    self?.hud.show(.error(
                        "Enable Microphone for Useful Voice in System Settings."))
                    self?.hud.hide(after: 6)
                }
            }
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                       as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
```
Nothing anywhere else calls `AVCaptureDevice.authorizationStatus(for: .audio)` or `requestAccess` again: `toggleDictation()` (`AppDelegate.swift:41–43`) starts a recording without consulting the microphone state, and `DictationController.process` only reports "Recording was too short." (`DictationController.swift:210–213`) when the capture produced no audio.

**Why it matters in production:** Microphone access can be revoked while the app runs (Privacy & Security → Microphone, an MDM privacy profile, or a macOS update resetting TCC). The user then taps the hotkey, the HUD shows "Recording", they speak, and the only outcome is the generic "Recording was too short." error — the app never says *why*, and it will never say why until the next relaunch. Neither denial message offers a route to the setting; the user must navigate System Settings by hand, and System Settings' Microphone list only shows apps that have requested access (which does happen at launch, so the row at least exists).

**Recommended fix:** Check the status on the dictation path, not just at launch: at the top of `toggleDictation()`/the `.idle → .recording` transition, call `AVCaptureDevice.authorizationStatus(for: .audio)`; on `.denied`/`.restricted` show a dedicated HUD error ("Microphone access is off — enable it in System Settings")) and deep-link with `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)`. On `.notDetermined`, call `requestAccess` and defer the start until the answer arrives. Mirror the same treatment for Accessibility (`…?Privacy_Accessibility`) and add a "Grant access" affordance on the Home page that opens the right pane (there is already a "Grant access" label at `HomePage.swift:60`, but it is text, not an action).

---

### HOOK-18 — Accessibility prompt re-shown on every launch; the only in-app guidance is a 6-second toast
**Severity: Medium · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:676–678` (prompt) and `469–482` (toast + poll).

**Evidence:**
```swift
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                       as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
```
```swift
        hud.show(.error("Enable Accessibility for Useful Voice in System Settings to use the hotkey."))
        hud.hide(after: 6)
```

**Why it matters in production:** `requestPermissions()` runs on every launch and always passes `prompt: true`, so while the app is untrusted macOS puts up its Accessibility alert at every single launch — including for a user who has deliberately decided not to grant it, and including every login when the login item is enabled. That is the classic "app nags me forever" review complaint and it is the opposite of what the poll's design intent (silent re-check) suggests. The alert fires before the main window appears (`AppDelegate.swift:73` vs `75–77`), and if the user dismisses it the only remaining explanation is a 6-second pill at bottom-center; after that the app looks completely dead (the settings footer dot is the only persistent signal, and it is hidden behind HOOK-16's navigation gap).

**Recommended fix:** Call `AXIsProcessTrustedWithOptions` with the prompt only on an explicit user action (a "Grant Accessibility access" button in Settings/Home, and the HUD error's own affordance), and use the non-prompting `AXIsProcessTrusted()` for the launch-time check — the 2 s poll already covers the "user grants it later" case and does not need the alert. Add a persistent, actionable state: keep the Home page's status card showing "Accessibility not granted — Open System Settings" with a deep link (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`), and make the HUD error sticky until acknowledged rather than `hide(after: 6)`.

---

### HOOK-19 — Login item: `.requiresApproval` treated as "off", no `openSystemSettingsLoginItems()`, no path validation after the app moves
**Severity: Medium · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/LoginItem.swift:6–22`; `Sources/UsefulVoiceApp/Pages/SettingsPage.swift:285–300` (and `308` for the read-back).

**Evidence** — `LoginItem.swift:6–22`:
```swift
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Throws so the caller
    /// can surface failure instead of silently swallowing it.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
```
and `SettingsPage.swift:288–297`:
```swift
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    launchAtLogin = newValue
                    saveMessage = "Login setting updated"
                    saveIsError = false
                } catch {
                    saveMessage = "Could not update login setting"
                    saveIsError = true
                }
```

**Why it matters in production:** `SMAppService.Status` has four cases and the code only distinguishes `.enabled`. When the user disables the item in System Settings → General → Login Items (or when a prior registration needs re-approval), the status is `.requiresApproval`: `isEnabled` reports `false`, so the toggle shows OFF while the system still considers the item registered, and toggling it ON calls `register()` again — which is the documented error path for an already-registered item rather than the documented re-approval flow (`SMAppService.openSystemSettingsLoginItems()`). The user sees the generic "Could not update login setting" with no indication that the fix is to approve the item in System Settings. Separately, `SMAppService.mainApp` records the **bundle path**: `make install` (`Makefile:50–52`) deletes and recreates `/Applications/Useful Voice.app`, and `make run` runs the app from `dist/UsefulVoice.app`. If the user enables launch-at-login while running from `dist/` and later installs to `/Applications` (or vice versa), the login item keeps pointing at the old path and will either fail silently at login or launch a *second* copy from the stale bundle — which is exactly the duplicate-instance precondition in HOOK-06.

**Recommended fix:** Model the full status: return/treat `.requiresApproval` as "registered but needs approval", surface it distinctly in the UI ("Approve in System Settings → Login Items") and call `SMAppService.openSystemSettingsLoginItems()` from that affordance instead of calling `register()` again. Wrap `register()`/`unregister()` errors with the underlying `SMAppServiceErrorDomain` code so the message is actionable. After a move/rename, re-register: at launch, if `SMAppService.mainApp.status == .enabled` compare the recorded item to `Bundle.main.bundleURL` (or simply `unregister()` then `register()` when `Bundle.main.bundleURL` differs from the last known path stored in settings) so a relocated app does not leave a dangling login item. Also make `make install`/a new `make uninstall` call `LoginItem.setEnabled(false)` before deleting the old bundle.

---

### HOOK-20 — No termination hooks: quitting mid-recording loses the recording; no teardown of tap/timers
**Severity: Low · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:8` (the delegate conformance) and `67–84` — the only lifecycle methods implemented are `applicationDidFinishLaunching` and `applicationShouldHandleReopen`. `grep` for `applicationWillTerminate`, `applicationShouldTerminate` and `applicationSupportsSecureRestorableState` over `Sources/` returns nothing.

**Evidence** (the entire implemented lifecycle surface):
```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
```
```swift
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }
```

**Why it matters in production:** ⌘Q (or the menu's "Quit Useful Voice", `AppDelegate.swift:95–97`) terminates immediately even while `controller.state == .recording`. The audio file the recorder is writing is left truncated/incomplete in `~/Library/Application Support/Sadaa/Recordings` and is never pruned, the microphone indicator disappears without a stop chime, and nothing is transcribed. Quitting during `.transcribing`/`.delivering` also loses the in-flight transcript with no explanation; the same is true for the menu's Quit while a retry is running. There is also no `applicationWillTerminate` to invalidate the two timers or disable the tap, so a slow shutdown can leave a stale tap (harmless in practice, because the process exit closes the mach port, but it is the kind of teardown a production app should have for `NSApplication.terminate` paths in tests/automation).

**Recommended fix:** Implement `func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply`: if `controller.state == .recording`, call `controller.cancel()` (or stop-and-transcribe, preferred), invalidate `recordingTimer`/`axPollTimer`, and return `.terminateNow` after the state settles; return `.terminateLater` plus `NSApp.reply(toApplicationShouldTerminate:)` if you want to finish an in-flight transcription. Add `applicationWillTerminate` for the synchronous teardown (`hotkeys.stop()`, timer invalidation) so automated tests and `pkill`/`SIGTERM` paths are deterministic.

---

### HOOK-21 — Esc `keyDown` is consumed but its `keyUp` is not (mask lacks `.keyUp`)
**Severity: Low · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/HotkeyManager.swift:72–73` (mask) and `137–141` (consumption).

**Evidence:**
```swift
        case .keyDown where keycode == Self.escapeKeycode:
            if isRecordingActive() {
                DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                return nil // consume Esc so the frontmost app never sees it
            }
```

**Why it matters in production:** Because `eventsOfInterest` excludes `.keyUp`, the matching `keyUp` for Escape is delivered to the ordinary event stream and the callback never sees it, so while a recording is active the app you are dictating into receives an **unpaired** `keyUp`. Most AppKit text fields ignore a keyUp, but some targets do care: games and remoted/game-streamed apps commonly track key state on down/up and can be left believing Esc is still held (or with a stuck-key flag), and JS/`keyup`-driven handlers on the web side (e.g. closing a dropdown, cancelling a drag) can fire spuriously when the user presses Esc to cancel dictation.

**Recommended fix:** Add `(1 << CGEventType.keyUp.rawValue)` to the mask and, when `isRecordingActive()` and the keycode is Escape, swallow the matching keyUp as well (returning `nil` for both), so the pair is symmetric. While you are there, this same mask change gives you a free invalidation signal for HOOK-03.

---

### HOOK-22 — `AppDelegate` is only referenced by a **weak** `NSApplication.delegate` from a local `let`
**Severity: Medium · Effort: S — flagged: latent / less than fully certain**

**File/lines:** `Sources/UsefulVoiceApp/main.swift:3–9`; AppKit declaration `NSApplication.h:194`.

**Evidence** — `main.swift:3–9`:
```swift
MainActor.assumeIsolated {
    UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
```
AppKit declares the property weakly (`NSApplication.h:194`):
```objc
@property (nullable, weak) id<NSApplicationDelegate> delegate;
```
and `grep` confirms `AppDelegate` has no other reference in the codebase (`main.swift:6` is the only mention).

**Why it matters in production:** The delegate owns everything this audit is about — the status item, the hotkey manager, the HUD, the view model, the login-item UI. `delegate` is a *local* inside the `assumeIsolated` closure (not a top-level global), and its last use is the weak assignment on line 7. Swift's ARC explicitly permits releasing a value after its last use (`withExtendedLifetime` exists for this reason), so an optimizer is free to insert the release before `app.run()`; with a zeroing weak reference, `NSApp.delegate` would then become `nil`. The failure mode is severe and silent: a process with an accessory activation policy, no status item, no hotkey and no window — the user sees nothing and can only kill it via Activity Monitor. I am flagging this as **latent/uncertain**: in practice this Apple-documented pattern usually survives (debug builds keep locals to end of scope, and in release the ARC optimizer often does not shorten this particular lifetime), and I could not compile to check which happens here. The fix is trivial and removes the question entirely.

**Recommended fix:** Keep a strong reference that cannot be optimized away: declare the delegate at top level in `main.swift` (`let delegate = AppDelegate()`) and set it inside the closure, or store it in a global/static (`private static var shared: AppDelegate?`), which is what `NSApplicationMain` effectively does. Do not rely on the local's lexical scope.

---

### HOOK-23 — `AppleShowScrollBars` is written into the user's global defaults domain on every launch
**Severity: Low · Effort: S**

**File/lines:** `Sources/UsefulVoiceApp/main.swift:4`.

**Evidence:**
```swift
    UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
```

**Why it matters in production:** This changes a *global* macOS appearance preference for the whole machine from a menu-bar dictation utility, without asking and without an option, and it does so on every launch (overwriting whatever the user set in System Settings → Appearance → "Show scroll bars"), so the setting can never be restored by the user while the app runs at login. The value nothing else in the codebase reads or reverses (`grep` finds no other reference, and it is unrelated to `ThinScrollbar.install()` on line 68 of `AppDelegate`). It is an unexpected, non-consensual system modification — a common App Store review rejection reason — and it does not even take effect until the affected apps relaunch.

**Recommended fix:** Remove the write. If overlay scrollbars are needed for the app's own UI, scope it to the app: `UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")` under the app's own domain does not work for this key, so instead style the app's own `NSScroller`s (`NSScroller.preferredScrollerStyle = .overlay`) or set the window's `scrollerStyle`. If you keep the global change, gate it behind an explicit opt-in in Settings and reset it to `.automatic`-equivalent on quit.

---

### HOOK-24 — Fn/Globe (`63`) as a hotkey option conflicts with the system Globe key
**Severity: Low · Effort: S — flagged: uncertain (not verified on a live system)**

**File/lines:** `Sources/UsefulVoiceApp/HotkeyManager.swift:17` and `54`.

**Evidence:**
```swift
        .init(label: "Fn / Globe", keycode: 63),
```
```swift
        case 63: return .maskSecondaryFn        // fn / globe
```

**Why it matters in production:** On modern Macs the Fn/Globe key is consumed by macOS "Press 🌐 key to" system settings (default: "Show Emoji & Symbols" / input-source switching) and by the on-screen keyboard; the key also emits `flagsChanged` only in some configurations. Two failure modes are plausible: the tap never sees the tap (the system handles the key earlier), or the user's dictation toggle *and* the system Globe action both fire (emoji picker opening over a recording). I could not verify the delivery behavior without running the app on hardware, so this is flagged as a lower-confidence item — the concrete, verifiable part is that the option is offered without any warning, and that a user who selects it may find the feature unusable. `maskSecondaryFn` is also asserted by synthetic/system events, which makes the `flags.contains` test in HOOK-04 more likely to misreport.

**Recommended fix:** Either drop `Fn / Globe` from `HotkeyOption.all`, or keep it and detect it through IOKit (`IOHIDManager` with usage page `kHIDPage_KeyboardOrKeypad`, usage `kHIDUsage_KeyboardPower`/`0x03`) rather than `flagsChanged`, and add an inline warning in the Settings picker that macOS's Globe-key action may take precedence (with a pointer to System Settings → Keyboard → "Press 🌐 key to"). Add a "test your hotkey" affordance so the user can confirm the choice works before relying on it.

---

## Lower-confidence notes (explicitly flagged)

* **HOOK-22** (weak delegate + local `let`) — the weak declaration is verified; whether ARC shortens the lifetime in this build is not verifiable without compiling.
* **HOOK-13(a)** (wrong monitor) — `NSScreen.main` semantics for an app that is never key are the uncertain part; the missing `didChangeScreenParametersNotification` observer is certain.
* **HOOK-19** (`.requiresApproval` → `register()` throws) — the status modelling gap is certain; the exact `SMAppServiceErrorDomain` code returned for a re-register of a `.requiresApproval` item is from documented/community behavior, not verified on this machine.
* **HOOK-24** (Fn/Globe) — the option's presence is certain; its runtime behavior on current hardware is not.
* **HOOK-15** (macOS "Secure coding is not enabled for restorable state" log) — the missing method is certain; the log line itself is inferred.

## Things I verified and found to be *correct* (contrary to the audit brief's suspicion)

* **The bundle is consistent and launchable.** `CFBundleExecutable = Sadaa` (`bundle/Info.plist:8`) matches the Makefile's `cp .build/release/UsefulVoiceApp …/MacOS/Sadaa` (`Makefile:39`); `CFBundleIconFile = Sadaa` (line 9) matches the copied `Sadaa.icns` (line 40); `assets/branding/Sadaa.icns` **exists** (106 801 bytes, `file` reports a valid `ic12` icon, `plutil -lint` passes, and `iconutil`-format `Sadaa.iconset` sources are in the repo). The on-disk `dist/UsefulVoice.app` has the plist byte-identical to `bundle/Info.plist`, the binary present, both resources present, and a valid signature. The "Useful Voice" vs "Sadaa" naming split is intentional (product name vs. internal/bundle name) and does not break launching or `open`ing.
* **`NSMicrophoneUsageDescription` is present and accurate** (`bundle/Info.plist:16–17`); `LSUIElement` is `true` (line 14) as required for a menu-bar app.
* **Tap creation handles the untrusted case correctly** (`AppDelegate.swift:461–465`): the code explicitly avoids the "`tapCreate` returns a non-nil but dead tap" trap by gating on `AXIsProcessTrusted()` *before* trusting a successful `start()`, and polls until the grant arrives so no relaunch is needed. This is better than most hotkey implementations.
* **Both tap-disable notifications are handled by name** (`HotkeyManager.swift:112`), and returning the event unchanged there is the correct response shape.
* **`HotkeyManager.deinit` calls `stop()`** (`HotkeyManager.swift:102–107`), closing the use-after-free hole created by `Unmanaged.passUnretained(self)` in `userInfo` (line 84). `stop()` is idempotent and removes the run-loop source as well as disabling the tap.
* **`onToggle`/`onCancel`/`onLanguageSwitch` are all marshalled with `DispatchQueue.main.async`** (`HotkeyManager.swift:129, 135, 139`), so no dictation work happens inside the tap callback — including the state-changing `controller.toggle()` and the Esc cancel.
* **Tap vs. hold is genuinely distinguished**, and the recognizer is pure, injected-clock and unit-tested for quick tap, slow hold, combo, up-without-down, reset-after-fire and fresh-tap-after-invalidated-combo (`RightOptionTapRecognizer.swift:22–36`, `RightOptionTapRecognizerTests.swift:5–45`).
* **Key repeat cannot double-fire the hotkey**: repeat generates `keyDown` (not `flagsChanged`), which only invalidates pending taps — the activation path is modifier-only.
* **Hotkey reassignment takes effect live** without recreating the tap, because the callback filters on `activationKeycode`/`languageSwitchKeycode` per event (`HotkeyManager.swift:36–40`, `AppDelegate.swift:441–447`), and `HotkeyAssignment.setDictation`/`setLanguageSwitch` swap the keys on collision so the two can never share a keycode through the UI (`AppSettings.swift:26–40`).
* **The HUD is a properly non-activating overlay**: `.nonactivatingPanel` + `orderFrontRegardless()` + `hidesOnDeactivate = false` never steals focus from the dictation target, level `.statusBar` sits above ordinary windows, and `collectionBehavior` correctly includes `.canJoinAllSpaces` + `.fullScreenAuxiliary` + `.ignoresCycle` so the pill survives full-screen apps and Mission Control (`HUDPanel.swift:100–115`).
* **No memory leak on repeated show/hide**: the panel/hosting view/timer are created once and reused, `hideTimer` is invalidated on every `show()`, the fade completion handler and all timers capture `self` weakly, and the fade-out has a correct re-show guard (`HUDPanel.swift:39–48, 61–76, 166–181`). (The 30 Hz *churn* in HOOK-12 is a performance cost, not a leak.)
* **`HUDPanel` is defensive about visibility in a way most HUDs are not**: it floors the size (`pillSize`/`minSize`, lines 32, 126–129) so an unresolved `TimelineView` cannot collapse the pill to zero pixels, is `reduceMotion`-aware for both motion and cross-fade (lines 34–36, 67–75, 169), clamps a dragged origin into the visible frame (lines 139–161), and distinguishes real user drags from its own repositioning so the drag position is preserved (`windowDidMove` + `isProgrammaticMove`, lines 27, 52–56, 148–152, 185–192).
* **`HotkeyManager` respects Secure Input** (`AppDelegate.swift:231` → `IsSecureEventInputEnabled()`), so dictation is refused in password fields, and the tap consumes Esc only while actually recording (`HotkeyManager.swift:137–141`), so Escape is never hijacked from other apps in the idle state.
* **Window/lifecycle hygiene is otherwise sound**: `NSApp.setActivationPolicy(.accessory)` at launch (`main.swift:8`) with `.regular` only while the window is open and a correct revert in `windowWillClose` (`MainWindowController.swift:37–40`), `isReleasedWhenClosed = false` so the window survives close/reopen, the app correctly does not quit when the last window closes (the dictation hotkey and status item keep working, which is the documented intent), and `applicationShouldHandleReopen` (`AppDelegate.swift:80–84`) returns `true` so a relaunch from Finder re-opens the window.
* **Responsive-layout rules and tests are correct and coherent** (`ResponsiveLayoutRules.swift:6–53`, `ResponsiveLayoutRulesTests.swift`): the header axis decision is `available >= accessory + title + spacing`, `rows` preserves source order and only breaks before an item when the row is non-empty (so a single over-wide item still gets placed), and `remainingHeight` cannot go negative (`max(0, …)`).
