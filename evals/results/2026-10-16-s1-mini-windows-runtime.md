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
alternative, shipping the official `llama-server.exe` as a helper, was about 35% faster at the median
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
- Windows: not available here. CI (`windows-latest`) ran typecheck, 1,208 unit tests, build, E2E and
  `electron-builder --win` on every push. No model inference ran on Windows.

## Numbers

Same 40 in-sample cases, 3 unscored warm-ups, `-c 2048`, greedy (`windows/scripts/bench-runtimes/`):

| Runtime | Load | RSS after load | Median | p95 | Max |
|---|---|---|---|---|---|
| node-llama-cpp, history cleared each request | 3.1 s | 1,195 MB | 552 ms | 754 ms | 1,147 ms |
| node-llama-cpp, history cleared each request (rerun) | 2.0 s | 1,191 MB | 597 ms | 743 ms | 774 ms |
| node-llama-cpp, system prompt kept in context (shipped) | 2.2 s | 1,194 MB | 389 ms (9 requests) | 547 ms | 547 ms |
| llama-server b11669 | 4.0 s | 1,012 MB | 288 ms | 5,799 ms | 10,738 ms |
| llama-server b11669 (rerun) | 1.2 s | 1,012 MB | 294 ms | 14,426 ms | 18,185 ms |

llama-server was faster at the median and had the worse tail on this box (its two slow stretches
overlapped other jobs). node-llama-cpp holds about 190 MB more RSS (the Node binding and its
buffers). Both stay under the 1.5 s deadline at the median.

Through the shipped worker (`windows/scripts/check-cleanup-model.mjs`, rules-cleaned text and
control line exactly as the eval sent them):

| Set | Cases | Identical to the eval's llama-server answer | Worker RSS | Median | p95 |
|---|---|---|---|---|---|
| In-sample | 188 | 184 | 1,200 MB (peak 1,201) | 493 ms | 867 ms (3 over 1.5 s, max 19 s) |
| Held-out | 73 | 72 | 1,200 MB (peak 1,206) | 4,948 ms | 20,780 ms |

The held-out latency is not usable: the run overlapped a Swift build and a Playwright run on the
same 4 vCPUs (load average 8 to 13). It is kept as raw output. The 5 differing answers are
sampling-level differences between two llama.cpp builds, not a prompt problem: `useLayoutEffect`
vs `use LayoutEffect`, `that that` kept, `fooBar_baz` vs `FooBar_baz`, `Index.html` vs
`index.html`, `3 to 2` vs `3-2`. The guard sees them like any other model answer.

End to end through the hookup facade with the real model (`check-cleanup-runtime.mjs`, 10 checks, all
pass): flag off spawns nothing; flag on loads one worker (1,203 MB) and the guard accepts "So I need
to send the report by Thursday."; a 20 ms deadline returns the rules text after 20 ms; under 8 GiB
the model is skipped; 4 s idle time ends the worker process; the next dictation loads it again.

Package cost (Linux `electron-builder --dir` with the same `files` and `asarUnpack`): `app.asar`
6.9 MB plus 30 MB unpacked (`@node-llama-cpp/win-x64`, 29.3 MB, 10.7 MB as a tarball). The CUDA
(176 MB), CUDA-ext (368 MB) and Vulkan (74 MB) packages install on a dev machine but are kept out of
the installer. CI: `npm ci` 35 s, `electron-builder --win` 1 m 47 s.

## Conclusion

- node-llama-cpp is in because it is the documented Electron path, adds no second executable and ran
  the model with the same answers as the eval's llama.cpp. It runs in a child process so unloading is
  `kill` and a stuck run cannot hang the app.
- The cost is real: about 36 MB on disk, a 1.2 GB worker while the model is loaded, and a
  load that takes 2 to 15 s here. The first dictation after an idle unload, or after a restart,
  will usually get the rules-only text because the 1.5 s deadline passes while the model loads. The
  load starts when the hotkey goes down, so a dictation longer than the load gets the model.
- Under heavy CPU load the model misses the deadline and the abort can take seconds to land (the
  worker is killed after 3 s). The dictation is never delayed, but the worker is reloaded. Worth
  measuring on real Windows hardware before the flag goes visible.

## What changed because of it

Nothing ships on by default. The runtime, downloader, pipeline, policy and notices are in the PR,
unwired. Open questions for the wiring PR: thread count (not measurable on this shared box), and
whether Windows machines sold as 8 GB (`os.totalmem()` often reports 7.x GiB) should pass the 8 GiB
rule.

## Files

Raw: `evals/results/raw/2026-10-16-s1-mini-windows-runtime-{insample,heldout,e2e,latency-run1-loaded}.json`
and `-e2e.log`. Commands:
`node scripts/check-cleanup-model.mjs <model> ../evals/cleanup/cases.json ../evals/results/raw/2026-10-16-cleanup-r4-linux-insample.json <out>`,
`node scripts/check-cleanup-runtime.mjs <model> <out>`,
`node scripts/bench-runtimes/bench-node-llama-cpp.mjs <model> 2048 ../evals/cleanup/cases.json 40 <out>`,
`LLAMA_DIR=<b11669> MODEL=<model> CASES=../evals/cleanup/cases.json python3 scripts/bench-runtimes/bench-llama-server.py`.
