# Audit 03 — Dictionary, language-memory learning, correction/matching engines, snippet expansion

**Scope:** `Sources/UsefulVoiceCore/Dictionary/*`, `Sources/UsefulVoiceCore/LanguageMemory/*`,
`Sources/UsefulVoiceCore/History/*`, `Sources/UsefulVoiceCore/Formatting/*`,
`Sources/UsefulVoiceCore/Snippets/*`, and the related tests in `Tests/UsefulVoiceCoreTests/`.
Read-only static audit; no build or test run (sandbox blocks `swift build`/`swift test`), so every
claim below is traced to source and, where possible, to a line-by-line execution of the code path
by hand.

**Audited revision:** `HEAD = a64542c` **plus uncommitted working-tree changes.**
⚠️ **The tree is being edited live while this audit runs.** `AppDelegate.swift` changed twice during
the audit (so its line numbers may already be stale — cite it by symbol), a new untracked
`Sources/UsefulVoiceCore/Transcription/KeytermBudget.swift` appeared, and
`LanguageMemoryMatcher.swift`, `MemoryBiasBuilder.swift`, `ReplacementEngine.swift`,
`SnippetExpansionEngine.swift`, `RecordingStore.swift`, `AudioRecorder.swift`, `HotkeyManager.swift`,
`HUDPanel.swift`, `UsefulVoiceViewModel.swift` and `SettingsPage.swift` all changed (14:15–14:30).
All line numbers in `Sources/UsefulVoiceCore/**` are pinned to the hashes in the appendix and were
re-verified unchanged after this report was written. Two defects found in the earlier snapshot
(`try!` regex crash, unbounded keyterm count) are **already addressed in the working tree** — see the
last section so no one re-fixes them.

**Severity key:** Critical = silent corruption of delivered text or data loss; High = wrong
behaviour a real user will hit; Medium = correctness/robustness gap with a plausible trigger;
Low = hygiene, edge case, or low blast radius.

---

## Findings table

| ID | Title | Severity | File:line | Effort |
|----|-------|----------|-----------|--------|
| MEM-01 | Dictionary case-normalization rules replace **inside words** (no word boundary) — `AI` → `sAId`, `API` → `therAPIst` | **Critical** | `DictionaryCorrector.swift:69-74`, `ReplacementEngine.swift:28-33` | S |
| MEM-02 | Effective rules are applied **twice** per dictation; self-containing rules double-apply (`Karko` → `Karko AI AI`) | **High** | `LanguageMemoryPostProcessor.swift:26-41` | S |
| MEM-03 | One edit teaches a **global word rule** with no threshold/confirmation — `then`→`than`, `there`→`three` rewrite every future dictation | **High** | `LanguageMemoryLearningPolicy.swift:69-81,100-141`, `CorrectionLearner.swift:60-67` | M |
| MEM-04 | `NSRegularExpression` recompiled per rule **and** per term-candidate, on the main actor — ~60k ICU compilations per dictation at 10k terms | **High** | `LanguageMemoryMatcher.swift:31-33,55-64`, `ReplacementEngine.swift:34-41`, `LanguageMemoryPostProcessor.swift:42-46` | M |
| MEM-05 | Full-file JSON re-encode + write of the whole history (and whole memory) **synchronously on the main actor** at the end of every dictation | **High** | `DictationHistory.swift:45-51,83-87`, `AppDelegate.swift:232` | M |
| MEM-06 | Every store swallows all write errors (`try?`) — dictionary/history silently stop persisting | Medium | `LanguageMemoryStore.swift:346-357`, `DictationHistory.swift:83-87`, `DictionaryStore.swift:179-189`, `SnippetStore.swift:40-44` | S |
| MEM-07 | A **read** failure is treated as "no data": starts empty (history even quarantines the file), then the next save overwrites the intact file | Medium | `LanguageMemoryStore.swift:11-23`, `DictationHistory.swift:29-38`, `DictionaryStore.swift:24-37` | S |
| MEM-08 | Schema `version` is written but never validated; no migration gate, no forward/back-compat policy | Medium | `LanguageMemoryModels.swift:187-192`, `LanguageMemoryStore.swift:16-23,346-357` | S |
| MEM-09 | CSV export does not neutralize formula-leading cells (`=`,`+`,`-`,`@`); import does not strip a BOM | Medium | `LanguageMemoryCSV.swift:142-147,173-180` | S |
| MEM-10 | CSV round-trip is lossy (no ids/usageCount/createdAt; `;` in a pronunciation splits it) — restore regenerates ids that history links point at | Medium | `LanguageMemoryCSV.swift:8-35,37-66,187-191` | M |
| MEM-11 | `upsertReplacement`/`upsertSnippet` replace wholesale on a canonical match: import **re-enables disabled rules**, zeroes usage, changes ids | Medium | `LanguageMemoryStore.swift:126-161` | S |
| MEM-12 | `canonical()` does no Unicode normalization: NFC vs NFD spellings never dedupe or match | Medium | `TermMatcher.swift:23-76`, `LanguageMemoryStore.swift:61-95` | S |
| MEM-13 | Learned data is unbounded (no cap/eviction/decay); `importSnapshot` bypasses the 20-suggestion cap | Medium | `LanguageMemoryStore.swift:100-123,213-228,270-281,32-58` | M |
| MEM-14 | Snippet expansion order is store order, not longest-trigger-first: `sig` shadows `my sig`; expansions are re-scanned by later snippets | Low | `SnippetExpansionEngine.swift:20-36` | S |
| MEM-15 | Shipped base vocabulary ships a third-party name (`Karko AI`) and generic common words Deepgram advises against | Low | `BaseVocabulary.swift:6-14` | S |
| MEM-16 | `DictionaryStore.biasList(budget:)` returns the **whole** list when `budget == 0` | Low | `DictionaryStore.swift:68-77` | S |
| MEM-17 | Documented ordering guarantees are not delivered: "stable for equal length" sort + locale-dependent tiebreak; `pendingSuggestions()` ties | Low | `DictionaryCorrector.swift:77-81`, `DictionaryStore.swift:82-90` | S |
| MEM-18 | `KeytermBudget` (new, uncommitted) undercounts non-Latin keyterms; length caps silently drop entries; `boundedSelection` is dead code | Low | `KeytermBudget.swift:36-50,66-78`, `MemoryBiasBuilder.swift:76-86` | S |
| MEM-19 | Dictionary page re-filters **all** terms × all fields with `range(of:)` on every keystroke, on the main actor | Low | `LanguageMemoryViewModel.swift:222-228`, `LanguageMemoryPage.swift:223` | S |
| MEM-20 | Import metrics are misleading: `updated`/`inserted` mis-count id-matches, `duplicates` only ever counts suggestions, `invalid` is unbounded and ignored by the UI | Low | `LanguageMemoryStore.swift:232-290`, `LanguageMemoryPage.swift:446-448` | S |

---

## Details

### MEM-01 — Dictionary case-normalization rewrites inside words (Critical)

**File:** `Sources/UsefulVoiceCore/LanguageMemory/DictionaryCorrector.swift:69-74` (rule construction)
and `Sources/UsefulVoiceCore/LanguageMemory/ReplacementEngine.swift:28-33` (application)

