# Audit 04 — SwiftUI UI layer, notes/scratchpad storage, ViewModels

Scope: `Sources/UsefulVoiceApp/{Pages,Components,ViewModels,Theme.swift,UsefulVoiceViewModel.swift,AppDelegate.swift,RootView.swift,MainWindowController.swift,main.swift}` and `Sources/UsefulVoiceCore/{Notes,Scratchpad}` plus `NotesStoreTests`, `ScratchpadStoreTests`, `ScratchpadMigratorTests`.

Method: read-only static review. Every finding below was verified against the code quoted; no build or test run was possible (sandbox blocks `swift build`/`swift test`). "Confidence" is my confidence that the described behaviour is real, not that it matters.

**No `TODO`, `FIXME`, `HACK` or `XXX` exists anywhere in `Sources/` or `Tests/` today (zero hits).** All other stale-branding hits are inventoried in the dedicated section at the end.

---

## Findings table

| ID | Title | Severity | Confidence | Effort |
|----|-------|----------|------------|--------|
| UI-01 | Note deletion is instant, unconfirmed and has no undo | High | High | S |
| UI-02 | The editor hardcodes "Saved"; every write failure is swallowed and `saveError` is dead | High | High | S |
| UI-03 | JSON import overwrites live notes by UUID — an old backup silently destroys newer edits | High | High | M |
| UI-04 | No flush of the debounced note draft on terminate; no dirty-state indicator | Medium | High | S |
| UI-05 | Auto-save bumps `updatedAt` every 350 ms, so the edited note jumps around the list while typing | Medium | High | S |
| UI-06 | Corrupt `scratchpad.json` silently yields an empty Notes page; `.bak` never surfaced, and a second corruption deletes the first backup | Medium | High | M |
| UI-07 | Settings only persist via "Save settings"; navigating away silently discards edits; no reset-to-defaults | Medium | High | S |
| UI-08 | "Auto-format transcript" has two sources of truth (status-bar menu vs. page `@State`) — Save silently reverts the menu | Medium | High | S |
| UI-09 | `HistoryPage` re-filters the whole history per row (`records`/`selectedRecord` are computed properties) → O(n²) work per render | Medium | High | S |
| UI-10 | Dictionary lists render in a non-lazy `VStack` inside a `ScrollView` (no virtualization) | Medium | High | S |
| UI-11 | All persistence + JSON encode/decode runs synchronously on the main actor | Medium | Medium | M |
| UI-12 | No single-instance guard: two copies of the app share the same JSON files and the same global hotkey | Medium | Medium | S |
| UI-13 | `fatalError` on launch when the Application Support directory can't be created → unkillable crash loop, no user-facing error | Medium | High | S |
| UI-14 | Only 4 dictionary suggestions are ever rendered, and the count shown ignores the search filter | Low | High | S |
| UI-15 | Accessibility: no Dynamic Type (fixed point sizes everywhere), no keyboard shortcuts, unlabelled icon-only clear button | Medium | High | M |
| UI-16 | `MicButton` labels itself "Start dictation" while transcribing; declared `reduceMotion` is never used | Low | High | S |
| UI-17 | Search is case-insensitive but not diacritic/ß-insensitive (German is a first-class language in this app) | Low | High | S |
| UI-18 | "Send to notes" / "Append latest" have no dedup and no reference to the note they touched | Low | Medium | S |
| UI-19 | Silent edit rejection: clearing both title and body is discarded with no feedback; a typed leading `#` in tags disappears | Low | High | S |
| UI-20 | Migration is not crash-safe or repeatable: an interrupted migration strands legacy notes | Low | Medium | M |
| UI-21 | Dead code: 5 unused views, 1 unused function, 12 unused Theme aliases, `NotesStore` is now migration-only | Low | High | S |
| UI-22 | Consistency nits: `PremiumSection` corner-radius mismatch (12 vs 8), Markdown export emits invalid multi-word tags, no dark mode, no version anywhere | Low | High | S |
| UI-23 | `try!` in `LanguageMemoryMatcher.wordBoundaryRegex` on a path exercised during formatting | Low | High | S |
| UI-24 | `Task { }` in `SettingsPage.testConnection` reads `@State` off the main context (possible data race) | Low | Low | S |

---

## Details

### UI-01 — Note deletion is instant, unconfirmed and has no undo
**Severity:** High · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/Pages/ScratchpadPage.swift:243-246`, `Sources/UsefulVoiceApp/ViewModels/ScratchpadViewModel.swift:87-93`, `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:75-78`

**Evidence** (`ScratchpadPage.swift:243`):
```swift
Button("Delete note", role: .destructive) {
    scratchpad.deleteSelected()
    toasts.show("Note deleted", kind: .info)
}
```
This sits one click deep in the "More note actions" menu next to "Duplicate note", with no `confirmationDialog` (contrast `HistoryPage.swift:39-51`, which *does* confirm "Delete all transcripts"). The store persists immediately and there is no trash, undo, or backup of the removed note:

```swift
// ScratchpadStore.swift:75
public func delete(id: UUID) {
    notes.removeAll { $0.id == id }
    save()
}
```

**Why it matters in production:** A mis-click permanently destroys the user's only copy of a dictated note. There is no `Undo` for this path — `AppDelegate.installMainMenu()` (`AppDelegate.swift:103-104`) wires Cmd-Z to `undo:`, which reaches the focused `NSTextView`, not the store — so a user who reflexively hits Cmd-Z gets nothing and does not learn the text is gone until much later. The `.bak` file is only ever a copy of a *corrupt* file, never of a deleted note, so there is no recovery path at all.

**Fix:** Gate the destructive action behind a `confirmationDialog` exactly like `HistoryPage.showClearConfirm`, or implement a soft delete (`ScratchpadStore` keeps `deletedAt` and `all()` filters it) plus an "Undo" action on the toast (`AppToastCenter` already supports one-at-a-time toasts, so an `undo` closure + 5 s window is a small addition). Also move "Delete note" out of the overflow menu into the toolbar and label it clearly.

---

### UI-02 — The editor hardcodes "Saved"; every write failure is swallowed and `saveError` is dead
**Severity:** High · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/Pages/ScratchpadPage.swift:173-176` and `:179-184`; `Sources/UsefulVoiceApp/ViewModels/ScratchpadViewModel.swift:13`, `:83`; `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:169-180`

**Evidence** (`ScratchpadPage.swift:170-176`):
```swift
Text("\(ScratchpadNote.wordCount(in: scratchpad.draftBody)) words")
    .font(.system(size: 11, weight: .medium).monospacedDigit())
    .foregroundStyle(Theme.muted)
Text("Saved")
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(Theme.success)
```
"Saved" is unconditional — it is not derived from any state. The error channel that was presumably meant to drive it is never populated: `saveError` is *only* ever assigned `""`:
```swift
// ScratchpadViewModel.swift:13
@Published var saveError = ""
// ScratchpadViewModel.swift:83
saveError = ""
```
(verified: `grep -rn saveError Sources/` returns exactly those two writes plus the read in `ScratchpadPage`). Underneath, the write itself can fail invisibly:
```swift
// ScratchpadStore.swift:174-179
guard let data = try? Self.encoder.encode(persisted) else { return }
try? FileManager.default.createDirectory(
    at: fileURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try? data.write(to: fileURL, options: .atomic)
```
`save()` returns `Void`, so `commitDraft()` cannot tell success from failure. `NotesStore.save()` (`NotesStore.swift:51-55`) has the same shape.

**Why it matters in production:** The full-disk / permission-denied / sandboxed-container case produces the worst possible outcome: the UI says "Saved" in green on every keystroke while nothing reaches disk. The user writes for an hour, quits, and arrives at an empty Notes page with no error ever shown, and nothing in the app's own logs. This is unbounded silent data loss guarded by an explicit false statement in the UI.

