# S1-mini on macOS: Metal as the default placement (2026-10-16)

## Question

The hidden S1-mini cleanup (`UV_CLEANUP_MODEL=1` or `uvCleanupModel`) ran llama.cpp on the CPU
only. On the owner's M4 that took 2.6 to 3.3 s per cleanup, so every call missed the 1.5 s
deadline and the user got the rules text (`2026-10-16-s1-mini-macos-m4-local.md`). Metal took
120 to 140 ms in the same harness. The CPU was the default because CI's virtual Mac showed
Metal as no faster, and because only the CPU can stop a decode mid-run. Does switching the
app to Metal on real hardware hold up, and what does it cost?

## What changed in the code

- `LlamaRuntime.preferredPlacement()`: Metal when the Mac is Apple silicon
  (`hw.optional.arm64`), is not a virtual machine (`kern.hv_vmm_present`) and llama.cpp lists a
  GPU device. The CPU otherwise. So CI's virtual Mac keeps the CPU path it was measured on, and
  Intel Macs (never measured on Metal) stay on the CPU.
- `LlamaCleanupGenerator` uses it by default. If the weights fail to load on Metal, it logs a
  warning and loads them on the CPU.
- The flag-off path is unchanged: `HiddenCleanupModel.shared` is nil with the flag off, so no
  generator is built and `preferredPlacement()` never runs. It also never touches Metal or
  llama.cpp before the flag check.

## What ran

- Machine: the owner's Mac, Apple M4 (`Mac16,10`), 10 cores, 16 GB, macOS 27.0.1, not a VM
  (`kern.hv_vmm_present` 0), as read by sysctl into `raw/2026-10-16-s1-mini-macos-metal-machine.txt`.
  Other agents were building on it. Load average 7.6 before run 1 (read in the terminal, not
  in its log) and 6.2 after, then 6.0 to 6.6 (run 2), 6.6 to 5.1 (run 3) and 5.5 to 5.7 (run 4).
- Code: branch `claude/awesome-blackwell-369fb1` on `3725095` plus this PR's placement and
  harness changes; run 4 and the second coexistence run used the PR's code after round 1 of
  review (the near-cap abort probe and the quit log). Debug build of the tests, llama.cpp b11669
  XCFramework, whisper.cpp v1.9.2 XCFramework.
- Weights, SHA-256 checked against the pins in `.github/workflows/ci.yml`:
  `s1-mini-q4_k_m.gguf` `3b41ebe2...003c634` and `ggml-tiny.en.bin` `921e4cf8...b1f`.
- Harness: `Tests/UsefulVoiceAppTests/LlamaWhisperCoexistenceTests.swift`. `measure` now runs
  the five dictations on both placements, prints the placement the app picks, and adds a Metal
  abort check (a prompt of 888 tokens, deadline at a quarter of its time to the first token).
  `aPassedDeadlineStopsTheRun` runs on the CPU and on the app's placement.
- Commands, from the repo root, `<scratch>` holding the two files:
  - `UV_S1_MINI_PATH=<scratch>/uv-models/s1-mini-q4_k_m.gguf UV_WHISPER_TINY_PATH=<scratch>/uv-models/ggml-tiny.en.bin swift test --skip-build --filter 'LlamaWhisperCoexistenceTests/measure'`,
    four times. Run 1's abort check failed with `output truncated` (a repeated sentence made the
    model loop), so the check's prompt was changed to numbered items for runs 2 and 3. Run 4
    adds a second prompt near the 1,536 token cap (review round 1 asked for the worst case).
  - The same variables with `swift test --skip-build --filter LlamaWhisper --skip 'LlamaWhisperCoexistenceTests/measure'`,
    twice (before and after review round 1): 7 tests, 8 cases, all passed both times.
- Raw logs (paths replaced by `<scratch>`, `<repo>` and `~`, nothing else edited):
  `raw/2026-10-16-s1-mini-macos-metal-measure-run{1,2,3,4}.log`,
  `raw/2026-10-16-s1-mini-macos-metal-coexistence.log` and `...-coexistence-2.log`, plus the
  machine, weight hashes and framework size in `raw/2026-10-16-s1-mini-macos-metal-machine.txt`.
