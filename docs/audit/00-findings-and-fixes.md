# Findings and fixes — consolidated

This is the synthesis of the four detailed audit reports in this directory:

| Report | Scope | Findings |
| --- | --- | --- |
| [`01-pipeline.md`](01-pipeline.md) | Recording → transcription → delivery | 20 |
| [`02-hotkey-lifecycle.md`](02-hotkey-lifecycle.md) | Hotkey, launch, lifecycle, packaging | 12 |
| [`03-memory-dictionary.md`](03-memory-dictionary.md) | Dictionary, language memory, keyterms | 21 |
| [`04-ui-notes.md`](04-ui-notes.md) | UI, notes/scratchpad, import/export | 24 |

Each report is written for a reader who wants the full reasoning. This document is
the shorter answer: what was actually wrong, what changed, and how each change was
checked. It also records what was deliberately **not** changed, since a few audit
items turned out not to be defects.

Findings raised by the four reports are labelled `PIPE-*`, `HOOK-*`, `MEM-*` and
`UI-*`. Five further findings — F-14 to F-18 below — were found *after* those
reports, while closing their remaining items against the live installation and the
Windows port, and are labelled `F-*` alongside the consolidated numbering.

| Verification | Result |
| --- | --- |
| macOS `swift build` | clean, no warnings |
| macOS tests | **290 in 40 suites**, passing |
| Windows tests | **317 in 14 files**, passing |
| Windows self-test | 6/6 |
| Windows packaging | installer + portable exe, icon embedded |

Verification commands, and what each does *not* cover, are in §4 and §6.

---

## 1. The findings that could destroy user data

These are the ones that mattered most, because the failure mode was silent
permanent loss rather than a visible error.

### F-1 — A failed read became a permanent overwrite *(pipeline, memory)*

**What was wrong.** Every JSON store read its file with `try? Data(contentsOf:)`.
Swift collapses four different situations into one `nil`: no file yet, a file that
could not be read, a file whose contents do not decode, and a successfully read
file that happened to be empty. Each store treated `nil` as "start empty", and the
next mutation wrote that emptiness back to disk.

The consequence: one transient read error — a lock, a permissions blip, a full disk
during a read — made the dictionary, snippets, language memory and history appear
empty, and then *permanently erased* them on the next edit. The `.bak` fallback did
not help, because it only ran on a decode failure and its own result was discarded
with `try?`.

**The fix.** A new shared `StoreFileReader` classifies the outcome as
`fresh` / `loaded` / `unreadable` / `corrupt` / `incompatible`, and only the first
two permit writing. A store that could not read its file now **refuses to write**
and reports the problem instead, holding the user's edits in memory. Corrupt files
are moved aside with `StoreFileReader.quarantine`, which will not destroy an
existing `.bak` (the old code deleted the previous backup before moving the new one
onto it, so a second corruption destroyed the first backup too).

Applied to `DictionaryStore`, `SnippetStore`, `LanguageMemoryStore` and
`DictationHistory`. The language-memory store additionally refuses a file whose
declared schema version is newer than the build, which previously decoded
successfully — unknown keys are ignored — and was then silently rewritten in the
older shape on the next save, discarding the newer fields.

**Checked by.** `Tests/UsefulVoiceCoreTests/StoreWriteRefusalTests.swift` (15 tests).
The load-bearing assertions are not "an error was reported" but "the original file
is still there". An unreadable path is simulated with a directory, which is robust
for any user because it does not depend on POSIX permissions that root ignores.

### F-2 — A corrupt dictionary silently erased itself

**What was wrong.** `DictionaryStore` moved a file it could not decode to
`dictionary.json.bak` inside `try?`. When that move failed, the store started empty
*and left the original file in place*, so the next write overwrote the user's real
dictionary while the backup it thought it had made did not exist.

**The fix.** Covered by F-1: the move result is now inspected, and if the file
cannot be preserved the store reports `corrupt(backupURL: nil)` and refuses to
write.

**Checked by.** The test asserts the original bytes survive on disk.

### F-3 — The clipboard was restored over the dictation

