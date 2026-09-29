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

The 3 that still differ are all the same documented gap (below). Nothing that was a digit on purpose
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
five times. Pass one: seven high false positives in the first version (acronym plus number
rewritten, "iOS 17.4" and "10.30 Uhr" turned into commas, money and symbols, spaced ranges,
capitals after abbreviations, a Swift/TS difference). Pass two, on the stricter rules: five more
highs from the German small-number rule guessing too widely ("iOS 9", "inkl. 3", half-converted
ranges, an ordinal swallowing a sentence end, "the version one would expect"). Pass three, on the
allowlist redesign: six more highs at the edges of the same heuristic (half-converted lists,
sentence-final digits, more range words, label numbers after determiners like "Die 7", ordinals
before a new sentence, English "version two and three"). Pass four, on the all-or-nothing design: three narrower highs
("14 und 5" continuing a quantity, "Dienstag, den 5. Kommst du?" losing its full stop, English
"version one to version two" half converted). Fixed by blocking und/oder after any number,
dropping "den" from the ordinal articles, and converting "version" only when it is the sole
version in the text.
Pass five: three more highs ("Freitag, dem 3. Kommst du?" losing its full stop, an abbreviation
such as "bzw." splitting a sentence so "zwei bzw. 3" came out half converted, mixed "2,5" and
"3.5" in one sentence). Fixed by letting an ordinal convert only before a short list of nouns
("Mal", "Kapitel", "Stock", "Quartal" and so on), counting a full stop as a sentence end only
before a capital letter or a line end, and giving decimals the same all-or-nothing rule.

Each pass fixed its findings and then changed the design instead of piling on exceptions:

1. A German digit becomes a word only after a short list of quantity words ("habe", "sind",
   "in", "mit", "für" and so on), or at the very start of the text. Determiners are not on it.
2. All or nothing per sentence. If any single digit in a sentence cannot be converted safely,
   none of that sentence's single digits are, so a list, range or score is never half converted.
3. Ordinals convert only after das, dem, des, im, zum, zur, beim and only before a listed noun
   ("Mal", "Kapitel", "Stock", "Quartal"). A date or a number that ends a sentence never matches.

Every finding is pinned as an input in `evals/formatting/style-guards.json` (121 inputs, run by
both the Swift and the Windows tests, which also assert their counts, so an emptied file fails).
READMEs are docs, not app text, and were not swept.

## Decisions

- A German digit stays unless a quantity word precedes it, or it opens the text, and a
  sentence with any digit that cannot convert keeps all of its single digits. So "Fertig. 3
  Leute kamen.", "Der 2. Entwurf hat 3 Abschnitte" and "Er hat 2, sie hat 3." keep their digits.
  These are safe misses: a digit is better than a wrong or half-converted word.
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
