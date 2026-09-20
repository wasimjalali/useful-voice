# Audit 05 — performance, dictation pipeline and language switching

**Date:** 2026-09-20
**Audited revision:** `d9156d9` (`main`, clean working tree)
**Status:** Phase 0 complete; no implementation code has been changed

This audit covers the whole macOS and Windows app, with the highest priority on the
language path and the main dictation engine. It is both an audit report and the
implementation specification for the next phase.

## Method and audit panel

The audit followed the multi-model performance loop:

1. map the product and hot paths;
2. measure before changing anything;
3. run a read-only audit;
4. verify every claim against current source;
5. run a resumed judge-and-trace pass;
6. attack the implementation plan before writing code.

The current Devin session exposed one persistent read-only audit worker and a Fast
Context exploration worker; it did **not** expose multiple independent
`subagent_explore` workers. The panel was therefore thinner than the requested
four-to-five-auditor panel: one independent read-only verdict, one search/exploration
view, and the orchestrator's separate source verification. This limitation is
recorded rather than presenting the run as a parallel multi-model panel.

| Role | How it ran | Contribution |
| --- | --- | --- |
| Read-only auditor | Devin subagent; same Round 1 brief; resumed for judge/trace and trap review | Findings A-01–A-13, end-to-end traces, implementation traps |
| Search explorer | Fast Context read-only search worker | Repository map and hot-path coverage |
| Orchestrator | Fusion; direct reads, offline harnesses and current-doc verification | Verified/rejected every claim; found B-01–B-06; owns this specification |

No auditor edited files, ran builds, accessed secrets or user data, or called the
Deepgram API. The orchestrator used only synthetic local data for measurements.

## Scope

Primary path:

`hotkey -> recording -> TranscriptionHint -> Deepgram /v1/listen -> response parsing ->
local Language Memory -> DictationRecord -> delivery`

Priority files:

- `Sources/UsefulVoiceCore/DictationController.swift`
- `Sources/UsefulVoiceCore/Transcription/DeepgramProvider.swift`
- `Sources/UsefulVoiceCore/Transcription/DeepgramLanguage.swift`
- `Sources/UsefulVoiceCore/Transcription/KeytermBudget.swift`
- `Sources/UsefulVoiceApp/AppDelegate.swift`
- `Sources/UsefulVoiceApp/Components/LanguagePicker.swift`
- `Sources/UsefulVoiceApp/HUD/LanguagePickerPanel.swift`
- `windows/src/core/transcription/*`
- `windows/src/main/dictationService.ts`
- the Language Memory and history stores on both platforms

The old reports in this directory were treated as historical leads, not current
evidence. Several of their findings are fixed; several current defects have since
appeared or remained.

## Baseline before changes

No Useful Voice process was running, so this audit does not claim live idle CPU,
settled memory, launch time or UI-frame numbers. Launching or interacting with the
user's installed app was deliberately avoided.

### Verification baseline

| Gate | Result | Wall time | Peak RSS |
| --- | --- | ---: | ---: |
| `make test` | 359 tests in 47 suites passed | 8.24 s | 208 MB |
| `swift build` | clean, no warnings | 8.13 s | 245 MB |
| `cd windows && npm run verify` | typecheck, 382 tests and build passed; Electron self-test failed before app code linked | 9.44 s | 276 MB |

The Windows failure is reproducible with a one-line ESM program whose only import is
`{ app } from 'electron'`. Electron 33.4.11's embedded Node 20.18.3 crashes in
`cjsPreparseModuleExports` before any Useful Voice statement executes. This proves the
self-test blocker is in that Electron/Node ESM interop combination, not in an app
module. It does **not** excuse the separate bare `require('electron')` in the app's ESM
main process; that defect becomes reachable after the link-time blocker is removed.

### Hardest realistic offline cases

The transcript is 15,149 characters. The history is at its 1,000-record cap. The
synthetic WAV is ten minutes of 16 kHz mono Int16 audio: 19.2 MB. No network request
was made.

