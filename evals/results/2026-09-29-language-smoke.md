# Language picker smoke test

Date: 2026-09-29.

## Question

The language picker lists every language Deepgram documents for Nova-3. English is the
primary language. Do the others work well enough to keep in the picker, or should the list be cut?

## What ran

- Script: `evals/language-smoke/run.py`. One spoken sentence per language ("tomorrow we have a
  meeting at ten and need to review the budget"), 19 languages, spoken with macOS `say`.
- Request: Nova-3, `language=<code>`, `smart_format=true`, the same query the app sends for a pinned
  language.
- Command: `python3 evals/language-smoke/run.py --out evals/results/raw/2026-09-29-language-smoke.json`
- Judged by eye. Word-for-word scoring across scripts says little, and a synthetic voice is a weak
  proxy for a person.
- Cost: about 1 audio minute, well under $0.01.

## Results

| Result | Languages |
|---|---|
| Transcribed correctly | Spanish, French, Italian, Dutch, Swedish, Danish, Russian, Turkish, Japanese, Korean, Chinese, Indonesian, Czech, Greek, Romanian, Hindi |
| Correct, with a small Deepgram quirk | Portuguese ("uma reunião" came out as "1 reunião"), Danish (dropped "i" before "morgen"), Chinese (no comma), Hindi (kept the English word "budget" in Latin script) |
| Wrong | Polish: "o dziesiątej" came out as "o dziesięć:zero" |
| Inconclusive | Finnish: valid 4 second audio, empty transcript twice with this synthetic voice |

## Decision

Keep every language in the picker. Seventeen of nineteen transcribed a real sentence correctly, the
app passes the pinned code straight to Deepgram, and removing languages would take away working
functionality (the owner dictates in German as well). The quirks above are Deepgram output and not
something the app causes or can fix without guessing at what was said.

English stays the priority in the formatting code: the number-style rules are strict for English
and cautious for German, and other languages pass through untouched.

Not tested: the other ~30 languages in the list, and real human speech. Finnish should be checked with
a person speaking before anyone relies on it.