**What was wrong.** After pasting, the app restored the previous clipboard on a
fixed timer. If the paste had not yet landed — a slow target app, a busy main
thread — the restore overwrote the dictation before the target read it. The
dictation was gone and the user had no way to recover it.

**The fix.** The restore is now gated on evidence that the paste actually landed:
focus must not have moved, and the clipboard must have been consumed. Anything that
cannot be positively confirmed leaves the transcript on the clipboard. A snapshot
that could not be captured completely (a file list, a proprietary format) is never
restored at all, because replacing the clipboard with a partial copy is itself data
loss. `Clipboard.restore` is now `@discardableResult` and returns whether the
read-back matched, so a restore that silently failed is visible.

**Checked by.** `Clipboard` and `TextInserter` tests, plus the Windows equivalent
described in §4.

---

## 2. The findings that made the app feel broken

### F-4 — Delivery that never called back wedged the app forever

**What was wrong.** The dictation state machine returned to `idle` only when the
delivery sink called back. A lost callback left the app in `delivering`
indefinitely: the hotkey did nothing, and only relaunching recovered it.

**The fix.** Delivery is raced against a timeout (5 s in production), so the state
is always released. The transcript is left on the clipboard on the timeout path, so
the failure degrades to "paste it yourself" rather than "lost".

**Checked by.** `windows/tests/dictationService.test.ts` — a sink that never settles,
asserting both that the state returns to `idle` and that the *next* dictation can
still start.

### F-5 — Raw mode leaked into the following dictation

**What was wrong.** The "raw mode" flag (skip formatting) was cleared only on the
success path. Every early return — recording too short, no API key, empty
transcript — left it set, so the *next* dictation silently skipped formatting with
no explanation.

**The fix.** The flag is consumed at the top of processing, so every exit path
clears it.

**Checked by.** Three tests covering each early-return path, each asserting that the
following dictation *is* formatted.

### F-6 — A short dictionary term rewrote unrelated words

**What was wrong.** The synthetic case-correction rule used a case-insensitive
*substring* replace. A term like `AI` therefore rewrote `said`, `email` and
`captain`; `term` rewrote `terminal`.

**The fix.** The synthetic rule now uses word-boundary matching, consistent with
every other rule. Matching is also normalised (NFC) so the same word cannot exist
twice in two Unicode forms.

**Checked by.** Regression tests including the specific `AI`/`said`/`email` case.

### F-7 — One edit created up to four permanent rules

**What was wrong.** Learning from a correction created a term *and* a replacement
*and* a pronunciation, and the pronunciation then generated a further rule. A
word-level inference from a longer sentence was committed globally without
confirmation.

**The fix.** A word-level pair inferred from a longer edit is now a *suggestion*
requiring confirmation, not a rule. Inferred pairs no longer attach a pronunciation.
`isPlausibleMishearing` requires both words to be at least four characters, which
excludes the dangerous class: English three-letter words are overwhelmingly function
words, where "the same word misheard" and "a deliberate edit to a different word"
are indistinguishable — `then`/`than`, `not`/`now`, `cat`/`car` all sit at a
0.25–0.33 ratio that any threshold accepts. A `COMMON_WORDS` set (English and
German) additionally forces confirmation when both sides are ordinary words.

**Checked by.** `windows/tests/learning.test.ts` and the macOS language-memory
regression suite, including an end-to-end test that a confirmed correction fixes the
next dictation.

### F-8 — A recording that lost its audio never stopped

**What was wrong.** Both the silence watchdog and the 600-second cap were evaluated
only inside the audio buffer callback. If buffers stopped arriving — the input
device was unplugged or switched mid-recording — neither ever fired and the app
stayed in the recording state indefinitely.

**The fix.** `RecordingClock` tracks elapsed time against a wall clock, independent
of buffers, and the cap is enforced outside the callback. Device changes are
observed and a capture failure is now a reported error rather than silence.

**Checked by.** `RecordingClock` tests drive injected time rather than real audio.

### F-9 — The test script only worked by accident