**Fix:** Make persistence failable — `@discardableResult func save() throws` (or return `Bool`) on `ScratchpadStore`, propagate through `update`/`add`/`delete`, and have `commitDraft()` do:
```swift
do { try store.update(note); saveState = .saved }
catch { saveError = "Could not save to disk: \(error.localizedDescription)" }
```
Drive the badge from a real `enum SaveState { case saved, saving, failed }` so "Saved" only appears after a successful write, and show `saveError` (the view already has the slot at `ScratchpadPage.swift:179-184`).

---

### UI-03 — JSON import overwrites live notes by UUID; an old backup silently destroys newer edits
**Severity:** High · **Confidence:** High · **Effort:** M

**File/lines:** `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:136-152`; `Sources/UsefulVoiceApp/Pages/ScratchpadPage.swift:304-311`

**Evidence** (`ScratchpadStore.swift:141-152`):
```swift
for note in imported {
    guard let normalized = normalized(note) else {
        invalid.append(note.id.uuidString)
        continue
    }
    if let index = notes.firstIndex(where: { $0.id == normalized.id }) {
        notes[index] = normalized          // ← unconditional overwrite, no timestamp check
        updated += 1
    } else {
        notes.append(normalized)
        inserted += 1
    }
}
```
The UI presents this as a harmless merge, with no confirmation step and no warning about replacements:
```swift
// ScratchpadPage.swift:305
guard let result = scratchpad.importJSON(importText) else { ... }
importMessage = "Imported \(result.inserted) new and updated \(result.updated)."
```
"Restore a backup" is the *only* recovery mechanism this app advertises (there is no versioned backup on disk), and `exportAllJSON()` writes the same UUIDs the store uses.

**Why it matters in production:** A user who restores a week-old backup to recover one note silently reverts every note edited since that backup, including ones they never intended to touch. The result message ("updated 12") reads as success. The bundled test even codifies the destructive semantics as intent (`ScratchpadStoreTests.swift:106-111` asserts a second import yields `updated: 2`).

**Fix:** In `importJSON`, compare `normalized.updatedAt` with `notes[index].updatedAt` and only replace when the incoming note is newer; count and report conflicts separately (`skippedStale`), or import conflicts as *copies* ("(imported)" suffix, new UUID) and let the user choose. In `ScratchpadPage`, add a `confirmationDialog` before importing into a non-empty store stating how many notes will be replaced, and surface `result.invalid.count` (currently dropped).

---

### UI-04 — No flush of the debounced note draft on terminate; no dirty-state indicator
**Severity:** Medium · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift` (no `applicationWillTerminate`/`applicationShouldTerminate` — verified by grep: zero matches for either, and zero matches for `atexit`/`scenePhase` in `Sources/`); `Sources/UsefulVoiceApp/ViewModels/ScratchpadViewModel.swift:165-172`; `Sources/UsefulVoiceApp/Pages/ScratchpadPage.swift:31`

**Evidence** (`ScratchpadViewModel.swift:165`):
```swift
private func scheduleSave() {
    pendingSave?.cancel()
    let work = DispatchWorkItem { [weak self] in
        Task { @MainActor in self?.commitDraft() }
    }
    pendingSave = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
}
```
The only explicit flush is a view lifecycle hook:
```swift
// ScratchpadPage.swift:31
.onDisappear { scratchpad.commitDraft() }
```
`AppDelegate` implements only `applicationDidFinishLaunching` (`:67`) and `applicationShouldHandleReopen` (`:80`); quitting with Cmd-Q or the status-bar "Quit Useful Voice" item (`AppDelegate.swift:95`) calls `NSApplication.terminate` and tears the process down without ever running the pending `asyncAfter` block.

**Why it matters in production:** Edits are committed at most 350 ms after the last keystroke, so the honest worst case is the final few characters typed before a quit or a crash — bounded, but real and reproducible ("type a word, hit Cmd-Q"). More importantly there is no dirty/pending indicator anywhere: the "Saved" badge in UI-02 is unconditional, so the user has no way to know a write is in flight. `onDisappear` is also *not* a reliable flush for window close: `MainWindowController.windowWillClose` (`MainWindowController.swift:37-40`) only flips the activation policy and the window is retained with `isReleasedWhenClosed = false`, so the SwiftUI hierarchy is not necessarily torn down — in that path the flush depends on the pending timer still firing before app exit, not on the lifecycle hook.

**Fix:** Implement `func applicationWillTerminate(_:)` on `AppDelegate` and call `viewModel?.scratchpad.commitDraft()` (plus a synchronous `flush()` on `ScratchpadViewModel` that cancels `pendingSave` and commits immediately). Also commit in `MainWindowController.windowWillClose`. Optionally shorten the debounce to ~150 ms and add `.onChange(of: draftBody)`-driven dirty state so the badge can show "Saving…".

---

### UI-05 — Auto-save bumps `updatedAt` every 350 ms, so the edited note jumps around the list while typing
**Severity:** Medium · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/ViewModels/ScratchpadViewModel.swift:75-85`; `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:217-223`

**Evidence** (`ScratchpadViewModel.swift:75`):
```swift
func commitDraft() {
    pendingSave?.cancel()
    guard var note = selected else { return }
    note.title = draftTitle
    note.body = draftBody
    note.tags = tagsFromDraft()
    note.updatedAt = Date()          // ← every auto-save
    store.update(note)
```
and the store sorts by exactly that field:
```swift
// ScratchpadStore.swift:217
private static func sorted(_ notes: [ScratchpadNote]) -> [ScratchpadNote] {
    notes.sorted { lhs, rhs in
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.createdAt > rhs.createdAt
    }
}
```
`commitDraft()` then calls `refresh()` (`:84`), which republishes `notes` in the new order; `ScratchpadPage` renders that array directly in a `LazyVStack` (`:107-115`).

**Why it matters in production:** Open an older note from the middle of the list and type: after the first 350 ms pause the row teleports to the top of the list under the user's cursor, dragging every other row with it. On every subsequent pause the sort key changes again. If the user is mid-click on a row when the reorder lands, they select the wrong note. This also destroys "most recently edited" as meaningful information, since a single keystroke rewrites the timestamp.

**Fix:** Keep the sort key stable while a draft is open: only bump `updatedAt` when the note is deselected/committed on exit (`ScratchpadViewModel.select` already calls `commitDraft()` — pass a flag so the intermediate auto-saves persist text *without* changing the sort key), or keep a separate `editedAt` for display and sort the list by `createdAt`/a pinned-first manual order. Cheapest robust option: sort by `updatedAt` only at load time and keep the in-memory order stable during a session.

---

### UI-06 — Corrupt `scratchpad.json` silently yields an empty Notes page; `.bak` never surfaced; second corruption deletes the first backup
**Severity:** Medium · **Confidence:** High · **Effort:** M

**File/lines:** `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:16-23` and `:251-255`

**Evidence** (`ScratchpadStore.swift:16-23`):
```swift
if let persisted = try? Self.decoder.decode(ScratchpadPersisted.self, from: data) {
    notes = Self.sorted(persisted.notes)
} else if let legacy = try? Self.decoder.decode([ScratchpadNote].self, from: data) {
    notes = Self.sorted(legacy)
} else {
    Self.backUpCorruptFile(fileURL)
    notes = []
}
```
```swift
// ScratchpadStore.swift:251
private static func backUpCorruptFile(_ url: URL) {
    let backup = url.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: backup)   // ← destroys any previous backup
    try? FileManager.default.moveItem(at: url, to: backup)
}
```
There is no `Result`/flag returned to the app layer: `ScratchpadMigrator.migrateIfNeeded` (`:6`) and `AppDelegate.setUpController` (`:149-152`) both ignore the condition, so nothing in the UI distinguishes "you have no notes" from "your notes could not be read".

**Why it matters in production:** A truncated write, a partial iCloud/Dropbox sync, or a hand-edited file leaves the user staring at "No notes yet — Create a note or send a transcript from Library." Their data is actually at `~/Library/Application Support/Sadaa/scratchpad.json.bak`, a path the app never mentions and only reachable by hand in Finder. If a *second* corruption occurs before they find it, the second `backUpCorruptFile` deletes the first backup, destroying the only copy. Note also that a corrupt file is moved aside and then immediately replaced by the empty store on the next save, so the window to notice is small.