**Evidence**

```swift
// DictionaryCorrector.swift:67-74
// Case-normalize the exact dictionary phrase when STT returns
// the right words with the wrong casing.
append(ReplacementRule(
    match: phrase,
    replacement: phrase,
    matchMode: .caseInsensitivePhrase,
    language: term.language
))
```

```swift
// ReplacementEngine.swift:28-33
case .caseInsensitivePhrase:
    output = output.replacingOccurrences(
        of: match,
        with: rule.replacement,
        options: [.caseInsensitive]
    )
```

**Why it matters in production.** Every saved term produces a synthetic `.caseInsensitivePhrase`
rule whose match is the term itself. That mode is a *plain substring* replacement
(`replacingOccurrences`) — there is no word-boundary guard, unlike `.wordBoundaryPhrase`, which the
same engine builds from `(?<![\p{L}\p{N}_])…(?![\p{L}\p{N}_])`. So any dictionary term that occurs
inside a longer word rewrites that word, in the delivered text, permanently:

* Term `AI` (an extremely likely entry for this app's audience) → `I said` ⇒ `I sAId`,
  `email` ⇒ `emAIl`, `available` ⇒ `avAIlable`, `train` ⇒ `trAIn`, `certain` ⇒ `certAIn`.
* Term `API` → `therapist` ⇒ `therAPIst`, `rapid` ⇒ `rAPId`, `capital` ⇒ `cAPItal`.
* Term `PR` → `project` ⇒ `PRoject`, `spread` ⇒ `sPRread`, `product` ⇒ `PRoduct`.
* Lower-case terms are just as destructive in the other direction: term `agent` turns a
  sentence-initial `Agent` into `agent` (`Agent Smith` ⇒ `agent Smith`).

The transcript is pasted into the user's editor/documents, so this is silent data corruption of
ordinary prose. The second pass in `MEM-02` re-applies the same rules, so the damage is not limited
to one pass. `DictionaryCorrectorTests.testDictionaryPhraseFixesCasing` (line 19-26) uses the phrase
`Sadaa`, which never appears as a substring of another word, so the whole test suite passes while
this is broken.

**Recommended fix.** Make the case-normalization rule word-bounded — it is a one-line change that
preserves the intended behaviour because `.wordBoundaryPhrase` already compiles with
`.caseInsensitive` and escapes the replacement template:

```swift
append(ReplacementRule(match: phrase, replacement: phrase,
                       matchMode: .wordBoundaryPhrase, language: term.language))
```

Add a regression test with term `AI` and input `"I said email"` expecting `"I said email"`
(unchanged). Consider also routing `.caseInsensitivePhrase` through the same word-boundary path, or
removing that mode from the UI (it is only reachable in practice through this synthetic rule).

**Effort: S**

---

### MEM-02 — Effective rules are applied twice per dictation (High)

**File:** `Sources/UsefulVoiceCore/LanguageMemory/LanguageMemoryPostProcessor.swift:26-41`

**Evidence**

```swift
let rules = DictionaryCorrector.effectiveRules(from: snapshot, language: language)
let firstReplacement = ReplacementEngine.apply(rules, to: text, language: language)
let snippet = SnippetExpansionEngine.apply(snapshot.snippets, to: firstReplacement.text, language: language)
let finalReplacement = ReplacementEngine.apply(rules, to: snippet.text, language: language)
```

**Why it matters in production.** `applyDeterministic` is the production path for *every* dictation
(`AppDelegate.swift:236-243` `format:` closure; also `rawTransform` at `:248-252` and the
history-reprocess path at `:393`; AppDelegate line numbers are moving while the tree is edited live —
cite it by symbol, the Core files below are hash-pinned). The same rule set is applied to the text, then to the snippet-expanded text. Any rule
whose replacement still contains its own match — the canonical "sounds-like/alias → full brand name"
case this product sells — fires a second time and duplicates its expansion:

* Term `Karko AI` with alias/pronunciation `Karko` → rule `Karko → Karko AI`.
  Input `Karko` ⇒ pass 1 `Karko AI` ⇒ pass 2 `Karko AI AI`.
* Term `Useful Voice` with "sounds like" `Useful` → `Useful` ⇒ `Useful Voice Voice`.
  This is exactly the flow on the Dictionary page: `addWord()` stores the typed phrase with the typed
  sound-alike as a pronunciation (`LanguageMemoryPage.swift:392-412`).
* The same pattern is used in the product's own test fixtures (`LanguageMemoryModelsTests.swift:11`
  gives `Karko AI` the alias `Karko`).

Rule application is therefore **not idempotent**, and the post-processor deliberately runs it twice.
The existing tests never exercise a replacement that contains its own match
(`DictionaryCorrectorTests`, `ReplacementEngineTests`), so nothing catches it.

**Recommended fix.** Do not re-apply an already-applied rule in the second pass:

```swift
let secondPass = rules.filter { !firstReplacement.appliedRuleIDs.contains($0.id) }
let finalReplacement = ReplacementEngine.apply(secondPass, to: snippet.text, language: language)
```

(and keep `replacementRuleIDs = mergedIDs(...)` for the union). Alternatively, expand snippets
*before* the single replacement pass, or apply the second pass only to the ranges inserted by
snippets. Add a test: alias `Karko` → phrase `Karko AI`, input `Karko`, expect exactly `Karko AI`.

**Effort: S**

---

### MEM-03 — One edit teaches a global word rule; common words get rewritten forever (High)

**Files:** `LanguageMemoryLearningPolicy.swift:63-90,100-141`, `CorrectionLearner.swift:24-28,60-67`,
`LanguageMemoryStore.swift:100-123`, `LanguageMemoryPage.swift:414-426`

**Evidence**

```swift
// LanguageMemoryLearningPolicy.swift:122-140
return [
    .replacement(ReplacementRule(
        match: observedTrimmed,
        replacement: correctedTrimmed,
        matchMode: .wordBoundaryPhrase,
        language: language,
        ...
    )),
    .term(MemoryTerm(
        phrase: correctedTrimmed,
        pronunciations: pronunciation,   // = [observed] when canonical forms differ
        priority: .high,
        ...
    )),
]
```

```swift
// CorrectionLearner.swift:55-67
guard correctedTrim.count >= 3 else { continue }
...
let dist = editDistance(observedTrim.lowercased(), correctedTrim.lowercased())
let maxLen = max(observedTrim.count, correctedTrim.count)
guard maxLen > 0, Double(dist) / Double(maxLen) <= maxRelativeDistance else { continue }
```

**Why it matters in production.** Learning is a single-shot, unconfirmed, unbounded action.
"Dictionary → Fixes" (`addCorrection`, `LanguageMemoryPage.swift:414-426`) writes the rules
immediately — no preview, no confirmation dialog (only the *Library* sheet previews, and only for
that one flow). The acceptance test is Levenshtein ratio ≤ 0.65 with length ≥ 3, which does not
distinguish a mis-hearing from a legitimate one-off textual fix between two *common English words*:

* User fixes `then` → `than` in one Library entry (or in the "teach the dictionary" sheet):
  `editDistance("then","than") = 1`, `maxLen = 4` ⇒ ratio `0.25` ⇒ accepted. Result: a
  `.wordBoundaryPhrase` rule `then → than` plus a high-priority term `than` with pronunciation
  `then`. From then on **every** dictation says `and than I went`, `better than later` …
  the opposite of what the user meant. Same class: `there`→`three` (0.4), `from`→`form` (0.5),
  `form`→`from` (0.5), `quite`→`quiet` (0.4), `trail`→`trial` (0.4).
* The same correction produces up to **four** persistent artefacts (whole-phrase rule, whole-phrase
  term, word rule, word term — `entries()` lines 63-87 adds the whole phrase when both sides are
  ≤ 6 words *and* the word pairs *and*, if nothing was extracted, the pair again at line 85-87), and
  the term's `pronunciations` list feeds `DictionaryCorrector` as *yet another* correction rule
  (line 53-65), so the blast radius of one mis-tap is several global rules.
* There is no evidence threshold (`evidenceCount` is only used for suggestions), no "this looks like
  a common word, are you sure?" guard, and no undo except deleting each rule by hand in the UI.

**Recommended fix.**
1. Require either explicit confirmation for word-level pairs that touch a curated stop-list of
   common English/German words, or a second observation before a word-level rule becomes active
   (`MemorySuggestion.evidenceCount >= 2`, which the model already supports).
2. Do not create a *pronunciation* on the learned term when the pair came from word-level
   auto-extraction; pass `pronunciations: []` for that path so one action creates one rule, not two.
3. Ship a small stop-list (`then/than/there/three/from/form/quite/quiet/trail/trial/…`) and ask for
   confirmation, or store such a rule with `isEnabled = false` and surface it in the Fixes list.
4. Add a "learned from" provenance field and an undo affordance on the toast.

**Effort: M**

---

### MEM-04 — Regex compilation per rule *and* per term-candidate on every dictation (High)

**Files:** `LanguageMemoryMatcher.swift:31-33,55-64`, `ReplacementEngine.swift:34-41`,
`LanguageMemoryPostProcessor.swift:42-46,109-115`

**Evidence**

```swift
// LanguageMemoryMatcher.swift:30-34
for term in filtered {
    let candidates = [term.phrase] + term.aliases + term.pronunciations
    guard candidates.contains(where: { containsWordBoundaryPhrase($0, in: text) }) else { continue }
```
```swift
// LanguageMemoryMatcher.swift:55-64
static func wordBoundaryRegex(for phrase: String) -> NSRegularExpression? {
    ...
    let escaped = NSRegularExpression.escapedPattern(for: trimmed)
    let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
    return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}
```
```swift
// LanguageMemoryPostProcessor.swift:42-46
let memoryHitIDs = matchingTermIDs(
    terms: snapshot.terms, language: language,
    texts: [text, firstReplacement.text, snippet.text, finalReplacement.text]
)
```

**Why it matters in production.** Every call to `containsWordBoundaryPhrase` **compiles a fresh
ICU regex** (there is no cache anywhere in the package — verified by grep). Per dictation:

* term matching: `4 texts × Σ(1 + aliases + pronunciations)` compilations — for a 10,000-term
  dictionary with no aliases that is **40,000 compilations**, each scanning a full transcript;
* rule application: `2 passes × R wordBoundary rules` — another **20,000** compilations at 10k rules.

ICU pattern compilation is on the order of tens of microseconds, so ~60k compilations is
**roughly 1–3 seconds of pure setup per dictation**, and all of it happens on the main actor
(see MEM-05 for why). The effect on the user: the HUD freezes after they stop speaking, the app looks
hung, and the 15 s transcription deadline runs concurrently. The 4-text union also does the work
4× even when the term only appears in the raw transcript. Note the uncommitted change to this file
made compilation *fail-safe* and capped phrase length at 200 — it did not add caching.

**Recommended fix.**
1. Cache compiled regexes: `NSCache<NSString, NSRegularExpression>` (or a dictionary keyed by
   `phrase + "\u{0}" + mode`) inside `LanguageMemoryMatcher`, keyed on the raw phrase, with a
   bounded count (e.g. 512 entries, evicted in insertion order).
2. Better: compile **one** alternation regex per snapshot — `(?:phraseA|phraseB|…)` from escaped
   literals sorted longest-first — and scan each text once for both matching and replacement.
3. Have `LanguageMemoryStore` expose a `revision: Int` bumped on every mutation; cache the derived
   `[ReplacementRule]` from `DictionaryCorrector` plus the compiled regexes keyed by that revision
   instead of rebuilding on every dictation.
4. Move `applyDeterministic` off the main actor. `LanguageMemorySnapshot` is already `Sendable` and
   the function is pure: the `format`/`rawTransform` closures are `async`, so
   `await Task.detached { LanguageMemoryPostProcessor.applyDeterministic(...) }.value` is a
   drop-in change that removes the stall from the UI thread.
5. Add a perf test that asserts a 10,000-term pass completes within a fixed budget.

**Effort: M** (caching) / **L** (single-alternation rewrite)

---

### MEM-05 — Synchronous full-file JSON writes on the main actor per dictation (High)

**Files:** `DictationHistory.swift:41-51,83-87`, `AppDelegate.swift:199-212`,
`LanguageMemoryStore.swift:32-58,346-357`, `DictationController.swift:103,292-293`

**Evidence**

```swift
// DictationHistory.swift:44-51
public func append(_ record: DictationRecord) {
    records.insert(record, at: 0)
    if records.count > retentionCap { records = Array(records.prefix(retentionCap)) }
    persist()
}
// :83-87
private func persist() {
    if let data = try? DictationHistory.makeEncoder().encode(records) {
        try? data.write(to: fileURL, options: .atomic)
    }
}
```
```swift
// AppDelegate.swift:227-236  (the `record:` closure handed to DictationController)
self.languageMemory?.recordUsage(termIDs: ..., replacementRuleIDs: ..., snippetIDs: ...)
self.history?.append(record)
self.viewModel?.refreshLanguageMemory()
```

**Why it matters in production.** `DictationController` is `@MainActor`, and `process` calls
`record(...)` on the main actor (`DictationController.swift:292`), so this whole block runs on the
main thread at the exact moment the user is waiting for their paste. `DictationHistory` keeps 1,000
records, each carrying `text`, `rawText` and `intermediateText` (`DictationRecord.swift:4-23`) — the
file and its in-memory encoding are ~3× the transcript volume, i.e. **multiple MB after a few
hundred dictations**, re-encoded and rewritten (with `.atomic`, so a temp file + rename) on *every*
single dictation. That is a main-thread hitch of tens of milliseconds on every use, growing
monotonically with history length, and it also blocks the global event tap. `recordUsage` similarly
re-serializes the entire memory snapshot (all terms/rules/snippets) whenever any usage counter ticks,
which with a large dictionary is another multi-hundred-KB write per dictation.

**Recommended fix.**
* Move persistence off the main thread: keep the in-memory array authoritative, snapshot it (it is
  `[DictationRecord]`, `Sendable`) and write via a serial background queue/actor, coalescing writes
  (e.g. at most one write per 500 ms, plus a flush on termination).
* Stop storing three copies of the text: persist `text` + `rawText` only, or move history to an
  append-only JSONL log with periodic compaction — an append is O(1) instead of O(n) bytes.