| Measure | macOS | Windows |
| --- | ---: | ---: |
| Memory pass, 1,000 terms, median | 566.71 ms | 12.75 ms warm; 566.56 ms first run |
| Memory pass, 5,000 terms, median | 2,883.05 ms | 56.59 ms warm; 2,280.44 ms first run |
| One history write at 1,000 records | 10.14 ms | 3.73 ms |
| 19.2 MB request path, 100 keyterms, 34 detection parameters | 0.04 ms request construction | 3.38 ms stubbed full transcription path |
| Import 1,000 dictionary terms | 8,093.11 ms | not re-derived; Windows already coalesces scheduled saves |

The 19.2 MB request-construction path is not the current latency problem. The macOS
Language Memory pass and import path are.

## Current Deepgram documentation check

Current documentation was fetched through Context7 and directly from Deepgram on
2026-09-20.

| Area | Current documented behavior | Audit conclusion |
| --- | --- | --- |
| Auto detection | `detect_language=true` enables detection; the same page explicitly supports repeated restrictions such as `detect_language=en&detect_language=es` | The app's repeated-parameter request shape is valid |
| Detection coverage | 35 documented codes; `detected_language` and `language_confidence` are under each result channel | Response parsing is at the correct location |
| Model fallback | If the detected language is unavailable on the requested model: Nova-3 -> Nova-2 -> Nova-1 -> Enhanced -> Base | A fallback can silently remove Nova-3-only keyterm behavior |
| Code switching | `language=multi`; ten Nova-3 languages; not dominant-language detection | The separate Auto and Multiple Languages UI modes are correct |
| Keyterms | Nova-3 and Flux; repeat `keyterm`; hard limit 500 tokens; prefer 20–50 important terms | The 400-token local ceiling is appropriate; the estimator must be conservative for every script |
| Dictation commands | English only; requires `dictation=true&punctuate=true` | Current English-only pin gate is conservative and correct |
| Smart Format | All languages; applies best available formatting | Current broad `smart_format` use is correct |
| Numerals | Specific language subset; Nova-3 `multi` excludes Hindi and Japanese | Unsupported behavior is not documented as an error; no change without live evidence |

Deepgram still documents `nl-BE` as detectable. Repository comments preserve prior
live evidence that `detect_language=nl-BE` returned HTTP 400 while
`language=nl-BE` worked. That conflict was **not** live-retested in this session.
Keeping `nl-BE` out of the repeated detection list remains the safer behavior until a
controlled API probe proves otherwise.

# Verified findings, ordered by user-visible impact

## F-1 — macOS auto detection does not control local language behavior

**Impact:** High
**Caught by:** read-only auditor; independently verified by the orchestrator

The provider returns the detected language, but the formatting and raw-transform
closures use the pre-transcription settings pin. Under the default `.auto` pin,
Language Memory treats the current language as a wildcard. English, German and every
other language-scoped replacement, snippet and term can therefore participate in the
same dictation.

Evidence:

- `AppDelegate.swift:305-365` builds both hint and context from
  `settings.languagePin`.
- `DictationController.swift:297-310` uses `transcript.detectedLanguage` only for a
  diagnostic and the record.
- `ReplacementEngine.swift:52-55` and `LanguageMemoryMatcher.swift:26-28` match every
  language when the current language is `.auto`.

**Visible result:** a German-scoped correction can rewrite an English auto-detected
dictation. It also maximizes the number of rules and terms scanned.

## F-2 — Windows discards 24 of its 34 detectable languages

**Impact:** High
**Caught by:** orchestrator measurement; read-only auditor traced the consequence

`coerceLanguage` recognizes only a hard-coded subset. The offline mapping check found:

- supported detection codes: 34;
- preserved: 10;
- collapsed to `auto`: 24 — `bg, ca, cs, da, el, et, fi, hi, hu, id, ko, lt, lv,
  ms, no, pl, ro, ru, sk, sv, th, tr, uk, vi`.

