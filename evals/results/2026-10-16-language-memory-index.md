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
  - Windows core: Node 22.22 (V8, the engine inside Electron) on Linux, `vitest`.
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

### Windows core (Node 22 on Linux; median of 5; `first` = the first call in the process)

| terms | scope | before | before, first | after | after, first |
|---|---|---:|---:|---:|---:|
| 1,000 | auto | 257 | 3,771 | 205 | 861 |
| 1,000 | de | 139 | 135 | 156 | 156 |
| 5,000 | auto | 3,183 | 17,197 | 1,260 | 3,370 |
| 5,000 | de | 2,104 | 2,104 | 748 | 709 |

Windows shows the same slowdown (the first dictation after launch spends 17 s at 5,000 terms),
so the index is mirrored there. At 1,000 terms with warm regexes the two are within noise of
each other (alternating runs, 15 samples: 211 to 245 ms before, 223 to 250 ms after for auto).

### Equivalence (the output did not change)

- Every benchmark row carries a fingerprint of the result (text, fired rule order, term hits,
  snippets). Before and after match on all 12 rows, on three platforms:
  `cb1c7f62...`, `df8d4302...`, `45ce5124...`, `e030a59b...` (macOS and Linux Swift, old and new);
  `2c2c1ae7...`, `93e35b52...`, `8c235675...`, `9d17d6fd...` (Windows core, old and new).
- Differential tests, old matcher as the oracle, 0 differences:
  - Swift: 5,000 random scenarios per test, three tests (rule application at three index
    settings, term matching at three settings over four texts each, the full pass), plus the
    index-never-rejects property, plus incremental-update equality. 14 tests passed
    (`...-swift-differential-5000.log`). CI runs 600 scenarios per test on every push.
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

## Conclusion

The indexed matcher gives 18x to 35x on macOS CI and about 25x on Linux, output identical, and
cuts the Windows first-dictation cost from 17 s to 3.4 s at 5,000 terms. What is left at 5,000
terms (about 1 s) is the regex replace for the roughly 360 rules that really fire, the rule
sort, and regex compilation; none of that is something an index removes. Follow-ups, not done: replace
at the positions the index already knows instead of scanning the whole text, and cache
the sorted rules between dictations.

Residual risk: the skeleton uses Swift's (and V8's) case tables, the regex uses ICU's. If an OS
ICU pairs two letters that Swift's tables do not, the index could skip a rule the regex would have
applied. The exhaustive test checks this on the CI runner's ICU for every scalar, not on every
macOS version users run.