* Make `recordUsage` dirty-flag + debounce its save instead of writing per call.

**Effort: M**

---

### MEM-06 — All store write failures are swallowed (Medium)

**Files:** `LanguageMemoryStore.swift:346-357`, `DictationHistory.swift:83-87`,
`DictionaryStore.swift:179-189`, `SnippetStore.swift:40-44`

**Evidence**

```swift
// LanguageMemoryStore.swift:346-357
private func save() {
    let persisted = LanguageMemoryPersisted(version: LanguageMemoryPersisted.currentVersion, snapshot: state)
    guard let data = try? Self.encoder.encode(persisted) else { return }
    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
}
```

**Why it matters in production.** Disk full, an unwritable Application Support directory, a file
locked by a sync/backup agent, or a permissions change all produce the same outcome: the mutation
appears to succeed (the UI lists the new word, the toast says "Added"), nothing is written, and the
user discovers the loss on the next launch. There is no error path, no `os_log`, no UI signal.
`.atomic` at least prevents a *partial* file, so the failure mode is loss, not corruption — but it is
completely invisible.

**Recommended fix.** Turn `save()` into `@discardableResult private func save() -> Bool` that
captures the thrown error, sets `private(set) var lastSaveError: Error?` and calls an injected
`onSaveFailure: ((Error) -> Void)?`; `LanguageMemoryViewModel` surfaces it once per session as a
toast plus a persistent banner on the Dictionary page ("Changes are not being saved — <reason>"), and
logs via `os.Logger(subsystem:category:)`. Add a test that injects a read-only directory URL and
asserts the failure is reported.

**Effort: S**

---

### MEM-07 — Read failure is indistinguishable from "no data yet" (Medium)

**Files:** `LanguageMemoryStore.swift:9-24`, `DictationHistory.swift:21-39`,
`DictionaryStore.swift:22-38`, `SnippetStore.swift:9-22`

**Evidence**

```swift
// LanguageMemoryStore.swift:9-23
public init(fileURL: URL) {
    self.fileURL = fileURL
    guard let data = try? Data(contentsOf: fileURL) else {
        state = LanguageMemorySnapshot()
        return
    }
    if let persisted = try? Self.decoder.decode(LanguageMemoryPersisted.self, from: data) { ... }
    else if let snapshot = try? Self.decoder.decode(LanguageMemorySnapshot.self, from: data) { ... }
    else { Self.backUpCorruptFile(fileURL); state = LanguageMemorySnapshot() }
}
```
```swift
// DictationHistory.swift:29-38
do {
    let data = try Data(contentsOf: fileURL)
    records = try DictationHistory.makeDecoder().decode([DictationRecord].self, from: data)
} catch {
    // Corrupt or unreadable file: move it aside (best-effort) and start empty.
    let backup = fileURL.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: fileURL, to: backup)
    records = []
}
```

**Why it matters in production.** Three distinct situations are collapsed into one: file absent
(fine), file unreadable *right now* (transient: a lock held by a backup tool, an iCloud-evicted
placeholder, a sandbox denial that resolves later), and file genuinely corrupt. In the first and
second the store starts empty and *the next mutation writes that empty state over the real file* —
one transient read error at launch becomes permanent loss of the dictionary/history. `DictationHistory`
is worse: any read error moves the (perfectly good) file to `history.json.bak`, so the user's Library
empties out with no message, and the *next* corruption quarantines the current file over that backup
(`removeItem` at line 35 destroys the previous `.bak` before moving), leaving only one generation.

**Recommended fix.** Distinguish the cases explicitly:

```swift
guard FileManager.default.fileExists(atPath: fileURL.path) else { state = .init(); return }
do { data = try Data(contentsOf: fileURL, options: .mappedIfSafe) }
catch { /* read error: keep the on-disk file, mark the store read-only, surface the error */ }
```

Only quarantine on a `DecodingError`, and when quarantining, use a timestamped name
(`history-corrupt-2026-09-10T14-25.json`) so successive incidents never destroy earlier evidence.
Do not enable saving until a successful load, or re-read before the first write.

**Effort: S**

---

### MEM-08 — Schema `version` is written but never validated (Medium)

**Files:** `LanguageMemoryModels.swift:187-192`, `LanguageMemoryStore.swift:16-23,346-357`

**Evidence**

```swift
// LanguageMemoryModels.swift:187-192
struct LanguageMemoryPersisted: Codable {
    static let currentVersion = 1
    var version: Int
    var snapshot: LanguageMemorySnapshot
}
```
```swift
// LanguageMemoryStore.swift:16-23 — `version` is decoded and then ignored
if let persisted = try? Self.decoder.decode(LanguageMemoryPersisted.self, from: data) {
    state = persisted.snapshot
}
```

**Why it matters in production.** There is no migration gate and no compatibility policy:
`version` is dead data. `JSONDecoder` ignores unknown keys, so a *newer* file decodes because it
still contains `version` + `snapshot` — the app then silently rewrites it in the old shape on the
next mutation, discarding any fields the newer build added (lossy downgrade, no warning). If a future
build instead changes the snapshot shape incompatibly, the old build fails to decode, quarantines the
file and starts empty — and the user's entire dictionary silently disappears from a version rollback.
`DictionaryStore` and `SnippetStore` have no version field at all, so any decode failure is treated
as corruption (`DictionaryStore.swift:28-37`).

**Recommended fix.** Decode `version` first with a tiny probe (`struct VersionProbe: Decodable { let version: Int }`)
and switch on it: `case 1: …`; `case > currentVersion:` refuse to load *and refuse to save* (read-only
mode + "This dictionary was written by a newer version of Useful Voice") instead of quarantining;
`default:` run an explicit migration chain `migrate(from:to:)`. Add a round-trip test per version
fixture. Also note the quarantine path must not be reachable from a version mismatch.

**Effort: S**

---

### MEM-09 — CSV formula injection on export; no BOM handling on import (Medium)

**File:** `LanguageMemoryCSV.swift:142-147` (escape), `:173-180` (header detection)

**Evidence**

```swift
// :142-147
private static func escape(_ field: String) -> String {
    let mustQuote = field.contains(",") || field.contains("\"") ||
        field.contains("\n") || field.contains("\r")
    let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
    return mustQuote ? "\"\(escaped)\"" : escaped
}
```
```swift
// :173-180
private static func rowsAfterOptionalHeader(_ rows: [[String]], requiredFirstHeader: String) -> ArraySlice<[String]> {
    guard let first = rows.first?.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          first == requiredFirstHeader else { return rows[rows.startIndex...] }
    return rows.dropFirst()
}
```

