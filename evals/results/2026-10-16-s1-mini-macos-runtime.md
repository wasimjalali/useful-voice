# S1-mini on macOS: runtime choice, memory and latency (2026-10-16)

## Question

Can llama.cpp run S1-mini (Qwen3-0.6B fine-tune, Q4_K_M, 462 MB) inside the app next to the
existing whisper.cpp, and does it fit the 1.5 s cleanup deadline and the memory budget of an
average Mac? Which runtime and placement (CPU or Metal) should the hidden flag use?

## What ran

- Runner: GitHub `macos-15`, Apple M1 (Virtual), 3 cores, 7,516,192,768 bytes of RAM. This is
  the weakest Mac we can measure, not a real laptop.
- llama.cpp b11669, two builds on the same runner and the same pinned weights
  (HF revision `34add00a48a2e5d24e5a4ee5405a99620a3a240c`):
  1. the official `llama.xcframework` that the app links, driven by
     `Sources/UsefulVoiceLlama/LlamaRuntime.swift` inside the `swift test` process;
  2. the official release CLI `llama-b11669-bin-macos-arm64`, `llama-bench` only, as the baseline.
- whisper.cpp v1.9.2 XCFramework in the same process (tiny.en).
- Prompt: the model card's system prompt verbatim plus a 92 to 99 token dictation, greedy,
  reasoning off, no output cap, 10 to 20 output tokens.
- Commands (CI, `.github/workflows/ci.yml`):
  - in the app's runtime, fresh process: `swift test --skip-build --filter 'LlamaWhisperCoexistenceTests/measure'`;
  - same file, second step: `swift test --skip-build --filter LlamaWhisper` (the numbers from the
    runs below also include `measure` in that step);
  - baseline: `llama-bench -m s1-mini-q4_k_m.gguf -ngl 0 -t 3 -p 100 -n 16 -r 3` (default), then
    `... -dev none -ngl 0 -t 3 -p 100 -n 16 -r 3` and `... -dev none -ngl 0 -t 1 -p 100 -n 16 -r 2`
    (CPU only).
- Harness: `Tests/UsefulVoiceAppTests/LlamaWhisperCoexistenceTests.swift` (`measure`, `probe`).
- Raw output, four CI runs, every line labelled with its run and step:
  `evals/results/raw/2026-10-16-s1-mini-macos-runtime-ci.log` (made by
  `...-extract.py`). Every range below is computed from it by `...-summarize.py`; the output is in
  `evals/results/raw/2026-10-16-s1-mini-macos-runtime-summary.txt`. Runs: 38899709145 (head
  4e1cc6b: native timers, threadpool), 38901063521 (605f07d: thread QoS, release build of the
  tests), 38902782660 (c88468b: CPU-only `llama-bench`, Metal in process), 38905410608
  (5f10093: one-context probe).
- Cost: CI minutes only.

## Numbers

Coexistence (the milestone): both frameworks load into one process, both `*_print_system_info`
answer, S1-mini completes between two whisper.cpp context loads, whisper loads afterwards. The
Swift side keeps the header sets apart (only `UsefulVoiceLlama` imports `llama`).

Memory (S1-mini Q4_K_M, 3 threads, one 512 token context; min to max over 9 measured processes,
4 for Metal):

| State | Physical footprint | Resident |
|---|---|---|
| Process baseline | 7.5 to 53.2 MB | 21.0 to 261.2 MB |
| Loaded, CPU | 422.8 to 436.6 MB | 836.5 to 966.5 MB |
| Loaded, Metal | 425.6 to 433.7 MB | 891.5 to 968.1 MB |
| After unload | 49.9 to 58.5 MB | 164.9 to 262.8 MB |

Unload returns the footprint to baseline range, so "load on the press, free after 60 s idle"
holds. The baseline spread depends on which test ran earlier in the process (whisper.cpp
loaded or not).

Latency of one cleanup in the app's own runtime (45 CPU calls, 12 Metal calls):

| Placement | Whole call | Median of 5 | Prompt decode (native timer) |
|---|---|---|---|
| CPU only, 3 threads | 6,843 to 13,953 ms | 7,495 to 11,088 ms | 5,660 to 10,758 ms |
| Metal, 3 threads | 8,882 to 10,479 ms | not computed (12 calls) | 6,247 to 7,556 ms |