**What was wrong.** `Scripts/run-tests.sh` looked for `lib_TestingInterop.dylib`
next to `Testing.framework`. This Command Line Tools installation ships it in
`Library/Developer/usr/lib/` instead. The script never found it, and the
`[ -f "$INTEROP" ] && cp …` guard discarded the failure — so the suite passed only
because a stale copy happened to be sitting in an existing `.build` directory.
Anyone who ran a clean build got
`Library not loaded: @rpath/lib_TestingInterop.dylib`.

**The fix.** The script searches the known locations, fails loudly with the paths it
tried when none match, verifies the staged copy exists, and no longer uses a guard
that discards errors.

**Checked by.** Deleting `.build` entirely and running the script: the full suite passes from a
cold tree.

### F-10 — Launching at login opened a window

**What was wrong.** A login-item launch opened the main window, so signing in
produced an unexpected window on top of whatever the user was doing.

**The fix.** `LaunchPolicy` reads `NSApplication.launchIsDefaultUserInfoKey` (the
current SDK name for the old `NSApplicationLaunchIsDefaultLaunchKey`), which is
`false` for a login-item launch, and the window is only opened for a user-initiated
launch. A second launch now hands off to the running instance instead of starting a
duplicate hotkey registration.

**Checked by.** `LaunchPolicy` unit tests plus the single-instance path.

### F-11 — The microphone indicator stayed lit

**What was wrong.** The audio engine was not always torn down on the error paths, so
a failed capture could leave the input device open — the recording indicator stayed
on and other apps could not use the microphone.

**The fix.** All session state lives on one queue behind a `Session` token, so a
stale callback cannot act on a new session, and every exit path stops the engine and
closes the file. Free space is checked before recording starts rather than failing
mid-way.

**Checked by.** The recorder/state-machine suites in both ports.

### F-12 — Notes could be deleted with no confirmation and no undo

**What was wrong.** (Reported against `NotesPage.swift`; the real page is
`ScratchpadPage.swift`, whose title is "Notes". `NotesStore` has no UI — its only
caller is a one-way migrator.) Deleting was immediate and permanent, and the "Saved"
label was hardcoded rather than reflecting real state.

**The fix.** Deletion is gated behind a confirmation dialog and offers a real undo
that restores the note **to its original position**, so undoing a mis-click does not
also reorder the list. The save indicator reflects reality: store writes no longer
use `try?`, `lastSaveError` and `onSaveFailure` were added, and the dead `saveError`
property (only ever assigned `""`) is now live.

**Checked by.** `ScratchpadStoreTests` and `NotesStoreTests`, including
failure-injection tests that were verified to be non-vacuous by temporarily
replacing their skip guard with a hard assertion.

### F-13 — Importing a backup destroyed newer work

**What was wrong.** Import overwrote by id unconditionally, so restoring an old
backup discarded every edit made since.

**The fix.** Import merges by timestamp: a matching id is adopted only when strictly
newer, otherwise the local record is kept and counted. The merge is a pure,
separately testable function. Decoding an older file no longer fails on a missing
field. On the Windows side the same rule applies, and imported suggestions are
capped (the suggestion path capped them but the import path did not, so one import
could add thousands).

**Checked by.** Merge tests for newer/older/unknown ids, plus an idempotent
re-import.

### F-14 — Recorded audio and transcripts were readable by every account on the Mac

**What was wrong.** Found while auditing PIPE-16 (unencrypted data at rest), and
verified against the live installation rather than inferred:

```
drwxr-xr-x  Sadaa
drwxr-xr-x  Sadaa/Recordings     <- 20 files, 8.1 MB of the user's speech
```

Both directories were `0755` and the files inside them `0644`, because everything
was created with the process umask (`022` on a default macOS install). Any other
user account on that Mac could read the dictionary, the complete dictation history,
the retained audio recordings and the transcript sidecars.

The parent `~/Library/Application Support` is `0700`, so a standard single-user Mac
was not actually exposed. But that is a permission set by the OS on a directory this
app does not own — a coincidence that held on the machines tested, not a guarantee.
Relying on it also breaks silently if it ever changes.

