# Transcript formatting: English first, plus German numbers

Date: 2026-09-29. Branch: `fix/transcript-formatting`.

English is the primary language, so it has the widest coverage here. German is secondary and
its rules are deliberately cautious.

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

- Script: `evals/formatting/run_eval.py`. Dataset: `evals/formatting/cases.json` (83 spoken
  sentences, 61 English and 22 German: ordinals, small numbers, quantities, dates, times, money,
  phone numbers, emails, URLs, versions, model names, questions, lists, names, greetings,
  multi-sentence dictation, and 6 "must stay digit" cases).
- Audio is synthesised with macOS `say` (Samantha and Daniel for English, Anna for German), 16 kHz
  mono WAV. A few sentences were reworded after the first run when the synthetic voice, not the
  formatting, was at fault (a dropped "We", "pool request", a mangled surname).
- Request: Nova-3, pinned `language=en` / `language=de`, the query string the app sends.
- Commands:
  - `python3 evals/formatting/run_eval.py --variant baseline  --out evals/results/raw/2026-09-29-formatting-baseline.json`
  - `python3 evals/formatting/run_eval.py --variant candidate --out evals/results/raw/2026-09-29-formatting-candidate.json`
  - `make test` and `cd windows && npx vitest run tests/transcriptStyle.test.ts` run the app's
    real post-processor (`TranscriptStyle`) over the recorded `candidate` output.
- Baseline is `smart_format=true&numerals=true` (the app before the fix). Candidate is
  `smart_format=true`.
- Cost: a full run is about 4 to 6 audio minutes and there were about 10 runs including partial
  ones, so roughly $0.25 at the Nova-3 pay-as-you-go rate (estimate, not read from the billing page).

## Numbers

| Stage | Pass |
|---|---|
| Baseline (before the fix) | 56 / 83 |
| Candidate, Deepgram output only (`numerals` dropped) | 68 / 83 |
| Candidate after `TranscriptStyle` (what the app now delivers) | 80 / 83 (asserted by `recordedDeepgramOutputEndsUpAsExpected`) |

The 3 that still differ are all the same documented German gap (below). Nothing that was a digit
on purpose regressed: versions, model names, money, times, percentages, decimals and years all pass.
All 61 English sentences pass after `TranscriptStyle`.

Fixed by dropping `numerals`: every English ordinal and small number ("the first", "the second
draft has three sections and 12 pages", "I have two questions and one idea").

Fixed by `TranscriptStyle`:

- English times: "07:45AM" becomes "7:45 AM" and "3PM" becomes "3 PM" (no leading zero, a space
  before AM or PM). Deepgram writes them glued together.
- English ordinal nouns: "the 21st Floor" becomes "the 21st floor". Deepgram capitalises the noun
  after a digit ordinal; only a list of common nouns is lowercased, so "5th Avenue" and
  "1st Street" keep their capital.
- English quarters: "q three" becomes "Q3" (only at the end of a phrase or before a word like
  "revenue" or "is", so "Press Q two times" is untouched).
- English closing full stop: "The ticket costs $25" becomes "The ticket costs $25." Deepgram drops it
  after a currency amount. Only for a one-line sentence of four or more words, starting with a capital
  letter and not a question, that ends on the amount with no punctuation.
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
eight times. Pass one: seven high false positives in the first version (acronym plus number
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
Pass six (German only, English matched): three highs ("Windows XP und 7" continuing a quantity from a
label, "bis zum 5. Mal sehen" read as an ordinal, "bzw. Welpen" splitting a sentence) and missing unit
abbreviations. Fixed by dropping "und" and "oder" as quantity continuations, removing "Mal" and
"Klasse" from the ordinal nouns, and ending a sentence at a full stop only after a word of five or
more letters. Since English is the primary language and German is not, these fixes chose the
safest option each time (the digit stays) rather than covering more German.
Pass seven (English only, the primary language): three highs in the new English rules ("Press Q two
times" became "Q2 times", "21st Place NW" and "21st Century Fox" lost a capital, "UA 007 PM" became
"UA 07 PM") and a low (a full stop added to a question or list item ending in an amount). Fixed by
limiting "Q" to real quarter contexts, dropping street and title nouns from the ordinal list and
requiring that no capitalised word follows, keeping times out of longer numbers and codes, and adding
the closing full stop only to a one-line sentence of four or more words that is not a question.
Pass eight (Sonnet only, on the owner's instruction to skip Opus): two Sonnet reviewers at high effort,
one on the English rules and one on the closing full stop, plus a Sonnet check of the eval files. No
highs. The lows worth fixing were: "Press Q two to quit" (dropped "to", "and" and "or" as quarter
followers), leading zeros stripped from "05 AM" (now only from a clock time with minutes), a time after a
comma or currency symbol, the question check looking only at the first word (now the last sentence),
and only "\n" counting as a newline (now every line break). Two lows were left: a partial conversion in
"Q one or two" and "3rd Time" losing a capital when Deepgram omits the full stop before it.

Each pass fixed its findings and then changed the design instead of piling on exceptions:

1. A German digit becomes a word only after a short list of quantity words ("habe", "sind",
   "in", "mit", "für" and so on), or at the very start of the text. Determiners are not on it.
2. All or nothing per sentence. If any single digit in a sentence cannot be converted safely,
   none of that sentence's single digits are, so a list, range or score is never half converted.
3. Ordinals convert only after das, dem, des, im, zum, zur, beim and only before a listed noun
   ("Kapitel", "Stock", "Quartal", "Jahr"). A date or a number that ends a sentence never matches.

Every finding is pinned as an input in `evals/formatting/style-guards.json` (168 inputs, run by
both the Swift and the Windows tests, which also assert their counts, so an emptied file fails).
READMEs are docs, not app text, and were not swept.

## Decisions

English, left as Deepgram writes it (correct, only a different style):

- "three point five million" comes out as "3,500,000", "twenty three of March" as "March 23",
  "two hours and thirty minutes" keeps "thirty", "four oh four" becomes "four zero four".
- Other English punctuation (commas before "but", question marks, capital after a full stop) was
  right on every sentence where the synthetic voice paused naturally.

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
