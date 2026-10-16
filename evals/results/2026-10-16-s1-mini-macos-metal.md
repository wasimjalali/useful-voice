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
  (`kern.hv_vmm_present` 0). Other agents were building on it. Load average 7.6 before run 1,
  then 6.0 to 6.6 (run 2) and 6.6 to 5.1 (run 3).
- Code: branch `claude/awesome-blackwell-369fb1` on `3725095`, debug build of the tests,
  llama.cpp b11669 XCFramework, whisper.cpp v1.9.2 XCFramework.
- Weights, SHA-256 checked against the pins in `.github/workflows/ci.yml`:
  `s1-mini-q4_k_m.gguf` `3b41ebe2...003c634` and `ggml-tiny.en.bin` `921e4cf8...b1f`.
- Harness: `Tests/UsefulVoiceAppTests/LlamaWhisperCoexistenceTests.swift`. `measure` now runs
  the five dictations on both placements, prints the placement the app picks, and adds a Metal
  abort check (a prompt of 888 tokens, deadline at a quarter of its time to the first token).
  `aPassedDeadlineStopsTheRun` runs on the CPU and on the app's placement.
- Commands, from the repo root, `<scratch>` holding the two files:
  - `UV_S1_MINI_PATH=<scratch>/uv-models/s1-mini-q4_k_m.gguf UV_WHISPER_TINY_PATH=<scratch>/uv-models/ggml-tiny.en.bin swift test --skip-build --filter 'LlamaWhisperCoexistenceTests/measure'`,
    three times. Run 1's abort check failed with `output truncated` (a repeated sentence made the
    model loop), so the check's prompt was changed to numbered items and runs 2 and 3 used that.
  - The same variables with `swift test --skip-build --filter LlamaWhisper --skip 'LlamaWhisperCoexistenceTests/measure'`:
    7 tests, 8 cases, all passed.
- Raw logs (paths replaced by `<scratch>`, `<repo>` and `~`, nothing else edited):
  `raw/2026-10-16-s1-mini-macos-metal-measure-run{1,2,3}.log` and
  `raw/2026-10-16-s1-mini-macos-metal-coexistence.log`.
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

Metal is 19 to 27 times faster and stays under 210 ms on every call, against a 1.5 s deadline.
The CPU missed the deadline on all 15 calls. The two placements gave the same text for all five
dictations in all three runs. A warm Metal call on the model card's example took 121 to 132 ms
(three repeats per run).

Where Metal's time goes (llama.cpp's own timers): about 40 to 85 ms for the prompt, 6 ms per
generated token after the first. On the CPU the prompt alone takes 2.2 to 4.1 s, so the
generated tokens (34 to 35 ms each) are not the problem.

Memory, physical footprint of the whole test process: CPU loaded about 520 MB; Metal loaded 89
to 94 MB, 138 to 143 MB after five runs (resident 615 to 667 MB: the weights are mapped, and
Metal's share is not in the footprint). After unload the footprint was 79 to 105 MB following
the CPU section and 180 to 185 MB following the Metal one. The Metal section also loaded
whisper.cpp on Metal in between, so this run does not say how much of that extra 100 MB is
llama.cpp's Metal state and how much is whisper.cpp's. Not attributed.

The deadline on Metal, measured (runs 2 and 3): an 888 token prompt reaches its first token
after 354 ms. With the deadline at 88 ms the run threw `deadlineExceeded` after 399 and 402 ms,
not near 88 ms. So llama.cpp does not stop a Metal run inside the prompt; the check lands at the
next token. (On Metal `llama_decode` returns in about 1 ms and the wait happens in sampling,
which is why the runtime's own "prompt decode" figure reads 1.2 ms there.) The 5 ms deadline
test passes on both placements, stopping after about 16 ms, because a dictation-length prompt is
short.

What that means for the app: the dictation never waits past 1.5 s either way
(`CleanupPipeline.withDeadline` returns at the deadline and drops a late answer). The worst
overrun is the model thread finishing one prompt decode, about 350 ms at 900 tokens, under
1 s at the 1,536 token cap by extrapolation. A quit waits up to 2 s for that thread, so it is
covered. The stop-signal test stays on the CPU, where it proves the mid-decode abort.

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