**The fix.** `FileProtection` applies an absolute owner-only mode (`0700`
directories, `0600` files) and is called in three places so the protection cannot be
forgotten: recursively over the data directory at launch (which also corrects files
written by an earlier build, and directories restored from a backup, where modes are
not preserved), on the recordings directory when the store is created, and on each
audio file and transcript sidecar as it is written. Hardening failures are reported,
never fatal — a managed or read-only volume must not stop dictation.

**Checked by.** `FileProtectionTests` and `RecordingStoreProtectionTests` (11 tests),
asserting `mode & 0o077 == 0` — the property that matters is that nobody but the
owner can reach the file, not that a particular literal was set.

### F-15 — A locked keychain was reported as "no API key"

**What was wrong.** `Keychain.get` collapsed four situations into `nil`: no item
stored, keychain locked, authorization prompt dismissed, and item present but
undecodable. The app turned all four into "No transcription provider configured", so
a user whose key was stored and fine was told to set one up — and the only action
offered, re-entering the key, would overwrite a working credential.

**The fix.** `Keychain.Lookup` distinguishes `found` / `absent` / `unavailable`, and
only `errSecItemNotFound` means `absent`. Locked, denied and failed-authentication
each report separately. `DeepgramKeyStore.lookupProblem` exposes the reason, the
Settings status line says "Your saved Deepgram key could not be read: …" with what to
do about it, and the reason is logged.

The status→outcome mapping was split into a pure `classify(status:result:)` so every
branch is testable: the interesting ones — locked, denied — cannot be produced on
demand against a live keychain, which is exactly why they had never been checked.

**Checked by.** `KeychainLookupTests` (10 tests). Each asserts both the specific
outcome and `!= .absent`, since conflating them was the original bug.

### F-16 — A failed dictionary migration lost the legacy dictionary

**What was wrong.** `LanguageMemoryMigrator` wrote its result with
`_ = store.importSnapshot(…)`, discarding the outcome. If that write failed, the app
carried on with an empty dictionary — and as soon as the user added one word, a
language-memory file existed, so the next launch skipped the migration entirely and
the whole imported dictionary was gone for good. The one-time migration was the only
path that read `dictionary.json`, so nothing else would ever recover it.

**The fix.** The migration now checks `store.lastSaveError` after importing. A
successful merge that failed to save is the dangerous case, because the in-memory
state looks correct while nothing reached disk; it is recorded with the entry count
and a note that the originals were deliberately left untouched. A successful
migration is logged too, so the file explains where the user's entries came from.
`importSnapshot` merges by phrase rather than replacing, which is what makes
re-running the migration safe.

---

### F-17 — The Windows renderer never heard that data had changed

**What was wrong.** The main process broadcast three channels that the preload
subscribed to nowhere: `history:changed` (every completed dictation),
`memory:changed` (12 sites) and `notes:changed` (3 sites) — verified by grepping both
files rather than trusting the report that found it.

The visible effect: dictate with a hotkey while the History page is open and the new
entry never appears. The list stays stale until you navigate away and back, because
the renderer only refreshed for mutations it had started itself. The same applied to
tray-driven changes to the dictionary and notes.

**The fix.** Three subscriptions in the preload (`onHistoryChanged`,
`onMemoryChanged`, `onNotesChanged`, sharing one `subscribe` helper so the three
cannot drift), and a renderer handler for each that refetches **only** the affected
collection, **only** while that page is the one on screen.

The second half is the part that needed care. Calling the existing `refresh()` would
have replaced every collection and re-rendered the forms, so a background event
arriving mid-sentence would discard half-typed input. The handler patches one
collection into state instead, leaving `historyQuery`, `dictionarySection` and the
note draft exactly as the user left them. A note deleted from the tray cannot leave
the editor pointing at an id that is gone.

Two further details came out of reviewing the fix, both worth recording:

