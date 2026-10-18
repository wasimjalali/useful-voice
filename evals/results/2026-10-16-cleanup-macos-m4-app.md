# S1-mini cleanup quality on macOS, answering inside the deadline (2026-10-16)

## Question

The cleanup eval (`2026-10-16-cleanup.md`) found that rules + S1-mini + guard lost spoken words
where rules-only lost none, so S1-mini stayed behind a hidden flag. On macOS that result was
moot: on the CPU the model never answered inside the 1.5 s deadline. With the app now on Metal
(`2026-10-16-s1-mini-macos-metal.md`), it answers in about 150 ms. So does the model, run by the
app itself and inside the deadline, pass the decision rule now? Should S1-mini stay on macOS?

The decision rule is the one fixed before the eval's round 2: ship the model only if rules +
S1-mini + guard loses no more spoken words than rules-only on both the in-sample and the
held-out set.

## Answer

**No. It fails the rule on both sets, for the same reasons as before. Keep S1-mini behind the
hidden flag, off. Don't ship it on macOS.**

| Set | Rules only: words lost | Rules + S1-mini + guard (app, Metal): words lost | Rule met? |
|---|---|---|---|
| In-sample, 188 cases | 0 | 3 (in 3 cases, all clean texts) | No |
| Held-out, 73 cases | 0 | 1 (in 1 case, a clean text) | No |

Speed is no longer the problem. Every one of the 261 cases got its answer inside the deadline:
no timeouts, no failures, 336 ms at the slowest.

## What ran

- The app's own path, not `llama-server`: a new opt-in test,
  `Tests/UsefulVoiceAppTests/CleanupEvalRunTests.swift`, feeds every case through
  `CleanupPipeline.run` with the real S1-mini in `LocalCleanupModel` and `LlamaCleanupGenerator`
  (Metal, the placement the app picks on this Mac), the Swift `CleanupRules`, `CleanupControlLine`
  and `CleanupGuard`, and the default 1.5 s deadline. The control line comes from each case's app
  category, with no user style, as in the eval. `begin()` and `end()` wrap each case, as a
  dictation does. Three unscored warm-up runs first, as `run_eval.py` does. It writes a raw file
  in `run_eval.py`'s format, so `--rescore` scores it with the eval's metric and the shipped
  TypeScript guard.
- Machine: the owner's Apple M4, 16 GB, macOS 27.0.1 (`raw/2026-10-16-s1-mini-macos-metal-machine.txt`),
  load average 3.3 to 3.8 during the runs (other agents were building).
- Code: branch `claude/awesome-blackwell-369fb1` on `3725095` plus this PR's placement change
  and harness, before review round 1. Round 1 then changed the harness only in branches no case
  reached here (a timeout, a skipped model, rules that left nothing), so the runs were not
  repeated. llama.cpp b11669 XCFramework.
- Weights: `s1-mini-q4_k_m.gguf`, SHA-256 `3b41ebe2...003c634` (hashed on this Mac, in the
  machine file above), the eval's file and CI's pin.
- Cases: `evals/cleanup/cases.json` (188, in-sample) and `evals/cleanup/heldout.json` (73, held
  out, still never tuned on).
- Commands, from the repo root:
  - `UV_S1_MINI_PATH=<gguf> UV_CLEANUP_EVAL_CASES=evals/cleanup/cases.json UV_CLEANUP_EVAL_OUT=$PWD/evals/results/raw/2026-10-16-cleanup-macos-m4-app-insample.json swift test --skip-build --filter CleanupEvalRunTests`
  - the same with `heldout.json` and `...-app-heldout.json`
  - `python3 evals/cleanup/run_eval.py --work <scratch> --rescore evals/results/raw/2026-10-16-cleanup-macos-m4-app-insample.json --out evals/results/raw/2026-10-16-cleanup-macos-m4-app-insample-scored.json`, and the same for held-out
  - `python3 evals/results/raw/2026-10-16-cleanup-macos-m4-app-compare.py` (cross-checks below)
- Cost: none. The two runs took 29 s and 14 s.

## Numbers

Same metric and definitions as the eval. The app rows are the app's final text (the Swift
guard's verdict), which matched `run_eval.py`'s TypeScript guard on every case.

In-sample (188 cases: 88 clean, 100 need an edit):

| Variant | Restraint | Edit accuracy | Words lost (lost cases) | Words added | Guard reject |
|---|---|---|---|---|---|
| Rules only | 100.0% | 48.0% | 0 (0.0%) | 0 | |
| Rules + S1-mini, no guard (app run) | 73.9% | 93.0% | 9 (4.3%) | 9 | |
| **Rules + S1-mini + guard (app, Metal)** | **93.2%** | **90.0%** | **3 (1.6%)** | 1 | 70.2% |
| Rules + S1-mini + guard (round 4, Linux llama-server) | 92.0% | 89.0% | 4 (2.1%) | 1 | 69.7% |