**Fix:** Return recovery status from `ScratchpadStore.init` (e.g. `public private(set) var recovery: RecoveryState` = `.ok` / `.restoredFromBackup(URL)`), surface it as a persistent banner on `ScratchpadPage` with a "Restore backup…" button that feeds the `.bak` through the existing `importJSON` path. Give backups unique names (`scratchpad-corrupt-\(timestamp).json`) and keep the N most recent instead of deleting. Do the same for `NotesStore` (`NotesStore.swift:17-21`) and `LanguageMemoryStore`.

---

### UI-07 — Settings only persist via "Save settings"; navigating away silently discards edits; no reset-to-defaults
**Severity:** Medium · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/Pages/SettingsPage.swift:26-43`, `:302-309`, `:311-333`; `Sources/UsefulVoiceApp/RootView.swift:135-149`

**Evidence** (`SettingsPage.swift:302`):
```swift
private func load() {
    hasDeepgramKey = Keychain.exists(account: "deepgram-key")
    formattingEnabled = settings.formattingEnabled
    silenceTimeout = settings.silenceTimeout
    recordsToKeep = settings.recordingsToKeep
    soundEffectsEnabled = settings.soundEffectsEnabled
    launchAtLogin = LoginItem.isEnabled
}
```
called only from `.onAppear(perform: load)` (`:42`), while `RootView.detail` is a `switch` that constructs a fresh page per section:
```swift
// RootView.swift:137
switch selection {
case .home: HomePage(viewModel: viewModel)
...
case .settings: SettingsPage(settings: settings, viewModel: viewModel)
}
```
So switching sections destroys the page and its `@State`; coming back re-runs `load()` from the persisted values. Edits are only written in `save()` (`:315-318`). There is no "Reset to defaults" control anywhere on the page, and none of the four non-secret settings has one.

**Why it matters in production:** A user drags "Stop after silence" from 60 s to 30 s, clicks "Notes" to check a note, returns — the slider is back at 60 s with no message. The same is true for "Keep recordings" and "Sound cues". Users will read this as "the setting doesn't stick" and file a bug against persistence that is actually working as written. Deprecated-by-design: the settings that *do* stick (language, hotkeys) apply immediately through bindings, so the page behaves inconsistently with itself.

**Fix:** Either save on change (`.onChange` per control → `settings.x = …`, dropping the button to a status indicator), or keep the Save button but add explicit state: mark the page dirty, warn on navigation ("Unsaved settings changes"), and add a "Reset to defaults" button per section that writes the defaults from `AppSettings` (add `static let defaultX` constants there so the page and the menu agree). Persist page-local `@State` outside the switched view (hoist to `RootView`) if unsaved-edit survival is desired.

---

### UI-08 — "Auto-format transcript" has two sources of truth; Save silently reverts the status-bar toggle
**Severity:** Medium · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:642-647` and `:633-636`; `Sources/UsefulVoiceApp/Pages/SettingsPage.swift:11`, `:167`, `:304`, `:315`

**Evidence** — the menu writes the store directly:
```swift
@objc private func toggleSmartFormatting() {
    settings.formattingEnabled.toggle()
    formattingMenuItem?.state = settings.formattingEnabled ? .on : .off
}
```
while the page holds an independent copy that is only refreshed in `load()`:
```swift
@State private var formattingEnabled = true      // :11
Toggle("", isOn: $formattingEnabled)             // :167
formattingEnabled = settings.formattingEnabled    // :304 (load)
settings.formattingEnabled = formattingEnabled    // :315 (save)
```
The menu also updates only its own checkmark (`formattingMenuItem`), never the page.

**Why it matters in production:** With the Settings page open, the user turns "Auto-format transcript" off from the menu-bar menu (the window stays open behind it), decides the page looks fine, and presses "Save settings" — which writes the page's stale `true` back and silently re-enables formatting. The user then gets punctuation behavior they believe they disabled and has no way to see why.

**Fix:** Make `AppSettings` observable (`final class AppSettings: ObservableObject` with `@Published`-backed properties, or a small `SettingsStore` struct published by `UsefulVoiceViewModel`) and bind the page directly to it — remove the mirrored `@State` entirely. If the mirror is kept, have the menu post a notification (`NotificationCenter.default.post(name: .settingsDidChange)`) that the page observes and reloads from.

---

### UI-09 — `HistoryPage` re-filters the whole history per row → O(n²) work per render
**Severity:** Medium · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/Pages/HistoryPage.swift:16-26`, used at `:79`, `:90`, `:121`, `:150`, `:155`

**Evidence**:
```swift
private var records: [DictationRecord] {
    _ = viewModel.recent.count
    return viewModel.historyStore.search(query)      // full scan + new array, per access
}

private var selectedRecord: DictationRecord? {
    if let selectedID, let selected = records.first(where: { $0.id == selectedID }) {
        return selected
    }
    return records.first
}
```
and inside the row builder, called once per row:
```swift
// HistoryPage.swift:121
.foregroundStyle(selectedRecord?.id == record.id ? Theme.brand : Theme.muted)
```
`selectedRecord` is called three times per row (`:121`, `:150`, `:155`), and each call re-runs `historyStore.search(query)` — which itself is `records.filter { … }` (`DictationHistory.swift:76-78`).

**Why it matters in production:** With 500 retained transcripts, one render of the list performs ≈1500 full-history filters, each allocating a fresh array of up to 500 records — hundreds of thousands of string comparisons plus megabytes of transient allocation *on the main thread*, and this re-runs on every selection change (`selectedID = record.id` in the row button). Scrolling/selecting in a long library gets progressively laggy; the `_ = viewModel.recent.count` line is a hack to force SwiftUI to re-read the non-observable store, which means the cost is paid on unrelated updates too.

**Fix:** Compute once per body evaluation into a local:
```swift
let matching = viewModel.historyStore.search(query)
let selected = matching.first { $0.id == selectedID } ?? matching.first
let groups = grouped(matching)
```
and pass `isSelected: selected?.id == record.id` down into `transcriptRow(_:isSelected:)`. Make `DictationHistory` (and `ScratchpadStore`/`LanguageMemoryStore`) `ObservableObject`s publishing a revision counter, and cache the search result with `@State`/`.onChange(of: query)` instead of `_ = viewModel.recent.count`. `ScratchpadPage` has the same pattern (`scratchpad.filteredNotes` is called at `:88`, `:97`, `:108`, each a fresh `store.search`), but with a smaller typical dataset.

---

### UI-10 — Dictionary lists render in a non-lazy `VStack` inside a `ScrollView`
**Severity:** Medium · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/Pages/LanguageMemoryPage.swift:286-291` and `:317-334`; compare `ScratchpadPage.swift:107` (`LazyVStack`) and `HistoryPage.swift:89`

**Evidence**:
```swift
} else {
    VStack(spacing: 0) {
        content()        // ForEach(viewModel.filteredTerms) / filteredReplacements
    }
    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}
```
The `words` and `corrections` sections (`:223`, `:235`) therefore build every row eagerly, and the snippets list (`:317-334`) does the same inside a plain `VStack`. The only thing above them is a `ScrollView` (`:22`).

**Why it matters in production:** "Import dictionary" (`:428-443`) accepts a whole JSON backup or CSV with no size limit; `LanguageMemoryStore.importSnapshot` inserts them all and `refresh()` republishes. A user importing a few thousand terms gets a frozen page — every row (`MemoryTermRow` with icons, backgrounds and overlays, `MemoryRows.swift:8-41`) is instantiated and laid out on the main thread in one pass, and the search field then re-filters on every keystroke against that fully built hierarchy.

**Fix:** Wrap the row containers in `LazyVStack(spacing: 0, pinnedViews: [])` instead of `VStack(spacing: 0)` at both `:286` and `:317`. Consider a `ScrollView` `LazyVStack` with `ForEach` inside `entriesList` reusing one implementation. Cap or warn on import size (e.g. >5000 entries) and log the count in the import result message.

