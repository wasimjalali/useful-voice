# S1-mini on macOS: runtime choice, memory and latency (2026-10-16)

## Question

Can llama.cpp run S1-mini (Qwen3-0.6B fine-tune, Q4_K_M, 462 MB) inside the app next to the
existing whisper.cpp, and does it fit the 1.5 s cleanup deadline and the memory budget of an
average Mac? Which runtime and placement (CPU or Metal) should the hidden flag use?

## What ran

- Runner: GitHub `macos-15`, Apple M1 (Virtual), 3 cores, 7 GiB RAM, paravirtual Metal GPU.
  These are the weakest Macs we can measure, not a real laptop.
- llama.cpp b11669, two builds on the same runner and the same pinned weights
  (HF revision `34add00a48a2e5d24e5a4ee5405a99620a3a240c`):
  1. the official `llama.xcframework` that the app links (`Package.swift` binary target), driven
     by `Sources/UsefulVoiceLlama/LlamaRuntime.swift` in the `swift test` process;
  2. the official release CLI (`llama-b11669-bin-macos-arm64`), `llama-bench` only, as the baseline.
- whisper.cpp v1.9.2 XCFramework in the same process (tiny.en loaded before, between and after).
- Prompt: the model card's system prompt verbatim plus a ~97 token dictation, greedy, reasoning
  off, no output cap. Harness: `Tests/UsefulVoiceAppTests/LlamaWhisperCoexistenceTests.swift`
  (`measure`, `probe`), `.github/workflows/ci.yml`. Raw output:
  `evals/results/raw/2026-10-16-s1-mini-macos-runtime-ci.log` (four CI runs, quoted below).
- Cost: CI minutes only.

## Numbers

Coexistence (the milestone): both frameworks load into one process, both `*_print_system_info`
answer, S1-mini completes between two whisper.cpp context loads, whisper loads afterwards. The
Swift side keeps the header sets apart (only `UsefulVoiceLlama` imports `llama`).

Memory (S1-mini Q4_K_M, 3 threads, one dictation context of 512 tokens):

| State | Physical footprint | Resident |
|---|---|---|
| Process baseline | 8 to 50 MB | 25 to 255 MB |
| Loaded (CPU) | 422 to 440 MB | 845 to 963 MB |
| After unload | 50 to 53 MB | 173 to 260 MB |

Unload returns the footprint to baseline, so "load on the press, free after 60 s idle" holds.

Latency of one cleanup (97 token prompt, 10 to 20 output tokens), in the app's own runtime:

| Placement | Median | Prompt decode | Single-token decode |
|---|---|---|---|
| CPU only, 3 threads | 8.2 to 9.9 s | 5.9 to 8.3 s | 78 ms |
| Metal, 3 threads | 9.5 to 10.5 s | 6.2 to 7.5 s | 235 to 340 ms |

Same weights, same runner, official release CLI (`llama-bench`, 3 threads, tokens per second):

| Mode | pp100 | tg16 |
|---|---|---|
| default (GPU used) | 244 to 399 | 77 to 104 |
| CPU only (`-dev none`) | 256 | 78.5 (13 ms per token) |
| CPU only, 1 thread | 114 | 39 |

So the same CPU, with the CLI build, decodes a token in 13 ms and the 97 token prompt in about
0.4 s: a whole cleanup in well under a second. Inside the app's runtime it takes 8 to 10 s.

What was ruled out, each by a CI run (raw log): the abort callback (the `probe` has none and is as
slow), a ggml threadpool, thread QoS (user-interactive, user-initiated, default), a release build of
the tests, micro-batch size and BLAS routing, Metal versus CPU placement, whisper.cpp loaded in the
process, and a cost paid once per context (4 decodes in one context cost the same each).

Likely cause: the xcframework's ggml CPU kernels. Its `ggml_vec_dot_q4_K_q8_K` contains no `sdot`
instructions (it is the generic NEON path of `smull` and `smlal`), so the build does not use the
Apple Silicon dot-product kernels or the repacked GEMM that the CLI build uses. Metal also slows
down here, which the CPU build flags do not explain; that part is unresolved.

## Conclusion

- Runtime: llama.cpp, official XCFramework, linked beside whisper.cpp in one process. No helper
  process needed. Default placement is the CPU, because it is the only one llama.cpp can stop in
  the middle of a decode (the deadline), it needs no first-use Metal shader compile (about 23 s on
  this VM, once) and it was not slower than Metal here.
- On this runner the app's llama.cpp cannot meet the 1.5 s deadline (8 to 10 s). With the flag
  on, every cleanup would time out and the user would get the rules text. That is the safe
  fallback working as designed, not a quality win. S1-mini on macOS is not usable until the
  runtime is as fast as the CLI build.
- The loss is not on the user: a cold model answers with the rules text at once and the load runs
  in the background, so no dictation waits on it.

## What changed because of it

- The pipeline, the 7 GiB rule, begin/end idle counting, the never-throw entry point and the cold
  model rule shipped behind `UV_CLEANUP_MODEL=1`, off by default (README untouched).
- Follow-up (needs Wasim's call, not done here): build llama.cpp ourselves for macOS arm64 with the
  dot-product CPU kernels (and BLAS device) enabled, host the XCFramework as a pinned release asset,
  and re-run `measure` and the `llama-bench` rows above. Alternative: bundle the release CLI's
  dylibs. Either needs a CI job and a hosted artifact, so it is a separate change.