**Why it matters in production.** Export is offered as "Words CSV" / "Fixes CSV" copied to the
clipboard (`LanguageMemoryPage.swift:47-53`) and users paste it into Numbers/Excel. RFC-4180 quoting
is correct, but a cell beginning with `=`, `+`, `-`, `@`, tab or CR is still interpreted as a formula
by Excel/LibreOffice: a term or note such as `=HYPERLINK("http://attacker/","click")` (or a DDE
payload on Windows Excel) executes on the machine that opens the sheet. The immediate risk is
self-inflicted (the user authored their own terms), but the realistic attack path is a *shared* team
dictionary CSV: import it, export it, open it in Excel. Separately, `rowsAfterOptionalHeader`
compares the first cell byte-for-byte against `"phrase"`/`"match"`; a UTF-8 BOM (U+FEFF) is not in
`CharacterSet.whitespacesAndNewlines` (it is a format character, not `White_Space`), so a
BOM-prefixed CSV imports its **header row as a real term** (`phrase`, priority `.high`) and shifts
every column of row 1. ⚠️ *Less certain in impact:* imports currently arrive by pasting into a
`TextEditor` (`LanguageMemoryPage.swift:354`), not by file picker, so a BOM only occurs when the user
pastes BOM-prefixed text — a file-picker import would make this trivially reproducible.

**Recommended fix.** In `escape`, neutralize formula-leading cells the way OWASP recommends (prefix a
single quote or a space when the trimmed cell starts with `= + - @` or a tab/CR, or always quote and
prefix `'`); apply it to every exported cell including `notes`. In `decode`, strip a leading
`\u{FEFF}` before parsing. Treat a header-only CSV as empty rather than as data. Consider adding a
real file-import path with the same guards.

**Effort: S**

---

### MEM-10 — CSV export/import is not a faithful backup (Medium)

**File:** `LanguageMemoryCSV.swift:8-35,37-66,187-191`

**Evidence**

```swift
// :9-19 — what a term export contains
let rows = [["phrase", "pronunciations", "aliases", "language", "priority", "notes"]]
    + terms.map { term in
        [term.phrase, term.pronunciations.joined(separator: "; "), term.aliases.joined(separator: "; "),
         term.language.rawValue, term.priority.rawValue, term.notes] }
```
```swift
// :187-191
private static func splitList(_ text: String) -> [String] {
    text.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}
```
```swift
// :53-62 — a fresh UUID and fresh timestamps on every import
terms.append(MemoryTerm(phrase: phrase, ... createdAt: now, updatedAt: now))
```

**Why it matters in production.** The "Words CSV"/"Fixes CSV" round-trip is presented next to the JSON
"Backup" as a dictionary backup, but it drops `id`, `usageCount`, `createdAt`/`updatedAt`, and
`tags`/`isEnabled` semantics beyond the single boolean. Concrete consequences:
* Restoring into a clean store **regenerates every id**, so `DictationRecord.memoryHitIDs` /
  `replacementRuleIDs` / `snippetIDs` in the user's Library no longer resolve — the "What did memory
  do on this dictation" linkage (and the usage ranking that drives keyterm order) is silently broken.
* A pronunciation or alias containing `;` is split into two entries on import (no escaping of the
  list separator), so `"GPT-4; o1"` becomes two pronunciations — harmless — but `"a;b"` written as a
  single term becomes two different rules.
* `usageCount` resets to 0, so a restored dictionary reorders the keyterm bias list.

**Recommended fix.** Make the JSON snapshot the only documented backup (it is already lossless:
`exportSnapshotJSON`/`importSnapshotJSON` preserve ids and counters) and label the CSVs "export for
spreadsheets, not for restore"; or, if CSV must round-trip, add `id`, `usageCount`, `createdAt`,
`updatedAt` columns and escape the `;` list separator (`\;` or quote each element). Round-trip tests
should assert `export(import(x)) == x` for ids and counts, not just for display fields.

**Effort: M**

---

### MEM-11 — Wholesale replacement on import re-enables and resets rules (Medium)

**File:** `LanguageMemoryStore.swift:126-161`

**Evidence**

```swift
public func upsertReplacement(_ rule: ReplacementRule) -> ReplacementRule {
    let normalized = normalizedReplacement(rule)
    ...
    if let index = state.replacements.firstIndex(where: {
        $0.id == normalized.id || TermMatcher.matches($0.match, normalized.match)
    }) {
        state.replacements[index] = normalized      // full overwrite, not a merge
    } else {
        state.replacements.insert(normalized, at: 0)
    }
```

