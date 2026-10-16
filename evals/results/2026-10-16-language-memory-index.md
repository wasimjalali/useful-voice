# Language Memory index

Date: 2026-10-16. Branch: `perf/language-memory-index`. PR: #55.

## Question

The September audit measured the macOS Language Memory pass at about 3.7 s with 5,000 terms in
auto scope and deferred an indexed matcher as high risk (`docs/audit/05-performance-language-audit-2026-09-20.md`,
"Skipped per owner direction"). Can an index skip the work for rules and terms that cannot match,
with output byte-identical to the current matcher, and does Windows have the same problem?

## What ran

- **Harness** (new, in the repo): `Tests/UsefulVoiceCoreTests/LanguageMemoryBench*.swift` and
  `windows/tests/languageMemoryBench.test.ts`. Off unless `UV_LM_BENCH=1`. The September audit's
  frozen corpus was not in the repo, so both harnesses generate a deterministic stand-in with the
  audit's shape: a 15,149-character mixed English and German transcript, 1,000 or 5,000 terms
  (a third English, a third German, a third language-neutral; 0 to 2 aliases, sometimes a
  pronunciation), 50 explicit replacement rules, 20 snippets. About 8% of the terms reuse phrases
  cut from the transcript, so about 360 rules fire at 5,000 terms. Auto scope and detected `de`.
- **Before**: the code on `main` at `bb754d9`, run through the same harness (the harness only
  uses the public entry point, so it compiles against both). Each Swift row also times the
  old matcher kept in `Tests/UsefulVoiceCoreTests/LanguageMemoryLegacyOracle.swift` (`legacy`).
- **After**: this branch.
- **Platforms**
  - Linux: x86_64, 4 vCPU shared with other jobs, Swift 6.1.2 release
    (`swift test -c release -Xswiftc -enable-testing`), swift-corelibs-foundation.
  - macOS: GitHub `macos-15` (arm64), Swift 6.1.2 release, system ICU. Run 38898778290.
  - Windows core: Node 22.22 on Linux, `vitest`. Node 22 is V8 12.4, ICU 77, Unicode 16. The app
    ships Electron 43.7.0 (V8 15.0, ICU 78, Unicode 17), so every Windows number and the exhaustive
    check below were measured on Node's engine, not Electron's. The review re-ran the exhaustive
    fold check and a 5,000-case differential under Electron 43's runtime: 0 failures.
- Commands: `UV_LM_BENCH=1 UV_LM_BENCH_RUNS=5 swift test -c release -Xswiftc -enable-testing --filter LanguageMemoryBenchTests`
  and `UV_LM_BENCH=1 npx vitest run tests/languageMemoryBench.test.ts` (add `UV_LM_BENCH_SIDE=legacy` for the old code).
- Raw output: `evals/results/raw/2026-10-16-language-memory-index-*`.
- Cost: none (no model or API calls).

## Numbers

Milliseconds for one `applyDeterministic` / `applyMemory` call, median unless noted. The machine was
shared, so `min` is in the raw files too; the conclusions do not depend on the noise.

### macOS (macos-15 CI, release, median of 3)

| terms | scope | before (old matcher) | after | |
|---|---|---:|---:|---:|
| 1,000 | auto | 6,413 | 321 | 20x |
| 1,000 | de | 3,678 | 204 | 18x |
| 5,000 | auto | 38,078 | 1,090 | 35x |
| 5,000 | de | 25,253 | 908 | 28x |

"Before" here is the old matcher kept in the tests, which has an unbounded regex cache. The real
code on `main` has the 4,096-entry cache bound and is slower than this past it (see Linux).
The September numbers (3.7 s at 5,000 auto on a Mac) came from a different, unpublished corpus
and machine, so they are not comparable with these.

### Linux (Swift release; before = `main` at `bb754d9`, median of 3; after = median of 5)

| terms | scope | before | before, first run | after | after, min |
|---|---|---:|---:|---:|---:|
| 1,000 | auto | 2,038 | 3,811 | 395 | 290 |
| 1,000 | de | 1,154 | 1,313 | 205 | 180 |
| 5,000 | auto | 35,155 | 36,536 | 1,557 | 1,393 |
| 5,000 | de | 23,352 | 23,352 | 834 | 768 |

At 5,000 terms the real code on `main` is 3x slower than the oracle (35 s against 11 s) because
past 4,096 rules the regex cache stops helping and every rule recompiles.

### Windows core (Node 22 on Linux; median of 5; `first` = the first call for this row)

| terms | scope | before | before, first | after | after, first |
|---|---|---:|---:|---:|---:|
| 1,000 | auto | 257 | 3,771 | 205 | 861 |
| 1,000 | de | 139 | 135 | 156 | 156 |
| 5,000 | auto | 3,183 | 17,197 | 1,260 | 3,370 |
| 5,000 | de | 2,104 | 2,104 | 748 | 709 |

The rows run one after another in one process, so `first` is the first call for that row, not
a cold start. Only the 1,000 auto row is cold (regex cache empty): 3.7 s before, 0.9 s after. The
5,000 auto `first` (17.2 s before, 3.4 s after) follows the 1,000 rows, so part of its regex cache
is already warm; a true cold start at 5,000 terms was not measured.

Windows shows the same slowdown on a cold start, so the index is mirrored there. It is not free
when everything is warm: at 1,000 terms the indexed version is slower by a few percent to about 20%
(three alternating pairs of 15-sample runs, auto scope: 222 to 246 ms before, 224 to 250 ms after,
3% to 7%; de scope 139 before, 156 after, 12% in the table above, 15% to 20% in the pairs),
because the index is built on every pass and only pays for itself when it skips many regexes.