- **The repaint needs a guard.** Refetching only the affected collection is not
  enough, because repainting rebuilds the page and the dictionary's six add-form
  inputs keep their text in the DOM alone — their buttons read the inputs when
  pressed, and nothing mirrors them into state. A background event arriving
  mid-entry would therefore have silently dropped a half-typed word. The repaint is
  now skipped while any of those inputs holds text; the fetched data is already in
  state and appears as soon as the user does anything that repaints.
- **Home counts as a visible page.** It renders the dictionary word count, the
  correction count, the dictation count and the four most recent dictations, so
  excluding it would have left the most visible half of the bug in place — Home is
  the screen in front of the user while they dictate.

**Checked by.** `tests/ipcContract.test.ts` was written to fail on a dead channel and
did its job twice: first by reporting this gap, then by failing when the fix's
`subscribe` helper initially hid the channels from its extraction regex. It now
asserts the unconsumed set is empty *and* that all three channels are both broadcast
and subscribed, so deleting a subscription fails with a reason rather than silently
reintroducing the stale list. `tests/rendererWiring.test.ts` pins the parts that
cannot execute off-Windows: that the three subscriptions appear once each inside
`mountMain` (so the hidden recorder and HUD windows, which load the same bundle, do
not subscribe), that the page check precedes the repaint, that the input guard
precedes it, and that Home is covered. Five mutations — each subscription no-op'd,
the guard removed, Home dropped — were each confirmed to fail the suite.

The headless self-test asserts all three methods exist on the live
`window.usefulVoice` and that the method count is exactly 50; **both pass by
execution**, not by static inspection.

### F-18 — The Windows app identity did not match its own installer

**What was wrong.** `app.setAppUserModelId('ai.karko.sadaausefulvoice')` disagreed
with `build.appId: "ai.karko.usefulvoice"` in `package.json`. Windows derives
taskbar grouping, notification identity and the registry `Run` value used for
launch-at-login from the App User Model ID, so the login entry the installer created
was attributed to a different app than the one running. Both values are plain
strings, so no type checker could have caught the divergence.

**The fix.** The AUMID is now the exported constant `APP_USER_MODEL_ID`, matching
`build.appId`, applied through that constant rather than a second literal.

This was worth fixing *now* rather than later: the app has never shipped, so there
are no existing login entries to orphan. After release the same change would silently
break launch-at-login for every user who had enabled it.

**Checked by.** `tests/appIdentity.test.ts` reads both files and asserts they agree,
that the literal is not reintroduced at the call site, that `productName` agrees
between the top level and the builder config, and that `main` matches
`extraMetadata.main`. Breaking the AUMID was verified to fail the test.

## 3. Hardening that prevents a whole class of failure

- **`KeytermBudget` / `keytermBudget.ts`.** Deepgram Nova-3 hard-fails a request
  over 500 tokens across all keyterms, which would break *every* dictation at once.
  A 400-token budget with a safety margin is enforced, with a script-aware estimator
  (CJK and kana count as 5 tokens, Cyrillic/Greek/Arabic/Thai as 3, Latin as 1) so a
  non-Latin dictionary cannot slip past a naive word count. The UI reports how many
  entries were dropped, because a silently truncated dictionary looks like poor
  recognition. Verified at 400 terms → 400 tokens, 384 dropped.
- **Pre-flight checks.** Recording size cap, free-space check, minimum payload size,
  and a speech gate. The speech gate exists because a silent clip can make a speech
  model echo its prompt bias — the dictionary — back as a fake transcript.
- **Bounded retries.** Transient provider failures retry with exponential backoff
  capped at 8 s, honouring `Retry-After` without letting a large value stall a
  dictation. Cancellation works during transcription and delivery, not only while
  recording.
- **Diagnostics.** The macOS build had no logging at all — no `os_log`, no file,
  nothing. Every failure existed for a few seconds in a floating pill and was then
  gone, so "it just doesn't work sometimes" was unanswerable and an intermittent
  paste failure left no trace. `Diagnostics` now records to a bounded log and
  surfaces the last 30 entries in Settings, with a Copy report button.

  It is wired at the places failures actually occur rather than sprinkled at call
  sites: every store read and write routes through `StoreFileReader` and
  `StoreFailureReporter`, so a store cannot forget to report. Two rules shaped it:
  the log must never hold a transcript or an API key (that is why it accepts only
  category/message pairs — there is no method a caller could pass a transcript
  through), and it must never block the caller (the global CGEvent tap runs on the
  main run loop and macOS disables a tap that stalls, so writes are enqueued and
  drained by a background queue). One line is recorded per launch, because on a
  healthy install nothing else is ever logged and an always-empty file cannot
  answer "which build was this".