**Why it matters in production.** `upsertTerm` merges carefully (keeps the existing id, unions
pronunciations/aliases, keeps the stronger priority, `max` usage — lines 65-95), but the
replacement/snippet paths replace the record outright. Because imported records carry fresh UUIDs and
`usageCount = 0`, importing a backup (or a CSV) silently:
* **re-enables rules the user deliberately paused** (`isEnabled` is overwritten with the imported
  value, which is `true` for every exported CSV row and for every learned rule) — a paused bad
  auto-correction (e.g. MEM-03's `then → than`) comes back on;
* resets `usageCount` to 0 and `updatedAt` to the import time, perturbing keyterm ranking;
* changes the rule's `id`, breaking the Library's per-dictation diagnostics for that rule.

`LanguageMemoryStoreTests.testUpsertPersistsPausedReplacementsAndSnippets` only proves that an
*identical* record round-trips, not that an import preserves an existing paused rule.

**Recommended fix.** Give these paths the same merge semantics as `upsertTerm`: preserve the existing
`id` on a canonical match, keep `isEnabled` when the incoming record has a *different* id (only an
explicit UI edit with the same id may flip it), and take `max(usageCount)` / keep the earlier
`createdAt`. Add a test: pause a rule, import an enabled copy, assert it stays paused.

**Effort: S**

---

### MEM-12 — No Unicode normalization in `canonical()` (Medium)

**File:** `TermMatcher.swift:23-76` (canonical), `LanguageMemoryStore.swift:61-95` (dedupe/merge)

**Evidence**

```swift
public static func canonical(_ term: String) -> String {
    var s = term.trimmingCharacters(in: .whitespacesAndNewlines)
    ...
    return result.lowercased()
}
```

**Why it matters in production.** Nothing normalizes to NFC/NFD, and neither `.lowercased()` nor
`NSRegularExpression.escapedPattern` folds decomposed sequences. macOS text arrives in **both** forms
in practice: text copied from the Finder/HFS+ side or pasted from some editors is NFD
(`Cafe` + U+0301), while STT output and `JSONEncoder` round-trips are typically NFC (`Café`). For a
German/English product with accented names (`Müller`, `Zürich`, `Café`, `Ångström`, `İstanbul`):
* `TermMatcher.matches("Müller"(NFC), "Mu\u{0308}ller"(NFD))` is `false`, so the user gets two
  dictionary entries for the same name, `biasList` sends the term twice, and
  `DictionaryCorrector.effectiveRules` produces two rules that each rewrite the *other* form;
* worse, the case-normalization rule (MEM-01) of the NFC entry will rewrite an NFD occurrence's
  casing while leaving the diacritic in NFD form, so the delivered text mixes both forms.

**Recommended fix.** Normalize at the entry point of `TermMatcher.canonical`
(`let s = term.precomposedStringWithCanonicalMapping.lowercased()` — or `.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)` if diacritic-insensitive matching is desired; note that changes the semantics, so decide explicitly), and normalize incoming `phrase`/`match`/`trigger`/`replacement` in `LanguageMemoryStore.normalized*`. Add NFC/NFD fixtures to `TermMatcherTests`.

**Effort: S**

---

### MEM-13 — Unbounded learned data and usage counters (Medium)

**File:** `LanguageMemoryStore.swift:100-123` (learning), `:213-228` (suggestion cap),
`:270-281` (import), `:32-58` (usage)

**Evidence**

```swift
// :212-228 — the 20-suggestion cap exists only on the `suggest` path
for suggestion in incoming { ... state.suggestions.append(suggestion) }
state.suggestions.sort { ... }
if state.suggestions.count > 20 { state.suggestions = Array(state.suggestions.prefix(20)) }
```
```swift
// :270-281 — importSnapshot appends suggestions with no cap
if state.suggestions.contains(where: { TermMatcher.matches($0.observed, suggestion.observed) }) {
    duplicates += 1
} else {
    state.suggestions.append(suggestion)
    inserted += 1
}
```

**Why it matters in production.** Terms, replacements, snippets and their pronunciations are never
capped, evicted, or aged. Each teaching action adds up to 4 entries (MEM-03), each import can add an
arbitrary number of suggestions (`importSnapshot` has no 20-cap, unlike `suggest`), and
`usageCount` only ever increments (no decay), so a term that is *frequently misheard* keeps climbing
the `MemoryBiasBuilder` ranking and permanently occupies keyterm budget ahead of things the user
actually says. Everything is written to one JSON file and copied wholesale into every `snapshot()`
call (per dictation), so growth is unbounded in memory, on disk, and in the per-dictation work of
MEM-04. The Dictionary page renders all of it (`LanguageMemoryPage.swift:223`).

**Recommended fix.** Cap totals (e.g. 2,000 terms / 500 replacements / 200 snippets / 20 suggestions)
with an explicit eviction policy — evict by lowest `priority` then lowest `usageCount` then oldest —
apply the same cap inside `importSnapshot`, and add usage decay (`usageCount = usageCount * 9 / 10`
on a weekly rollup, or order by a recency-weighted score). Surface "dictionary full, N oldest entries
dropped" in the UI rather than dropping silently.

**Effort: M**

---

### MEM-14 — Snippet expansion order is store order, not longest-trigger-first (Low)

**File:** `SnippetExpansionEngine.swift:20-36`

**Evidence**

```swift
for snippet in snippets where snippet.isEnabled && languageMatches(snippet.language, language) {
    let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    let expansion = snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trigger.isEmpty, !expansion.isEmpty else { continue }
    let before = output
    guard let regex = LanguageMemoryMatcher.wordBoundaryRegex(for: trigger) else { continue }
    ...
}
```

**Why it matters in production.** `snapshot.snippets` is in insertion order, newest first
(`upsertSnippet` inserts at index 0), so a shorter trigger added later silently shadows a longer one:
with snippets `sig → signature` and `my sig → Best,\nWasim`, dictating "my sig" expands the inner
`sig` first and the intended snippet never fires — with no feedback. Conversely, because each snippet
scans the *already expanded* output of the previous ones, one snippet's expansion can be re-expanded
by a later snippet (`addr → 123 Main St` followed by `Main → Main Street` yields
`123 Main Street St`). `DictionaryCorrector` sorts rules longest-first for exactly this reason; the
snippet engine does not.

**Recommended fix.** Sort by descending trigger length before the loop (ties broken by store order or
id, deterministically), and expand against a "don't re-scan what I just wrote" strategy — e.g. build
the output by scanning the *original* text once with a single alternation of all triggers (longest
alternation first) and substituting on the fly, which also removes the chained-expansion class
entirely and is faster with many snippets.

**Effort: S**

---

### MEM-15 — Base vocabulary content (Low)

**File:** `BaseVocabulary.swift:6-14`

**Evidence**

```swift
"Next.js", "Vercel", "Stripe", "Bedrock", "Tailwind", "TypeScript",
"Karko AI", "Useful Voice", "SwiftUI", "Xcode", "GitHub", "API", "JSON",
"endpoint", "deployment", "Azure", "prompt", "embeddings", "fine-tune",
```

**Why it matters in production.**
* **`Karko AI`** is not this product, its vendor, or any term a user of a general dictation app would
  say. It is in the shipped list in every version since the file's creation (verified with
  `git log -p --follow`), it appears nowhere else in the repo except tests, and it is included in the
  Deepgram keyterm list for **every** user, spending budget and biasing recognition toward a
  third-party brand. ⚠️ *Less certain about intent:* if `Karko AI` is deliberately shipped as a
  product-owned term, the only remaining issue is the wasted budget slot — but nothing in the repo
  documents that.
* **Generic common words** — `agent`, `token`, `repo`, `PR`, `prompt`, `endpoint`, `deployment` —
  are exactly what Deepgram's keyterm guidance says to avoid ("Generic common words: very common
  words that are rarely misrecognized"), and `PR`/`token`/`agent` also collide with ordinary speech
  ("pull request", "token", "agent"). They consume slots in a 100-term list that is filled *after*
  the user's own terms, so they are mostly harmless — but they are the only items that can never
  help and occasionally hurt.
* No duplicates and no misspellings were found: all 40 entries have distinct canonical forms
  (checked by canonicalising the list), and `Nova-3`, `Next.js`, `Supabase`, `Postgres`,
  `Kubernetes` are spelled correctly, with no unexpected trade names.
* Note these entries are keyterms only — they never become replacement rules (`MemoryBiasBuilder`
  passes `baseVocabulary` separately from `terms`), so they cannot cause an auto-correction. That is
  a good design decision.

**Recommended fix.** Remove `Karko AI` (or move it behind a build flag / first-run onboarding that
offers it as a suggested dictionary entry the user can accept). Drop the generic single-word entries
or move them to a "suggested terms" list, so the 100-slot keyterm budget goes to the user's own
vocabulary first.

**Effort: S**

---

### MEM-16 — `biasList(budget:)` returns everything when `budget == 0` (Low)

**File:** `DictionaryStore.swift:68-77`

**Evidence**

```swift
public func biasList(budget: Int) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for word in entries.map(\.word) + BaseVocabulary.terms {
        let key = TermMatcher.canonical(word)
        if seen.insert(key).inserted { result.append(word) }
        if result.count == budget { break }        // never true when budget == 0
    }
    return result
}
```

**Why it matters in production.** The cap is enforced with `==`, so the documented "capped at
`budget`" contract fails for `budget == 0` (and for any budget the caller expects to be a hard
ceiling): the function returns the entire personal dictionary plus all base terms. Today this store
is only used by `LanguageMemoryMigrator` (the app builds `MemoryBiasBuilder` instead), so the blast
radius is small — but it is a public API with a broken precondition. The equivalent code in
`MemoryBiasBuilder` correctly uses `guard budget > 0` + `result.count < budget`.

**Recommended fix.** `guard budget > 0 else { return [] }` at the top and use `>= budget` for the
break, or delegate to `MemoryBiasBuilder` so there is exactly one implementation.

**Effort: S**

---

### MEM-17 — Documented ordering guarantees are not delivered (Low)

**Files:** `DictionaryCorrector.swift:77-81`, `DictionaryStore.swift:82-90`

**Evidence**