Evidence: `windows/src/main/dictationService.ts:326-328,496-501`.

**Visible result:** a Russian or Korean dictation can be correctly detected by
Deepgram but is stored as `auto`, processed with every language's local rules, and
shown as if detection did not work.

## F-3 — macOS undercounts non-Latin keyterms and can fail every request

**Impact:** High
**Caught by:** orchestrator; confirmed by the auditor

The Swift estimator assumes roughly five characters per token for every script.
Japanese, Chinese and Korean often cost roughly one token per character. The Windows
port already contains a per-script estimator and regression tests whose comment
explicitly identifies the macOS undercount.

Evidence:

- `Sources/UsefulVoiceCore/Transcription/KeytermBudget.swift:36-50`
- `windows/src/core/transcription/keytermBudget.ts:45-88`
- `windows/tests/keytermBudget.test.ts:41-61`

**Visible result:** a CJK dictionary can pass the local 400-token check but exceed
Deepgram's hard 500-token limit, causing the whole dictation request to fail.

## F-4 — macOS Language Memory takes 2.88 seconds at 5,000 terms

**Impact:** High
**Caught by:** previous audit lead; measured and re-verified in this audit

Current work includes:

- rule synthesis and sorting;
- a first full-string replacement pass;
- a second pass over non-fired rules;
- per-term/per-candidate matching over four text variants;
- a 4,096-entry regex cache that clears the entire cache when full, causing thrash
  above the limit.

The controller is `@MainActor`, so the 566 ms/2.88 s work delays delivery and blocks
main-actor UI updates.

Evidence:

- `LanguageMemoryPostProcessor.swift:20-66,118-124`
- `LanguageMemoryMatcher.swift:23-42,50-92`
- `ReplacementEngine.swift:14-50`
- `DictationController.swift:266-294`

## F-5 — Windows cannot pass its required runtime gate with Electron 33.4.11

**Impact:** High gate blocker; packaged-Windows consequence still requires Windows
**Caught by:** baseline run; root cause discriminated by orchestrator-authored minimal probe

A one-line Electron ESM program crashes identically before app code links. Windows
feature PRs cannot satisfy the required `npm run verify` gate until this is resolved.

Separately, `windows/src/main/index.ts:262` calls `require('electron').screen` from a
native ESM main process. Once linking works, the first recording reaches `showHud()`
and `require` is undefined. The safe source fix is to statically import `screen`.

## F-6 — macOS pinned dictations store no language and reprocess with today's pin

**Impact:** Medium
**Caught by:** orchestrator; confirmed by the auditor

Deepgram returns `detected_language` only when detection was requested.
`DictationController` stores only that optional field, so pinned Japanese, English or
German records have `language=nil`. Reprocessing retained audio uses the current
settings pin rather than the record's original language.

Evidence:

- `DictationController.swift:299-310`
- `DeepgramProvider.swift:291-296`
- `AppDelegate.swift:392-522`

**Visible result:** History omits the language, and reprocessing an old German
recording after switching to English can transcribe and correct it as English.

## F-7 — importing 1,000 macOS terms blocks for 8.1 seconds

**Impact:** Medium
**Caught by:** read-only auditor; measured by the orchestrator

`importSnapshot` calls public upserts. Each upsert performs a full JSON encode and
atomic write, then import saves once again. The 1,000-term synthetic import took
8,093.11 ms and produced a 239,975-byte final file.

Evidence: `LanguageMemoryStore.swift:98-132,163-198,269-327,391-414`.

## F-8 — Windows language switching takes focus and loses the original target

**Impact:** Medium; requires real-Windows UX verification before a fix
**Caught by:** orchestrator; confirmed by the auditor

