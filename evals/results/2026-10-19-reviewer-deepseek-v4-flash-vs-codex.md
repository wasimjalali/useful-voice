# Can DeepSeek V4 Flash take Codex's slot as PR reviewer?

Date: 2026-10-18 to 2026-10-19 (reviews ran 20:11 to 00:15 CEST on 2026-10-18/19). Repo: Useful Voice, PRs #63, #64 and #65.
This is an observation from real review work, not a controlled bake-off. Read "Limits" before quoting a number.

## Question

Codex (GPT 6.1 Sol) was the second reviewer on every PR. Partway through, the owner asked to swap it for DeepSeek V4 Flash
through the DeepSeek Harness CLI (`dsh`) and to report how the two compare. Does a cheap open-weights model, run read-only
in a harness, find the defects that matter on a delivery-critical Windows/Electron codebase?

## Answer

**Yes, as a reviewer in the Codex slot. It isn't a like-for-like replacement.**

- DeepSeek's findings were grounded, each with file:line and a traced scenario. 23 of its 25 have a fix named in a later
  commit or brief (see "Findings that led to a change"). None was dismissed as wrong.
- It found three real highs Codex never had the chance to look for: media pause ids lost on a host timeout, Electron killing the
  process right after `session-end`, and a session-end resume budget eaten by a re-added grace.
- It was slower and chattier than Codex: 226 to 503 s and 41 to 163 tool calls per review, against 188 to 378 s and 13 to 36
  commands. It never ran code. All 5 finished Codex reviews report in-memory reproductions of the races they found.
- It rated 3 of 25 findings high. Codex rated 18 of 26 high. Part of that is the diffs (DeepSeek got later, cleaner rounds),
  part may be calibration. This eval can't separate the two.

Recommendation: keep DeepSeek V4 Flash as the Codex-slot reviewer when Codex is out of credits or when a second cheap
opinion is wanted. Keep Sonnet and Opus for the mandatory slots. Don't read "3 highs vs 18" as "DeepSeek is less thorough".

## Setup

| | Codex | DeepSeek |
|---|---|---|
| Model | `gpt-6.1-sol` | `deepseek-v4-flash` (the harness reports only this alias, not a dated snapshot) |
| Tool | Codex CLI 0.162.1 | `dsh` (DeepSeek Harness CLI, `@deepseek-ai/dsh`) in `headless` mode |
| Effort | `reasoning effort: high` (from each run log) | `reasoningEffort: max`, then `high` (see below) |
| Mode | `sandbox: read-only`, `approval: never` | `DSH_PERMISSION_MODE=read-only` |
| Tools it used | shell (`git`, `rg`, `sed`, small in-memory probes) | `bash`, `read`, and in 3 reviews `web_search` / `web_fetch` |
| Area | `windows/` only, every round | `windows/` only, every round |
| Checkout | a detached worktree at the PR head | same |

Run command for DeepSeek, from the review checkout:

```sh
DSH_PERMISSION_MODE=read-only dsh headless --patch <patch.yml> --json - < brief.md > events.jsonl
```

The headless profile ships with the `credentials` plugin disabled, so it can't see the key that the web profile saved
(`MISSING_CREDENTIAL`). The patch has to switch the plugin on and set the model:

```yaml
- id: agent-default-model
  config:
    provider: deepseek-official
    model: deepseek-v4-flash
    reasoningEffort: max     # dsh-patch-high.yml: high
- id: credentials
  disabled: false
```

`dsh-patch-max.yml` was written at 21:52 and `dsh-patch-high.yml` at 23:41, just before PR #65 round 3. The command lines
weren't saved, so which run used which effort is inferred from those times: the first three DeepSeek runs (#64 round 3,
#65 rounds 1 and 2) on `max`, the last two (#65 round 3 and the closing check) on `high`. Vitest can't run under the harness's
read-only mode (EPERM writing a timestamp file), so DeepSeek reviewed by reading, not by running tests.
A one-line smoke test (`dsh-smoke-events.jsonl`) confirmed the model id before the first review.

