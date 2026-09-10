# Useful Voice — Dictation Pipeline Audit (audio → transcription → delivery)

**Scope:** `DictationController`, `Audio/*` (recorder, WAV writer, store, watchdog, chime synth),
`Transcription/*`, `ProviderHealth/*`, `Delivery/DeliveryPolicy`, `UsefulVoiceApp` (TextInserter,
Clipboard, ChimePlayer), `Settings/Keychain`, plus the relevant tests and the app wiring in
`AppDelegate` (needed to judge reachability of each path).

**Method:** static read-only review. Every claim below is quoted from the file at the cited line.
Findings marked *(unverified)* are ones I could not fully confirm from source alone — they are
listed explicitly in the last section so they are not over-trusted.

**Provenance / workspace churn — read this before acting on a line number.** The working tree was
being edited by another writer *while* this audit ran. Two in-scope files changed under me:
`Audio/AudioRecorder.swift` and `Audio/RecordingStore.swift` were both rewritten at 14:23 (after my
first read), and two new files appeared in the dependency path (`Transcription/KeytermBudget.swift`,
plus edits to `LanguageMemory/MemoryBiasBuilder.swift`). Findings PIPE-02, PIPE-09 and PIPE-12 have
been **re-verified against the post-change content** and their wording updated; the other sixteen
findings were verified against files whose modification time predates this audit and which I
re-checked as unchanged. The MD5 of every file as audited is recorded in the appendix at the end of
this report, so a later diff can tell whether a line number has drifted. If you are reading this
after the working tree has moved again, re-verify before quoting line numbers.

**Note on the build mode:** `Package.swift:1` declares `swift-tools-version:5.9` with no
`swiftLanguageMode` / `-strict-concurrency` setting, so the package compiles in Swift 5 language
mode. None of the concurrency findings below are *diagnosed* by the compiler today; they are latent
until the flag is enabled (which is the point of enabling it).

---

## Findings table

| ID | Title | Severity | File:line | Effort |
|----|-------|----------|-----------|--------|
| PIPE-01 | Hard 15 s total deadline covers upload **and** server processing — long dictations can never succeed | Critical | `DeepgramProvider.swift:31,68,98-100` | S |
| PIPE-02 | No `AVAudioEngineConfigurationChange` / device-change handling: capture dies silently and the recording never auto-stops | High | `AudioRecorder.swift:89-148,184-187,209-214` | M |
| PIPE-03 | "Paste landed" proof is a bare `after > before` char count re-read from the *current* focused element | High | `TextInserter.swift:118-140` | M |
| PIPE-04 | User's clipboard is destroyed on every unproven delivery, with the only copy held in memory | High | `TextInserter.swift:87,110-111,146-148`, `Clipboard.swift:35-40` | M |
| PIPE-05 | Capture-time disk-write failures swallowed (`try? … append`) → truncated audio uploaded as if complete | Medium | `AudioRecorder.swift:240-243`, `WavWriter.swift:17-24` | S |
| PIPE-06 | No cancellation and no overall timeout for transcription/delivery; Esc only works while recording | Medium | `DictationController.swift:138-142,305-313`, `HotkeyManager.swift:138-141` | M |
| PIPE-07 | Delivery blocks the main thread: full clipboard deep-copy (incl. lazy types) + synchronous cross-process AX calls | Medium | `TextInserter.swift:87-94,102-104,190-204`, `Clipboard.swift:19-31` | M |
| PIPE-08 | `clearContents()` + unchecked `writeObjects` — clipboard can be left empty, losing user data *and* the dictation | Medium | `Clipboard.swift:35-40`, `TextInserter.swift:163-169` | S |
| PIPE-09 | `fatalError` on recordings-directory failure ⇒ crash at launch on a disk/permission problem | Medium | `AppDelegate.swift:133-135` | S |
| PIPE-10 | Zero logging/diagnostics anywhere; errors exist only as a HUD message that hides after 6 s | Medium | `AppDelegate.swift:526-531` (no `Logger`/`os_log` in `Sources/`) | M |
| PIPE-11 | No transient-failure resilience: single provider, no retry/backoff, no 429 / `Retry-After` handling | Medium | `AppDelegate.swift:408-418`, `DictationController.swift:219-228`, `DeepgramProvider.swift:107-109` | M |
| PIPE-12 | Permission denial is still not checked (`authorizationStatus`) and `AudioRecorderError` has no `LocalizedError` ⇒ HUD shows "error 4" | Medium | `AudioRecorder.swift:23-29,89-102`, `DictationController.swift:162,171` | S |
| PIPE-13 | Unsynchronized `watchdog`/`startedAt`/`autoStopFired` between `start()` (main) and a mid-flight tap callback *(unverified)* | Medium | `AudioRecorder.swift:124-126,209-213` vs `150-169` | M |
| PIPE-14 | Allocating an `AVAudioPCMBuffer` and running `AVAudioConverter` on the real-time tap thread *(partially unverified)* | Medium | `AudioRecorder.swift:216-235` | M |
| PIPE-15 | Unbounded response buffering; whole WAV read into RAM and set as `httpBody` | Medium | `DeepgramProvider.swift:94-110` | S |
| PIPE-16 | Raw dictation audio + transcripts stored unencrypted under Application Support, backup-eligible, no retention control | Medium | `RecordingStore.swift:8-12,50-53`, `AppDelegate.swift:129-140` | M |
| PIPE-17 | `pendingRawMode` is never reset on the early-return paths (currently unreachable from the app UI) | Low | `DictationController.swift:210-214,230-239,247-251,261,290` | S |
| PIPE-18 | `retryLast()` can target an already-pruned file and reports the wrong reason | Low | `DictationController.swift:118-130,208-214`, `RecordingStore.swift:55-65` | S |
| PIPE-19 | Keychain: no accessibility/data-protection attribute; `delete` result and lookup failures are indistinguishable from "not configured" | Low | `Keychain.swift:18-37,39-54,74-81` | S |
| PIPE-20 | No `applicationWillTerminate` hook: an in-progress WAV is never finalized and a pending clipboard restore never runs | Low | `AppDelegate.swift:8-45,176-184` | S |

---

## Details

### PIPE-01 — Hard 15 s total deadline covers upload *and* server processing — Critical

**Evidence** — `Sources/UsefulVoiceCore/Transcription/DeepgramProvider.swift:30-31,63-68,93-100`

```swift
/// Wall-clock deadline for one attempt (matches the old provider chain).
static let totalDeadline: TimeInterval = 15
...
        request.httpBody = audio
        request.timeoutInterval = Self.totalDeadline
...
            (data, response) = try await Self.withDeadline(seconds: Self.totalDeadline) { [session] in
                try await session.data(for: request)
            }
```

`withDeadline` (`:75-91`) races the request against `Task.sleep(15s)` and throws
`ProviderError.timedOut`. The doc comment confirms it is a *total* cap, not an idle cap.

**Why it matters.** The recorder is capped at 10 minutes (`AudioRecorder.swift:51-52,78-79`:
`maxDuration: TimeInterval = 600`), and 16 kHz/mono/16-bit is 32 000 bytes/s, so a 600 s dictation
is **19.2 MB**. Delivering that inside 15 s requires ~10.2 Mbps of *sustained useful uplink* — and the
same 15 s also has to cover the TLS handshake and Deepgram's own decode of a 10-minute file, which is
not instant. So for exactly the use case the app advertises (up to 10 minutes of dictation), the
request is aborted mid-upload on essentially any ordinary connection, the user sees
`Transcription failed: timed out`, and the retry re-uploads the same 19.2 MB and times out again.
Even a 2-minute dictation (3.84 MB) needs a sustained 2 Mbps, which is unattainable on tethering or
a congested Wi-Fi network. The audio is retained (`DictationController.swift:233-237`) so nothing is
*lost*, but the feature is dead for long recordings.