One context, repeated decodes (the `probe`, no abort callback, 97 token prompt, 8 prompt
decodes and 20 single-token decodes per placement): CPU prompt decode 5,835 to 6,158 ms, CPU
single-token decode 77 to 156 ms; Metal prompt decode 6,104 to 7,173 ms, Metal single-token
decode 217 to 342 ms. Four decodes in one context cost the same each, so this is not a
once-per-context cost.

Load time of the weights: 610 to 1,699 ms in every process except the first one after a build,
where the CPU placement took 18,445 to 24,650 ms (runs 38899709145, 38901063521, 38902782660,
38905410608, step "fresh process"). The release CLI's own log shows its first start spending about
21 s compiling the Metal shader library, and the runtime registers the Metal backend even for the
CPU placement, so the slow first load is most likely the same one-time compile, cached by macOS
afterwards. That is an inference, not a measurement of its own.

Same weights, same runner, the official release CLI (`llama-bench`, tokens per second):

| Run | Mode | Threads | pp100 | tg16 (ms per token) |
|---|---|---|---|---|
| 38899709145 | default | 3 | 244.5 | 86.8 (11.5) |
| 38901063521 | default | 3 | 299.0 | 104.0 (9.6) |
| 38902782660 | default | 3 | 304.8 | 76.8 (13.0) |
| 38902782660 | CPU only (`-dev none`) | 3 | 255.7 | 78.5 (12.7) |
| 38902782660 | CPU only | 1 | 113.7 | 39.0 (25.7) |
| 38905410608 | default | 3 | 398.4 | 113.4 (8.8) |
| 38905410608 | CPU only | 3 | 361.6 | 104.8 (9.5) |
| 38905410608 | CPU only | 1 | 139.4 | 58.7 (17.0) |

By the CLI's own numbers the same CPU decodes a token in 9.5 to 12.7 ms (3 threads) and the
prompt in about 0.3 to 0.4 s, so a whole cleanup would take well under a second. In the app's
runtime the same step takes 6.8 to 14 s. Note that the CLI rows labelled CPU only still list the
`MTL,BLAS` backends in the table, so they are not a pure CPU-kernel measurement.

What was varied without changing the result, each in the raw log: no abort callback (the
`probe`), a ggml threadpool attached (`MEASURE pool`, 7,695 to 9,827 ms whole call), thread QoS
(user-interactive, user-initiated, default: 7,098 to 11,332 ms), a release build of the tests,
CPU against Metal placement, whisper.cpp loaded in the same process or not, and one context
against a new one per call.

Untested hypothesis for the gap: the XCFramework and the CLI are different builds of ggml, and
something in the XCFramework build (compiler flags, which CPU kernels are compiled in, how
BLAS and Metal are wired) makes it 6 to 15 times slower. The XCFramework's own system-info line
reports `NEON = 1 | ARM_FMA = 1 | FP16_VA = 1 | DOTPROD = 1 | ACCELERATE = 1 | REPACK = 1`, so
the obvious feature flags are present and I have not found the cause. The slow Metal path is
unexplained too. Finding it needs a build of llama.cpp from source with known flags,
compared against the XCFramework on the same runner.

## Conclusion

- Runtime: llama.cpp, official XCFramework, linked beside whisper.cpp in one process. No helper
  process needed. Default placement is the CPU: it is the only placement llama.cpp can stop in
  the middle of a decode (the deadline), and it was no slower than Metal here.
- On this runner the app's llama.cpp cannot meet the 1.5 s deadline (6.8 to 14 s per cleanup).
  With the flag on, every cleanup would time out and the user would get the rules text. That is
  the safe fallback working as designed, not a quality win. S1-mini on macOS is not usable until
  the runtime is as fast as the CLI build.
- The loss is not on the user: a cold model answers with the rules text at once and the load runs
  in the background, so no dictation waits on it.

## What changed because of it

- The pipeline, the 7 GiB rule, begin/end idle counting, the never-throw entry point and the cold
  model rule shipped behind `UV_CLEANUP_MODEL=1`, off by default.
- Follow-up (needs Wasim's call, not done here): build llama.cpp ourselves for macOS arm64 with
  known flags, compare it with the XCFramework on the same runner, host the result as a pinned
  release asset if it is fast, and re-run the rows above. Alternative: bundle the release CLI's
  dylibs. Either needs a CI job and a hosted artifact, so it is a separate change.