---

### UI-11 — All persistence and JSON work is synchronous on the main actor
**Severity:** Medium · **Confidence:** Medium · **Effort:** M

**File/lines:** `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:169-180`; `Sources/UsefulVoiceCore/Notes/NotesStore.swift:51-55`; `Sources/UsefulVoiceCore/LanguageMemory/LanguageMemoryStore.swift:346-356`; `Sources/UsefulVoiceApp/ViewModels/ScratchpadViewModel.swift:75-85`; `Sources/UsefulVoiceApp/ViewModels/LanguageMemoryViewModel.swift:171-177`, `:198-220`

**Evidence** (`ScratchpadStore.swift:169`):
```swift
private func save() {
    let persisted = ScratchpadPersisted(
        version: ScratchpadPersisted.currentVersion,
        notes: notes
    )
    guard let data = try? Self.encoder.encode(persisted) else { return }
    ...
    try? data.write(to: fileURL, options: .atomic)
}
```
The stores are plain classes (no actor, no queue) reached from `@MainActor` view models and from `AppDelegate` (`@MainActor`, `AppDelegate.swift:7`) — every `commitDraft` re-encodes and rewrites the *entire* notes array, and the import/export helpers (`LanguageMemoryViewModel.exportSnapshotJSON` at `:171`, `importSnapshotJSON` at `:179`, `importTermsCSV`/`importReplacementsCSV` at `:198`/`:210`, `ScratchpadViewModel.importJSON` at `:145`) decode/encode whole documents inline on the calling (main) actor.

**Why it matters in production:** The trailing-edge debounce (350 ms) keeps *continuous* typing cheap, but each pause still pays a full encode + atomic write of the whole file (all notes, all bodies, ISO-8601 dates) on the main thread; with a large scratchpad (tens of MB of dictated text) that is a visible input hitch right after the user stops typing — the worst possible moment for one. The genuinely bad case is import/export: pasting a 5 MB JSON backup and pressing Import blocks the main thread for the entire decode + insert + re-encode + write, with no progress UI (`isTesting`-style state does not exist here), so the window beachballs and macOS may offer to force-quit.

**Fix:** Move encode/decode + file I/O off the main actor: give each store a private serial `DispatchQueue` (or make the store an `actor`) with the in-memory array staying the synchronous source of truth for reads, and have `save()` do `queue.async { try? data.write(...) }`. Keep write ordering with the serial queue (do not use a global concurrent queue — that would break the atomic-write guarantee). For import, run the decode/validate on a background task and apply the result on the main actor, showing a spinner. A quick interim step: encode on a background queue while keeping the array snapshot capture synchronous.

---

### UI-12 — No single-instance guard: two copies share the same JSON files and the same global hotkey
**Severity:** Medium · **Confidence:** Medium · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/main.swift:1-10`; `bundle/Info.plist` (no `LSMultipleInstancesProhibited`); `Sources/UsefulVoiceApp/AppDelegate.swift:129-152`, `:465-497`

**Evidence**:
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
Verified by grep: zero hits for `NSRunningApplication`, `runningApplications`, `LSMultipleInstancesProhibited`, `flock` or `NSDistributedLock` in `Sources/` and `bundle/`. Every store opens the same paths (`~/Library/Application Support/Sadaa/{scratchpad,history,language-memory,dictionary,snippets}.json`, `AppDelegate.swift:140-151`) and each `save()` rewrites the whole file from its own in-memory array.

**Why it matters in production:** LaunchServices normally routes `open` to an existing instance, so the everyday double-click case is fine — but nothing stops a second instance: a dev running `dist/UsefulVoice.app` while `/Applications/Useful Voice.app` is installed (exactly what `make run` does without `make install`), a second copy in `~/Downloads`, or `open -n`. The two processes then keep divergent in-memory copies of the same file, and the *last* writer wins on the entire document — the other instance's notes, edits and history additions vanish with no error. Both also install a CGEvent tap for the same hotkey (`startHotkeys`, `:439-483`) and a status item, so one keypress fires two dictations into the frontmost app.

**Fix:** Add a launch guard at the top of `main.swift`: `guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).isEmpty else { NSApp.activate…; exit(0) }` (or take an exclusive `flock` on a lock file in the support directory, which also covers two copies with different bundle IDs). Add `<key>LSMultipleInstancesProhibited</key><true/>` to `bundle/Info.plist`. Independently, consider a `.bak`-style optimistic-concurrency check in `save()` (compare file mtime/size before overwriting) so an external writer cannot be silently clobbered.

---

### UI-13 — `fatalError` on launch when the support directory can't be created
**Severity:** Medium · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/AppDelegate.swift:133-135`

**Evidence**:
```swift
guard let store = try? RecordingStore(directory: appSupport) else {
    fatalError("Cannot create recordings directory at \(appSupport.path)")
}
```
Reached from `applicationDidFinishLaunching` (`:72`).

**Why it matters in production:** If `~/Library/Application Support` is unwritable (full disk, weird ACLs, a managed Mac blocking app-support subdirectories, or a sandboxed/copied home), the app dies during launch — before the status item and menu exist, so the user sees only a Dock bounce or nothing at all (it is an `LSUIElement` accessory app). Relaunching reproduces it exactly: an unresolvable crash loop with a message visible only in Console/crash logs, and no way to reach the running app. This is the single unguarded crash on the launch path.

**Fix:** Don't crash. Fall back to a user-visible, degraded state: try the Application Support path, then `FileManager.default.temporaryDirectory`, then show the HUD error (`hud.show(.error("Useful Voice can't write to its data folder. Check disk space and permissions."))`, `hud.hide(after: 20)`) and keep the app alive with recording disabled. Return `Optional` from `setUpController()` and let `applicationDidFinishLaunching` skip `mainWindow.show` if setup failed.

---