**Recommended fix.** Make the deadline a function of payload size rather than a constant:
`let deadline = 30 + Double(bytes) / 64_000` (≈20 s per MB, i.e. a ~0.5 Mbps floor) computed from
`FileManager` size before the request; set both `request.timeoutInterval` and the `withDeadline`
value from it; keep a small constant floor (≥20 s) so short clips stay snappy. Additionally use
`session.upload(for:fromFile:)` (see PIPE-15) so the deadline measures wall clock rather than
buffered-body construction.

**Effort:** S.

---

### PIPE-02 — No device-change / engine-configuration handling — High

**Evidence** — `Sources/UsefulVoiceCore/Audio/AudioRecorder.swift:128-136,184-187,209-214`

```swift
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter,
                          targetFormat: targetFormat)
        }
        engine.prepare()
        do { try engine.start() } catch { ... }
...
    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
...
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        if !autoStopFired,
           watchdog.observe(rms: rms, at: elapsed) || elapsed > maxDuration {
```

There is **no observer for `AVAudioEngineConfigurationChange`** anywhere in the repo (grep for
`ConfigurationChange`, `routeChange`, `defaultDevice` over `Sources/` returns nothing). The format is
resolved once at `:92` (`input.outputFormat(forBus: 0)`) and the tap is installed once.