Both tools got the same kind of brief: what the PR does, the commit range to read, the output shape
`{ finding, severity, file, line, scenario }`, a required DISMISSED list, a word cap, and a `YOUR AREA` paragraph naming the
`windows/` files and the risks to chase. The macOS half of each PR went to Opus and Sonnet.

## What ran

| PR | Round | Reviewer | Brief task |
|---|---|---|---|
| #63 paste reliability | 1, 2, 3 | Codex | find defects, then verify the previous round's fixes |
| #64 models and AI formatting | 1, 2 | Codex | find defects, then verify fixes |
| #64 | 3 | DeepSeek | verify the parity rules S1 to S7 between macOS and Windows. A Codex run on the same brief was started at about 21:50 and stopped after about 70 s (19 commands, no answer) when the owner asked for the swap. Its log is kept. |
| #65 pause media | 1, 2, 3, closing | DeepSeek | find defects, then verify fixes |

Opus and Sonnet also reviewed each PR. Their outputs weren't kept in the files this write-up is built from, so nothing below
compares DeepSeek or Codex against them finding by finding.

## Per-review numbers

Duration is the gap between the brief being written (Codex) or the run starting (DeepSeek, the empty `.err` file's time)
and the final answer file being written, so it includes a few seconds of start-up. Codex's token figure is the
"tokens used" line at the end of its log. DeepSeek's are summed from the `step_end` usage events: uncached input, output,
and cache reads. The cache-read number is the context re-read on every step, so it grows with the number of steps and
isn't a cost-comparable figure to Codex's total. Words are the length of the final answer.

### Codex (GPT 6.1 Sol, high)

| PR / round | Time | Commands | Tokens | Findings | High | Low | Words |
|---|---|---|---|---|---|---|---|
| #63 r1 | 378 s | 36 | 159,160 | 7 | 5 | 2 | 734 |
| #63 r2 | 298 s | 21 | 131,600 | 6 | 5 | 1 | 654 |
| #63 r3 | 188 s | 13 | 123,079 | 3 | 3 | 0 | 428 |
| #64 r1 | 233 s | 25 | 161,722 | 6 | 3 | 3 | 691 |
| #64 r2 | 214 s | 23 | 168,574 | 4 | 2 | 2 | 537 |
| **Total** | **1,311 s** | **118** | **744,135** | **26** | **18** | **8** | |

### DeepSeek V4 Flash (max, then high)

| PR / round | Time | Tool calls | Steps | Input / output tokens | Cache reads | Findings | High | Low | Words |
|---|---|---|---|---|---|---|---|---|---|
| #64 r3 | 481 s | 163 | 98 | 183,530 / 81,426 | 14,390,784 | 7 | 0 | 7 | 821 |
| #65 r1 | 226 s | 41 | 28 | 60,411 / 39,717 | 1,635,584 | 5 | 1 | 4 | 896 |
| #65 r2 | 362 s | 52 | 31 | 74,399 / 69,867 | 2,466,816 | 5 | 0 | 5 | 923 |
| #65 r3 | 503 s | 89 | 69 | 116,085 / 87,250 | 7,443,200 | 4 | 1 | 3 | 687 |
| #65 closing | 383 s | 80 | 64 | 96,220 / 64,411 | 6,060,544 | 4 | 1 | 3 | 549 |
| **Total** | **1,955 s** | **425** | **290** | **530,645 / 342,671** | **31,996,928** | **25** | **3** | **22** | |

Tool calls: 384 `bash`, 33 `read`, 5 `web_fetch`, 3 `web_search`. The web lookups were all in the two Electron `session-end`
reviews (Electron's `native_window_views_win.cc` and `browser_win.cc`, the `session-end` docs) and one check of the sherpa-onnx model
release list.

Cost: neither tool reports money. Codex runs on the owner's plan and DeepSeek on a DeepSeek account, and no invoice line is tied to
these runs, so no dollar figure is recorded and per-token prices aren't assumed here. Token volume is above. DeepSeek used more
calls and more re-read context per review, so check the DeepSeek billing page before assuming it's cheaper per review.

## Findings that led to a change

"Acted on" means a later commit or brief names the fix. It's the only validity signal in the record, and it doesn't prove
the reviewer was first to find it.

| Reviewer | Findings | Acted on | Evidence |
|---|---|---|---|
| Codex #63 r1 | 7 | 7 | Fixes listed in the round 2 brief (`962f1cd`): sent paste keeps the clipboard, one-shot killed on abort, stdin EPIPE handler, cancel restore guards, window rechecked before the keystroke, repeat window 600 ms, picker reads the current window |
| Codex #63 r2 | 6 | 6 | `3ed8f8c` (a written keystroke counts as sent, guard inside the script, picker settled before delivery), round 3 brief |
| Codex #63 r3 | 3 | 3 | `9c5e599` (decide the paste at the last moment, never overwrite a newer copy, read the foreground after the clipboard hash) |
| Codex #64 r1 | 6 | 6 | `ac5afaf`, `1245a08` and the round 1 fix brief (F1 truncated replies, F5 log hygiene, key encryption, Parakeet worker, notices, E2E stub) |
| Codex #64 r2 | 4 | 4 | `23885f5` and the round 2 fix brief (S1 Gemini complete transcript, S2 log hygiene, S5 body timeout, first-run model) |
| DeepSeek #64 r3 | 7 | 5 of 7 | `5fee007` names provider-named HUD errors, ElevenLabs quota, real key-save outcome, setup local option, one Parakeet language source. The unreadable-key banner and the first-run model recompute aren't named |
| DeepSeek #65 r1 | 5 | 5 | Round 2 brief (`492ad83`): ids held before pausing, no pause after the recording ended, timeline check, grace on a timer, quit budget, real-session test |
| DeepSeek #65 r2 | 5 | 5 | `e190e3c`, round 3 brief: confirmed pauses only, refusals logged, `before-quit` routing, back-compat test |
| DeepSeek #65 r3 | 4 | 4 | `204081b`, closing brief: quit coordinator, per-session `UVSKIP`, `UVRESUMED` sentinel, behavioural quit tests |
| DeepSeek #65 closing | 4 | 4 | `60fcb55`: quit budget kept, unfinished session named, no installer on logoff, `session-end` emitted on a real window |

Totals: Codex 26 of 26, DeepSeek 23 of 25. No finding from either reviewer was dismissed as wrong in the record.

## Notable catches

DeepSeek:

- **Lost pause ids** (#65 r1, high, `mediaScripts.ts:63`). The pause script printed its list of paused sessions only when it
  finished. A 6 s host timeout killed the process and dropped the list, so the media was paused with nothing remembered, and
  not even quit would resume it. Fix: hold the ids before pausing.
- **Electron terminates the process after `session-end`** (#65 r3, high, `index.ts:390`). The reviewer fetched Electron's
  Windows window source and showed that `WM_ENDSESSION` emits `session-end` and then terminates the process unless the
  app is already quitting. The async resume never ran on logoff or shutdown, and the code comment saying it went through
  `before-quit` was wrong. This is the sort of catch that needs the platform source, and the web lookup is what made it.
- **Session-end grace budget** (#65 closing, high, `index.ts:1108`). The quit's own `cancel()` re-armed a 400 ms back-to-back
  grace that ate the 1 s resume budget, and the unit test used `graceMs: 0` so it couldn't see it.
- Smaller: a resume that plays something the user paused during a long dictation, an installer spawned on logoff, tests that
  can't fail (a regex over source, a back-compat test that kept the key it claimed to be missing).

Codex:

- **Clipboard restore races** (#63 r1 and r3): restoring the old clipboard before a stalled target consumed the paste, cancel
  restoring over a newer copy, and fallback paths overwriting a newer copy.
- **Indeterminate sends** (#63 r2): after the keystroke may have gone out, a cancel or abort must not claim "nothing was
  sent" and restore the clipboard. This rule shaped the final design of the paste flow.
- **Truncated formatter replies** (#64 r1) pasted as complete text, and the Gemini transcription version (#64 r2) that accepted a
  cut-off transcript without keeping the audio for Retry.
- **Dictation text in diagnostics** (#64 r1 and r2): a provider's error body can echo the transcript, and the log is
  exposed through the diagnostics page.
- It reproduced races in memory with mocked I/O in every finished review ("reproduced" appears in all five answers).
  DeepSeek only read.

## Limits

- **Not a head-to-head.** No review was run by both on the same diff. Codex reviewed #63 rounds 1 to 3 and #64 rounds 1 and 2.
  DeepSeek reviewed #64 round 3 and all of #65. The one shared brief (#64 round 3) was cut short on the Codex side.
- **Later and cleaner diffs.** DeepSeek saw rounds that were already shaped by earlier reviewers and fixes, and its #64
  round 3 task was to verify parity rules rather than hunt. Fewer highs are what that predicts.
- **Different code.** Codex's PRs were clipboard and paste logic. DeepSeek's PR was media control and Electron quit handling,
  where reading the platform source matters more than running a probe.
- **Half the PR each time.** Both reviewed `windows/` only. The macOS halves went to other reviewers.
- **No ground truth.** "Acted on" is the validity signal. There's no count of false positives, and none of missed bugs: a defect
  nobody found doesn't show up here. Sonnet and Opus outputs weren't kept, so unique-versus-shared findings can't be counted.
- **Severity isn't calibrated across reviewers.** Each reviewer set its own severity, and Codex used high freely on narrow races.
- **Effort differs and is partly inferred.** Codex ran at high throughout. DeepSeek ran at max, then high, and which run used which
  isn't recorded in a command line.
- **Model identity.** `dsh` reports `deepseek-v4-flash`, not a snapshot. A later run may be a different build.
- **Timing is from file times.** They were read from the scratchpad files' modification times, which a copy doesn't keep, so
  the seconds can't be re-derived from `raw/`. They include start-up. Treat them as rough.

## What changed

- The owner moved the Codex slot for the rest of PR #64 and all of PR #65 to DeepSeek V4 Flash through `dsh`.
- The `dsh` recipe (read-only, credentials patch, how to read the event stream) is above, with the patch files in
  `evals/results/raw/`.
- Gap found while writing this: Sonnet and Opus review outputs weren't saved. Without them, "who found it first" can't be
  answered. Saving every reviewer's brief and answer to `verify/<branch>/` and copying them here would close it.

## Reproduce

Everything is in `evals/results/raw/`, prefixed `2026-10-19-reviewer-`:

- `prNN-rN-codex-{brief,out}.md` and `-run.log`: the brief, the final answer and the full Codex session log.
- `pr64-r3-brief.md`: the brief given to both tools in #64 round 3; `pr64-r3-codex-aborted-run.log` is the stopped Codex run.
- `prNN-*-dsh-{brief,out}.md` and `-events.jsonl`: the brief, the final answer and the `dsh --json` event stream (session,
  status with usage, thinking, `tool_call`, `tool_result`, `final`).
- `dsh-patch-max.yml`, `dsh-patch-high.yml`, `dsh-smoke-events.jsonl`.

Count the numbers above from the event streams with:

```sh
python3 - <<'EOF'
import json, glob
for f in sorted(glob.glob('evals/results/raw/2026-10-19-reviewer-pr6*-dsh-events.jsonl')):
    calls = steps = 0
    use = dict(inputTokens=0, outputTokens=0, cacheReadTokens=0)
    for line in open(f):
        e = json.loads(line)
        calls += e['type'] == 'tool_call'
        if e['type'] == 'status' and e.get('phase') == 'step_end':
            steps += 1
            for k in use: use[k] += e['usage'][k]
    print(f.split('reviewer-')[1], calls, steps, use)
EOF
```

Codex's figures: `grep -c '^exec$'` and the `tokens used` line of each `-run.log`. The briefs name absolute paths from the machine
that ran them, and the PR heads they point at are in git history.