### UI-14 — Only 4 dictionary suggestions are ever rendered, and the count ignores the search filter
**Severity:** Low · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/Pages/LanguageMemoryPage.swift:74`, `:79`

**Evidence**:
```swift
Spacer()
Text("\(viewModel.suggestions.count)")                     // total, unfiltered
...
ForEach(viewModel.filteredSuggestions.prefix(4)) { suggestion in
```
The header count reads the raw array while the list reads the filtered one, and `.prefix(4)` is applied with no "show more" affordance.

**Why it matters in production:** A user with 30 learned suggestions sees "30" beside 4 rows and has no way to reach the rest except by adding/dismissing the visible four — the other 26 are effectively invisible. Typing in the search field changes the rows but not the count, so the numbers on screen contradict each other (e.g. "30" next to "No matches" behavior).

**Fix:** Use `viewModel.filteredSuggestions.count` for the badge, and render the list lazily with a "Show all (N)" disclosure that flips a `@State private var showAllSuggestions` — or move suggestions to their own scrollable section/card.

---

### UI-15 — Accessibility: no Dynamic Type, no keyboard shortcuts, one unlabelled icon-only button
**Severity:** Medium · **Confidence:** High · **Effort:** M

**File/lines:** every page/component; representative: `PremiumControls.swift:125-134`, `RootView.swift:83-101`; verified by grep: zero `keyboardShortcut`, zero `Font.TextStyle`/`relativeTo:` usages in `Sources/UsefulVoiceApp/`.

**Evidence** (unlabelled, un-hinted clear button, ~12 pt hit target):
```swift
if !text.isEmpty {
    Button {
        text = ""
    } label: {
        Image(systemName: "xmark.circle.fill")
            .foregroundStyle(Theme.inkFaint)
    }
    .buttonStyle(.plain)
    .clickableCursor()
}
```
and the typography pattern used throughout (e.g. `HomePage.swift:90`, `ScratchpadPage.swift:139`, `SettingsPage.swift:217`):
```swift
.font(.system(size: 22, weight: .semibold))
```
Only 5 `.accessibilityLabel` calls exist in the entire app (`RootView.swift:80`, `:97`, `PremiumControls.swift:196`, `:230`, `MicButton.swift:35`); everything else relies on `.help()` (10 uses) or on SwiftUI inferring a label from an SF Symbol name ("trash", "doc.on.doc"). There are zero `keyboardShortcut` modifiers, so no section can be reached without the mouse beyond AppKit's default Tab handling (which requires the user to enable "Keyboard navigation" first), and `.clickableCursor()` on a `.plain` button does not add focusability.

**Why it matters in production:** The app is unusable for low-vision users: fixed point sizes mean the system "larger text" preference is ignored entirely (nothing scales), and there is no in-app zoom. VoiceOver users hear "trash, button" / "doc dot on doc, button" for the destructive and copy actions, and "xmark circle fill, button" for clearing search — the SF Symbol names, not the intent. Keyboard-only users cannot navigate five sections, cannot trigger "New note", and cannot delete without a mouse; the only wired key equivalents are Cmd-Q, Cmd-Z/X/C/V/A and Cmd-, (`AppDelegate.swift:95-119`, `:617-621`).

**Fix:** (1) Add `.accessibilityLabel("Clear search")` (and a `.frame(minWidth: 22, minHeight: 22)` + `.contentShape`) to the clear button, and audit every icon-only button. (2) Express fonts semantically where it matters (`.font(.title2.bold())` etc., or `.font(.system(size: 15, weight: .regular))` retained but with `@ScaledMetric` for the container sizes) so macOS text-size settings apply; at minimum add an `.dynamicTypeSize` respect path for the note body and settings labels. (3) Add `.keyboardShortcut("1"..."5", modifiers: .command)` to the sidebar items and Cmd-N for "New note", Cmd-S to commit the draft, and `.focusable()` on rows. (4) Prefer `.help()` **and** `.accessibilityLabel()` together — `.help` is a tooltip, not a substitute.

---

### UI-16 — `MicButton` mislabels itself while transcribing; declared `reduceMotion` is unused
**Severity:** Low · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/Components/MicButton.swift:8`, `:64-66`, `:69-74`

**Evidence**:
```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion   // :8 — never read
...
private var accessibilityLabel: String {
    state == .recording ? "Stop dictation" : "Start dictation"       // :65
}
```
The `.transcribing` and `.delivering` states show a `ProgressView` (`:53-56`) but still announce "Start dictation", and the button remains enabled in those states. Meanwhile `PressButtonStyle` animates unconditionally and the hover shadow animation (`:21-25`, `:33`) ignores the Reduce Motion setting the component bothered to read.

**Why it matters in production:** A VoiceOver user pressing the control while a transcription is in flight is told they can start dictation, which is wrong and encourages a double-trigger. Reduce Motion users still get the scaling/shadow motion — a small but explicit accessibility-preference violation in a component that declares the environment value.

**Fix:**
```swift
private var accessibilityLabel: String {
    switch state {
    case .recording: return "Stop dictation"
    case .transcribing: return "Transcribing, please wait"
    case .delivering: return "Inserting text"
    case .idle, .error: return "Start dictation"
    }
}
```
add `.disabled(state == .transcribing || state == .delivering)` (and make `DictationController.toggle()` a no-op in those states if it isn't already), and gate animations: `.animation(reduceMotion ? nil : .easeOut(duration: 0.14), value:)`.

---

### UI-17 — Search is case-insensitive but not diacritic/ß-insensitive
**Severity:** Low · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:30-38`; `Sources/UsefulVoiceCore/History/DictationHistory.swift:73-79`; also `Sources/UsefulVoiceApp/ViewModels/LanguageMemoryViewModel.swift:222-228`

**Evidence**:
```swift
public func search(_ query: String) -> [ScratchpadNote] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return all() }
    return all().filter { note in
        note.title.range(of: trimmed, options: .caseInsensitive) != nil ||
        note.body.range(of: trimmed, options: .caseInsensitive) != nil ||
        note.tags.contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
    }
}
```
Only `.caseInsensitive` is passed — no `.diacriticInsensitive`, no `.widthInsensitive`, and no folding of `ß`/`ss`.

**Why it matters in production:** This is a bilingual (explicitly German-supported) dictation app whose German transcriptions contain `ü/ö/ä/ß`. Searching "uber" does not find "über", "strasse" does not find "Straße", and "Muenchen" does not find "München" — the user concludes their note is gone. Also note `ScratchpadStore.search` deliberately does *not* search `createdAt`/dates, and `DictationHistory.search` searches only `text`, never `rawText`, so a phrase visible in the "Original transcript" disclosure on the detail pane is not findable.

**Fix:** Add `.diacriticInsensitive` to every `range(of:options:)` call (three in `ScratchpadStore.select`, one in `DictationHistory.search`, one in `LanguageMemoryViewModel.filter`), and consider `String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)` for the ß/ss case. Add a test row for "uber" → "über" in `ScratchpadStoreTests.testSearchMatchesTitleBodyAndTags`.

---

### UI-18 — "Send to notes" / "Append latest" have no dedup and no link to the note they touched
**Severity:** Low · **Confidence:** Medium · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/UsefulVoiceViewModel.swift:119-121`; `Sources/UsefulVoiceApp/ViewModels/ScratchpadViewModel.swift:109-130`; `Sources/UsefulVoiceApp/Pages/ScratchpadPage.swift:212-222`; `Sources/UsefulVoiceApp/Pages/HomePage.swift:130-133`

**Evidence**:
```swift
// UsefulVoiceViewModel.swift:119
func sendToScratchpad(_ record: DictationRecord) {
    scratchpad.createDictationNote(record.text)      // always a NEW note
}
```
```swift
// ScratchpadViewModel.swift:124
func createDictationNote(_ text: String) -> ScratchpadNote? {
    guard let note = store.captureDictation(text) else { return nil }   // title "Dictation"
```
versus the page's separate append path:
```swift
// ScratchpadPage.swift:212
Button("Append latest") { ... scratchpad.appendTextToSelectedOrCreate(latest) ... }
```
Both entry points show a success toast (`"Sent to notes"`, `"Latest dictation appended"`) regardless of what happened, and `appendTextToSelectedOrCreate` appends `viewModel.recent.first?.text` — "latest *transcript*", not "latest since last append".

**Why it matters in production:** Two clicks on "Send to notes" for the same utterance create two indistinguishable notes titled "Dictation" with identical bodies; two clicks on "Append latest" insert the same paragraph twice into the note. Neither the toast nor the note list tells the user which note was touched, so the only way to find the result is to sort/inspect. Duplicated text in a dictated note is exactly the failure mode this feature is supposed to avoid.

**Fix:** Make both actions idempotent and traceable: `captureDictation` should return the existing note when a note created from the same `DictationRecord.id` already exists (add `sourceRecordID: UUID?` to `ScratchpadNote` and look it up first); `appendTextToSelectedOrCreate` should skip the append when the selected note's body already ends with the same text. Change the toasts to name the target ("Appended to \"Plan\"", "Updated the dictation note") and add a "Go to note" action that switches `RootView.selection` to `.scratchpad` and selects the note.

---

### UI-19 — Silent edit rejection: clearing both title and body is discarded; a typed leading `#` disappears
**Severity:** Low · **Confidence:** High · **Effort:** S

**File/lines:** `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:63-73` and `:182-198`; `Sources/UsefulVoiceApp/ViewModels/ScratchpadViewModel.swift:75-85`

**Evidence**:
```swift
public func update(_ note: ScratchpadNote) {
    guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
    let normalized = normalize(title: note.title, body: note.body, tags: note.tags)
    guard !normalized.title.isEmpty || !normalized.body.isEmpty else { return }   // silent no-op
```
and the tag normalizer strips a leading `#` that the user typed:
```swift
let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
```
`commitDraft()` never reloads the draft after the store call, so the rejected value stays on screen — and the badge still says "Saved".