```swift
// DictionaryCorrector.swift:77-81
// Longest match first; stable for equal length.
return rules.sorted {
    if $0.match.count != $1.match.count { return $0.match.count > $1.match.count }
    return $0.match.localizedCaseInsensitiveCompare($1.match) == .orderedAscending
}
```
```swift
// DictionaryStore.swift:82-90  ("ties in insertion order" per the doc comment)
return pending.sorted { a, b in
    let countA = pendingCounts[TermMatcher.canonical(a)] ?? 1
    let countB = pendingCounts[TermMatcher.canonical(b)] ?? 1
    return countA > countB
}
```

**Why it matters in production.** ⚠️ *Both are real but low-impact today; flagging as uncertainty.*
Swift's `sorted(by:)` is documented as **not stable**, so "stable for equal length" is not what the
code does: for two equal-length matches the comparator returns a locale-dependent verdict
(`localizedCaseInsensitiveCompare`) — and because rules are applied *sequentially* (a later rule sees
the earlier rule's output), a user in a different locale can get a different result from the same
dictionary and the same transcript. The dedupe key in `effectiveRules` (`mode|canonical`) does not
prevent two equal-length matches from both existing. `pendingSuggestions()`'s doc-comment promise of
"ties in insertion order" is likewise unspecified behaviour: two terms with the same count can swap
order between launches (the order is at least deterministic for a fixed input array, so this is a UX
inconsistency, not a data bug). Note the suggestion *ranking* itself remains deterministic in
practice because `suggest()` bumps counts monotonically.

**Recommended fix.** Make both orderings total and locale-independent: in `DictionaryCorrector`,
break ties on `TermMatcher.canonical(match)` compared with plain `<` (or on the rule's `id`
string) instead of a locale-aware compare, and fix the comment; in `pendingSuggestions()`, sort by
`(count desc, insertion index asc)` explicitly (map to `enumerated()` and use the index as the
tiebreaker).

**Effort: S**

---

### MEM-18 — New keyterm budget code: non-Latin undercount, silent drops, dead API (Low)

**Files:** `KeytermBudget.swift:29-50,63-78` (untracked, new), `MemoryBiasBuilder.swift:76-86` (modified),
`LanguageMemoryMatcher.swift:44-58` (modified)

**Evidence**

```swift
// KeytermBudget.swift:40-49
let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
let byLength = Int((Double(trimmed.count) / 5.0).rounded(.up))
let separators = trimmed.filter { !$0.isLetter && !$0.isNumber }.count
let base = max(words, byLength) + separators
return max(1, base)
```
```swift
// MemoryBiasBuilder.swift:76-78
func append(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard KeytermBudget.isSendableKeyterm(trimmed) else { return }   // not counted as dropped
```

**Why it matters in production.** This new code genuinely fixes the failure mode I flagged in the
earlier snapshot (Deepgram rejects the whole request with `Keyterm limit exceeded. The maximum number
of tokens across all keyterms is 500.`, so an oversized dictionary would break *every* dictation).
Two residual gaps:
* The estimator assumes ~5 characters per subword token, which holds for Latin script but
  **undercounts CJK and other non-space-delimited scripts by roughly 4-6×** (a 5-character Japanese
  term is estimated at 1 token; real BPE cost is closer to 5). `language = multi` and the `ja`/`ru`
  codes are reachable through auto-detect, so a Japanese or Chinese dictionary can still blow the
  500-token ceiling while the estimator reports ~100. ⚠️ *Less certain about the exact ratio for
  Deepgram's tokenizer* — but the estimator has no script-awareness at all, so the direction of the
  error is not in doubt.
* `isSendableKeyterm` rejections (length > 64, control characters, punctuation-only) return without
  incrementing `dropped`, so `KeytermSelection.isOverCapacity` under-reports what was left out;
  `maxTermLength = 64` and `maxPhraseLength = 200` also mean a long term is silently excluded from
  keyterms/matching/expansion with no user-visible signal, and `boundedSelection` is currently called
  from nowhere (dead API — `AppDelegate.swift:431` still calls the count-budget `biasList`).

**Recommended fix.** Estimate tokens per script (`scalar.isASCII`/Latin → `len/5`; CJK/Hangul/Kana →
`len`; Cyrillic/Greek/Arabic → `len/3`), or reserve a much larger margin (e.g. 250) and log actual
usage; count every rejected term in `dropped` (add a `rejected` counter); wire `boundedSelection` into
`AppDelegate.dictionaryBiasWords` and surface `isOverCapacity` in Settings; add unit tests for
non-Latin terms and for the 500-token boundary.

**Effort: S**

---

### MEM-19 — Per-keystroke O(terms × fields) filtering on the main actor (Low)

**Files:** `LanguageMemoryViewModel.swift:20-34,222-228`, `LanguageMemoryPage.swift:223`

**Evidence**

```swift
// LanguageMemoryViewModel.swift:222-228
private func filter<T>(_ values: [T], fields: (T) -> [String]) -> [T] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return values }
    return values.filter { value in
        fields(value).contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
    }
}
```

**Why it matters in production.** `filteredTerms` is a computed property used directly in the view
body (`LanguageMemoryPage.swift:223`, and again at `:261` for the count), and `query` is bound to a
search field, so every keystroke re-runs `filter` over all terms × (phrase + notes + aliases +
pronunciations) with a locale-aware, case-insensitive `range(of:)` per field. With a 10,000-term
dictionary that is ~40,000 substring searches per keystroke on the main thread — visible typing lag
in exactly the screen a power user with a large dictionary lives in. The same is true for the
Fixes/Shortcuts sections.

**Recommended fix.** Precompute a lowercased `searchText` blob once per term when the snapshot is
refreshed (cheap: one lowercasing per term per refresh, not per keystroke), debounce the query
(150 ms), and filter with `contains` on the precomputed blob (or use `localizedStandardContains` on
the blob if locale-aware behaviour is wanted). For very large dictionaries, move filtering to a
background task with an id query so stale results are discarded.

**Effort: S**

---

### MEM-20 — Import metrics are misleading (Low)

**Files:** `LanguageMemoryStore.swift:232-290`, `LanguageMemoryPage.swift:446-448`

**Evidence**

```swift
let existed = state.replacements.contains { TermMatcher.matches($0.match, rule.match) }
_ = upsertReplacement(rule)
if existed { updated += 1 } else { inserted += 1 }      // mismatches upsert's own id-match
...
if state.suggestions.contains(where: { TermMatcher.matches($0.observed, suggestion.observed) }) {
    duplicates += 1
} else { state.suggestions.append(suggestion); inserted += 1 }
```

**Why it matters in production.** `upsert*` matches on `id == id || matches(...)` while the counters
re-check only `matches`, so a record with the same id and a renamed phrase is reported as "new"
although it overwrote an existing row; `duplicates` can only ever be non-zero for suggestions
(terms/replacements/snippets never increment it). The UI then reports
`"Imported N new and updated M. K duplicates skipped."` (`LanguageMemoryPage.swift:446-448`) and never
mentions `invalid`, even though `invalid` is collected (and is unbounded — one `invalid` element per
rejected row, with the whole row text concatenated, which is fine for a warning list but must be
capped in the UI).

**Recommended fix.** Derive the counts from the store's own state before/after (`terms.count`,
`replacements.count`, … diffed by id) instead of a parallel pre-check; report invalid rows in the
import sheet (first ~10 plus "and N more"); cap the `invalid` array.

