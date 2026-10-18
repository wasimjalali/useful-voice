# S1-mini on macOS: the same runtime on a real Apple M4 (2026-10-16)

Follow-up: the app now uses Metal on real Apple-silicon Macs, CPU elsewhere (`2026-10-16-s1-mini-macos-metal.md`), and the cleanup eval was re-run through it (`2026-10-16-cleanup-macos-m4-app.md`).

## Question

The CI runner for the macOS runtime measurements is a virtual M1 with 3 cores
(`2026-10-16-s1-mini-macos-runtime.md`). It showed 6.8 to 14 s per cleanup on the CPU and no
gain from Metal. Is that the runtime, or the runner? How does the same code behave on a real
Apple-silicon laptop?

## What ran

- Machine: the owner's Mac, Apple M4, 10 cores, 16 GB (17,179,869,184 bytes), macOS 27.0.1,
  2026-10-16. Other agents were building on it: load average about 4.8 during run 1 and about
  2.5 during run 2 (noted when the runs were made, not in the logs).
- Code: the PR #54 branch (`feat/s1-mini-hidden-mac`) at `597cd52`, debug build of the tests,
  llama.cpp b11669 XCFramework, whisper.cpp v1.9.2 XCFramework, the same harness as the CI runs
  (`Tests/UsefulVoiceAppTests/LlamaWhisperCoexistenceTests.swift`: `measure`, `probe`).
- Weights, SHA-256 checked against the pins in `.github/workflows/ci.yml`:
  - `s1-mini-q4_k_m.gguf`, 484,219,808 B, `3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634`
    (`superwhisper/s1-mini-GGUF` at `34add00a48a2e5d24e5a4ee5405a99620a3a240c`)
  - `ggml-tiny.en.bin`, 77,704,715 B, `921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f`
- Commands, from the repo root, with `<scratch>` holding the two files:
  - `UV_S1_MINI_PATH=<scratch>/uv-models/s1-mini-q4_k_m.gguf UV_WHISPER_TINY_PATH=<scratch>/uv-models/ggml-tiny.en.bin swift test --skip-build --filter 'LlamaWhisperCoexistenceTests/measure'`
    run twice (run 1 straight after a build, run 2 right after it);
  - the same variables with `swift test --skip-build --filter LlamaWhisper --skip 'LlamaWhisperCoexistenceTests/measure'`
    for the coexistence checks (7 tests, all passed).
- Prompt: the model card's system prompt plus five dictations of 92 to 99 tokens, greedy, 10 to
  20 output tokens, 3 measured runs on Metal after the CPU ones.
- Raw output, paths replaced by `~` and `<scratch>`, nothing else edited:
  `evals/results/raw/2026-10-16-s1-mini-macos-m4-local-run1.log`, `...-run2.log`,
  `...-coexistence.log`.
- Cost: none.

## Numbers

Latency of one cleanup in the app's own runtime, CPU only (the default placement, 4 threads on
this machine):

| | Weights load | Whole call, 5 dictations | Median | Max |
|---|---|---|---|---|
| Run 1 (load about 4.8) | 4,843 ms (first load after a build) | 2,710 to 3,300 ms | 3,037 ms | 3,300 ms |
| Run 2 (load about 2.5) | 581 ms | 2,612 to 2,996 ms | 2,760 ms | 2,996 ms |

The prompt decode is 2.1 to 2.9 s of each call (native prompt timer). The 1.5 s deadline is
missed on every call, by about 2x.

Metal placement (3 runs per process, one short dictation):

| | Weights load | Whole call | Native prompt | Native generate |
|---|---|---|---|---|
| Run 1 | 118 ms | 120 to 123 ms | 45 ms | 58 ms |
| Run 2 | 119 ms | 134 to 140 ms | 49 to 50 ms | 65 to 67 ms |

Probes (one context, repeated decodes, 97 token prompt, no abort callback):

| | Prompt decode | Single-token decode |
|---|---|---|
| CPU, run 1 | 2,271 to 2,970 ms | 34 ms |
| CPU, run 2 | 2,261 to 2,269 ms | 34 to 37 ms |
| Metal, run 1 | 236 ms (first), then 44 to 49 ms | 76 ms (first), then 6 ms |
| Metal, run 2 | 4 ms (first), then 49 to 64 ms | 49 ms (first), then 6 to 7 ms |

Memory (physical footprint, the whole test process): about 508 to 512 MB with the CPU
placement loaded (resident about 866 MB), 119 MB after unload, 8 MB before anything loaded;
about 141 MB with Metal loaded (resident about 650 to 670 MB).

Coexistence on this machine: all 7 tests passed in 22.1 s, including whisper.cpp transcribing a
synthesized clip after S1-mini ran in the same process ("Hello, this is a test of local
dictation on this Mac."), and the 5 ms deadline stopping a run after 16 ms. The `failed to
load Core ML model` lines in the logs are whisper.cpp looking for an optional Core ML encoder
next to the tiny model; the transcription test passed regardless.

## Conclusion

On real Apple-silicon hardware the CPU path still misses the 1.5 s deadline, by about 2x
(2.6 to 3.3 s). Metal is about 20x faster (a whole call in about 120 to 140 ms) and well inside
the deadline. The CI runner's virtual Mac GPU is why the first write-up measured Metal as no
faster: that was the runner, not the runtime. The first write-up's CPU gap to the CLI is not
explained by this run, only reduced: a real M4 does the CPU path in about 3 s where the
virtual M1 needed 7 to 14 s.

Quality is unchanged by this. The cleanup eval's recommendation stands (rules only, S1-mini
stays behind the hidden flag; `2026-10-16-cleanup.md`).

## What changed because of it

- Nothing in the shipped default: the flag stays off.
- Recommended follow-up (needs Wasim's call): make Metal the placement on real hardware,
  with the CPU path as the fallback when no GPU is usable. The catch the first write-up gave
  for the CPU default (only the CPU can abort a decode mid-run) has to be re-checked for
  Metal, since a 130 ms call may not need the abort at all but a stuck GPU decode would. Then
  re-run the cleanup eval on the Metal output before anyone turns the flag on.