**Why it matters in production:** A user who clears a note's title and body to "reset" it sees an empty editor, quits, returns, and the old text is back — indistinguishable from an auto-save failure, and it undermines the same trust that UI-02 damages. Conversely the '#' behaviour is a *correct* normalization surfaced badly: the field shows "#work", the store holds "work", and on the next `loadSelectedDraft()` the '#' vanishes as if the user's keystroke was ignored.

**Fix:** Return a result from `store.update` (`.updated` / `.rejectedEmpty`) and have `commitDraft()` react: on `.rejectedEmpty`, keep the draft but show an inline hint ("A note needs a title or some text"), or allow genuinely empty notes and prune them on deselect. Normalize tags on *entry* (`updateDraftTags`) so the field text matches what is stored, or keep the '#' consistently in both places.

---

### UI-20 — Migration is not crash-safe or repeatable
**Severity:** Low · **Confidence:** Medium · **Effort:** M

**File/lines:** `Sources/UsefulVoiceCore/Scratchpad/ScratchpadMigrator.swift:6-21`

**Evidence**:
```swift
public static func migrateIfNeeded(scratchpadURL: URL,
                                   notesURL: URL) -> ScratchpadStore {
    let scratchpad = ScratchpadStore(fileURL: scratchpadURL)
    guard !FileManager.default.fileExists(atPath: scratchpadURL.path),
          FileManager.default.fileExists(atPath: notesURL.path)
    else { return scratchpad }

    let notesStore = NotesStore(fileURL: notesURL)
    for note in notesStore.all().reversed() {
        _ = scratchpad.add(title: title(from: note.text), body: note.text, tags: [], createdAt: note.createdAt)
    }
    return scratchpad
}
```
`add()` persists after *every* note (`ScratchpadStore.swift:58-59`), so `scratchpad.json` comes into existence with the first migrated note; the guard is a pure file-existence check with no completion marker.

**Why it matters in production:** Two failure modes. (a) If the app is force-quit, crashes, or the machine loses power during the first post-upgrade launch, the remaining legacy notes are never migrated, and because `scratchpad.json` now exists, *no* subsequent launch will resume — the un-migrated notes are stranded in `notes.json` forever with no UI path to them. (b) If a user later deletes `scratchpad.json` (to "reset" their notes, or after UI-06 makes an empty store look like data loss), the migrator re-imports every legacy note, resurrecting notes they had deleted. The loop also runs synchronously on the main thread during launch with no progress indication.

**Fix:** Write a completion marker: migrate into a temp file, then atomically move it into place and rename `notes.json` → `notes.migrated.json` only after the whole batch is written (or set a `migratedFromNotes: true` flag inside `ScratchpadPersisted`). Add `store.add` calls into a single batch API (`ScratchpadStore.addMany(_:)`) that persists once, so the loop is one atomic write rather than N. Document/handle the `notes.json`-leftover case explicitly, and consider offering an explicit "Import legacy notes" action in the UI instead of an implicit migration.

---

### UI-21 — Dead code
**Severity:** Low · **Confidence:** High · **Effort:** S

Verified by symbol grep (each of these appears exactly once in `Sources/` — its own definition — and nowhere else):

| Symbol | Location |
|---|---|
| `PremiumStatusBadge` | `Components/PremiumControls.swift:53-79` |
| `PremiumSection` | `Components/PremiumControls.swift:274-306` |
| `CommandMetric` | `Components/PremiumControls.swift:666-700` |
| `CommandToolbarButton` | `Components/PremiumControls.swift:702-725` |
| `MemorySuggestionRow` | `Components/MemoryRows.swift:139-158` (the live suggestions UI is built inline in `LanguageMemoryPage.swift:79-99`) |
| `priorityTitle(_:)` | `Components/MemoryRows.swift:168-174` (private, never called) |
| 12 of the 42 `Theme` tokens | `Theme.swift:51-62` — `navy`, `navy800`, `gold`, `gold300`, `cream`, `creamSurface`, `sage`, `charcoal`, `white`, `focus`, `red` are all unreferenced outside `Theme.swift` |

Additionally, `NotesStore`/`Note` (`Sources/UsefulVoiceCore/Notes/`) now have exactly one production caller — `ScratchpadMigrator.migrateIfNeeded` — and `notes.json` is never written by the app again; the "Notes" feature in the UI is entirely the scratchpad. `RootView.AppIconMark` (`:170-183`) also keeps a two-step stale-asset lookup with a third fallback, which is three code paths for one 28 pt mark.

**Why it matters in production:** ~200 lines of unreachable UI code plus a legacy store are maintenance surface that will drift from the design system (the `PremiumSection` radius bug in UI-22 is exactly that drift), and they mislead readers into thinking there is a second notes system. The dead `Theme` aliases also invite new code to use the old palette names.

**Fix:** Delete the five unused views, `priorityTitle`, and the compatibility aliases; if `NotesStore` must stay for migration, move it under `Sources/UsefulVoiceCore/Scratchpad/` as `LegacyNotesStore` with a doc comment stating it is migration-only, and keep only its migration test (`NotesStoreTests` currently owns six tests of behaviour no user path exercises).

---

### UI-22 — Consistency nits (radius mismatch, Markdown export, dark mode, version)
**Severity:** Low · **Confidence:** High · **Effort:** S

**(a) `PremiumSection` border/background radius mismatch** — `Components/PremiumControls.swift:300-305` (if the class is kept per UI-21):
```swift
.background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
.overlay(
    RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Theme.line, lineWidth: 1)
)
```
The 12 pt fill and 8 pt stroke do not align, so the border cuts across the corner fill. Every other card uses matching radii (`CommandPanel:658-662`, `LanguageMemoryPage:144-145`). Fix: make both 12 (or both 8).

**(b) Markdown export produces invalid tags** — `Sources/UsefulVoiceCore/Scratchpad/ScratchpadStore.swift:155-167`:
```swift
if !note.tags.isEmpty {
    lines.append("")
    lines.append(note.tags.map { "#\($0)" }.joined(separator: " "))
}
```
Tags are normalized with only whitespace trimming and `#` stripping (`:185-191`), so a multi-word tag survives as `my tag` and exports as `#my tag` — which Markdown renders as the tag `#my` followed by the word "tag". Titles/bodies containing a line beginning with `#` or `---` are also copied verbatim into a document that uses `#` for the title and `\n\n---\n\n` as the note separator, so a note whose body starts with `---` corrupts the concatenated export. Also `exportMarkdown(id:)` is what the "Copy" chip in the note toolbar uses (`ScratchpadPage.swift:226-230`) while a second menu item "Copy as Markdown" (`:237-241`) does exactly the same thing — two labels, one behaviour.

**(c) No dark mode** — `Sources/UsefulVoiceApp/RootView.swift:50`: `.preferredColorScheme(.light)` is applied unconditionally, and `Theme` hardcodes light values only (`Theme.swift:10-49`). Deliberate per the "Useful Brain" design intent, but it means the app ignores the system appearance with no user override.

**(d) No version/build anywhere in the UI** — `bundle/Info.plist` carries `0.1.0` and there is no About panel, no `NSApplication.orderFrontStandardAboutPanel` call, and no version string in `SettingsPage`. Support conversations start with "which version?", and there is no way to answer from inside the app.

**Fix:** Align the radii; sanitize exported tags (`$0.replacingOccurrences(of: " ", with: "-")`) and escape/indent leading `#`/`-` in bodies; add a "Send feedback" style footer row in Settings showing `CFBundleShortVersionString` with a copy button; decide explicitly on dark mode (either add a second `Theme` variant + drop the `.preferredColorScheme` pin, or document the pin as intentional in the README).

---

### UI-23 — `try!` in `LanguageMemoryMatcher.wordBoundaryRegex`
**Severity:** Low · **Confidence:** High (the code is as quoted; the crash is not currently reachable) · **Effort:** S

**File/lines:** `Sources/UsefulVoiceCore/LanguageMemory/LanguageMemoryMatcher.swift:43-47`