**Effort: S**

---

## Already good (verified, not findings)

* **Regex construction from user input is safe.** Every user-supplied pattern goes through
  `NSRegularExpression.escapedPattern(for:)` (`LanguageMemoryMatcher.swift:59`) and every replacement
  through `NSRegularExpression.escapedTemplate(for:)` (`ReplacementEngine.swift:40`,
  `SnippetExpansionEngine.swift:31`), so metacharacters and `$1` sequences are literal — the failing
  case is tested (`ReplacementEngineTests.testRegexReplacementIsLiteral`, expecting `$1.00` verbatim).
  *Caveat:* the uncommitted working tree changed `wordBoundaryRegex` to return `nil` instead of using
  `try!`, which removes the (real, pre-existing) crash path where a pathological user phrase could
  trap the app — that change should be kept and covered by a test.
* **No catastrophic backtracking / ReDoS.** Patterns are `(?<![\p{L}\p{N}_])` + escaped-literal +
  `(?![\p{L}\p{N}_])`: no nested quantifiers, no alternation, fixed-width lookarounds. Worst case is
  linear in the transcript. The only cost problem is *compilation frequency* (MEM-04), not blowup.
* **Word-boundary replacement semantics are correct where they are used.** The lookarounds use
  `\p{L}\p{N}_`, which handles German umlauts/ß and technical terms correctly (`C++`, `gpt-4o`, `sig`
  inside `signal`), and longest-match-first ordering is implemented for dictionary-derived rules.
* **Atomic writes everywhere.** Every store writes with `.atomic` (`LanguageMemoryStore.swift:356`,
  `DictationHistory.swift:85`, `DictionaryStore.swift:187`, `SnippetStore.swift:42`), so a crash
  mid-write yields the old file, never a half-written JSON. `LanguageMemoryStore` also creates its
  parent directory before writing.
* **Corruption does not brick the app.** A malformed `language-memory.json` is moved aside and the app
  starts with an empty store (`LanguageMemoryStore.swift:20-23`); the migrator then re-imports the
  legacy `dictionary.json`/`snippets.json` because they are deliberately left in place, which is a
  genuinely good recovery path (`LanguageMemoryMigrator.swift:9-12`, tested in
  `LanguageMemoryMigratorTests`).
* **`try!` is gone from the current tree, and `MemorySuggestionEngine`/`CorrectionLearner` have no
  force-unwraps or index assumptions** in reachable paths (`makeEntry` uses `[0]` but `makeEntries`
  always returns at least one element).
* **No repeated full-file reads.** Snapshot/getters read from memory; the file is read exactly once in
  `init`. Disk I/O per dictation is writes only. (Per-keystroke cost is in-memory filtering,
  MEM-19.)
* **Store threading is fine.** All `LanguageMemoryStore`/`DictationHistory` access happens on the main
  actor: `DictationController` is `@MainActor` (`DictationController.swift:13`) and its
  `format`/`rawTransform`/`record`/`hint` closures are invoked from `process`, which runs in a
  MainActor-inherited `Task` (`:103`). The stores are non-`Sendable` classes but never actually
  escape the main actor, so the `swift-tools-version:5.9` build is not papering over a real race. I
  found **no** unsynchronised cross-actor store access, and no `Task.detached`/`DispatchQueue.global`
  touching these stores.
* **Priority ordering between rule sources is deliberate and mostly right.** Explicit user
  replacements are appended first and claim the dedupe key, so they win over synthetic rules derived
  from the same term (`DictionaryCorrector.swift:26-46`); replacements run before snippet expansion
  and again after it (the intent, not the double-apply — MEM-02); `MemoryBiasBuilder` sends only
  *correct* forms as keyterms (never pronunciations/mis-heard forms), which is exactly right.
* **Language gating is consistent** across `ReplacementEngine`, `SnippetExpansionEngine`,
  `DictionaryCorrector`, `LanguageMemoryMatcher` and `MemoryBiasBuilder` (`.auto` on either side
  matches), including a test for the German/English split.
* **CSV parsing/quoting is RFC-4180-correct for the common cases:** doubled quotes, embedded commas,
  embedded newlines, quoted fields spanning lines, `\r\n` line endings, and a trailing newline that
  does not create a phantom row; `boolValue` accepts `true/yes/1/enabled/on`. The problems are
  formula-leading cells, BOM, and round-trip fidelity (MEM-09/MEM-10), not basic parsing.

---

## Appendix — snapshot hashes (sha256, first 12 hex)

`HEAD = a64542c7a6219b6faa96704b240823476af80766` + working tree at 2026-09-10 14:25 CEST.

```
2cc3b9d9ef48 BaseVocabulary.swift        1a130374ce5e LanguageMemoryModels.swift
e834c3260b23 DictionaryEntry.swift       60a647e2ad20 LanguageMemoryPostProcessor.swift
ad2bd185194a DictionaryStore.swift       ed040ed46be5 LanguageMemoryStore.swift
57282c77c50a TermMatcher.swift           a5c29bd2dbc8 MemoryBiasBuilder.swift
1e29caf3b520 CorrectionLearner.swift     1c3a224eb11f MemorySuggestionEngine.swift
ecf1ba0f1363 DictionaryCorrector.swift   664d19675636 ReplacementEngine.swift
670ee962d81b LanguageMemoryCSV.swift    63e61cd9d343 SnippetExpansionEngine.swift
5bafdb167b07 LanguageMemoryLearningPolicy.swift
bd8effff4025 LanguageMemoryMatcher.swift 1d4a330c043b DictationHistory.swift
c0579e3af8ed LanguageMemoryMigrator.swift 847f1d2c328c DictationRecord.swift
ac2ef151474c HistoryReprocessor.swift    51758389368b FormattingContext.swift
0a9e84e0b3ef Snippet.swift               4885341f4d1f SnippetStore.swift
4b43e16964da KeytermBudget.swift (new, untracked)
2272cafa337f UsefulVoiceViewModel.swift  7d67812cfc36 AppDelegate.swift
                                          (re-hashed 14:30: f1586ddde8a5 — edited again after this report)
5cea4fe6d4d6 LanguageMemoryViewModel.swift aa8ecdb82a61 LanguageMemoryPage.swift
```

## Concurrent work already in the tree (do not re-fix)

* Regex compile failure → trapped `try!` (crash risk) **fixed**:
  `LanguageMemoryMatcher.wordBoundaryRegex` now returns `NSRegularExpression?` with a 200-character
  phrase cap; `ReplacementEngine` and `SnippetExpansionEngine` `continue` on `nil`. Residual issues
  are MEM-04 (still no cache) and MEM-18 (silent drops).
* Deepgram 500-token keyterm ceiling **now enforced** by the new `KeytermBudget` +
  `MemoryBiasBuilder.biasSelection` (safety margin 100, `maxTerms = 100`, per-term 64-char cap).
  Residual issue is MEM-18 (non-Latin undercount, `boundedSelection` not wired in).
* Unrelated to this scope: `AppDelegate` keychain priming, `RecordingStore.make` fallback instead of
  `fatalError`, `HotkeyManager`, `SettingsPage`, `AudioRecorder`.