Held-out (73 cases: 38 clean, 35 need an edit):

| Variant | Restraint | Edit accuracy | Words lost (lost cases) | Words added | Guard reject |
|---|---|---|---|---|---|
| Rules only | 100.0% | 31.4% | 0 (0.0%) | 0 | |
| Rules + S1-mini, no guard (app run) | 86.8% | 85.7% | 1 (1.4%) | 0 | |
| **Rules + S1-mini + guard (app, Metal)** | **94.7%** | **77.1%** | **1 (1.4%)** | 0 | 69.9% |
| Rules + S1-mini + guard (round 4, Linux llama-server) | 92.1% | 77.1% | 4 (2.7%) | 1 | 68.5% |

Latency of the whole pipeline call (rules, control line, model, guard), warm model:

| Set | Median | p95 | Max | Over 1.5 s |
|---|---|---|---|---|
| In-sample | 139 ms | 249 ms | 307 ms | 0 |
| Held-out | 183 ms | 275 ms | 336 ms | 0 |

What the pipeline did with the model's answers. In-sample: 56 accepted, 125 rejected as the
input's own words (format-only, so the rules text carries the same words), 4 dropped content,
2 dropped a negation, 1 changed a number. Held-out: 22 accepted, 49 the input's own words, 1
negation, 1 changed number.

## Where the words went

All four are clean texts the guard let through, and all four were already on the eval's list:

- k08: "It was, like, really cold outside, you know?" became "It was really cold outside, you know?"
- k10: "She had had enough of the noise." became "She had enough of the noise."
- k24: "lol ok" became "Lol, okay." (the metric counts "ok" to "okay" as one lost, one added)
- h34 (held-out): "The word um shows up a lot in transcripts." lost "um", the word being talked about.

Without k24, which is arguably a spelling change, the in-sample set still fails the rule.

## Cross-checks

- The Swift rules gave the same text as the TypeScript rules the eval scores, on all 261 cases.
- The Swift pipeline's final text equals `run_eval.py`'s rules + S1-mini + guard final on all
  261 cases, so the Swift and TypeScript guards agree here.
- The app's raw answers are identical to round 4's Linux `llama-server` answers on 184 of 188
  in-sample and 72 of 73 held-out cases. Of the five that differ, two removed a loss the Linux
  run had: k09 ("that that" kept, so the guard rejected it as format-only) and h30 ("3 to 2" kept,
  as the macOS CI runner's run 13 did, per `2026-10-16-cleanup.md`). The other three are format choices ("twelfth" against "12th", one
  comma) and g11, which the guard rejected either way.

So Metal changed the speed, not the model's behaviour, and the eval's llama-server numbers were
a fair stand-in for the app.

## Conclusion

- **Recommendation: keep S1-mini on macOS behind the hidden flag, off, and don't ship it.** It
  fails the decision rule on both sets. Its gain is real (edit accuracy 90.0% against 48.0%
  in-sample and 77.1% against 31.4% held-out; in-sample, self-corrections go from 0% to 95.8%,
  spoken numbers and formats from 0% to 78.6%, and file mentions from 33.3% to 100%, per the
  `by_group` scores in the scored files), but
  it still silently drops words from text that needed no edit, which is the worst thing a
  dictation app can do.
- Why keep rather than drop: what blocks it now is the guard, not the model's speed or the
  runtime. All four losses are the guard's known function-word and mentioned-filler blind spot
  (`2026-10-16-cleanup.md`, known gap 1). This harness re-runs the whole eval through the app in
  under a minute, so a guard fix can be judged quickly.
- The cost of keeping it: llama.framework adds about 24 MB (uncompressed, universal; 24,726,256
  bytes of binary, in the machine file above) to every macOS download, for a feature no user can turn on. If the guard fix is not planned before 1.0,
  drop S1-mini on macOS and the framework with it.
- Before anyone turns the flag on: fix the guard's function-word blind spot, write a fresh
  held-out set first (h34 came from this one, so tuning on it is out), then re-run
  `CleanupEvalRunTests` on both sets.

## What changed because of it

- Nothing in the shipped default: the flag stays off.
- New opt-in harness `CleanupEvalRunTests` runs the eval's cases through the app's own pipeline
  and writes `run_eval.py`-format raw files (`evals/cleanup/README.md`).

## Raw files

All in `evals/results/raw/`, prefix `2026-10-16-cleanup-macos-m4-app-`:

- `insample.json`, `heldout.json`: the app's run as written by the test (every answer, outcome,
  latency, the app's final text and source).
- `insample-scored.json`, `heldout-scored.json`: the same with `run_eval.py --rescore`'s scores
  and finals; `insample-rescore.log`, `heldout-rescore.log`: its printed report.
- `insample.log`, `heldout.log`: the test output.
- `compare.py`, `compare.txt`: the cross-checks and the per-case losses above.

Paths in the logs are replaced by `<scratch>`, `<repo>` and `~`. Nothing else was edited.
