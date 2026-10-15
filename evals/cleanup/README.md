# Cleanup eval

Decides whether a small local model ships on top of the deterministic cleanup rules. The
write-up and numbers are in `evals/results/2026-10-16-cleanup.md`.

- `cases.json`: hand-written English cases. Each has the text as Deepgram smart format would
  return it (`input`), the `expected` text (and `accept` alternatives), a `group`, the
  `app` category the control line is built from, `needs_edit`, and a `dev` or `test` split
  (by SHA-1 of the id; the guard limits were tuned on `dev` only). About 47% are already
  clean and must come back byte for byte.
- `run_eval.py`: starts `llama-server` for each model with the model card's settings, runs
  every variant, scores restraint, edit accuracy, content loss, content addition and guard
  rejects separately, and measures latency and peak RSS.
- `core_entry.ts`, `core_cli.mjs`: esbuild bundles the shipped TypeScript core
  (`windows/src/core/formatting/cleanup*.ts`) so the eval runs the code that ships.
- `fixtures/`: shared unit-test rows for the Swift and TypeScript cores.
- `prompts/speakoflow-system.txt`: the SpeakoFlow Mini system prompt, copied from its model card.

```sh
(cd windows && npm ci)
python3 evals/cleanup/run_eval.py --fetch --work /tmp/cleanup-work --out evals/results/raw/<date>-cleanup-<host>.json
python3 evals/cleanup/run_eval.py --work /tmp/cleanup-work --rescore evals/results/raw/<file>.json
```

`--fetch` downloads the pinned llama.cpp release and both Q4_K_M files and stops on a SHA-256
mismatch. `.github/workflows/cleanup-eval.yml` runs a subset on `macos-15` and uploads the
latency and memory numbers.

Licenses: both models are Apache 2.0. S1-mini adds one term: it must always be credited as
"S1-mini" by "Superwhisper".
