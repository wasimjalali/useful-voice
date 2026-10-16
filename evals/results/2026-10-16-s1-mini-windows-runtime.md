# S1-mini on Windows: which llama.cpp runtime?

Date: 2026-10-16. Branch `feat/s1-mini-hidden-win`, PR #56. S1-mini ships only behind a hidden flag
(`--cleanup-model` or `UV_CLEANUP_MODEL=1`), because the cleanup eval
(`2026-10-16-cleanup.md`) found it loses spoken words where rules-only loses none.

## Question

Wasim's brief: on Windows, run S1-mini with "a llama.cpp based runtime (for example node-llama-cpp,
MIT)", chosen by measured memory and latency. Does node-llama-cpp work inside this Electron app, how
heavy is it, and does it behave like the llama.cpp the cleanup eval used?

## Answer

**node-llama-cpp 3.22.1, CPU only, in a child process.** It runs the real model, gives the same
answers as the eval's `llama-server` on 256 of 261 cases, peaks at about 1.2 GB for the worker, and
packages with electron-builder (CI's windows job, which runs `electron-builder --win`, is green). The
alternative, shipping the official `llama-server.exe` as a helper, took about 27% less time at the median (291 vs 401 ms)
on the same noisy box but needs a second binary to fetch, pin and sign, so it stays the fallback.

## What ran

- Model: `superwhisper/s1-mini-GGUF` @ `34add00a48a2e5d24e5a4ee5405a99620a3a240c`,
  `s1-mini-q4_k_m.gguf`, 484,219,808 B, SHA-256 `3b41ebe2...003c634` (same file as the eval, hash
  checked). The model card was re-read at that revision for the prompt, the thinking switch and the
  greedy-decoding note.
- Runtime A: node-llama-cpp 3.22.1 (MIT), `gpu: false`, `build: 'never'`, context 2048, greedy
  (`temperature: 0`), the card's raw prompt with the think block already closed, no `maxTokens`. It
  bundles llama.cpp as its own release `v0.5.0` (`_nlcBuildMetadata.json`), not b11669.
- Runtime B: official llama.cpp `llama-server` b11669 (the eval's build) with `--jinja
  --chat-template-kwargs '{"enable_thinking":false}' --temp 0 -c 2048 -np 1 -t 4`.
- Box: Linux cloud VM, 4 vCPU Xeon @ 2.1 GHz, 16 GB, CPU only. **Shared with other jobs the whole
  time**, load average 4 to 13 on 4 cores. Every latency here is noisy; the medians are the usable
  numbers.
- Windows: not available here. CI (`windows-latest`) runs typecheck, 1,360 unit tests (21 skipped), build, E2E and
  `electron-builder --win` on every push. No model inference ran on Windows.

## Numbers

Same 40 in-sample cases, 3 unscored warm-ups, `-c 2048`, greedy (`windows/scripts/bench-runtimes/`).
Median and p95 are `sorted[floor(p * n)]` of the 40 request times, so the p95 is the 39th fastest, which is
the second slowest of the 40, and the max is the slowest one. Each row names the raw file that backs it (`evals/results/raw/`, prefix
`2026-10-16-s1-mini-windows-bench-`), with the load average at the start of the run:

| Runtime | Raw file | Load | RSS after load | Median | p95 | Max |
|---|---|---|---|---|---|---|
| node-llama-cpp, history cleared each request | `nlc-cleared-1` (load avg 1.6) | 2.3 s | 1,194 MB | 613 ms | 1,314 ms | 16,251 ms |
| node-llama-cpp, history cleared each request | `nlc-cleared-2` (4.7) | 2.1 s | 1,193 MB | 600 ms | 841 ms | 2,281 ms |
| node-llama-cpp, system prompt kept in context (shipped) | `nlc-kept-1` (3.1) | 2.2 s | 1,192 MB | 401 ms | 3,849 ms | 4,601 ms |
| node-llama-cpp, system prompt kept in context (shipped) | `nlc-kept-2` (5.2) | 2.4 s | 1,191 MB | 401 ms | 630 ms | 677 ms |
| llama-server b11669 | `llama-server-1` (4.5) | 1.2 s | 1,012 MB | 291 ms | 15,372 ms | 17,134 ms |
| llama-server b11669 | `llama-server-2` (5.1) | 1.2 s | 1,012 MB | 292 ms | 773 ms | 7,359 ms |

Keeping the system prompt in context cuts the median time by a third (about 600 to 400 ms). llama-server
takes about 27% less time than the shipped node-llama-cpp at the median (291 vs 401 ms) and its tail
was as bad as node-llama-cpp's on the same box (its slow stretches overlapped other jobs). node-llama-cpp
holds about 180 MB more RSS (the Node binding and its buffers). Both stay under the 1.5 s deadline at the median.
The tails (one slow run in each pair) track the load average, not the runtime, which is why the
decision rests on the medians.

Through the shipped worker (`windows/scripts/check-cleanup-model.mjs`, rules-cleaned text and
control line exactly as the eval sent them):

| Set | Raw file (`-runtime-`) | Cases | Identical to the eval's llama-server answer | Worker RSS | Load | Median | p95 |
|---|---|---|---|---|---|---|---|
| In-sample | `insample` | 188 | 184 | 1,200 MB (peak 1,201) | 6.0 s | 493 ms | 867 ms (3 over 1.5 s, max 19 s) |
| Held-out | `heldout` | 73 | 72 | 1,200 MB (peak 1,206) | 2.5 s | 4,948 ms | 20,780 ms |

`latency-run1-loaded.json` (60 cases, all identical to the eval, load 24.8 s, median 445 ms, p95
16.3 s) is an earlier run taken under heavy load. It backs no table; it is kept as raw output, and
it is where the top of the load-time range below comes from.

The held-out latency is not usable: the run overlapped a Swift build and a Playwright run on the
same 4 vCPUs (load average 8 to 13). It is kept as raw output. The 5 differing answers are
sampling-level differences between two llama.cpp builds, not a prompt problem: `useLayoutEffect`
vs `use LayoutEffect`, `that that` kept, `fooBar_baz` vs `FooBar_baz`, `Index.html` vs
`index.html`, `3 to 2` vs `3-2`. The guard sees them like any other model answer.

End to end through the hookup facade with the real model (`check-cleanup-runtime.mjs`, raw
`-runtime-e2e.json` and `.log`, every check must pass): flag off spawns nothing and reads no disk;
flag on: the first dictation on a cold model gets the rules text at once (10 ms in the committed run) while the load carries on in the background, then one worker (about 1.2 GB) holds the model and the guard accepts "So I need to send the report by
Thursday."; a 20 ms deadline returns the rules text without waiting for the model; a runtime reporting 5.9 GiB
skips the model and loads nothing at the hotkey; with a patient 120 s deadline the answer is
accepted; 4 s idle time ends the worker process, the first dictation after it gets the rules text at
once and the next one is accepted; the template token `<|im_end|>` is one token with specials on and several with them off,
and a dictation that says it aloud does not break the run.

Package cost (Linux `electron-builder --dir` with the same `files` and `asarUnpack`): `app.asar`
6.9 MB plus 30 MB unpacked (`@node-llama-cpp/win-x64`, 29.3 MB, 10.7 MB as a tarball). The CUDA
(176 MB), CUDA-ext (368 MB) and Vulkan (74 MB) packages install on a dev machine but are kept out of
the installer. CI: `npm ci` 35 s, `electron-builder --win` 1 m 47 s.

## Conclusion

- node-llama-cpp is in because it is the documented Electron path, adds no second executable and ran
  the model with the same answers as the eval's llama.cpp. It runs in a child process so unloading is
  `kill` and a stuck run cannot hang the app.
- The cost is real: about 36 MB on disk, a 1.2 GB worker while the model is loaded, and a
  load that takes about 2 to 25 s here (2 to 6 s on a quiet box, up to 25 s under heavy load, per the raw files). The first dictation after an idle unload, or after a restart,
  gets the rules-only text at once: a dictation never waits for a model that cannot answer, so it
  does not spend the 1.5 s deadline on a load. The load starts when the hotkey goes down (and carries on
  in the background if it was not started), so a dictation longer than the load, and every dictation
  after it, gets the model.
- Under heavy CPU load the model misses the deadline and the abort can take seconds to land (the
  worker is killed after 3 s). The dictation is never delayed, but the worker is reloaded. Worth
  measuring on real Windows hardware before the flag goes visible.

## What changed because of it

The runtime, downloader, pipeline, policy and notices shipped in this PR behind the hidden flag, and
phase 2 wires them into the Windows dictation path (flag off is byte-identical to main, proven by a
golden-file test). Decisions taken after review:

- RAM rule: the model runs on machines that report **at least 7 GiB** (on both platforms). Windows
  `os.totalmem()` leaves out hardware-reserved memory, so machines sold with 8 GB report about 7.0 to
  7.9 GiB; 6 GB and smaller stay off. Tests cover 6.9, 7.0, 7.8 and 8 GiB.
- Cold model: when the weights are not loaded, a load or unload is in flight or a stopped run is
  still being aborted, the model answers null at once and the dictation keeps the rules text. The
  first dictation after launch or an idle unload therefore costs nothing; the next one uses the model.
- Style: the style picked for an app category maps to the control line like the macOS app (Formal is
  formal, Casual is semi-casual, Very casual is casual, none is semi-formal).
- `run()` never rejects: any failure while checking the model file, loading or generating returns
  the rules text, and the disk check sits inside the 1.5 s deadline.
- Idle unload waits for every dictation in progress (begin/end count), and the preload skips a pinned
  non-English language.
- Open questions still: thread count (not measurable on this shared box), and no inference was run on
  real Windows hardware.

## Files

Raw (`evals/results/raw/`, prefix `2026-10-16-s1-mini-windows-`):
`bench-nlc-cleared-{1,2}.json`, `bench-nlc-kept-{1,2}.json`, `bench-llama-server-{1,2}.json`,
`runtime-{insample,heldout,latency-run1-loaded}.json`, `runtime-e2e.json` and `runtime-e2e.log`.
Commands (from `windows/`):
`node scripts/check-cleanup-model.mjs <model> ../evals/cleanup/cases.json ../evals/results/raw/2026-10-16-cleanup-r4-linux-insample.json <out>`,
`node scripts/check-cleanup-runtime.mjs <model> <out>`,
`CLEAR=1 node scripts/bench-runtimes/bench-node-llama-cpp.mjs <model> 2048 ../evals/cleanup/cases.json 40 <out>` (leave `CLEAR` unset for the kept-in-context runs),
`LLAMA_DIR=<b11669> MODEL=<model> CASES=../evals/cleanup/cases.json OUT=<out> python3 scripts/bench-runtimes/bench-llama-server.py`.