**Why it matters.** Both control paths that end a recording — the silence watchdog and the 10-minute
`maxDuration` cap — live *inside the tap callback*. When the input device disappears (AirPods
disconnect, USB mic unplugged, a headset switching to HFP) or when the user changes the default input
in Sound settings, `AVAudioEngine` stops the node and delivers no further buffers. Nothing then
notices: no callback ⇒ no watchdog evaluation ⇒ no `maxDuration` check ⇒ `autoStopFired` never fires.
The app stays in `.recording` indefinitely (the HUD's own timer keeps counting up, because the app
layer's timer is independent), the WAV holds only the pre-disconnect audio, and the only way out is a
manual hotkey press — after which the user is told "No speech detected" or gets a truncated
transcript. The same applies to display/system sleep mid-recording. *(Note: the newly added
zeroed-format guard at `:100-102` covers only the "device is already gone when you press the key"
case; it does nothing for a device that disappears mid-recording, which is the common case.)*

**Recommended fix.** In `AudioRecorder`, register
`NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, …)`
at `init` and, on fire: remove the tap, re-read `input.outputFormat(forBus: 0)`, rebuild the
converter, reinstall the tap, and `try engine.start()`; if that fails, tear down and invoke a new
`onCaptureFailure(Error)` callback so the controller moves to `.error` instead of hanging in
`.recording` (reuse the `noInputDevice` case that now exists). Stop relying on buffer flow for
time-based limits: move `maxDuration` enforcement into an app-level `Timer`/`Task` in
`DictationController` that force-stops at `maxDuration` regardless of callbacks, and switch the
recording clock (`:125`, `:209`) from `Date()` to a monotonic clock
(`ContinuousClock`/`CACurrentMediaTime()`) so an NTP step or a sleep/wake cycle cannot skew the
watchdog or the reported duration.

**Effort:** M.

---

### PIPE-03 — "Paste landed" proof is a bare `after > before` char count — High

**Evidence** — `Sources/UsefulVoiceApp/TextInserter.swift:87-94,118-140`

```swift
        let saved = Clipboard.snapshot(pb)
        let before = focusedCharCount()
        writeDelivery(text, to: pb)
        let ourChangeCount = pb.changeCount
        let posted = synthesizePaste()
...
    private func grew(from before: Int?) -> Bool {
        guard let before, let after = focusedCharCount() else { return false }
        return after > before
    }
```

`focusedCharCount()` (`:190-204`) re-resolves the *system-wide* focused element on every call; the
`AXUIElement` reference read before the paste is discarded, and the comparison is
`after > before` — any growth, of any size, from any cause.

**Why it matters.** `grew(...) == true` is the *only* trigger for the destructive step
(`restoreIfUnchanged` → `Clipboard.restore`, `:120,126,146-148`): it wipes the clipboard back to the
user's snapshot. Three ways that turns into "dictation lost, and the user's clipboard too":

1. **Different element.** Between `before` (`:88`) and the check 250 ms later (`:118`), focus can move
   (a click, a new window, a URL-bar focus, an app that opens a panel on paste). Comparing a char
   count from element A against element B is meaningless; "B is longer than A" is common.
2. **Unrelated input.** The user starts typing into their document right after releasing the hotkey,
   or an IME/autocorrect inserts text; the element grows although our Cmd-V never landed.
3. **Wrong amount.** A growth of +1 char is accepted as proof that a 400-character dictation landed.

In each case the deliverable is restored away — leaving the dictation neither in the document nor on
the clipboard (it survives only in History), which is precisely the failure the file's own header
comment (`:16-29`) claims to have eliminated.

**Recommended fix.** Keep the element identity across the check and tighten the predicate: hold the
`AXUIElement` returned by the pre-paste read (and verify it is still the system-wide focused element
with `CFEqual(currentFocused, captured)` before trusting any comparison), and require the growth to
be *consistent with the payload* — read `kAXSelectedTextRange`/`kAXValue` around the caret and
require the inserted text to match `text` (or a suffix/prefix of it), or at minimum require
`after - before >= min(text.count, someFloor)`. Also require the element to still be the focused
element of the same frontmost `NSRunningApplication` as when the paste was posted. Publish a
`charactersInserted` value from the growth check and pass it into `DeliveryPolicy.finalDecision`
so the policy stays pure and testable.

**Effort:** M.

---

### PIPE-04 — The user's clipboard is destroyed on every unproven delivery — High

**Evidence** — `Sources/UsefulVoiceApp/TextInserter.swift:87,110-111,146-148` with
`Sources/UsefulVoiceApp/Delivery/DeliveryPolicy.swift:30-35` and
`Sources/UsefulVoiceApp/Clipboard.swift:35-40`

```swift
        let saved = Clipboard.snapshot(pb)          // in-memory only
...
            self.apply(decision, saved: saved, to: pb,
                       expectedChangeCount: ourChangeCount, completion: completion)
...
        if decision.restoresUserClipboard {
            restoreIfUnchanged(saved, to: pb, expectedChangeCount: expectedChangeCount)
        }
```

`restoresUserClipboard` is false for both `keepDictation*` decisions, and `saved` is captured by the
scheduled closures only.

**Why it matters.** `keepDictationPasted` is the *normal* outcome for every AX-blind target —
Electron apps, web views, terminals (`DeliveryPolicy.swift:19-22` says so explicitly). For a
terminal-heavy user this means their clipboard is silently replaced by the dictation on essentially
every successful dictation, and the previous contents are dropped: the snapshot lives on the stack of
`deliver`, so nothing can bring it back — not the next launch, not a crash-recovery path, and not
"restore my clipboard" (there is no UI for it). `Clipboard.snapshot` will not even see it later: a
subsequent snapshot skips items carrying `deliveryMarker` (`Clipboard.swift:22,16`), so the original
is unrecoverable. The same single point of loss covers app termination mid-delivery: `saved` is
in-memory, `AppDelegate` installs no `applicationWillTerminate`/`applicationShouldTerminate` handler
(grep confirms none exists), so quitting inside the 250–600 ms verification window leaves the
dictation on the clipboard and the user's data gone.

**Recommended fix.** Make the never-lose guarantee symmetric and recoverable:
(i) persist `saved` (e.g. an `NSPasteboard`-serialized blob in Application Support, or
`ClipboardHistory` in `UserDefaults`) and delete it only after a *successful* restore;
(ii) restore-on-demand — keep the snapshot for the session and surface an undo affordance in the
HUD ("Press ⌥-Z within 30 s to restore your clipboard"), triggered by the next hotkey press;
(iii) at minimum, when a `keepDictation*` decision fires, tell the user *once* that their previous
clipboard was replaced, so the loss is not silent.

**Effort:** M.

---

### PIPE-05 — Capture-time write failures are swallowed — Medium

**Evidence** — `Sources/UsefulVoiceCore/Audio/AudioRecorder.swift:240-243`

```swift
        writerQueue.async { [weak self] in
            if isSpeech { self?.capturedSpeech = true }
            try? self?.writer?.append(samples: samples)
        }
```

with `WavWriter.append` (`WavWriter.swift:17-24`) being a throwing `FileHandle.write`, and the only
`finish()` call sites being `AudioRecorder.stop()` (`:158-165`) / `cancel()` (`:174-177`).

**Why it matters.** There is no disk-space check anywhere in the repo (grep for
`volumeAvailableCapacity`/`NSFileSystemFreeSize` returns nothing) and no error latch. On a full or
nearly-full volume (or a write-permission failure, or a store that fell back to a directory that does
not exist — see PIPE-09) `append` starts throwing; every throw is discarded with `try?`, so the
capture loop keeps "recording" with the mic indicator on while the file stops growing. `finish()`
then patches a header consistent with the *truncated* byte count, and `DictationController.process`
reads only the file size (`:208-214`) — which is above the `44 + 3200` floor — so the short file is
uploaded and billed as a complete recording, and the user gets a transcript that silently stops
mid-sentence with no indication that anything failed.

**Recommended fix.** Store the first error: `do { try self?.writer?.append(samples: samples) } catch { self?.writeError = error }`
(a field owned by `writerQueue`), surface it through a new `AudioRecording.captureError: Error?`
read in `stop()`, and have `DictationController.stopAndProcess()` fail loudly
(`.error("Ran out of disk space while recording — check free space.")`) instead of transcribing a
truncated file. Add a pre-flight check with
`URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])` in `startRecording()`
and refuse to start below ~50 MB.

**Effort:** S.

---

### PIPE-06 — No cancellation and no overall timeout for transcription/delivery — Medium

**Evidence** — `Sources/UsefulVoiceCore/DictationController.swift:138-142,305-313` and
`Sources/UsefulVoiceApp/HotkeyManager.swift:136-141`

```swift
    public func cancel() {
        guard state == .recording else { return }
        recorder.cancel()
        state = .idle
    }
...
        state = .delivering
        try? store.prune(keep: recordingsToKeep)
        deliver(finalText) { [weak self] in
            guard let self else { return }
            self.state = .idle
        }
```

```swift
            if isRecordingActive() {                 // .recording only
                DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                return nil                            // consume Esc
            }
```

**Why it matters.** Once the user stops a recording, every input is ignored: `toggle()` breaks in
`.transcribing`/`.delivering` (`:104-106`), `cancel()` returns early, and Esc is not even consumed
(`isRecordingActive` is `.recording`-only), so Esc goes to the frontmost app — a user who wants to
abort the upload cannot. A hung upload therefore holds the app in `.transcribing` for up to the
provider deadline, and there is no deadline at all on delivery: the state returns to `.idle` **only**
when `TextInserter` calls back, which depends on a `DispatchQueue.main.asyncAfter` chain
(`TextInserter.swift:118-132`) plus `AXIsProcessTrusted()`-gated synchronous AX calls. If the main
queue is starved or the callback is lost, the app is permanently wedged in `.delivering` and the
hotkey never works again until relaunch. There is a second, smaller version of the same trap in the
app wiring: `AppDelegate.swift:176-184` starts delivery with `self?.inserter.deliver(...)`, so if
`self` is gone the `done()` completion is never called and the controller is stuck forever.

**Recommended fix.** Add `DictationController.cancelProcessing()` that cancels `processingTask`
(`Task` cancellation already propagates into `URLSession.data(for:)`) and force-resets state to
`.idle`; wire it to the Esc hotkey for `.transcribing`/`.delivering` (change `isRecordingActive` to
"busy" or add a second predicate). Add a delivery watchdog: if `deliver` has not called back within
~5 s, set `.idle` anyway, log it, and leave the dictation on the clipboard. Make the `deliver`
contract total in `AppDelegate` — call `done()` unconditionally after a bounded timeout so the
controller can never depend on an optional-chained callee.

**Effort:** M.

---

### PIPE-07 — Delivery blocks the main thread — Medium

**Evidence** — `Sources/UsefulVoiceApp/TextInserter.swift:72-94,102-104` with
`Sources/UsefulVoiceApp/Clipboard.swift:19-31`

```swift
    func deliver(_ text: String,
                 completion: @escaping (DeliveryOutcome) -> Void = { _ in }) {
        let pb = pasteboard()
...
        let saved = Clipboard.snapshot(pb)
        let before = focusedCharCount()
```

```swift
        return items.compactMap { item in
            guard !item.types.contains(deliveryMarker) else { return nil }
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
```

`deliver` is reached from `DictationController.process` (`DictationController.swift:310`), a
`@MainActor` method, and from a `@MainActor` `AppDelegate` — i.e. on the main thread, as are the
fallback's `axInsert`/`focusedCharCount` calls (`:102-104`) and the static AX helpers (`:206-221`).

**Why it matters.**
1. `Clipboard.snapshot` eagerly reads **every representation of every item** and copies the bytes
   into memory. Copying a 100 MB file or a large image in Finder/Preview, or reading a
   promised/lazy representation, forces the *owning* app to produce the data; the read has no
   timeout, so a slow or beachballed owner stalls this app's main thread — the HUD freezes and the
   hotkey becomes unresponsive at the exact moment the user is watching for feedback. The class
   comment documents only that promised types are *dropped*, not that reading them is a blocking IPC
   round trip.
2. `AXUIElementCopyAttributeValue`/`AXUIElementSetAttributeValue` against a third-party app are
   synchronous cross-process calls on the main thread; against a busy app they block up to the AX
   messaging timeout (and `AXUIElementSetMessagingTimeout` is never set), which is a visible freeze
   in the middle of delivery.

**Recommended fix.** Move the snapshot off the main thread (a serial `DispatchQueue` + `async` hop,
with the delivery itself resumed on main), and copy only a whitelist of eager types
(`.string, .rtf, .html, .tiff, .png, .fileURL, .URL`) instead of iterating `item.types`
indiscriminately; explicitly refuse (`saved = []`, keeping the dictation) when the pasteboard holds
types that cannot be copied eagerly, which is already the safe branch. Wrap AX work in
`AXUIElementSetMessagingTimeout(element, 0.5)` and perform it off-main via
`AXUIElementCopyAttributeValue`'s async variants (`AXObserver`/`AXUIElementSetAttributeValue` on a
background queue is permitted) or at minimum accept a bounded stall by setting the messaging
timeout.

**Effort:** M.

---

### PIPE-08 — `clearContents()` with unchecked `writeObjects` — Medium

**Evidence** — `Sources/UsefulVoiceApp/Clipboard.swift:35-40` and
`Sources/UsefulVoiceApp/TextInserter.swift:163-169`

```swift
    static func restore(_ items: [NSPasteboardItem],
                        to pasteboard: NSPasteboard = .general) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
```

```swift
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("1", forType: Clipboard.deliveryMarker)
        pb.writeObjects([item])
```