- **Delivery timeout** (F-4) and **clipboard verification** (F-3).

---

## 4. Windows-specific: what could not be tested, and what was done instead

The Windows app was developed on macOS and **has never been run on Windows**. Being
precise about that distinction is more useful than a green checkmark.

What is proven by execution:

| Check | Result |
| --- | --- |
| `npm test` | 258 tests, 9 files, passing |
| `npm run typecheck` | clean |
| `npm run self-test` | 6/6 — preload API (50 channels, 53 methods), no Node leak, renderer paints, recorder has `getUserMedia` + `AudioContext`, store round-trip, keyterm budget |
| `npm run dist` | real PE32 installer and portable exe, 256 px icon embedded |
| Packaged contents | `app.asar` contains `dist/main/index.js`, `preload/`, `renderer/` |

The self-test exists because the two most dangerous Windows-side mistakes both
produce a normal-looking window with a dead UI and no error anywhere: a preload
emitted as ESM (Electron requires CommonJS for preloads, and ignores
`"type": "module"` for them) and a renderer bundle containing an import that cannot
be resolved from a `file://` page under the app CSP. Both are now checked by
construction and by execution.

Three real bugs were found this way and fixed:

1. **`package.json` `main` pointed at `dist/main/main.js` while tsc emits
   `index.js`.** Electron could not find the app at all. The build now asserts that
   `main` and `extraMetadata.main` match the emitted path.
2. **`app.exit()` abandoned the pending report write**, so the self-test produced an
   empty file. The write is now synchronous and its completion is verified, because
   a check whose result cannot be read is worse than no check.
3. **`window-all-closed` was registered only in the non-self-test branch.** Electron
   quits when the last window closes and no handler is attached, so the self-test
   destroyed its first window and then could not create the second
   (`ERR_FAILED`). The handler is now unconditional.

The installer icon was also found to be wrong: the generator centred every bar on
the canvas, so only the middle bar of the three-bar mark was ever drawn. The
generator now verifies its own output — three bars, each at its own position, with a
gap between them and transparent corners — and fails the build otherwise.

**Not verified, and requiring a Windows machine:** microphone capture and permission
prompts, global hotkey registration and conflict handling, clipboard save/restore
and Ctrl+V delivery into real applications, tray rendering at real DPI, DPAPI key
encryption on a real profile, and the installer on a clean machine. These are listed
in `windows/README.md` as the first-run checklist.

**Not verified on either platform:** the full microphone → Deepgram → paste path
end-to-end, which needs a live API key and real speech.

---

## 5. Deliberately not changed

Recording these matters as much as the fixes, because acting on them would have
made the code worse.

- **`AppDelegate.swift` line numbers drift.** It was edited during the audit, so the
  detailed reports cite it by symbol instead.
- **Pipeline regex escaping, ReDoS exposure, atomic writes and store threading** were
  audited and found sound. They are not defects and were not "fixed".
- **`SettingsPage`'s save state was already correct.** The finding's premise did not
  hold: there is no hardcoded "Saved" and no dead `saveError` there. Both are in the
  scratchpad editor, which is what was fixed. `SettingsPage` was not touched.
- **`NotesStore` gained no delete/restore API.** It has no UI, so adding one would be
  dead code. It was changed only for the save-error path.
- **`Makefile`'s `SIGN_IDENTITY` stays `Sadaa Local Signing`.** Switching the local
  build to a Developer ID would invalidate every existing user's Accessibility
  grant. Distribution signing lives only in the `bundle-release` target.