The language hotkey shows and focuses the main window, has no busy guard and does not
restore the prior application. The next dictation sees Useful Voice itself as the
foreground app and clears `audioTargetApp`. `DictationService.stopAndProcess` also
drops the target captured at recording start.

Evidence:

- `windows/src/main/index.ts:343-387,503-523`
- `windows/src/main/dictationService.ts:159-207`

The macOS picker explicitly restores the previous application in
`LanguagePickerPanel.swift:125-140`.

## F-9 — macOS cannot cancel transcription and has no delivery timeout

**Impact:** Medium; high-risk change, deferred
**Caught by:** read-only auditor; verified by the orchestrator

`cancel()` accepts only `.recording`; Escape is also gated to that state.
Transcription can consume up to the payload-scaled attempt deadline across retries,
and `.delivering` returns to idle only when its callback fires.

Evidence:

- `DictationController.swift:143-147,194-243,312-320`
- `AppDelegate.swift:595-603`

The Windows state machine already has an abort controller and a five-second delivery
bound. Porting the behavior is not mechanical: the Swift provider uses an
unstructured work task whose cancellation semantics must be designed and tested.

## F-10 — macOS synchronously rewrites two JSON files after a dictation

**Impact:** Medium/low at the measured data size
**Caught by:** read-only auditor; measured by the orchestrator

Usage recording rewrites all Language Memory, then history append rewrites all
history, on the main actor. History alone measured 10.14 ms at the 1,000-record cap.
The cost is real but smaller than F-4 and F-7.

Evidence:

- `AppDelegate.swift:324-334`
- `LanguageMemoryStore.swift:69-95,391-414`
- `DictationHistory.swift:55-61,95-112`

## F-11 — Windows lacks the macOS model-fallback diagnostic

**Impact:** Medium/low
**Caught by:** read-only auditor

`detectionStayedOnNova3` exists in Windows but has no production call site. A model
fallback can remove keyterms while looking like a dictionary failure.

Evidence:

- `windows/src/core/transcription/languages.ts:233-257`
- macOS call site: `DictationController.swift:343-365`

## F-12 — raw-mode state leaks after a failed macOS raw dictation

**Impact:** Low and currently latent
**Caught by:** read-only auditor

`pendingRawMode` clears only after successful formatting. Early returns retain it for
the next dictation. No current app UI calls `toggle(rawMode: true)`, so this is not a
present user path, but the state machine is wrong.

Evidence: `DictationController.swift:41,101-108,171-295`.

## F-13 — language copy is contradictory

**Impact:** Low
**Caught by:** orchestrator

Settings claims automatic detection across the full Nova-3 catalogue even though the
request is restricted to 34 codes. README still describes only Auto, English and
German although the picker offers the full catalogue plus code-switching.

Evidence: `SettingsPage.swift:117-123`, `README.md:9,48`.

# Rejected, unproven and deliberately deferred

| Item | Decision | Reason |
| --- | --- | --- |
| Repeated `detect_language` is invalid | Rejected | Current Deepgram docs explicitly document repeated values for restricted detection |
| Re-add `nl-BE` to detection | Not doing | Docs list it, but recorded live API evidence says one rejected value fails every auto request; no live retest this session |
| Suppress `numerals=true` for multi/auto | Unproven | Docs state a support subset but do not document rejection; Smart Format already chooses best available behavior |
| Long request construction is the main latency | Rejected | 0.04 ms Swift request construction and 3.38 ms Windows stubbed path for 19.2 MB |
| Replace `/v1/listen` with streaming | Not doing | Large rewrite; no profile showing network mode is the dominant cost |
| Rewrite replacement semantics / port Windows `ProtectedSpans` | Not doing now | High correctness risk; first take output-identical scan/cache wins |
| Audio tap allocation rewrite | Unproven | Mechanism exists, but no live profile or glitch reproduction in this audit |
| Database migration | Not doing | Current bounded JSON files are not the dominant measured cost |
| Bare `detect_language=true` | Not doing | Would broaden model-fallback risk and does not expand Deepgram's documented 35-language detector |

