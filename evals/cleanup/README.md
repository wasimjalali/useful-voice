# Cleanup eval

Decides whether a small local model ships on top of the deterministic cleanup rules. The
write-up and numbers are in `evals/results/2026-10-16-cleanup.md`.

- `cases.json`: 188 hand-written English cases, the in-sample set. Each has the text as
  Deepgram smart format would return it (`input`), the `expected` text (and `accept`
  alternatives), a `group`, the `app` category the control line is built from and
  `needs_edit`. About 47% are already clean and must come back byte for byte. The `split`
  field (dev or test, by SHA-1 of the id) is not a held-out split: the rules and the guard
  were changed while looking at results on all 188 cases, so every number on this file is
  in-sample.
- `heldout.json`: 73 cases (52% clean) written after the guard and rules were fixed and
  committed before anything ran on them. They lean on what the guard must catch: negations,
  amounts, doses, phone and room numbers, order-sensitive sentences, self-corrections, emails
  and code. Never tune on this file. A change made because of a held-out result needs a new
  held-out set.
- `run_eval.py`: starts `llama-server` for each model with the model card's settings, runs
  every variant, scores restraint, edit accuracy, spoken words lost and added (the decision
  metric, see the script header) and guard rejects separately, and measures latency and peak
  RSS.
- `core_entry.ts`, `core_cli.mjs`: esbuild bundles the shipped TypeScript core
  (`windows/src/core/formatting/cleanup*.ts`) so the eval runs the code that ships.
- `fixtures/`: shared unit-test rows for the Swift and TypeScript cores.
- `prompts/speakoflow-system.txt`: the SpeakoFlow Mini system prompt, copied from its model card.

```sh
(cd windows && npm ci)
python3 evals/cleanup/run_eval.py --fetch --work /tmp/cleanup-work --out evals/results/raw/<date>-cleanup-<host>.json
python3 evals/cleanup/run_eval.py --fetch --work /tmp/cleanup-work --cases evals/cleanup/heldout.json --out <new file>
python3 evals/cleanup/run_eval.py --work /tmp/cleanup-work --rescore <raw file> --out <new file>
```

`--fetch` downloads the pinned llama.cpp release and both Q4_K_M files and stops on a SHA-256
mismatch. `--out` never overwrites a file. `.github/workflows/cleanup-eval.yml` (manual dispatch
only) runs an in-sample subset and the held-out set on `macos-15`, prints the raw JSON to the job
log and uploads it.

Licenses: both models are Apache 2.0. S1-mini adds one term: it must always be credited as
"S1-mini" by "Superwhisper".
