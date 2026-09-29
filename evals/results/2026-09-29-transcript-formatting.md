# Transcript formatting: ordinals, small numbers and German numbers

Date: 2026-09-29. Branch: `fix/transcript-formatting`.

## Question

"The first numbers look good" was transcribed as "the 1st numbers looks good". Where do the
digits come from, and can Deepgram's documented options fix it without changing words the
speaker said?

## Cause

`DeepgramProvider.makeRequest` (and the Windows mirror) sent `smart_format=true&numerals=true`.
Deepgram's docs for `numerals`: "nine hundred" becomes "900", "june twenty eighth" becomes
"june 28th". So every ordinal and every small number turned into digits.
Smart Format on its own writes English small numbers and ordinals as words and keeps dates,
times, money and decimals as digits. For non-English languages the docs say Smart Format
"will always include punctuation and paragraphs, with numerals support also available for
select languages". In practice German Smart Format digitises with or without `numerals`.

## What ran

- Script: `evals/formatting/run_eval.py`. Dataset: `evals/formatting/cases.json` (44 spoken
  sentences, 22 English and 22 German: ordinals, small numbers, quantities, dates, money,
  versions, model names, questions, lists, names, greetings, and 6 "must stay digit" cases).
- Audio is synthesised with macOS `say` (Samantha for English, Anna for German), 16 kHz mono WAV.
- Request: Nova-3, pinned `language=en` / `language=de`, the query string the app sends.
- Commands:
  - `python3 evals/formatting/run_eval.py --variant baseline  --out evals/results/raw/2026-09-29-formatting-baseline.json`
  - `python3 evals/formatting/run_eval.py --variant candidate --out evals/results/raw/2026-09-29-formatting-candidate.json`
  - `make test` and `cd windows && npx vitest run tests/transcriptStyle.test.ts` run the app's
    real post-processor (`TranscriptStyle`) over the recorded `candidate` output.
- Baseline is `smart_format=true&numerals=true` (the app before the fix). Candidate is
  `smart_format=true`.
- Cost: each 44-sentence run is about 2 to 3 audio minutes and there were about 8 runs, so
  under $0.10 at the Nova-3 pay-as-you-go rate (estimate, not read from the billing page).

## Numbers

| Stage | Pass |
|---|---|
| Baseline (before the fix) | 29 / 44 |
| Candidate, Deepgram output only (`numerals` dropped) | 34 / 44 |
| Candidate after `TranscriptStyle` (what the app now delivers) | 41 / 44 (asserted by `recordedDeepgramOutputEndsUpAsExpected`) |

The 3 that still differ are one documented gap (below). Nothing that was a digit on purpose
regressed: versions, model names, money, times, percentages, decimals and years all pass.

Fixed by dropping `numerals`: every English ordinal and small number ("the first", "the second
draft has three sections and 12 pages", "I have two questions and one idea").

Fixed by `TranscriptStyle`:

- English: "version two is out" becomes "version 2 is out", "GPT-five" becomes "GPT-5".
  Dropping `numerals` had turned these into words, so this keeps them as names. Narrow on
  purpose: a bare acronym plus a number ("call the API one more time") and "version one users"
  are left as spoken.
- German small numbers and ordinals: "2 Fragen" becomes "zwei Fragen" and "das 1. Kapitel" becomes
  "das erste Kapitel".
- German decimals: "3.5 Gigabyte" becomes "3,5 Gigabyte". Only before a unit or quantity
  word, never before "Uhr" (a time) or after a capitalised word, digit or hyphen ("iOS 17.4",
  "GPT-4.5", "10.30 Uhr" stay).

## Review round

Two reviewers (Opus 5.5 on the styling logic, Sonnet 5.5 on request, tests and sweep) ran on PR 27,
twice. Pass one: seven high false positives in the first version (acronym plus number rewritten,
"iOS 17.4" and "10.30 Uhr" turned into commas, money and symbols, spaced ranges, capitals after
abbreviations, a Swift/TS difference). Pass two, on the stricter rules: five more highs, nearly
all from the German small-number rule guessing too widely ("iOS 9", "inkl. 3", half-converted
ranges, an ordinal swallowing a sentence end, "the version one would expect").

The fix for pass two was a design change, not more exceptions: a German digit becomes a word only
after a short list of words that take a quantity ("habe", "sind", "in", "mit", "für" and so on),
or at the very start of the text. Everything else keeps Deepgram's digit. Ordinals no longer use
"am" or "vom" (usually dates). All findings are pinned as inputs in
`evals/formatting/style-guards.json` (79 inputs, run by both the Swift and the Windows tests,
which also fail if the counts change or a file is empty). READMEs are docs, not app text, and
were not swept.

## Decisions

- A German digit stays unless a quantity word precedes it, or it opens the text. So
  "Fertig. 3 Leute kamen." and "In 2 Wochen ist es soweit." keep the digit. Safe misses.
- German ordinals after "der" and "die" stay as digits ("die 3. Runde"). The ending depends
  on gender and number, and a wrong ending would change a word the speaker said. These are the
  3 cases marked `known_gap`.
- German dates: Deepgram writes "am fünften März" as words. The clock time still becomes digits.
  Left as Deepgram returns it.
- Repeated words are not collapsed. "had had" and "that that" are real, and a rule cannot tell
  a stutter from grammar.
- German "Du" mid-sentence is capitalised by Deepgram ("Hast Du ..."). Both spellings are
  accepted in modern German, so it is left alone.
- Sentence ends, commas, question marks, spacing and capitalisation after punctuation come from
  Deepgram and were correct in every case where the synthetic voice paused naturally. "Hi, team."
  style greetings come out right. Where the test voice paused mid-sentence Deepgram split it
  into two sentences, which is punctuation following the audio and not a defect. No rule added.
- The response parser trims the transcript, and no case produced trailing or doubled spaces.
- Auto-detect requests cannot know the language before sending, so `numerals` is never sent.
  `TranscriptStyle` then runs in the language Deepgram detected.

## Changed because of this

- `numerals=true` removed from the macOS and Windows requests and from
  `scripts/check-deepgram-request.sh`.
- New `TranscriptStyle` (Swift) and `transcriptStyle.ts` (Windows), applied in the Deepgram
  response parser only when auto-format is on. Unknown languages pass through untouched.
- Em dashes removed from every user-facing string (Settings language line, keyterm pricing note,
  tray tooltips, clipboard message, empty Dictionary hint) and from the shareable diagnostic log.
- The Settings line now reads "Transcribing English. Use the language hotkey to change it."