# Implementation specification

Each PR is independently shippable, branches from `main`, uses conventional commits,
and must not be combined with another batch. Windows PRs remain blocked until Gate 0
is resolved. Re-measure the same frozen cases after each relevant fix.

## Gate 0 — choose the Windows runtime strategy before implementation

This is high risk and requires the owner's decision.

### Option A — upgrade and pin Electron (recommended)

Pin Electron to a supported release older than seven days, starting with
`43.7.0` (released 2026-09-10, Node 24.21.0), in its own PR. Run the one-line ESM
probe first, then the complete Windows gate and packaging checks. Electron 43 remains
within the supported release window and Windows 10 x64 remains supported.

**Pros:** smallest source diff; removes the proven old-loader failure; keeps native
ESM.
**Cons:** ten-major dependency jump; requires full Electron API, self-test and package
verification; real Windows still required for OS integrations.

### Option B — convert main/core output to CommonJS

Keep Electron 33 and change the main build/runtime module format.

**Pros:** avoids a major Electron upgrade.
**Cons:** larger code/configuration blast radius; must account for `import.meta.url`,
core module loading, package `type`, preload boundaries and packaged entry points.

### Option C — defer Windows changes

Proceed only with macOS PRs and record all Windows items as open.

**Pros:** zero runtime migration risk.
**Cons:** leaves the Windows verification gate, detected-language loss and latent HUD
crash unresolved.

## PR1 — budget non-Latin macOS keyterms conservatively

**Risk:** Low
**Files:**

- `Sources/UsefulVoiceCore/Transcription/KeytermBudget.swift`
- new cases in the existing keyterm/bias test suites

**Change:** port the Windows script-aware weighting exactly, iterating Unicode scalars
rather than Swift grapheme clusters:

- Kana, Han and Hangul: weight 5;
- other covered non-Latin ranges: weight 3;
- Latin/default: weight 1;
- divide the accumulated weight by five and round up;
- retain `max(words, byLength) + separators` and all current limits.

**Invariant to preserve:**

> "the estimate must never undercount."

Also preserve the comments stating that exceeding the API limit rejects the whole
request and that the app intentionally keeps a 100-token margin.

**Tests:** mirror the Windows CJK, Hangul, Cyrillic and Latin comparisons; verify
existing Latin cases and constants are unchanged.

**Gates:** `make test`, `swift build`.
**Measurement:** selection result/count only; no Deepgram call.

## PR2 — remove the latent CommonJS call from the Windows ESM main

**Risk:** Low, but blocked by Gate 0
**Files:**

- `windows/src/main/index.ts`
- an existing source-contract test

**Change:** statically import `screen` from `electron`; replace
`require('electron').screen` in `showHud`. Add a contract assertion that
`windows/src/main` contains no bare `require(`. Scope the assertion to main sources;
the bundled preload has different module requirements.

**Invariant to preserve:**

> "Deliberately not focusable: it must never steal focus from the app the user is dictating into."

**Gates:** `cd windows && npm run verify`.
**Measurement:** self-test reaches and reports the HUD/audio-capability checks.

## PR3 — preserve every Windows detected language and add fallback diagnostics

**Risk:** Low/medium, blocked by Gate 0
**Files:**

- `windows/src/main/dictationService.ts`
- `windows/src/main/index.ts`
- `windows/src/core/transcription/languages.ts` only for reused exports, not catalogue changes
- `windows/tests/dictationService.test.ts`

**Change:**

1. Resolve the effective processing language by exact case-insensitive catalogue
   match first, then base-subtag match; a non-empty unknown detection becomes `auto`
   for processing, not the original pin.
2. Use the effective language for memory and formatter scope.
3. Store the raw provider-detected code in history; if detection is absent, store the
   requested pin. `DictationRecord.language` is already a string and persisted
   history is not normalized on load.