`writeObjects` returns `Bool`; both call sites discard it, and `guard !items.isEmpty` does not protect
against a *non-empty array of empty items* — `snapshot`'s `compactMap` returns an `NSPasteboardItem`
with zero representations when none of the item's types could be read (`Clipboard.swift:21-30`).

**Why it matters.** The sequence is non-atomic: `clearContents()` immediately invalidates the old
pasteboard owner, and if the subsequent write does not fully succeed the pasteboard is left empty.
Two concrete consequences: (a) a restore whose snapshot contained only unreadable representations
clears the user's clipboard and restores nothing — the word "never-lose" applies to the dictation,
and here both the user's data and the dictation are gone; (b) if `writeDelivery`'s write fails, the
synthetic Cmd-V pastes an empty/foreign clipboard, and since the element may then grow from something
else, PIPE-03 can even report success.

**Recommended fix.** Check the return value and read back:
`let ok = pb.writeObjects(objects); guard ok, pb.changeCount > previousChangeCount else { /* fall back to pb.setString(text, forType: .string) and report .clipboardOnly */ }`.
In `snapshot`, filter out items with no successfully-copied types
(`.filter { !$0.types.isEmpty }`) so `restore` receives only writable items, and treat "some items
could not be copied" as "do not restore" (keep the dictation on the clipboard) rather than
partially restoring. Verify the restore by re-reading `pb.string(forType: .string)`.

**Effort:** S.

---

### PIPE-09 — `fatalError` on recordings-directory failure ⇒ crash at launch — Medium

**Evidence** — `Sources/UsefulVoiceApp/AppDelegate.swift:132-135`

```swift
        let appSupport = sadaaDir.appendingPathComponent("Recordings")
        guard let store = try? RecordingStore(directory: appSupport) else {
            fatalError("Cannot create recordings directory at \(appSupport.path)")
        }
```

**Why it matters.** `RecordingStore.init` only does `createDirectory` (`RecordingStore.swift:8-12`),
which fails on a full disk, a permissions change (enterprise/managed Macs, MDM-restricted
`~/Library`), a read-only home, or a *file* sitting at that path. The result is an immediate hard
crash at launch with no window, no message and no crash log of our own making — the app simply
doesn't start, and the user has no idea why. It is also the earliest possible failure point in the
pipeline, so it makes every downstream error path unreachable.

**Note on the current tree:** `RecordingStore.make(directory:)` (`RecordingStore.swift:14-35`) was
added while this audit was running and already implements exactly the right degradation — try the
preferred directory, fall back to a temp directory, then to a non-throwing store. **It is dead code:
nothing calls it** (grep for `RecordingStore.make` finds only its definition; `AppDelegate.swift:133`
still constructs the store directly). So the crash is still live, and the fix is now one line.

**Recommended fix.** `let store = RecordingStore.make(directory: appSupport)` and delete the
`fatalError`, plus surface a non-fatal notice when the fallback was used
(`RecordingStore.make` should return `(store, usedFallback: Bool)` or log it) so the user learns
their recordings are landing in a temp directory that the OS may purge. If even the temp fallback
fails, the `uncheckedDirectory` path means capture runs with no writable directory; every `append`
then fails silently (PIPE-05) and the user is told **"Recording was too short."**
(`DictationController.swift:210-214`) rather than "audio could not be saved" — that specific
misreport should be fixed along with PIPE-05, not left as the last-resort behavior.

**Effort:** S.

---

### PIPE-10 — No logging or diagnostics at all — Medium

**Evidence** — no `os_log`, `Logger`, `NSLog` or `print` exists anywhere under `Sources/`
(verified by grep). The single diagnostic surface is transient UI:

```swift
        case .error(let message):
            stopRecordingTimer()
            setIcon("waveform", tint: nil)
            hud.show(.error(message))
            hud.hide(after: 6)
```

`Sources/UsefulVoiceApp/AppDelegate.swift:526-531`.

**Why it matters.** In production every failure in this pipeline — a provider 429, a timeout, an
`AVAudioEngine` restart failure, a refused recording, a truncated WAV — exists for 6 seconds in a
floating pill and then is gone. There is no log the user can send, no counters (dictations started /
completed / failed by reason), no record of the provider and latency actually used for a given
delivery, and no way to distinguish "the mic never delivered buffers" from "Deepgram rejected the
audio" after the fact. The retained audio + sidecar (PIPE-16) is the only forensic artifact, and
nothing in the app points at it. `DictationHistory` records successes (`DictationRecord`), not
failures — a failed dictation leaves no trace at all.

**Recommended fix.** Introduce a tiny `Diagnostics` façade over `OSLog`
(`Logger(subsystem: "ai.karko.sadaa", category: "pipeline")`) and log at fixed points: state
transitions in `DictationController` (with `audioBytes`, provider name, latency, outcome), provider
errors (`ProviderError` mapped, body run through the existing `ProviderHealthCheck.sanitize`), audio
capture anomalies (buffer gaps > 250 ms, `writeError` from PIPE-05, engine restart failures), and
delivery decisions (the `DeliveryDecision` case plus `charactersInserted`). Never log the API key or
transcript text at default level. Add a "Copy diagnostics" button in Settings that dumps the last
N entries.

**Effort:** M.

---

### PIPE-11 — No transient-failure resilience — Medium

**Evidence** — `Sources/UsefulVoiceApp/AppDelegate.swift:408-418`

```swift
    private static func buildProviders(settings: AppSettings)
        -> [TranscriptionProvider] {
        guard let key = Keychain.get(account: "deepgram-key")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return []
        }
        return [DeepgramProvider(config: .init(apiKey: key,
                                               smartFormat: settings.formattingEnabled))]
    }
```

`DictationController.swift:219-228` iterates the chain once, moving on only when a provider throws;
`DeepgramProvider.swift:106-109` turns any non-2xx into a terminal `ProviderError.http`.

**Why it matters.** The chain has exactly one element, so "try the next provider" is a no-op and
there is no retry at all: a momentary network blip, a connection reset mid-upload, or a Deepgram
`429` (rate limit) / `503` fails the user's dictation outright and demands a manual Retry click.
`429` bodies are shown verbatim but the `Retry-After` header is never read, and there is no
distinction between permanent failures (401 bad key, 400 bad audio) and transient ones (429/5xx/
timeout) — so the UI cannot even say "trying again" for the recoverable class.

**Recommended fix.** Add a `transient` classification to `ProviderError` (`429`, `500...599`,
`timedOut`, `transport`) and retry those once or twice inside `DeepgramProvider.transcribe` with
exponential backoff + jitter (e.g. 0.5 s, 1.5 s), honoring `Retry-After` when present. Give the
controller a per-attempt budget so the total stays inside the user's patience (~30 s), and surface
"Retrying (2/3)…" through `onStateChange` so the HUD shows progress instead of a dead pill. Keep the
existing "next provider in the chain" behavior for permanent failures.

**Effort:** M.

---

### PIPE-12 — Permission denial is still not checked, and `AudioRecorderError` has no `LocalizedError` — Medium

**Status after the mid-audit rewrite:** the zeroed-format case is now handled — `AudioRecorder.swift:100-102`
guards `hwFormat.sampleRate > 0, hwFormat.channelCount > 0` and throws the new `noInputDevice` case
(`:27-28`). What remains is (a) no `authorizationStatus` check and (b) unlocalized errors.

**Evidence** — `Sources/UsefulVoiceCore/Audio/AudioRecorder.swift:23-29,89-102` and
`Sources/UsefulVoiceCore/DictationController.swift:149-163`