- Cost: none.

## Numbers

The app picks Metal here (`MEASURE preferred placement metal`, `COEXIST pipeline placement metal`).

One cleanup in the app's runtime, the five `measure` dictations (92 to 99 prompt tokens, 10 to
20 output tokens):

| Run | CPU median (max) | Metal median (max) | CPU load | Metal load |
|---|---|---|---|---|
| 1 | 4,277 ms (4,918) | 176 ms (207) | 631 ms | 149 ms |
| 2 | 4,413 ms (4,566) | 162 ms (188) | 582 ms | 128 ms |
| 3 | 2,833 ms (3,120) | 146 ms (185) | 324 ms | 119 ms |
| 4 | 3,197 ms (3,555) | 168 ms (196) | 548 ms | 147 ms |

Metal is 19 to 27 times faster and stays under 210 ms on every call, against a 1.5 s deadline.
The CPU missed the deadline on all 20 calls. The two placements gave the same text for all five
dictations in all four runs. A warm Metal call on the model card's example took 121 to 140 ms
(three repeats per run).

Where Metal's time goes (llama.cpp's own timers): about 40 to 85 ms for the prompt, 6 to 7 ms
per generated token after the first (44 to 46 ms). On the CPU the prompt alone takes 2.2 to
4.1 s, so the generated tokens (34 to 35 ms each in runs 2 and 3, 34 to 88 ms in the noisier
runs 1 and 4) are not the problem.

Memory, physical footprint of the whole test process: CPU loaded about 520 MB; Metal loaded 89
to 94 MB, 138 to 145 MB after five runs (resident 611 to 667 MB: the weights are mapped, and
Metal's share is not in the footprint). After unload the footprint was 79 to 105 MB following
the CPU section and 180 to 188 MB following the Metal one. The Metal section also loaded
whisper.cpp on Metal in between, so this run does not say how much of that extra 100 MB is
llama.cpp's Metal state and how much is whisper.cpp's. Not attributed.

The deadline on Metal, measured (runs 2 to 4): an 888 token prompt reaches its first token
after 354 to 366 ms. With the deadline at 88 to 91 ms the run threw `deadlineExceeded` after 399
to 419 ms, not near the deadline. A 1,515 token prompt, near the 1,536 cap (run 4), reaches its
first token after 645 ms; with the deadline at 161 ms it stopped after 501 ms. So on Metal the
stop does not land inside a decode the way it does on the CPU; it lands at the next token or, for
a long prompt, somewhere inside it (most likely between llama.cpp's 512 token batches; not
established). (On Metal `llama_decode` returns in about 1 ms and the wait happens in sampling,
which is why the runtime's own "prompt decode" figure reads 1.2 ms there.) The 5 ms deadline
test passes on both placements, stopping after about 16 ms, because a dictation-length prompt is
short.

What that means for the app: the dictation never waits past 1.5 s either way
(`CleanupPipeline.withDeadline` returns at the deadline and drops a late answer). The worst
overrun measured is the model thread finishing one prompt decode: about 350 ms past the
deadline at both 900 and 1,515 tokens on this M4. A quit waits up to 2 s for that thread, so it
is covered here; on a slower or busier GPU it might not be, and a quit that times out is now
logged as an error instead of passing silently. The stop-signal test stays on the CPU, where it proves the mid-decode abort.

## Conclusion

On a real Apple-silicon Mac, Metal brings the cleanup from about 3 to 4 s to about 150 ms,
well inside the deadline, with the same answers and a smaller footprint while loaded. The CPU
stays the path on virtual Macs, Intel Macs and when Metal fails to load. Speed is no longer a
reason to keep S1-mini off on macOS. Quality is the open question:
`2026-10-16-cleanup-macos-m4-app.md` answers it.

## What changed because of it

- `LlamaCleanupGenerator` now runs on Metal where `LlamaRuntime.preferredPlacement()` says so,
  with the CPU as the fallback. The hidden flag stays off by default.
- The runtime's comments now say the Metal deadline lands between tokens, not inside a decode.
- `HiddenCleanupModel.shutDown()` logs an error when a model thread is still inside llama.cpp
  after the 2 s quit wait.