4. Add an optional diagnostic callback dependency. Warn on a raw detected code that
   fails `detectionStayedOnNova3`; wire the callback to the existing bounded
   diagnostics log. Never log transcript text or a key.

**Invariants to preserve:**

> "An unknown code must never be sent."

> "`auto` on either side matches everything: a term saved while the language was auto-detected must still work once the user pins a language, and vice versa."

The first invariant applies to request pins; storing a raw provider response in
history does not send it back without later validation.

**Tests:** all 34 codes resolve away from `auto`; exact `de-CH` remains exact;
`en-US` processes as `en`; unknown processes as auto but is stored raw and warned;
absent detection uses the pin; a Russian-scoped rule applies while an English-scoped
rule does not; raw regional history round-trips. Update the existing `is` fallback
test intentionally.

**Gate:** `cd windows && npm run verify`.
**Measurement:** mapping becomes `supported=34 preserved=34 lost=0`.

## PR4 — make macOS detected/requested language semantics end to end

**Risk:** Medium
**Files:**

- `Sources/UsefulVoiceCore/DictationController.swift`
- `Sources/UsefulVoiceCore/Formatting/FormattingContext.swift`
- `Sources/UsefulVoiceApp/AppDelegate.swift`
- `Tests/UsefulVoiceCoreTests/DictationControllerTests.swift`
- related language/reprocess tests

**Change:**

1. Capture one `TranscriptionHint` before provider iteration and send that same value
   to every provider in the chain.
2. After success, derive the effective pin from the raw detected code using
   `LanguagePin(code:)`; if no detected code exists, use the requested pin.
3. Copy the captured `FormattingContext`, changing only its language before invoking
   format/rawTransform. App identity, snippets, replacement rules and dictionary
   context remain the values captured at recording time.
4. Store the raw detected code when present; otherwise store the requested pin.
5. Reprocess with the record language when available and valid; old nil records keep
   the current fallback behavior.
6. Consume `pendingRawMode` once at the start of processing.

**Invariants to preserve:**

> "Retry must format for the app the user dictated into, not for whatever is frontmost when they click Retry."

> "Raw transcript to the sidecar BEFORE formatting (never-lose)."

> "A stored code the catalogue no longer offers falls back to detection rather than being sent and failing at the provider."

**Tests:** auto+detected German excludes English rules and applies German rules;
pinned Japanese with no detected field stores/applies Japanese; unknown detected code
is stored raw but memory falls back to auto; every provider receives the same captured
hint even if settings change; retry keeps original context; German reprocess ignores a
current English pin; failed raw mode does not affect the next dictation. Include a
wiring-level assertion that the effective `FormattingContext.language` reaches the
real AppDelegate memory closure, not only an injected mock.

**Gates:** `make test`, `swift build`.
**Measurement:** re-run the 1,000/5,000-term auto-language case; fewer language-scoped
rules should participate when detection succeeds.

## PR5 — remove output-identical macOS Language Memory work

**Risk:** Medium
**Files:**

- `LanguageMemoryMatcher.swift`
- `LanguageMemoryPostProcessor.swift`
- existing Language Memory tests

**Change:**

1. At the 4,096 regex-cache bound, retain existing entries and return a new compiled
   regex without caching it. Never clear the entire cache.
2. Skip the second replacement pass only when **both** pass one and snippet expansion
   left the text unchanged:
   `firstReplacement.text == input && snippet.text == firstReplacement.text`.
   A weaker snippet-only condition is incorrect because a later rule can create a
   match for an earlier rule.
3. Deduplicate the four term-matching texts by exact string equality while preserving
   first occurrence.
4. Use a `Set` for merged-ID membership while preserving first-seen output order.

**Invariants to preserve:**

> "Second pass catches text introduced by snippet expansions."

> "Rules that already fired are skipped: re-running them is not idempotent."