```swift
public enum AudioRecorderError: Error {
    case notRecording
    case formatUnsupported
    case alreadyRecording
    /// No usable microphone / input device is available.
    case noInputDevice
}
```

```swift
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
```

```swift
        } catch {
            state = .error("Couldn't start recording: \(error.localizedDescription)")
```

**Why it matters.** Two remaining defects on the same path:
1. The only microphone check is `AVCaptureDevice.requestAccess(for: .audio)` fired once at launch
   (`AppDelegate.swift:666-675`); its result is not stored and `AVCaptureDevice.authorizationStatus`
   is never consulted again (grep confirms). The new zeroed-format guard *may* incidentally catch a
   TCC denial (the comment at `:94-99` asserts the system reports a zeroed format, *(unverified)*),
   but nothing inspects the actual authorization state — so the app cannot tell the user "your
   permission was revoked" versus "no microphone is attached", and it cannot offer the one-click
   System Settings deep link that `SettingsPage.openPrivacyPane` already knows how to build. When the
   device does report a usable format but the app is not authorized, the recording proceeds and the
   user is told **"No speech detected."** (`DictationController.swift:178-182,247-251`) — pointing
   them at their mic level instead of at Privacy & Security.
2. `AudioRecorderError` still does not conform to `LocalizedError` (grep for `LocalizedError`/
   `errorDescription` over `Sources/UsefulVoiceCore` returns nothing), and these are exactly the
   errors that reach the HUD via `error.localizedDescription` (`:162`, `:171`). The user sees
   `Couldn't start recording: The operation couldn't be completed. (UsefulVoiceCore.AudioRecorderError error 1.)`
   — and now, for the no-device case, `… error 4.` — an unactionable string that names neither the
   cause nor the remedy.

**Recommended fix.** In `startRecording()` (and in the device-change handler from PIPE-02), check
`AVCaptureDevice.authorizationStatus(for: .audio)` first and emit a dedicated
`DictationState.error("Microphone access is off. Enable Useful Voice in System Settings → Privacy &
Security → Microphone.")` with a HUD action that opens
`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` (mirror
`SettingsPage.openPrivacyPane`); only then fall through to `recorder.start`. Conform
`AudioRecorderError` to `LocalizedError` with an `errorDescription` per case (and a
`recoverySuggestion` for `noInputDevice` / `formatUnsupported`), and keep the distinction between
"no device" and "format conversion unsupported" so the message stays actionable.

**Effort:** S.

---

### PIPE-13 — Unsynchronized recorder state between `start()` and a mid-flight tap callback — Medium *(unverified)*

**Evidence** — `Sources/UsefulVoiceCore/Audio/AudioRecorder.swift:121-126,150-169,209-214`

```swift
        // Assign all session state BEFORE installing the tap so the tap thread
        // never observes stale watchdog/startedAt/latch from a prior session.
        fileURL = url
        watchdog = SilenceWatchdog(timeout: silenceTimeout)
        startedAt = Date()
        autoStopFired = false
```

```swift
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        if !autoStopFired,
           watchdog.observe(rms: rms, at: elapsed) || elapsed > maxDuration {
            autoStopFired = true
            onAutoStop?()
        }
```

The file's own ordering contract is `start()` (main thread) writes these fields, then the tap is
installed; the comment at `:46-49` claims single-thread ownership by "the single AVAudioEngine tap
thread". But `stop()` explicitly assumes the opposite:

```swift
        // A buffer still mid-process when the tap is removed may
        // enqueue after finish(); that tail (a few ms) is dropped, which is fine
        // for dictation.
```