### Equivalence (the output did not change, apart from the cache note under What changed)

- Every benchmark row carries a fingerprint of the result (text, fired rule order, term hits,
  snippets). Before and after match on all 12 rows, on three platforms:
  `cb1c7f62...`, `df8d4302...`, `45ce5124...`, `e030a59b...` (macOS and Linux Swift, old and new);
  `2c2c1ae7...`, `93e35b52...`, `8c235675...`, `9d17d6fd...` (Windows core, old and new).
- Differential tests, old matcher as the oracle, 0 differences:
  - Swift: 5,000 random scenarios per test, three tests (rule application at three index
    settings, term matching at three settings over four texts each, the full pass), plus the
    index-never-rejects property, plus incremental-update equality. 14 tests passed
    (`...-swift-differential-5000.log`). The 5,000-scenario run was on Linux
    (swift-corelibs-foundation), not macOS. The same differential tests also run on the macOS
    runner (macos-15, system ICU) on every push, as part of `make test`, at 250 scenarios per test.
  - Windows: 3,000 scenarios per test, same shape. 6 tests passed (`...-windows-differential-3000.log`).
    CI runs 150 per test.
  - Scenarios mix: ASCII, German (`ß`, umlauts, NFC and NFD), Cyrillic, Greek (final sigma),
    Turkish `İ`/`ı`, Kelvin sign, `ſ`, `ẞ`, ligatures, CJK, emoji and ZWJ, regex metacharacters,
    odd spaces, case changes, overlapping terms, long and empty phrases, disabled rules, three match
    modes, language scopes, snippets, replacements containing `$0 \1 $&`.
  - Exhaustive: for every Unicode scalar that changes under case mapping, and every ASCII
    one- and two-letter phrase, whatever the real case-insensitive regex matches the index also
    accepts (Swift against the macOS ICU in CI, Windows against V8).
- The formatting eval (`evals/formatting/run_eval.py`) needs a Deepgram key and macOS `say`, so it
  was not run, and cannot change: it sends audio to Deepgram and never reaches Language Memory.
  The deterministic half of it, `TranscriptStyleEvalTests` (80 of 83 on the recorded transcripts),
  runs in `swift test` and passed unchanged in CI.

## What changed

- `LanguageMemoryTextIndex.swift` (Swift) and `src/core/memory/textIndex.ts` (Windows): the index.
  A phrase and the text are reduced to a case skeleton (full upper then lower mapping per scalar,
  to a fixed point). A phrase that is not a substring of the text's skeleton cannot match, and
  neither can one flanked by an ASCII letter, digit or underscore. Everything the index lets
  through still runs the old regex, so it can only skip work the regex would not have changed anything with.
- Used in `ReplacementEngine`, `LanguageMemoryMatcher.matchingTermIDs` (Swift) and `RuleSet`,
  `matchingTermIds` (Windows). Below 16 rules or candidates the old path runs unchanged.
- The regex cache is keyed on the phrase's UTF-8 bytes. `String` keys treat NFC and NFD
  spellings as one key, so which regex a phrase got depended on which spelling was looked up first
  in the process (found by the differential test). It is also a class now, so its overflow test
  runs on a private instance rather than the process-wide one the new tests fill.

### Behaviour change: NFC and NFD phrases no longer share a regex

Before: `[String: NSRegularExpression]` treated a phrase's NFC and NFD spellings (`café` as one
scalar or as `e` plus a combining acute) as the same key, so whichever spelling reached the cache
first in the process decided the regex both spellings used. ICU matches code points, so the two
regexes are not the same: the NFC one does not match NFD text and the reverse. The result for a
given phrase could therefore depend on what was dictated earlier.

Now: each spelling gets its own regex, so a phrase matches what its own code points match, whatever
ran before. That is the deterministic behaviour, and it is what the old matcher does on a fresh process
for either spelling. Output is therefore not strictly byte-identical to the old code for a dictionary
that holds both spellings of one phrase and a process that looked the other one up first. Nothing in the
differential run needs the old order-dependent result (the oracle compiles by bytes too). This is a
call for the owner to confirm; reverting it is one line (key the cache on the `String`) but brings back
the order dependence.

## Conclusion

The speedup depends on the size. On macOS CI it is 18x to 20x at 1,000 terms and 28x to 35x at
5,000. On Linux it is about 5x at 1,000 terms and 22x to 28x at 5,000 (about 25x holds only at 5,000).
Output is identical, apart from the NFC and NFD cache change above.

Windows is a mixed result and should be read that way. The first dictation after launch drops from
3.7 s to 0.9 s at 1,000 terms, and the 5,000 auto first call from 17.2 s to 3.4 s. But warm
1,000-term dictations are about 20 ms slower than before (de scope 15% to 20%, auto 3% to 7%), since
the index is built on every pass. At 5,000 terms warm runs are 2.5x to 2.8x faster. What is left at 5,000
terms (about 1 s) is the regex replace for the roughly 360 rules that really fire, the rule
sort, and regex compilation; none of that is something an index removes. Follow-ups, not done: replace
at the positions the index already knows instead of scanning the whole text, and cache
the sorted rules between dictations.

Residual risk: the skeleton uses Swift's (and V8's) case tables, the regex uses ICU's. If an OS
ICU pairs two letters that Swift's tables do not, the index could skip a rule the regex would have
applied. The exhaustive test checks this on the CI runner's ICU for every scalar, not on every
macOS version users run. The one case that can be closed in code is closed: on macOS a scalar that
Swift's Unicode tables leave unassigned (which a newer ICU might case-map) turns the index off for
that text, and a phrase containing one skips the index, so the regex decides. Windows has no
such guard; there the exhaustive check above, run on Node's and Electron 43's engines, is the evidence.