- **`FillRemainingHeightLayout` silently places nothing with three children**
  (`PremiumControls.swift`). The undo bar was nested in the header rather than added
  as a sibling. The layout guard itself was left alone as out of scope, but it is a
  trap worth knowing about.

---

## 6. Two claims worth distrusting

- The macOS suite passing 313 tests does **not** cover rendering. The confirmation
  dialog, the undo bar's spacing and the 8-second timer are not exercised by any
  automated test; they match the surrounding component idioms but have not been seen
  drawn.
- The Windows suite passing 345 tests covers `src/core`, the dictation state machine,
  and the IPC/naming/identity contracts read out of the sources. It does **not** cover
  anything that needs Electron or Windows at runtime: the registry write behind
  launch-at-login, the `win32` guard, the login-item read-back, clipboard save/paste
  against real apps, DPAPI, or the renderer's own wiring. Those are verified at
  pure-logic, static-source and type level only.

Where a claim above says "checked by", it means an automated test exercises it.
Where it says "not verified", it means exactly that.

---

## 7. Deepgram integration audit (F-19 … F-27)

A separate pass against Deepgram's current published documentation — fetched, not
recalled: the site's HTML is client-rendered, so every quote below comes from the
`.md` variant each page exposes, plus the OpenAPI spec. The relevant files are
`DeepgramProvider.swift` (macOS), `windows/src/core/transcription/deepgramProvider.ts`,
and the two `KeytermBudget` implementations.

The audit's most important result is that **the app was not using language detection
at all** — it was using multilingual code-switching and calling it auto-detect. That
is the likeliest single cause of the user's complaint that formatting "is not
absolutely on point", because it puts the model in the wrong mode for the audio.

### F-19 — "Auto" meant code-switching, not language detection

`language=multi` and auto-detect are different features. `multi` is Multilingual
Code-Switching, for "conversations where speakers switch between multiple languages";
the auto-detect parameter is `detect_language`, which the app never sent. A user
dictating in one language with the pin on auto was therefore asking Deepgram to
expect language switching mid-sentence.

Fixed: auto now sends `detect_language`, **restricted to the two languages the app
offers** (`detect_language=en&detect_language=de`). The restriction is load-bearing.
The docs say that when a detected language is unavailable on the requested model,
Deepgram "will automatically select the next highest model" — and since `keyterm`
works only on Nova-3, an unrestricted detection could silently drop the dictionary
feature entirely. Both offered languages are native Nova-3 languages, so that
fallback is unreachable.

Consequence: the `detectedLanguage` plumbing, which the app has always stored and
displayed, was previously **dead on both platforms** — macOS hardcoded `nil`, Windows
parsed a field it never asked for. It now carries the provider's answer.

### F-20 — Numerals were never requested

`smart_format` guarantees punctuation and paragraphs; numerals are documented as
available "for select languages" on non-English models. `numerals=true` now
accompanies smart formatting, removing a language-dependent ambiguity instead of
relying on a default.

### F-21 — Formatting could not be switched off on Windows

`deepgramProvider.ts` sent `punctuate=true` unconditionally, so turning formatting
off still produced punctuation and capitalisation — while macOS sent nothing and
produced fully raw text. The same setting had different meanings per platform.
`punctuate` now follows the toggle, and is sent only when implied (see F-22).

### F-22 — Spoken punctuation was missing entirely (new feature)

Deepgram's Dictation feature converts spoken "period", "comma", "new line" into the
characters themselves. It was not implemented on either platform. It is now an
opt-in setting on both, **off by default** (it changes what the words mean, so it
should be asked for), and suppressed for German because the docs scope Dictation to
"English (all available regions)". The docs require punctuation to be enabled for it
to work, so `dictate=true` is sent together with `punctuate=true`.

### F-23 — The request deadline could not cover the app's own longest recording

Both platforms' ceilings were below what their own formula requires. A ten-minute
recording is 19.2 MB; at the documented-in-comment pessimistic rate of 100 kB/s that
is 192 s of upload plus a 12 s allowance = **204 s**. The ceilings were 180 s (macOS)
and 195 s (Windows), so the largest advertised dictation was guaranteed to fail on
exactly the slow connections the pessimistic figure was chosen for. Both are now 210.