**Why it matters.** If a tap callback can be in flight after `teardownEngine()` returns (which
`stop()`'s own comment at `:154-156` asserts), then the sequence *stop → start* gives: main thread
writes `watchdog`/`startedAt`/`autoStopFired` for session N+1 (`:124-126`) while the render thread is
still executing `process` for session N and reading/writing the same three fields (`:209-213`).
`SilenceWatchdog` is a struct with a mutating `observe`, so a stale callback can rewrite
`lastLoudAt` mid-update and the `startedAt` read can straddle the write (`Date` is two words). The
practical outcomes range from a spurious auto-stop (a fresh recording instantly stopped because a
stale callback fired with a large `elapsed`) to a torn read. Today nothing detects it because
`Package.swift` builds in Swift 5 mode and none of these fields is `atomic`/actor-isolated; under
Swift 6 strict concurrency the whole `AudioRecorder` (a non-`Sendable` class mutated from a
nonisolated tap closure) is a diagnosed violation.
*(Confidence: the race is structural and forced by the code's own stated assumption about in-flight
callbacks; I could not confirm the exact `removeTap` guarantee at runtime, so treat the *impact* as
unverified while the *missing synchronization* is certain. Note the concurrent rewrite did not touch
this path.)*

**Recommended fix.** Give the session state one owner: move `watchdog`, `startedAt`, `autoStopFired`
and `silenceTimeout` behind the existing `writerQueue` (or a dedicated `os_unfair_lock`/`NSLock`),
read/write them inside the same `writerQueue.async` block that already carries the converted samples,
and evaluate the watchdog there (it needs nothing from the render thread — `elapsed` can be computed
inside the block). Additionally gate the callback with a session token:
`let generation = UUID()` captured by the tap closure; `process` early-returns unless
`writerQueue.sync { self.generation == generation }`. That also fixes the dropped-tail case
(`:154-156`) properly instead of by "a few ms is fine".

**Effort:** M.

---

### PIPE-14 — Per-buffer allocation and `AVAudioConverter` on the real-time tap thread — Medium *(partially unverified)*

**Evidence** — `Sources/UsefulVoiceCore/Audio/AudioRecorder.swift:189-244`

```swift
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: capacity) else { return }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
...
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
```

**Why it matters.** Every tap callback heap-allocates an `AVAudioPCMBuffer` and then a Swift
`Array` copy on the audio render thread, and calls `AVAudioConverter.convert`, which is not
documented as real-time safe (it can allocate, query the hardware and take internal locks). The
comment above `process` correctly identifies file I/O as the thing to keep off this thread, then
introduces two other blocking/allocation hazards into the same thread. The symptom is not a crash but
audible glitches and — worse for a dictation tool — dropped buffers on a loaded machine, i.e. words
missing from the transcript. The subsequent `writerQueue.async` is correct, though it does mean the
tap thread can still enqueue unboundedly if the disk stalls (no bounded queue, no backpressure).
*(Confidence: the allocation/converter-on-render-thread pattern is certain from the source; the
magnitude of glitching is runtime-dependent, so I am not claiming an audible defect, only the
suspect pattern.)*

**Recommended fix.** Pre-allocate one converted `AVAudioPCMBuffer` of a fixed max capacity (e.g.
`sampleRate * 0.25` frames) when the tap is installed and reuse it inside the callback via
`out.frameLength = 0`; either move the conversion into the `writerQueue` block (converter ownership
then sits entirely on one serial queue, which is also where `WavWriter` lives) or use
`AVAudioConverter`'s `convert(to:from:)` on a preallocated buffer. If the conversion stays on the tap
thread, switch the sink to a preallocated `UnsafeMutableBufferPointer<Int16>` owned by the writer
queue to drop the `Array` allocation, and add a bounded queue (drop-oldest with a counter) so a
stalled disk cannot grow memory without limit.

**Effort:** M.

---

### PIPE-15 — Unbounded response buffering; whole WAV in RAM as `httpBody` — Medium

**Evidence** — `Sources/UsefulVoiceCore/Transcription/DeepgramProvider.swift:93-110`

```swift
    public func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        let request = try makeRequest(audio: Data(contentsOf: audio), hint: hint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.withDeadline(seconds: Self.totalDeadline) { [session] in
                try await session.data(for: request)
            }
```

**Why it matters.** `Data(contentsOf:)` reads the whole file synchronously (a blocking call on a
concurrency cooperative thread, with no cancellation check) and `request.httpBody = audio` keeps a
second full copy alive for the duration of the request: a 19.2 MB dictation costs ~40 MB of
transient heap, plus whatever URLSession copies internally. On the receive side,
`session.data(for:)` buffers the entire response with no size cap and no
`URLSessionConfiguration.timeoutIntervalForResource`. For the fixed, TLS-authenticated
`api.deepgram.com` endpoint the inbound risk is small (a JSON transcript and error bodies), so I
rate this Medium rather than High — but a captive-portal/proxy on the network path can stream an
arbitrarily large body, and the error body is fully retained before being sliced to 200 characters
in `DictationController.describe` (`:316-331`) / `ProviderHealthCheck.sanitize`.

**Recommended fix.** Stream the body instead of buffering it:
`try await session.upload(for: request, fromFile: audio)` with
`session.configuration.timeoutIntervalForRequest/ForResource` set from the size-derived deadline
(PIPE-01). For the response, cap it explicitly — either `session.bytes(for:)` and accumulate with a
hard limit (e.g. 4 MB, well above any real transcript), or check
`response.expectedContentLength` against a maximum before reading. Add a `Task.checkCancellation()`
before the read so a cancelled dictation does not pay for a full file read.

**Effort:** S.

---

### PIPE-16 — Unencrypted dictation audio and transcripts at rest, no retention control — Medium

**Evidence** — `Sources/UsefulVoiceApp/AppDelegate.swift:129-140` and
`Sources/UsefulVoiceCore/Audio/RecordingStore.swift:8-12,50-53`

```swift
        let sadaaDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sadaa")
        let appSupport = sadaaDir.appendingPathComponent("Recordings")
...
        let history = DictationHistory(
            fileURL: sadaaDir.appendingPathComponent("history.json"))
```

```swift
    public func saveTranscript(_ text: String, for audio: URL) throws {
        let sidecar = audio.deletingPathExtension().appendingPathExtension("txt")
        try text.write(to: sidecar, atomically: true, encoding: .utf8)
    }
```

**Why it matters.** Every dictation writes raw microphone audio plus a plaintext sidecar transcript
into `~/Library/Application Support/Sadaa/Recordings` and the text into `history.json`, with default
file permissions and no at-rest protection, no `NSURLIsExcludedFromBackupKey`, and no
`.completeFileProtection` equivalent. `~/Library/Application Support` is included in Time Machine
and in iCloud device backups, so dictated content — which in this app's intended use includes
customer names, code identifiers and private notes — is replicated off-device by default. The only
retention control is a *count* (`AppSettings.recordingsToKeep`, default 10, `AppSettings.swift:74-76`),
which is not a retention policy: nothing bounds age or total bytes, pruning only runs on
success/failure paths of a dictation (`DictationController.swift:179,211,248,306`), and the
never-lose design means a user with persistent failures accumulates full audio indefinitely. Deletion
is `removeItem` — not a secure erase — and there is no "delete all recordings" affordance.

**Recommended fix.** (i) Set `URLResourceValues.isExcludedFromBackup = true` on the recordings
directory at creation (`RecordingStore.init`); (ii) add an age/size retention policy alongside the
count (`prune(keepAge:)` using `resourceValues(forKeys: [.contentModificationDateKey])`, plus a
total-bytes cap) and run it at launch, not only after a dictation; (iii) add an explicit
`deleteAllRecordings()` + Settings control, and document in the UI what is stored and for how long;
(iv) if the spec requires keeping audio, consider encrypting the sidecars/history with a key stored
in the existing Keychain wrapper — the `Keychain` façade is already there.

**Effort:** M.

---

### PIPE-17 — `pendingRawMode` is never reset on the early-return paths — Low (latent)

**Evidence** — `Sources/UsefulVoiceCore/DictationController.swift:100-103,208-214,230-239,247-251,290`

```swift
        case .recording:
            pendingRawMode = rawMode
            state = .transcribing
            processingTask = Task { await stopAndProcess() }
```

```swift
        guard audioBytes >= 44 + 3200 else {
            try? store.prune(keep: recordingsToKeep)
            state = .error("Recording was too short.")
            return
        }
...
        pendingRawMode = false          // only reached on the success path
```

**Why it matters.** `pendingRawMode` is consumed and cleared only at the very end of `process()`
(`:290`). Every early return in between — no provider configured (`:198-201`), too short
(`:210-214`), all providers failed (`:230-239`), empty transcript (`:247-251`) — leaves it set. The
next dictation then silently applies the *raw* transform instead of the formatter, i.e. the user
turns auto-formatting back on and gets unformatted text with no explanation; it also makes
`retryLast()` replay the stale mode (`:126-129`).

**Reachability (verified):** the app never passes `rawMode: true` — grep over `Sources/` finds
`rawMode` only at its declaration (`DictationController.swift:96`) and its use at `:101`, and
`AppDelegate.toggleDictation()` calls `controller?.toggle()` with the default. So this is a **latent**
bug: it is exercised by the test suite (`DictationControllerTests.testRawModeSkipsFormatter`) but
cannot fire in the shipped app today. It becomes a real bug the moment raw mode is wired to a UI
control, which the parameter's existence implies is intended.

**Recommended fix.** Capture the mode at the start of `process()`
(`let rawMode = pendingRawMode; pendingRawMode = false`) so it is consumed exactly once per
dictation regardless of which path returns, and pass it explicitly to `retryLast`'s replay instead of
reading shared state. Add a test that sets raw mode, forces a "too short" failure, and asserts the
next dictation formats normally.

**Effort:** S.

---

### PIPE-18 — `retryLast()` can target an already-pruned file and reports the wrong reason — Low

**Evidence** — `Sources/UsefulVoiceCore/DictationController.swift:118-130,206-214` with
`Sources/UsefulVoiceCore/Audio/RecordingStore.swift:55-65`

```swift
    public func retryLast() {
        guard let url = lastFailedAudio else { return }
...
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let audioBytes = (attrs?[.size] as? Int) ?? 0
        guard audioBytes >= 44 + 3200 else {
            try? store.prune(keep: recordingsToKeep)
            state = .error("Recording was too short.")
            return
        }
```

**Why it matters.** `canRetry` is derived purely from `lastFailedAudio != nil` (`:50`), and
`prune(keep:)` runs on other dictations' error paths (`:179,211,248`) and on success (`:306`) using
the *user-configurable* `recordingsToKeep`. With `recordingsToKeep = 1` (or 2): dictation A fails
(audio A retained, "Retry" is offered), the user then dictates a too-short/silent clip B, whose error
path calls `prune(keep: 1)` and deletes A. The controller still advertises `canRetry == true`, and
clicking Retry produces `"Recording was too short."` — because `attributesOfItem` failed and the
byte count defaulted to `0` — instead of "the audio for that dictation is no longer available". The
user is told something false about a clip they just recorded, and there is no path that clears the
stale retry affordance.

**Recommended fix.** Never prune the file referenced by `lastFailedAudio` (skip it in
`RecordingStore.prune`, or re-check `fileExists` immediately after each prune and clear
`lastFailedAudio`/`lastFailedContext` when it is gone). Distinguish the two failures in
`process(…)`: `guard FileManager.default.fileExists(atPath: audioURL.path) else { state = .error("That recording is no longer on disk. Please dictate again."); return }`
before the size check, and make the size check use the real error rather than a silent `?? 0`.
The history path already does this correctly (`AppDelegate.swift:253-260`), so mirror it.

**Effort:** S.

---

### PIPE-19 — Keychain: no accessibility attribute; failures look like "not configured" — Low

**Evidence** — `Sources/UsefulVoiceCore/Settings/Keychain.swift:18-37,39-54,74-81`

```swift
    public static func set(_ value: String, account: String) throws {
...
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
```

```swift
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
```

```swift
    public static func delete(account: String) {
        ...
        SecItemDelete(query as CFDictionary)
    }
```

**Why it matters.** Three related gaps, all Low individually:
1. No `kSecAttrAccessible`/`kSecUseDataProtectionKeychain` is set. The doc comment (`:14-17`) gives a
   defensible reason (iOS semantics, entitlements), and on a non-sandboxed macOS app the legacy
   login keychain does prompt per-app via its ACL — so this is a hardening gap, not an exposed
   secret. It does mean the key cannot follow the stronger "when unlocked / this device only"
   protection the platform now offers, and it is stored in a keychain the user's other tools also
   prompt for.
2. `get()` collapses *every* `SecItemCopyMatching` failure — including `errSecAuthFailed`,
   `errSecInteractionNotAllowed` (keychain locked, e.g. right after wake before the login keychain is
   unlocked) — into `nil`, which callers read as "not configured"
   (`AppDelegate.swift:410-414` returns `[]` ⇒ `"No transcription provider configured. Open Settings."`,
   `DictationController.swift:198-201`). A user with a perfectly good key who happens to hit a locked
   keychain during a period of network/credential weirdness is told they were never configured, and
   Settings shows "no key" (`SettingsPage.swift:303` `hasDeepgramKey = Keychain.exists(...)`).
3. `delete()` discards the `OSStatus`, so a failed delete (e.g. `errSecInteractionNotAllowed`)
   silently leaves the credential in place while the UI reports it was removed
   (`SettingsPage.swift:155`).
   *Positively:* the API key is **not** written to `UserDefaults` or any file (verified by grep —
   the only `UserDefaults` writers are `AppSettings` and `main.swift`'s scrollbar default), and
   error strings are passed through `ProviderHealthCheck.sanitize`, which redacts
   `Token <key>`, `Bearer <token>` and `api-key:` shapes (`ProviderHealthCheck.swift:95-112`).

**Recommended fix.** Return a typed `KeychainLookup` (`found(String)`, `notFound`,
`failure(OSStatus)`) from `get`/`exists` so callers can say "Keychain locked — unlock your login
keychain" instead of "not configured"; make `delete` throwing/`@discardableResult` and check the
status; and set `kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked` (ignored by the file keychain,
honored if the item is later moved to the data-protection keychain), documenting the choice in the
comment that already exists.

**Effort:** S.

---

### PIPE-20 — No termination hook: the in-progress WAV is never finalized and a pending restore never runs — Low

**Evidence** — `Sources/UsefulVoiceApp/AppDelegate.swift:8-45` (no `applicationWillTerminate` /
`applicationShouldTerminate` is implemented; grep confirms one is absent) with
`Sources/UsefulVoiceCore/Audio/WavWriter.swift:9-15,26-31`

```swift
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: self.sampleRate,
                                                 dataBytes: 0))
```

```swift
    public func finish() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: dataBytes))
        try handle.close()
    }
```

**Why it matters.** Two leaks across a quit:
1. The WAV's `data` chunk size is written as `0` at creation and only patched by `finish()`. Quitting
   (or crashing) mid-recording leaves a 44-byte "valid but empty" WAV in `Recordings/` that no
   cleanup path ever removes unless a later prune reaches it; the audio captured so far is
   unreadable even though the bytes are on disk. `AppDelegate` also never calls `recorder.cancel()`,
   so the FileHandle and the AVAudioEngine tap are torn down only by process exit.
2. A delivery in progress holds the user's clipboard snapshot in memory only (PIPE-04); a quit
   inside the 250–600 ms verification window loses it permanently with no recovery at next launch.

**Recommended fix.** Implement
`applicationShouldTerminate(_:)` → `controller?.shutdown()` which (a) cancels an active recording
(`recorder.cancel()`), (b) finalizes a completed-but-unwritten recording via `recorder.stop()` if
the state is `.recording` and the audio is long enough to be worth keeping, (c) if delivery is
pending, immediately restores the saved clipboard or, better, flushes the persisted snapshot from
PIPE-04 — then returns `.terminateNow`. Cheap insurance against an unrecoverable state.

**Effort:** S.

---

## Less-certain / needs runtime verification

Listed so the reader can discount them appropriately:

- **PIPE-13 (data race)** — the *missing synchronization* is certain; whether a tap callback can
  truly be in flight after `removeTap` returns is inferred from the codebase's own comment
  (`AudioRecorder.swift:154-156`), not confirmed against Apple's `AVAudioNode.removeTap`
  documentation. Worth a targeted stress test (rapid stop/start cycles with an assertion in
  `process` that `fileURL` matches the current session).
- **PIPE-14 (real-time thread)** — the allocation/`AVAudioConverter` pattern is certain; the audible
  impact is not measured. `AVAudioConverter`'s real-time suitability is not something I verified in
  Apple's docs here, so treat it as a suspect pattern rather than a proven defect.
- **PIPE-02 crash hypothesis** — that a 0-channel `hwFormat` from `inputNode.outputFormat(forBus:)`
  can make `installTap` raise an ObjC exception (rather than returning/throwing) is a known
  AVAudioEngine class of failure but I could not confirm the exact version/condition from source.
- **PIPE-07 promised-data block** — that `NSPasteboardItem.data(forType:)` on a promised/lazy type is
  a blocking round trip is well-established; the exact timeout behavior (whether the pasteboard
  server bounds the wait) I did not confirm.
- **PIPE-15 inbound size risk** — the endpoint is fixed and TLS-authenticated; the unbounded
  `session.data(for:)` buffering is real but the exposure is limited to network-path tampering.
- **PIPE-12 part 2** — the exact `localizedDescription` text for a Swift enum error without
  `LocalizedError` is the standard Foundation bridge ("The operation couldn't be completed.
  (… error N.)"); the specific error number per case is not asserted here.
- **Mid-audit rewrites I re-verified rather than assumed:** `AudioRecorder.swift` and
  `RecordingStore.swift` were rewritten at 14:23 while this audit ran. Re-read after the change:
  the new `noInputDevice` guard (`AudioRecorder.swift:100-102`) is real and narrows PIPE-12 part 1;
  `RecordingStore.make` (`:14-35`) is real but **unreferenced**, so PIPE-09's crash is still live;
  PIPE-02/05/13/14 line numbers were re-anchored to the post-change file. `KeytermBudget.swift`
  (new, untracked) is referenced only from `MemoryBiasBuilder` and, read on its own, is coherent
  (500-token API ceiling, 400-token budget, count and length caps) — I did not audit the Language
  Memory side of that dependency, which is out of this report's scope.
- **Not a finding (checked and dismissed):** the `UInt32` `dataBytes`/RIFF-size fields in
  `WavWriter` cannot overflow in practice — the 600 s `maxDuration` caps a recording at ~19.2 MB,
  and since samples are 16-bit the `data` chunk is always even-length, so RIFF padding rules never
  apply. Likewise the missing `User-Agent` on the Deepgram request is not a defect (the API does not
  require one), and the prompt-bias `keyterm` query growth is bounded by
  `dictionaryBiasBudget = 100` (`AppDelegate.swift:387`) and, in the current tree, tightened
  further by the new `Transcription/KeytermBudget.swift` (a 400-token budget plus `maxTerms = 100`
  and a 64-character per-term cap), keeping the request URL at roughly 2–3 KB — far under any
  practical request-line limit. `SilenceWatchdog` cannot be set to 0 from the UI (the slider is `15...120`,
  `SettingsPage.swift:178`), so the "instant auto-stop" edge case is unreachable.

## Test-coverage gaps behind these findings

- `AudioRecorder` (the real one — taps, converter, watchdog wiring, teardown/restart) has **no**
  tests; `FakeRecorder` in `DictationControllerTests.swift:5-31` bypasses everything this audit
  flags in PIPE-02/05/13/14.
- `TextInserter`, `Clipboard` and `ChimePlayer` have **no** tests at all — only the pure
  `DeliveryPolicy` is covered (`DeliveryPolicyTests.swift`), so the char-count predicate and the
  pasteboard write/restore paths (PIPE-03/04/07/08) are entirely untested.
- `WavWriterTests.swift` asserts a single happy-path header; no test covers a partial write, a
  write failure, or a `finish()` without appends.

## Already good

- **Files and handles are closed on the normal paths.** `WavWriter.finish()` patches the header and
  closes; `AudioRecorder.stop()`/`cancel()` always drain `writerQueue` before `finish()`, and
  `start()`'s failure path removes the tap, finishes/deletes the partial file and resets state
  (`AudioRecorder.swift:136-147`) — a genuine restartable-state cleanup rather than a leak.
- **Real-time safety was consciously designed for.** File I/O is on a dedicated serial queue with a
  clear ownership story (`:65-67`), the RMS/peak scan is a single pass, and `didCaptureSpeech` is
  serialized through the same queue (`:76`) instead of a bare bool.
- **The silent-clip gate is well-founded.** `didCaptureSpeech` gates transcription before upload
  (`DictationController.swift:178-182`) with a documented rationale (Whisper echoing prompt bias),
  and the peak-vs-RMS rationale for `speechPeakThreshold` (`:53-60`) is a real, sensible distinction.
- **Byte-size pre-flight.** The `44 + 3200` minimum-audio guard (`:206-214`) prevents a pointless
  upload and bill for an instant tap, and it is covered by a test.
- **The state machine's busy mutex is synchronous and correct.** `toggle()` sets
  `.transcribing` before spawning the task (`:100-103`), the auto-stop hop re-checks
  `state == .recording` before acting (`:83-91`), and `.delivering` is held until delivery actually
  settles (`:305-313`) — a re-entrant hotkey cannot start a second recording mid-paste.
- **Every `deliver` path completes exactly once.** All three branches of `TextInserter.deliver`
  (posted-and-grew, late-grew, fallback) call `completion` exactly once (`:118-132`), so the
  controller cannot be left in `.delivering` by a logic gap (only by a lost main-queue block —
  PIPE-06).
- **Clipboard restoration is conditional on `changeCount`.** `restoreIfUnchanged` refuses to clobber
  a newer copy (`TextInserter.swift:173-179`) — the right guard against a user copy during the
  verification window.
- **Secure input is checked twice.** Once before recording starts (`DictationController.swift:152-155`)
  and again at delivery and before the fallback AX insert (`TextInserter.swift:79-83,102`), so a
  password field cannot be typed into.
- **Secret hygiene is deliberately handled.** The API key lives only in the Keychain; error messages
  pass through `ProviderHealthCheck.sanitize`, which redacts `Token …`, `Bearer …`, `api-key:` and
  `Ocp-Apim-Subscription-Key` shapes and truncates output (`ProviderHealthCheck.swift:95-112`), and
  `redactedEndpoint` strips path/query from any endpoint surfaced in the UI (`:69-78`). There is no
  logging to leak into.
- **Network timeouts are not naive.** The `withDeadline` construction correctly identifies that
  `URLRequest.timeoutInterval` is an idle timeout and enforces a real wall-clock cap, converts
  `URLError.timedOut` to a typed `ProviderError.timedOut`, and cancels the losing task
  (`DeepgramProvider.swift:72-91,101-105`) — the *value* is wrong (PIPE-01), the *mechanism* is right.
- **Retry-without-re-record is properly implemented.** Failed audio plus the formatting context
  captured at dictation time are retained and replayed (`DictationController.swift:41-47,230-242`),
  with a test proving the retry formats for the original target app rather than for Useful Voice
  itself (`DictationControllerTests.testRetryUsesContextCapturedAtDictationTime`).
- **The HUD is a non-activating panel.** `styleMask: [.borderless, .nonactivatingPanel]` plus
  `orderFrontRegardless()` (`HUDPanel.swift:92-101`) means the delivery indicator cannot steal focus
  from the app being dictated into — an important prerequisite for the paste to land at all.
- **Provider chain semantics and the health check are clean.** The chain falls through on error
  (`:219-228`), the health probe uses a real WAV in the temp dir and always deletes it via `defer`
  (`ProviderHealthCheck.swift:42,114-132`), latency is measured as a delta rather than wall clock,
  and both are well covered by tests.

---

## Appendix — files as audited (MD5) and the exact churn observed

Files were read at 14:15–14:19; the two marked *changed* were re-read at 14:24 and the findings
re-verified against the new content.

| File | MD5 as audited | mtime | Note |
|------|----------------|-------|------|
| `Sources/UsefulVoiceCore/DictationController.swift` | `a457bc7b662e95def32012970f7d46e8` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceCore/Audio/AudioRecorder.swift` | `910a934e4955ffd86e6045dbbb3b2003` | 09-10 **14:23** | **changed mid-audit**, re-verified |
| `Sources/UsefulVoiceCore/Audio/WavWriter.swift` | `d5b4286cbcff924d60917cd9ee8ce0be` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceCore/Audio/RecordingStore.swift` | `bed922d22b1f67399cf495bd1f03541f` | 09-10 **14:23** | **changed mid-audit**, re-verified |
| `Sources/UsefulVoiceCore/Audio/SilenceWatchdog.swift` | `086d333f796f524cad912beaf5ea0f2c` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceCore/Audio/ChimeSynth.swift` | `243ff108fd683e998df1d7697dbf4350` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceCore/Transcription/TranscriptionProvider.swift` | `74b6edcdaea1afb1332ce6990be9cfcd` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceCore/Transcription/DeepgramProvider.swift` | `b85a3b47b6c66379cb8002803f587459` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceCore/Transcription/KeytermBudget.swift` | `1ededdfff68977b4ed2ce447e4c9258b` | 09-10 **14:19** | **new/untracked**, out of scope, noted only |
| `Sources/UsefulVoiceCore/ProviderHealth/ProviderHealthCheck.swift` | `e08ba695f73069f0b3bf36be17e1fc6e` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceCore/Delivery/DeliveryPolicy.swift` | `df931a0bfbe0db56be361a2725357a31` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceApp/TextInserter.swift` | `0e721afa8d3a8a40e987769472839191` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceApp/Clipboard.swift` | `b87b52c279e92c1dabe2f228dd1554d1` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceApp/ChimePlayer.swift` | `f2f62145e5b31ba70a282d8a7c5b7eac` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceCore/Settings/Keychain.swift` | `bd1328e8c16ad1f37b8bff23e81a00aa` | 08-26 13:03 | stable |
| `Sources/UsefulVoiceApp/AppDelegate.swift` | `f0c16cd4667ed6e289a00790c4f64283` | 09-02 19:32 | stable |

Also modified in the working tree relative to `HEAD` but outside this report's scope:
`LanguageMemory/LanguageMemoryMatcher.swift`, `LanguageMemory/MemoryBiasBuilder.swift`,
`LanguageMemory/ReplacementEngine.swift`, `LanguageMemory/SnippetExpansionEngine.swift`.