**Evidence**:
```swift
static func wordBoundaryRegex(for phrase: String) -> NSRegularExpression {
    let escaped = NSRegularExpression.escapedPattern(for: phrase)
    let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}
```
This is the only `try!` in `Sources/` (verified by grep). The phrase is passed through `escapedPattern(for:)` first, so a malicious/garbled dictionary entry cannot inject regex syntax today, and the two lookarounds are fixed-width — i.e. I could not construct an input that makes this throw. It is still a force-crash in a path exercised *during formatting* for every term × every dictation (`matchingTermIDs` calls it per term at `:32`).

**Why it matters in production:** Any future edit that stops escaping (for example, to support a user-authored pattern, or adding a `(?i)`-style prefix poorly) turns this into an instant hard crash of the whole app on a dictation, in a hot path where the user cannot see the cause. The failure mode is total (process death) rather than degraded.

**Fix:** `return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) ?? NSRegularExpression()` — or better, build the pattern and log/return `nil` so the caller can fall back to a plain `range(of:)` containment check. Add a unit test with a pathological phrase (`"a)\\E((?<"` and a lone `"\\"`) asserting no crash.

---

### UI-24 — `Task { }` in `SettingsPage.testConnection` reads `@State` off the main context
**Severity:** Low · **Confidence:** Low · **Effort:** S

**File/lines:** `Sources/UsefulVoiceApp/Pages/SettingsPage.swift:335-366`

**Evidence**:
```swift
private func testConnection() {
    testResult = nil
    isTesting = true
    Task {
        let typed = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (Keychain.get(account: "deepgram-key") ?? "") : typed
```
```swift
        let provider = DeepgramProvider(config: .init(apiKey: key, smartFormat: formattingEnabled))
```
`testConnection()` is a method on a `View` struct that is *not* `@MainActor`-isolated (only `body` is, via the protocol), so the unstructured `Task` does not inherit the main actor and reads `deepgramKey` and `formattingEnabled` (both `@State`) from a non-main executor. The subsequent `await MainActor.run` blocks (`:342`, `:361`) are correctly used for the writes.

**Why it matters in production:** SwiftUI `@State` access from a background thread is a data race by contract (the storage behind the wrapper is not synchronized). The practical exposure is small — two reads of small values, once per button press, and the compiler does not currently diagnose it under Swift 5 language mode — which is why I rate it Low and flag my uncertainty: I cannot verify without compiling whether the target's concurrency settings make this `Task` main-actor-isolated (Swift 6 / `-strict-concurrency` would reject it as written). Note that `Package.swift` is `swift-tools-version:5.9` with no `swiftLanguageMode`/`-strict-concurrency` settings, so it compiles today.

**Fix:** Capture the values before the `Task` and mark the function `@MainActor`:
```swift
@MainActor private func testConnection() {
    let typed = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let smartFormat = formattingEnabled
    testResult = nil; isTesting = true
    Task { /* uses typed, smartFormat only */ }
}
```
Then the whole view is main-actor-safe by construction.

---

## Stale-branding and risky-pattern grep results

Command surface: `grep -rn -E "Sadaa|sadaa|Whisper|whisper|Azure|azure|OpenAI|TODO|FIXME|HACK|XXX|fatalError|try!|as!" Sources/` plus a repo-wide sweep of `*.swift|*.md|*.plist|*.sh|Makefile|*.yml|*.json` (excluding `.build/` and `dist/`).

### `TODO` / `FIXME` / `HACK` / `XXX`

**Zero hits in `Sources/` and `Tests/`.** No placeholder copy, no unfinished work markers. (This is a genuinely clean result — see "Already good".)

### `Sadaa` / `sadaa` — 13 hits in `Sources/`, all identifiers, one with a user-visible consequence

| File:line | Hit | User-visible? |
|---|---|---|
| `Sources/UsefulVoiceApp/AppDelegate.swift:131` | `.appendingPathComponent("Sadaa")` → all user data lives in `~/Library/Application Support/Sadaa/` | **Yes — in Finder.** The only place a user can find, back up or hand-repair their notes/history. Renaming it later requires a migration, so this is the highest-value stale string. (See UI-06: the `.bak` recovery file lives here too.) |
| `Sources/UsefulVoiceApp/AppDelegate.swift:129` | local variable `sadaaDir` | No (internal name) |
| `Sources/UsefulVoiceCore/Settings/Keychain.swift:8,10` | `service = "ai.karko.sadaa"` | Marginally — Keychain Access.app shows the service name, and changing it later orphans every stored key |
| `Sources/UsefulVoiceCore/ProviderHealth/ProviderHealthCheck.swift:116` | temp file `sadaa-provider-health-<uuid>.wav` | No (temp dir; also a cleanup question, see below) |
| `Sources/UsefulVoiceCore/Audio/AudioRecorder.swift:65` | queue label `com.sadaa.audiorecorder.writer` | No (shows in crash reports/`sample`) |
| `Sources/UsefulVoiceApp/Clipboard.swift:16` | pasteboard type `ai.karko.sadaa.delivery` | No (pasteboard marker) |
| `Sources/UsefulVoiceApp/RootView.swift:171,175` | `Bundle.main.url(forResource: "SadaaLogo", withExtension: "png")` / `"Sadaa"` `.icns` | **Indirectly.** The rendered asset is user-visible; the *lookup keys* are stale, so the moment the build renames the resource (or someone ships a clean asset set), the sidebar mark silently falls back to `NSApplication.shared.applicationIconImage` with no error. |
| `Makefile:9,14`, `scripts/setup-signing.sh:16,38` | signing identity `"Sadaa Local Signing"` | No (developer tooling; but it is the identity that preserves the Accessibility grant) |
| `Makefile:39-41` | `cp .build/release/UsefulVoiceApp $(APP)/Contents/MacOS/Sadaa`; `cp assets/branding/Sadaa.icns …/Sadaa.icns`; `cp assets/branding/useful-voice-mark-dark.png …/SadaaLogo.png` | Build output naming |
| `Makefile:47` | `pkill -x Sadaa` | No (script) |
| `bundle/Info.plist` | `CFBundleIdentifier = ai.karko.sadaa`, `CFBundleExecutable = Sadaa`, `CFBundleIconFile = Sadaa` | **Yes, indirectly.** The shipped binary is `Contents/MacOS/Sadaa` inside `/Applications/Useful Voice.app`, so Activity Monitor, `ps`, crash reports and `Force Quit` can show "Sadaa" while the app and its menu say "Useful Voice". `CFBundleName`/`CFBundleDisplayName` are correctly "Useful Voice". |
| `dist/UsefulVoice.app/Contents/{MacOS/Sadaa,Resources/Sadaa.icns,Resources/SadaaLogo.png}` | built artifact | Same as above |

Not stale — **false positives to leave alone**: `Sources/UsefulVoiceCore/Dictionary/BaseVocabulary.swift:7,12` contains `"OpenAI"`, `"Whisper"`, `"Azure"` as dictation *vocabulary* (names the user might dictate and wants spelled correctly). These are data, not branding.

### `Whisper` / `whisper` — 6 hits, all comments

| File:line | Context | User-visible? |
|---|---|---|
| `Sources/UsefulVoiceCore/DictationController.swift:175` | "makes Whisper echo its prompt bias (the whole dictionary) back as a …" | No — comment; stale provider reference (the app now uses Deepgram) |
| `Sources/UsefulVoiceCore/Audio/AudioRecorder.swift:12`, `:57` | "a silent clip makes Whisper echo its own …" | No — comments, same staleness |
| `Sources/UsefulVoiceCore/Audio/ChimeSynth.swift:26` | "plus a whisper of an octave harmonic for body." | No — English word, not branding |
| `Sources/UsefulVoiceApp/AppDelegate.swift:509` | "the way WhisperFlow and friends do." | No — comment |
| `Sources/UsefulVoiceApp/HUD/HUDView.swift:71` | "dictation app like WhisperFlow shows while you speak." | No — comment |