**Tests:** no snippets; snippet introduces a replacement target; `Karko -> Karko AI`
never produces `Karko AI AI`; pass-one cascade (`teh -> the`, then
`the cat -> a cat`) still reaches the current final output; duplicate text variants;
more than 4,096 phrases across two runs; exact ID order.

**Gates:** `make test`, `swift build`.
**Measurement:** re-run the frozen 15,149-character, 1,000/5,000-term harness. Do not
claim the 4,096 cache policy eliminates compilation for every term above the bound.
If wall time remains material, stop and consult on an off-main or indexed matcher as a
new high-risk item; do not add it to this PR.

## PR6 — persist macOS bulk Language Memory mutations once

**Risk:** Medium
**Files:**

- `LanguageMemoryStore.swift`
- `LanguageMemoryStoreTests.swift`
- write-refusal regression tests

**Change:** extract private term/replacement/snippet mutation helpers with an explicit
`persist` argument. Public one-off upserts persist immediately. `importSnapshot` and
`learnFromEdit` perform their current ordered mutations without intermediate writes,
then call `save()` once. Do not use mutable global batching state. `acceptSuggestion`
may remain two writes unless measurement justifies expanding scope.

**Invariants to preserve:**

> "A file from a newer build decodes but must not be written back."

> "the previous version wrote unconditionally, so a file that failed to load was silently replaced by an empty snapshot"

Keep validation, merge order, stable IDs, disabled-state behavior, counters,
suggestion removal and write-refusal semantics unchanged.

**Tests:** complete 100-term import persists; idempotent re-import; existing IDs and
merge behavior survive; learned entries save once; unreadable/newer-version stores
refuse writing and preserve original bytes. If a persistence seam is needed for write
counts, place it after the `isWritable` guard.

**Gates:** `make test`, `swift build`.
**Measurement:** repeat the frozen 1,000-term import. Baseline is 8,093.11 ms and
239,975 bytes; the final logical file must remain equivalent.

## PR7 — align language documentation after behavior lands

**Risk:** Low
**Files:**

- `Sources/UsefulVoiceApp/Pages/SettingsPage.swift`
- `README.md`
- this audit record if measurements change

**Change:** report `detectionCodes.count`, not the full Nova-3 catalogue count.
Describe the searchable full-language picker, the smaller auto-detection set, pinning
for other Nova-3 languages, and `multi` as code-switching. Preserve the historical
`nl-BE` qualification.

**Invariant to preserve:**

> "Says what the current selection actually does."

**Gates:** platform gates for the files touched; review rendered copy.

# Explicit not-doing list

The first implementation sequence will **not**:

- implement macOS upload/delivery cancellation or a delivery timeout without a
  separate high-risk design consult;
- debounce macOS history/memory writes until the larger measured costs are removed
  and termination durability is specified;
- restore Windows focus, direct paste to a captured window, or change target identity
  without a real Windows UX run;
- change numeral gating without evidence of a provider failure;
- re-add `nl-BE` to detection;
- use unrestricted `detect_language=true`;
- change the 500/400/100 keyterm limits;
- rewrite the replacement engine, port ProtectedSpans, add a database, or switch to
  streaming transcription;
- optimize audio-tap allocation without a live profile;
- claim live CPU, memory, launch or network gains that were not measured.

# Required PR review loop

Before each implementation PR is merged:

1. ensure `.devin/agents/pr-reviewer.md` exists with the exact SWE-2 Max model id from
   the model picker and only `read`, `grep`, `glob`, `exec` tools;
2. run the required platform gates;
3. run the pinned reviewer with branch/base, behavior, invariants, priority order and
   the required numbered severity/evidence/fix/verdict contract;
4. fix or disprove every blocker/major with code evidence;
5. re-run until the verdict is `merge-ready` with no blocker/major;
6. squash-merge; never commit directly to `main`;
7. re-measure the frozen hardest case and record actual before/after numbers.

Phase 1 must not begin until Gate 0's Windows strategy is chosen and the owner approves
this implementation specification.