### F-24 — Windows offered a recording longer than Deepgram will process

The UI offered 15 minutes and the store clamped to 900 s. Deepgram documents that
"Requests exceeding 10 minutes (Nova/Base/Enhanced) … return a `504: Gateway
Timeout`" — so the option was a coin flip on failing *after* the user had spoken for
a quarter of an hour. The option is gone and the clamp is 600 s, applied on load as
well as update so a stored 900 from an older build is corrected at launch.

### F-25 — Error classification lost the distinction and the reference

HTTP 402 has its own documented code (`ASR_PAYMENT_REQUIRED`) and its own fix —
topping up — but was reported as a generic bad request, sending the user to look for
a fault in their audio. It is now its own error with its own message. HTTP 408 and
422 are documented as *interrupted or slow uploads*, i.e. retryable in substance, and
were classified as permanent; Windows now treats them as transient. Neither platform
surfaced `metadata.request_id`, which is what the docs tell users to quote to
support; it is now carried into the message.

### F-26 — macOS had no retry at all

Windows retried transient failures with backoff; macOS did not, so a single momentary
429 during a dictation surfaced as a hard failure the user had to repeat by hand,
against documented guidance that "an exponential-backoff retry strategy is
recommended". macOS now makes three attempts with 0.5 s/1.5 s backoff, retrying 429,
408 and 5xx only.

### F-27 — Test-run diagnostics were written into the real install's log

Found while verifying the fixes, and a defect in the diagnostics work from the
previous round rather than in the app. Every store routes through
`Diagnostics.shared`, so any test that provoked a failing read appended its fixture
to the developer's own `~/Library/Application Support/Sadaa/diagnostics.log` — 285
lines of `corrupt.json` and `unreadable.json` fixtures in a live install, which would
have made that log actively misleading to debug a real problem against. The polluted
log was removed after confirming it contained no real entries (zero `launch:`
records).

The first fix — injecting a silent sink per test — was one forgotten call site away
from recurring, so the guard now lives in `Diagnostics`: the shared sink is
memory-only under a test run. **The guard's own first implementation silently did
nothing**, because it detected tests by looking for `.build` in `Bundle.main`'s path,
and this toolchain runs the whole suite inside `swiftpm-testing-helper` where
`Bundle.main` is SwiftPM's own directory and no XCTest environment variables are set.
A guard that fails open is worse than no guard, so the detection is now pinned by
test.

### Confirmed correct, deliberately unchanged

Verified against the docs and left alone: `Authorization: Token <key>`;
`Content-Type: audio/wav`; omitting `encoding`/`sample_rate` for a container (which
the docs require); 16 kHz mono 16-bit capture; `model=nova-3`; repeated `keyterm`
rather than a joined string; the **500-token ceiling across all keyterms** and its
verbatim error string; the 400-token budget as a deliberate margin ("stay well under
the 500 token limit"); reading `results.channels[0].alternatives[0].transcript`; and
**not** sending `utterances` or `paragraphs`, which `smart_format` already covers and
which would only add response weight the app never reads.

Two documentation inaccuracies were corrected in comments rather than in behaviour:
the `maxTerms = 100` cap is a sensible self-imposed bound, not a documented API limit
(the explicit "100 per request" limit belongs to `keywords`, which Nova-3 does not
support), and the `Retry-After` header the code reads defensively is not documented
for this endpoint anywhere.

### Could not verify

The docs are silent on: how Deepgram tokenises a keyterm (so the budget estimator's
per-word inference cannot be validated); whether `detect_language` may be combined
with `keyterm`; whether `smart_format=true` makes `numerals=true` redundant (it is
not in the documented "not included" list, and setting it explicitly cannot hurt);
whether Dictation works outside English; and any recommended sample rate for Nova-3
pre-recorded audio. Two Deepgram pages also contradict each other on the concurrent
request limit for Nova-3 pre-recorded (100 vs 50); this is immaterial for a
single-user desktop app and was left alone.