No user-facing string mentions Whisper, WhisperFlow, Azure or OpenAI anywhere. I checked every user-visible literal in the pages, components, HUD and AppDelegate menus: the only provider named is Deepgram, consistently (`HomePage.swift:74`, `SettingsPage.swift:148`, `:344`, `:355`, `AppDelegate.swift:407`, `:410`).

### `fatalError` — 1 hit

- `Sources/UsefulVoiceApp/AppDelegate.swift:134` — user-visible crash on the launch path. Reported as **UI-13**.

### `try!` — 1 hit

- `Sources/UsefulVoiceCore/LanguageMemory/LanguageMemoryMatcher.swift:46` — reported as **UI-23**.

### `as!` — 2 hits, both guarded (not defects)

- `Sources/UsefulVoiceApp/TextInserter.swift:198` and `:214`:
```swift
guard AXUIElementCopyAttributeValue(…, &focusedRef) == .success,
      let focusedRef,
      CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
let element = focusedRef as! AXUIElement
```
The `CFGetTypeID` check immediately precedes each cast, which is the documented-correct pattern for CF bridged types. Safe as written; a stylistic `unsafeDowncast`/`as?` would silence the grep.

### Force unwraps (`)!`, `]!`) — 2 hits, plus 1 outside my scope

- `Sources/UsefulVoiceApp/AppDelegate.swift:592`:
```swift
let title = ["auto": "Auto-detect", "en": "English", "de": "German"][pin.rawValue]!
```
Iterating `LanguagePin.allCases`, whose raw values are exactly `auto`/`en`/`de` (`AppSettings.swift:3-15`), so this cannot trap today — but it is an unguarded assumption that breaks the app at launch the moment a fourth `LanguagePin` case is added (which the `quickToggled` switch at `:8-14` would also need updating). Replace with an exhaustive `switch` on the enum.
- `Sources/UsefulVoiceCore/Transcription/DeepgramProvider.swift:48` — `URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!` where `baseURL` is a static literal. Safe; out of scope but recorded for completeness.

### Other `try?`-swallowed failure paths worth naming (no `try!` involved, same class of risk)

`try? data.write(to:options:.atomic)` appears at `ScratchpadStore.swift:179`, `NotesStore.swift:53`, `LanguageMemoryStore.swift:356`, `DictationHistory.swift:85` — every one of them is an unobservable failure and is the mechanism behind **UI-02**. Likewise `try?` around `createDirectory`/`moveItem` in `ScratchpadStore.swift:175`, `NotesStore.swift:18`, `:253-254`.

### Out-of-scope observation surfaced by the grep

`ProviderHealthCheck.makeProbeWAV()` (`ProviderHealthCheck.swift:114-135`) writes a temp `.wav` whose filename still uses the `sadaa-` prefix; I did not find a corresponding delete in the code I read, so "Test connection" may leave a file in `$TMPDIR` per invocation. Flagging for the core-layer auditor rather than claiming it — cleanup may live in the caller.

---

## Already good

Things I checked and found sound; listed so the fixes above are not over-applied.

1. **Ownership and property wrappers are correct.** `RootView` owns its `AppToastCenter` with `@StateObject` (`RootView.swift:39`) and passes it via `.environmentObject`; every view model and store is owned by `AppDelegate`/`UsefulVoiceViewModel` and consumed with `@ObservedObject`/plain `let` — no `@StateObject` misuse, no view-model recreated on re-render, no missing `@MainActor` on any ViewModel (`ScratchpadViewModel:5`, `LanguageMemoryViewModel:5`, `UsefulVoiceViewModel:6`, `AppDelegate:7`).
2. **No retain cycles in the app layer.** Every escaping closure captures `[weak self]` (`AppDelegate.swift:126`, `:159`, `:176`, `:185`, `:227`, `:233`, `:238`, `:241`, `:441`, `:445`, `:448`, `:449`, `:452`, `:457`; `ScratchpadViewModel.swift:167`; `AppToast.swift:39`; `ThinScroller.swift:152`). The two `[settings]`/`[languageMemory]` strong captures are of leaf objects that do not reference their owners.
3. **`ForEach` identity is stable.** `ScratchpadNote`/`DictationRecord`/`Note` are `Identifiable` by UUID; `ForEach(Array(viewModel.recent.prefix(3).enumerated()), id: \.element.id)` (`HomePage.swift:160`) uses the model id, not the offset; day groups key on `\.day` (`HistoryPage.swift:90`). The one index-keyed list (`HistoryPage.swift:295`, `id: \.offset`) is a static, non-animated preview where index identity is harmless.
4. **The debounce itself is correct** — trailing-edge, cancelled and rescheduled per keystroke (`ScratchpadViewModel.swift:165-172`), so continuous typing does not thrash the disk; the `DispatchWorkItem` cancel/reschedule happens on the main queue, so the auto-save and explicit `commitDraft()` cannot race each other.
5. **Atomic writes everywhere.** Every store uses `.atomic` (`ScratchpadStore.swift:179`, `NotesStore.swift:53`, `DictationHistory.swift:85`, `LanguageMemoryStore.swift:356`), so a crash mid-write cannot truncate the live file. `ScratchpadStore` also creates its parent directory before writing (`:175-178`).
6. **The `NSTextView`-bridging concern does not reproduce here.** `ScratchpadPage` uses SwiftUI's `TextEditor` with a `Binding` whose getter reads `draftBody` and setter writes it (`:144-149`); `commitDraft()` never calls `loadSelectedDraft()`, and the enclosing `if let selected` branch does not change identity across saves, so there is no per-keystroke string reset that could move the caret. I specifically looked for the classic cursor-jump and found no mechanism for it.
7. **Tags are de-duplicated and whitespace-normalized** (`ScratchpadStore.swift:182-198`), case-insensitively, and `NotesStore.update`/`ScratchpadStore.update` both reject blank content rather than destroying it — the *handling* is right even though the *feedback* is missing (UI-19).
8. **Corrupt-file handling never deletes the user's bytes** on the first occurrence: the corrupt file is moved aside, not overwritten (`ScratchpadStore.swift:251-255`), and a legacy-format array decodes via a second attempt (`:18`), so the migration from the bare `[ScratchpadNote]` format is real and tested.
9. **Accessibility where it was done, is done well.** `MicButton` has an explicit label (`:35`), `BrandedMenuPicker` exposes label + value for VoiceOver (`PremiumControls.swift:196-197`), `BrandedMenuButton` labels itself from its help text (`:230`), sidebar items combine label + `.isSelected` trait (`RootView.swift:97-98`), and the toast is a single combined accessibility element (`AppToast.swift:119-120`). Reduce Motion is honored in the HUD (`HUDView.swift:25`, `:198`, `HUDPanel.swift:35`).
10. **Secrets are not exposed in the UI.** The Deepgram key is entered through `SecureField` (`SettingsPage.swift:254`), is never read back into the field (only `Keychain.exists` on load, `:303`), is cleared from `@State` after a successful save (`:325`), and provider errors are regex-redacted before display (`ProviderHealthCheck.sanitize`, `:100-114`) — the deliberate `exists()`-not-`get()` choice is documented at `UsefulVoiceViewModel.swift:61-67`. Numeric settings are bounded by `Slider(value:in:15...120, step: 5)` and `Stepper(value:in: 0...50)` (`SettingsPage.swift:178`, `:187`), so no absurd values are reachable from this UI.
11. **Layout engines are defensive.** `FillRemainingHeightLayout` and `CommandPageHeaderLayout` both `guard subviews.count == 2` (`PremiumControls.swift:326`, `:492`), non-finite proposals are filtered (`finite(_:)` at `:378`, `:459`, `:568`), and `ResponsiveLayoutRules.rows` returns `[]` for empty input and never indexes out of range (`ResponsiveLayoutRules.swift:22-45`).
12. **Scroll performance on the two hottest lists is already handled**: `ScratchpadPage` (`:107`) and `HistoryPage` (`:89`) both use `LazyVStack`; only the dictionary page misses it (UI-10).
