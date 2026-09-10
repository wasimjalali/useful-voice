# Deepgram models, languages & pricing — verified research for Useful Voice

Research date: fetched live. Every quote below was retrieved from the URL shown.
Method: `web_fetch` only (`web_search` returns HTTP 402 on this machine).
`developers.deepgram.com` HTML is client-rendered; appending `.md` yields Markdown.
`deepgram.com/pricing` is also client-rendered — its rate tables were extracted from
the raw Next.js/Sanity payload of `https://deepgram.com/pricing`.

Scope: pre-recorded `POST https://api.deepgram.com/v1/listen`, 16 kHz mono 16-bit WAV,
`model=nova-3`, `smart_format`, `keyterm` personal-dictionary prompting.

---

## A. Which pre-recorded model

### A1. Models available for pre-recorded `/v1/listen`

The authoritative enum is in the OpenAPI spec for `POST /v1/listen`
(https://developers.deepgram.com/openapi.json, `V1ListenPostParametersModel0`,
`"description": "Our public models available to all accounts"`):

`nova-3`, `nova-3-general`, `nova-3-medical`, `nova-2`, `nova-2-general`,
`nova-2-meeting`, `nova-2-finance`, `nova-2-conversationalai`, `nova-2-voicemail`,
`nova-2-video`, `nova-2-medical`, `nova-2-drivethru`, `nova-2-automotive`, `nova`,
`nova-general`, `nova-phonecall`, `nova-medical`, `enhanced`, `enhanced-general`,
`enhanced-meeting`, `enhanced-phonecall`, `enhanced-finance`, `base`, `meeting`,
`phonecall`, `finance`, `conversationalai`, `voicemail`, `video`

Languages, from https://developers.deepgram.com/docs/models-languages-overview.md:

| Model | Pre-recorded `/v1/listen`? | Languages |
|---|---|---|
| `nova-3` / `nova-3-general` | Yes (in the enum) | 105 codes incl. `multi` — full list in section B |
| `nova-3-medical` | Yes (in the enum) | "English: `en`, `en-US`, `en-AU`, `en-CA`, `en-GB`, `en-IE`, `en-IN`, `en-NZ`" |
| `nova-2` / `nova-2-general` | Yes | See quote below |
| `nova-2-meeting`, `-phonecall`, `-finance`, `-conversationalai`, `-voicemail`, `-video`, `-medical`, `-drivethru`, `-automotive`, `-atc` | Yes | `nova-2-atc` is documented on /docs/models-languages-overview, and `nova-2-conversationalai` there too, but **neither appears in the OpenAPI `/v1/listen` enum** (the enum has bare `conversationalai` instead). Discrepancy noted. English: `en`, `en-US` for each |
| `nova-2-<CUSTOM>` | Yes | "All available" |
| `nova` / `nova-general`, `nova-phonecall`, `nova-medical` | Yes | "English: `en`, `en-US`, `en-AU`, `en-GB`, `en-NZ`, `en-IN` Spanish: `es`, `es-419` Hindi:`hi-Latn`" |
| `enhanced` / `enhanced-general` | Yes | "Danish: `da` Dutch: `nl` English: `en`, `en-US` Flemish: `nl` French: `fr` German: `de` Hindi: `hi` Italian: `it` Japanese: `ja` Korean: `ko` Norwegian: `no` Polish: `pl` Portuguese: `pt`, `pt-BR`, `pt-PT` Spanish: `es`, `es-419`, `es-LATAM` Swedish: `sv` Tamasheq: `taq` Tamil: `ta`" |
| `base` / `base-general` | Yes | "Chinese: `zh`, `zh-CN`, `zh-TW` Danish: `da` Dutch: `nl` English: `en`, `en-US` Flemish: `nl` French: `fr`, `fr-CA` German: `de` Hindi: `hi`, `hi-Latn` Indonesian: `id` Italian: `it` Japanese: `ja` Korean: `ko` Norwegian: `no` Polish: `pl` Portuguese: `pt`, `pt-BR`, `pt-PT` Russian: `ru` Spanish: `es`, `es-419`, `es-LATAM` Swedish: `sv` Tamasheq: `taq` Turkish: `tr` Ukrainian: `uk`" |
| `whisper`, `whisper-tiny`, `-base`, `-small`, `-medium`, `-large` | Yes | ~99 codes, quoted in full in section C |
| `flux-general-en`, `flux-general-multi` | **NO — streaming only** | See A3 |

Nova-2 languages, verbatim from the same page:

> `nova-2` or `nova-2-general` | [**Multilingual (Spanish + English): `multi`** ](/docs/multilingual-code-switching),  Bulgarian: `bg`,  Catalan: `ca`,  Chinese (Mandarin, Simplified):`zh`, `zh-CN`,`zh-Hans`,  Chinese (Mandarin, Traditional):`zh-TW`,`zh-Hant`,  Chinese (Cantonese, Traditional): `zh-HK`,  Czech: `cs`,  Danish: `da`, `da-DK`,  Dutch: `nl`,  English: `en`, `en-US`, `en-AU`, `en-GB`, `en-NZ`, `en-IN`,  Estonian: `et`,  Finnish: `fi`,  Flemish: `nl-BE`,  French: `fr`, `fr-CA`,  German: `de`,  German (Switzerland): `de-CH`,  Greek: `el`,  Hindi: `hi`,  Hungarian: `hu`,  Indonesian: `id`,  Italian: `it`,  Japanese: `ja`,  Korean: `ko`, `ko-KR`,  Latvian: `lv`,  Lithuanian: `lt`,  Malay: `ms`,  Norwegian: `no`,  Polish: `pl`,  Portuguese: `pt`, `pt-BR`, `pt-PT`,  Romanian: `ro`,  Russian: `ru`,  Slovak: `sk`,  Spanish: `es`, `es-419`,  Swedish: `sv`, `sv-SE`,  Thai: `th`, `th-TH`,  Turkish: `tr`,  Ukrainian: `uk`,  Vietnamese: `vi`

Whisper's own caveat, same page:

> Whisper models are less scalable than all other Deepgram models due to their inherent model architecture. All non-Whisper models will return results faster and scale to higher load.

### A2. What Deepgram says Nova-3 is for

https://developers.deepgram.com/docs/models-languages-overview.md:

> [nova-3](/docs/models-languages-overview#nova-3) | Our highest-performing general-purpose ASR (no turn detection). Recommended for meetings, event captioning, multi-speaker, multilingual, noisy, or far-field audio in batch or streaming.

> [nova-2](/docs/models-languages-overview#nova-2) | Recommended for use cases with languages not yet supported by nova-3, and filler word identification.

> All models default to `language=en` unless otherwise specified via the `language` parameter.

The pricing page tooltip (https://deepgram.com/pricing):

> Nova-3 Monolingual — Our highest performing model. Recommended for most use cases, especially audio with multiple languages, background noise, crosstalk and far field audio.

https://developers.deepgram.com/docs/measuring-streaming-latency.md:

> Nova-3 is Deepgram's flagship STT model, delivering sub-300 ms streaming latency with industry-leading accuracy.

Nothing in Deepgram's docs names a *different* model as better for short single-speaker
dictation utterances. Nova-3 is the top of the documented line for pre-recorded general ASR.

### A3. Flux — streaming only

Plainly: **Flux cannot be used for pre-recorded transcription.**

https://developers.deepgram.com/docs/flux/flux-nova-3-comparison.md, "Use Cases" matrix:

> | Pre-recorded Audio      | 🚫   | ✅      |

https://developers.deepgram.com/docs/flux/quickstart.md:

> **Flux requires the `/v2/listen` endpoint** — Using `/v1/listen` will not work with Flux.

https://developers.deepgram.com/reference/speech-to-text/listen-flux.md declares
`GET /v2/listen` as a WebSocket (AsyncAPI, `servers: Production: url: wss://api.deepgram.com/`).
No REST/POST form exists.

### A4. Anything better than Nova-3 here? — No.

`keyterm` is Nova-3-and-Flux only. Two independent confirmations:

https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded.md:

> `keyterm` (list of string, optional) — Key term prompting improves recognition of specialized terminology and brands. **Only compatible with Nova-3.**

> `keywords` (string or list of string, optional) — Keywords can boost or suppress specialized terminology and brands. **`keywords` is not supported with Nova-3 models; use `keyterm` instead.**

https://developers.deepgram.com/docs/keyterm.md:

> Keyterm Prompting is available for both monolingual and multilingual transcription using the [Nova-3 Models](/docs/models-languages-overview#nova-3), as well as [Flux](/docs/models-languages-overview#flux). To boost recognition of keywords using another Deepgram model (such as Nova-2), use the [Keywords](/docs/keywords) feature.

Note the app uses `POST /v1/listen`, so the Flux half of that sentence is unreachable
for it. On pre-recorded, `keyterm` is effectively Nova-3-only.

If a user switched to any other model they would lose:

1. **`keyterm` entirely** — the whole personal-dictionary feature. Nova-2/Enhanced/Base
   only have legacy `keywords`, which is a *different* feature: it takes a
   numeric intensifier (`keywords=KEYWORD:INTENSIFIER`) and is capped at
   "Keywords are limited to 100 keywords per request" with no token model
   (https://developers.deepgram.com/docs/keywords.md). Every keyterm would have to be
   re-encoded and the weight-tuning semantics would change.
2. **Language coverage** — Nova-2 documents 47 codes vs Nova-3's 105.
3. **Multilingual capacity** — Nova-2's `multi` covers only "Multilingual (Spanish + English)",
   versus Nova-3's 10 languages.
4. **Spoken punctuation** stays (Dictation is a separate feature, not model-gated).

Also confirmed: `keywords` is *not* a drop-in fallback, because
https://developers.deepgram.com/docs/stt-pre-recorded-feature-overview.md lists
Keyterm Prompting as "All available" languages while the feature-overview matrix for
Nova-3 lists Keyterm Prompting ✅ — but the model-level restriction in the OpenAPI
description is explicit and unambiguous.

### A5. Published latency / WER figures

**WER — and Deepgram's own docs contradict each other on the same sentence.**

https://developers.deepgram.com/docs/models-languages-overview.md:

> The model delivers industry-leading performance with a **54.2% reduction in word error rate (WER) for streaming and 47.4% for batch processing compared to competitors.**

https://developers.deepgram.com/docs/model.md:

> The model delivers industry-leading performance with a **53.4% reduction in word error rate (WER) for streaming and 47.4% for batch processing compared to competitors.**

54.2% vs 53.4% for the identical claim. Both pages otherwise carry identical Nova-3 prose.
Both figures are "compared to competitors" — **not** Nova-3 vs Nova-2. A genuine
Nova-3-vs-Nova-2 WER comparison or benchmark table could not be found on any Deepgram
developer-docs page; I could not run `web_search` to look further.

Multilingual claim, same page:

> In multilingual testing, Nova-3 demonstrated superior performance across all seven tested languages, with particularly strong results showing up to 8:1 preference ratios in certain languages.

**Latency.** No pre-recorded latency figure is published. The latency doc explicitly
scopes itself away from batch:

https://developers.deepgram.com/docs/measuring-streaming-latency.md:

> **Batch transcription** processes pre-recorded audio files and returns complete transcripts once processing finishes. For batch, throughput and turnaround time matter more than per-word latency. This guide focuses exclusively on streaming.

> | Transcription latency        | 150–300 ms    | Deepgram's models are optimized to deliver 300 ms or less under most conditions |

Flux figures (not usable by this app): "**Ultra-low latency** ~260ms end-of-turn detection
(p50 at defaults)" (https://developers.deepgram.com/docs/flux/nova-3-migration.md) and
"Flux can reduce agent response latency by 200–600 ms compared to traditional STT+VAD
approaches" (https://developers.deepgram.com/docs/measuring-streaming-latency.md).

**A hard limit that matters for this app.** https://developers.deepgram.com/docs/pre-recorded-audio.md:

> **Processing time**: Requests exceeding 10 minutes (Nova/Base/Enhanced) or 20 minutes (Whisper) return a `504: Gateway Timeout` error.

Also: "**File size**: Maximum 2 GB."

---

## B. Complete Nova-3 language list for pre-recorded (the dropdown deliverable)

Source: https://developers.deepgram.com/docs/models-languages-overview.md — the only
place Deepgram enumerates Nova-3 languages. The page does **not** split Nova-3's list by
endpoint: there is one `nova-3` row, and the same languages are documented for
pre-recorded and streaming. Section A1 confirms `nova-3` and `nova-3-medical` are valid
`/v1/listen` model values via the OpenAPI enum.

### B1. General Nova-3 — verbatim row

> | `nova-3` or `nova-3-general` | [**Multilingual (English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, and Dutch): `multi`** ](/docs/multilingual-code-switching),  Afrikaans: `af`, `af-ZA`,  Arabic: `ar`, `ar-AE`, `ar-SA`, `ar-QA`, `ar-KW`, `ar-SY`, `ar-LB`, `ar-PS`, `ar-JO`, `ar-EG`, `ar-SD`, `ar-TD`, `ar-MA`, `ar-DZ`, `ar-TN`, `ar-IQ`, `ar-IR`,  Armenian: `hy`,  Assamese: `as`, `as-IN`,  Belarusian: `be`,  Bengali: `bn`,  Bosnian: `bs`,  Bulgarian: `bg`,  Catalan: `ca`,  Chinese (Cantonese, Traditional): `zh-HK`,  Chinese (Mandarin, Simplified): `zh`, `zh-CN`, `zh-Hans`,  Chinese (Mandarin, Traditional): `zh-TW`, `zh-Hant`,  Croatian: `hr`,  Czech: `cs`, `cs-CZ`,  Danish: `da`, `da-DK`,  Dutch: `nl`,  English: `en`, `en-US`, `en-AU`, `en-GB`, `en-IN`, `en-NZ`,  Estonian: `et`,  Finnish: `fi`,  Flemish: `nl-BE`,  French: `fr`, `fr-CA`,  Georgian: `ka`, `ka-GE`,  German: `de`,  German (Switzerland): `de-CH`,  Greek: `el`,  Gujarati: `gu`, `gu-IN`,  Hebrew: `he`,  Hindi: `hi`,  Hungarian: `hu`,  Indonesian: `id`,  Italian: `it`,  Japanese: `ja`,  Kannada: `kn`,  Kazakh: `kk`, `kk-KZ`,  Korean: `ko`, `ko-KR`,  Latvian: `lv`,  Lithuanian: `lt`,  Macedonian: `mk`,  Malay: `ms`,  Marathi: `mr`,  Mongolian: `mn`,  Nepali: `ne`,  Norwegian: `no`,  Pashto: `ps`, `ps-AF`,  Persian: `fa`,  Polish: `pl`,  Portuguese: `pt`, `pt-BR`, `pt-PT`,  Punjabi: `pa`, `pa-IN`,  Romanian: `ro`,  Russian: `ru`,  Serbian: `sr`,  Slovak: `sk`,  Slovenian: `sl`,  Spanish: `es`, `es-419`,  Swedish: `sv`, `sv-SE`,  Tagalog: `tl`,  Tamil: `ta`,  Telugu: `te`,  Thai: `th`, `th-TH`,  Turkish: `tr`, `tr-TR`,  Ukrainian: `uk`,  Urdu: `ur`,  Vietnamese: `vi` |

Flat expansion (my transcription of the row above — 63 named languages plus `multi`,
105 code strings total; the doc states no count itself):

| Language | Codes |
|---|---|
| *(multilingual code-switching)* | `multi` |
| Afrikaans | `af`, `af-ZA` |
| Arabic | `ar`, `ar-AE`, `ar-SA`, `ar-QA`, `ar-KW`, `ar-SY`, `ar-LB`, `ar-PS`, `ar-JO`, `ar-EG`, `ar-SD`, `ar-TD`, `ar-MA`, `ar-DZ`, `ar-TN`, `ar-IQ`, `ar-IR` |
| Armenian | `hy` |
| Assamese | `as`, `as-IN` |
| Belarusian | `be` |
| Bengali | `bn` |
| Bosnian | `bs` |
| Bulgarian | `bg` |
| Catalan | `ca` |
| Chinese (Cantonese, Traditional) | `zh-HK` |
| Chinese (Mandarin, Simplified) | `zh`, `zh-CN`, `zh-Hans` |
| Chinese (Mandarin, Traditional) | `zh-TW`, `zh-Hant` |
| Croatian | `hr` |
| Czech | `cs`, `cs-CZ` |
| Danish | `da`, `da-DK` |
| Dutch | `nl` |
| English | `en`, `en-US`, `en-AU`, `en-GB`, `en-IN`, `en-NZ` |
| Estonian | `et` |
| Finnish | `fi` |
| Flemish | `nl-BE` |
| French | `fr`, `fr-CA` |
| Georgian | `ka`, `ka-GE` |
| German | `de` |
| German (Switzerland) | `de-CH` |
| Greek | `el` |
| Gujarati | `gu`, `gu-IN` |
| Hebrew | `he` |
| Hindi | `hi` |
| Hungarian | `hu` |
| Indonesian | `id` |
| Italian | `it` |
| Japanese | `ja` |
| Kannada | `kn` |
| Kazakh | `kk`, `kk-KZ` |
| Korean | `ko`, `ko-KR` |
| Latvian | `lv` |
| Lithuanian | `lt` |
| Macedonian | `mk` |
| Malay | `ms` |
| Marathi | `mr` |
| Mongolian | `mn` |
| Nepali | `ne` |
| Norwegian | `no` |
| Pashto | `ps`, `ps-AF` |
| Persian | `fa` |
| Polish | `pl` |
| Portuguese | `pt`, `pt-BR`, `pt-PT` |
| Punjabi | `pa`, `pa-IN` |
| Romanian | `ro` |
| Russian | `ru` |
| Serbian | `sr` |
| Slovak | `sk` |
| Slovenian | `sl` |
| Spanish | `es`, `es-419` |
| Swedish | `sv`, `sv-SE` |
| Tagalog | `tl` |
| Tamil | `ta` |
| Telugu | `te` |
| Thai | `th`, `th-TH` |
| Turkish | `tr`, `tr-TR` |
| Ukrainian | `uk` |
| Urdu | `ur` |
| Vietnamese | `vi` |

Note there is **no `de-DE`** and **no `en-CA`** in the general Nova-3 row (`en-CA`
appears only in the `nova-3-medical` row).

### B2. `nova-3-medical` — verbatim row

> | `nova-3-medical`             | English: `en`, `en-US`, `en-AU`, `en-CA`, `en-GB`, `en-IE`, `en-IN`, `en-NZ` |

### B3. The `multi` member list — exact

From the Nova-3 row label (URL in the row: https://developers.deepgram.com/docs/multilingual-code-switching):

> Multilingual (English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, and Dutch): `multi`

Codes, spelled out on the Flux row of the same page and confirmed by
https://developers.deepgram.com/docs/models-languages-overview.md Flux table:

> `flux-general-multi` | [**Multilingual (English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, and Dutch)**](/docs/flux/language-prompting): `en`, `es`, `fr`, `de`, `hi`, `ru`, `pt`, `ja`, `it`, `nl`

So Nova-3 `multi` = `en`, `es`, `fr`, `de`, `hi`, `ru`, `pt`, `ja`, `it`, `nl` (10 languages).
Nova-2 `multi` = "Multilingual (Spanish + English)" only.

### B4. `detect_language` supported codes

https://developers.deepgram.com/docs/language-detection.md — verbatim, 35 entries:

> If you are submitting multichannel audio, Language Detection identifies one language per channel. Language Detection is supported for the following languages:
>
> * Bulgarian - `bg`
> * Catalan - `ca`
> * Czech - `cs`
> * Danish - `da`
> * German - `de`
> * German (Switzerland) - `de-CH`
> * Greek - `el`
> * English - `en`
> * Spanish - `es`
> * Estonian - `et`
> * Finnish - `fi`
> * French - `fr`
> * Hindi - `hi`
> * Hungarian - `hu`
> * Indonesian - `id`
> * Italian - `it`
> * Japanese - `ja`
> * Korean - `ko`
> * Lithuanian - `lt`
> * Latvian - `lv`
> * Malay - `ms`
> * Dutch - `nl`
> * Flemish - `nl-BE`
> * Norwegian - `no`
> * Polish - `pl`
> * Portuguese - `pt`
> * Romanian - `ro`
> * Russian - `ru`
> * Slovak - `sk`
> * Swedish - `sv`
> * Thai - `th`
> * Turkish - `tr`
> * Ukrainian - `uk`
> * Vietnamese - `vi`
> * Chinese - `zh`

**Different from Nova-3's list — much smaller.** 35 vs 105. Nova-3 supports e.g. `ar`,
`zh-HK`, `he`, `vi`-adjacent regional variants and dozens more that `detect_language`
cannot return. Conversely `detect_language`'s list is region-less for most entries
(`zh`, `pt`) whereas Nova-3's is not.

The doc then states:

> It is critical to know that the `language_confidence` score only takes into account the 35 supported languages. If the audio is in a language not supported by language detection, the value of `language_confidence` should be ignored.

(This confirms 35; I counted the bullet list and it matches.)

Doc inconsistency to note: the page header badge reads
"`detect_language` *boolean* Default: `false` — Pre-recorded  Streaming:Nova",
but the body says:

> Language Detection is not currently supported for streaming.

### B5. `language=multi` — valid on Nova-3 pre-recorded, and it is code-switching

https://developers.deepgram.com/docs/multilingual-code-switching.md:

> `language` *string* Option: `multi` — Pre-recorded  Streaming:Nova  Specific languages only
>
> The Multilingual Codeswitching feature in Deepgram's API allows you to transcribe conversations where speakers switch between multiple languages.

> To enable Multilingual Codeswitching on Nova-2 or Nova-3, use the following language parameter in the query string when you call Deepgram's `/listen` endpoint: `language=multi`

And its pre-recorded cURL example is literally:

> `--url 'https://api.deepgram.com/v1/listen?language=multi&model=nova-3`

**Confirmed: `multi` = code-switching, `detect_language` = auto-detect.** They are
different mechanisms with different parameter names and different response fields
(`languages` array per word vs `detected_language` + `language_confidence` per channel).

Corroborating, https://developers.deepgram.com/docs/flux/flux-nova-3-comparison.md:

> | Code-switching              | ✅ Native with `flux-general-multi`                                          | ✅ With `language=multi`                                          |
> | Language control            | `language_hint` parameter                                                    | `language` parameter                                             |

Also from https://developers.deepgram.com/docs/models-languages-overview.md (streaming section):

> When using Nova-3 Multilingual (`model=nova-3`, `language=multi`), numeral formatting is supported for: English, Spanish, French, German, Russian, Portuguese, Italian, and Dutch. Numeral formatting is not currently supported for Hindi or Japanese.

---

## C. Pricing

All figures from https://deepgram.com/pricing (Pay As You Go and Growth columns),
extracted from the page's own rate tables. Page footer reads "Copyright © 2026 Deepgram".
Currency: USD. No "prices valid as of" date is stated. The page carries
"**_Limited-time promotional rates on streaming._**" — the **pre-recorded** cells carry
no strikethrough/regular-price pair, so they are **not** promotional.

### C1. Pre-recorded speech-to-text rate table (complete — 4 rows)

| Model | Pay As You Go | Growth |
|---|---|---|
| Nova-3 Monolingual | `$0.0043/min` (`$0.26/hour`) | `$0.0036/min` (`$0.22/hour`) |
| Nova-3 Multilingual | `$0.0052/min` (`$0.31/hour`) | `$0.0043/min` (`$0.26/hour`) |
| Whisper Large | `$0.0048/min` (`$0.29/hour`) | `$0.0048/min` (`$0.29/hour`) |
| Custom | Contact Sales | Contact Sales |

Tooltips as published: Nova-3 Monolingual — "Our highest performing model. Recommended
for most use cases, especially audio with multiple languages, background noise,
crosstalk and far field audio."

**Nova-2, Enhanced, Base and Nova-1 have no published pre-recorded rate.** They are
absent from the pre-recorded table (verified by enumerating every rate row in the page
payload — the pre-recorded STT table contains exactly the four rows above). The
streaming table likewise now lists only Flux English, Flux Multilingual, Nova-3
Monolingual, Nova-3 Multilingual, Custom. The FAQ states:

> **Are older models (Nova-2, Enhanced, Base) still available?** — Yes. These remain available at unchanged rates for existing deployments: Nova-2 streaming at $0.35/hour, Enhanced at $0.99/hour, and Base at $0.87/hour. Growth plan rates are about 12.5% lower. We recommend new projects start with Nova-3 for general-purpose transcription or Flux for real-time voice agents.

Those are **streaming** rates and are not convertible to pre-recorded. The OpenAPI
description for `mip_opt_out` says "Refer to our Docs for pricing impacts before setting
this to true" — no figure for that impact was found anywhere.

Sanity check: `$0.0043/min × 60 = $0.258`, which the page rounds to the `$0.26/hour` it
publishes. Internally consistent.

### C2. Pre-recorded add-ons — `keyterm` is a PAID extra

Complete add-on table for pre-recorded (5 rows; no others exist):

| Feature | Pay As You Go | Growth |
|---|---|---|
| Redaction | `$0.0020/min` | `$0.0017/min` |
| **Keyterm Prompting** | **`$0.0013/min`** | **`$0.0012/min`** |
| Smart Formatting | **Included** | **Included** |
| Entity Detection | `$0.0017/min` | `$0.0017/min` |
| Speaker Diarization | **Included** | **Included** |

Descriptions as published: Keyterm Prompting — "Boost accuracy for specific
domain-specific jargon, product names, or acronyms important to your use case."
Smart Formatting — "Automatically format punctuation, casing, dates, and currency for
readability."

**This is the single most consequential pricing finding: `smart_format` is free, but
`keyterm` adds ~30% to a Nova-3 monolingual pre-recorded request**
(`0.0013 / 0.0043 = 30.2%`).

`detect_language`, `dictation`, `numerals` and `punctuate` appear in **no** add-on row,
so they are included in the per-minute rate. (Inference from documented absence — see
Confidence.)

### C3. Free tier and billing increment

> **What is included in the $200 free credit?** — Every new account receives $200 in free credit, which is equivalent to approximately 43,000 minutes (over 700 hours) of transcription using our Nova model. Unlike "free tiers" that expire after 12 months, this credit is available until you use it up, allowing you to prototype without time pressure.

> **Does Deepgram charge for silence or round up audio time?** — No. Deepgram uses true per-second billing. If your audio file is 14 seconds long, you pay for exactly 14 seconds. Many competitors round up to the nearest 15 seconds or full minute, which can inflate your actual invoice by 15-20%.

Corroborated: "Signup is free and includes **$200** in free credit and access to all of
Deepgram's features!" (https://developers.deepgram.com/docs/deepgram-whisper-cloud.md).

**There is no minimum billing increment — billing is true per-second.** For 2–60 s
dictation utterances this is materially better than per-minute rounding.

> **How do you calculate costs for multichannel audio?** — We bill based on the total duration of processed audio. If you process a 10-minute file with 2 channels (stereo), you are billed for 20 minutes of processing.

This app sends mono 16 kHz WAV, so no multiplier applies.

Plans: "Pay-As-You-Go requires no upfront commitment and bills monthly based on usage.
The Growth plan requires a commitment (starting at $4k/year) but unlocks up to a ~20% off
across our products, higher concurrency limits, and priority support."
Also: PAIG "**No credit card required.**"

### C4. Heavy dictation user: 1 hour/day × 30 days

Input: 60 min/day × 30 days = **1,800 minutes/month** (30 hours).

Nova-3 Monolingual, pre-recorded, Pay As You Go:

```
speech                    1,800 min
Nova-3 monolingual  1,800 × $0.0043 = $ 7.74
Keyterm Prompting   1,800 × $0.0013 = $ 2.34
                                     --------
total                                $10.08 / month
```

Cross-check against the published hourly rate: `30 h × $0.26/h = $7.80` (page's rounded
hourly; the exact `$0.0043 × 60 × 30 = $7.74`). Rounding on the marketing page only.

- **Without** the keyterm dictionary: **$7.74/month**.
- **With** keyterms (the app's actual config): **$10.08/month**.
- Growth plan (needs the $4k/yr commitment): `1,800 × $0.0036 = $6.48` +
  `1,800 × $0.0012 = $2.16` = **$8.64/month**.
- If `language=multi` were used instead: `1,800 × $0.0052 = $9.36` + `$2.34` =
  **$11.70/month**.
- All figures are 0.004% of the $200 signup credit — the credit covers roughly
  **20 months** at this usage with keyterms ($200 / $10.08 ≈ 19.8).

---

## D. What the app should change

First, a correction to the brief: **the app does not offer only en/de/auto.**
`Sources/UsefulVoiceCore/Transcription/DeepgramLanguage.swift` curates 10 languages —
Dutch, English, French, German, Hindi, Italian, Japanese, Portuguese, Russian, Spanish —
plus `auto` presented separately. Those 10 are exactly Nova-3's `multi` set. The app also
already restricts `detect_language` to the catalogue codes
(`DeepgramProvider.swift:91,120-121`), which is the documented-safe behaviour (see D15).

### Ranked recommendations

**1. Keep `model=nova-3`. Do not change it.** It is the highest-performing general-purpose
model Deepgram documents for pre-recorded batch transcription, and it is the *only*
pre-recorded-capable model that supports `keyterm`. Switching models would delete the
personal-dictionary feature rather than reduce cost. There is no better model for this
use case, and no documented evidence that any other model beats Nova-3 for short
dictation utterances. **No change.**

**2. Expand the language dropdown from 10 to the full Nova-3 pre-recorded set (section B1).**
This is the highest-value change and it is the deliverable the brief asked for. The
current 10-word list silently omits ~53 languages Nova-3 genuinely supports, including
large dictation markets: `zh`/`zh-CN`, `ko`, `tr`, `pl`, `sv`, `da`, `no`, `fi`, `uk`,
`ar`, `he`, `th`, `vi`, `id`, `cs`, `el`, `hu`, `ro`, `sk`, `bg`, `hr`, `ca`, `ms`, `tl`.
Adding them is data-only — the enum is already data-driven precisely so this is a
one-file change (`DeepgramLanguageCatalog.all`), and `LanguagePin.init(code:)`
already normalises unknown codes to `auto`, so stale stored values stay safe.
Keep collapsing regional variants to a single root row (the existing `en` decision) —
but note the two exceptions worth surfacing: `de-CH` is a *different* language entry on
Deepgram's list, not merely a regional variant of `de`, and `zh-HK` (Cantonese) is a
different language from `zh` (Mandarin). Lumping Cantonese under `zh` would transcribe
Cantonese audio with a Mandarin model.

**3. Add a `multi` option for code-switching users.** Nova-3's `multi` covers exactly the
10 languages already in the catalogue, so it is a natural 11th entry — and the catalogue
was evidently *derived* from that set. It is valid on pre-recorded
(`/v1/listen?language=multi&model=nova-3` is Deepgram's own example). Cost: `$0.0052/min`
vs `$0.0043/min`, i.e. +21%. It is **not** a replacement for `auto`: `multi` tells Deepgram
to *expect* mid-conversation switching, which is why the current code correctly moved
`auto` off `multi` onto `detect_language`. Offer it as a distinct, explicitly-labelled
choice for bilingual speakers, not as the auto path.

**4. Warn (or guard) that `keyterm` is billed.** At `$0.0013/min` on top of
`$0.0043/min`, enabling the personal dictionary is a 30.2% cost increase. The app should
not hide this from a user who is watching spend, and settings diagnostics are the natural
place. This is a disclosure change, not a functional one.

**5. `detect_language` cannot detect most of the languages in an expanded dropdown.**
If recommendation 2 is implemented, `auto` becomes weaker than it looks: detection
supports only the 35 codes in B4. German `de` and English `en` are covered, so the
*current* app is fine. But after expansion, a user pinning `tr` or `pl` is fine while
`auto` can still detect them, whereas `ar`, `he`, `zh-HK`, `zh-TW`, `fa`, `ur`, `bn`,
`ta`, `te` etc. are Nova-3-transcribable but **not** detectable. `auto` would never
select them, and worse — per D15 — an unsupported detection plus a pinned model makes
Deepgram fall back to a *different* model. Recommend: when `auto` is selected, restrict
`detect_language` to codes that are in **both** the Nova-3 list and the 35-code detection
list (which is what the app already does, since its 10 codes are all in both), and make
the UI honest that `auto` covers only those languages.

**6. Consider offering `smart_format` as a user-visible toggle, not a constant.**
It is free, and it is what produces the `punctuated_word` field the app likely reads for
pasting. No cost argument to change it — this is only worth doing if users complain about
over-formatting (e.g. it rewrites spoken numbers into digits).

**7. Do not switch to `whisper`, `nova-3-medical`, or a Nova-2 variant.**
- `whisper`: slower (Deepgram's own words: "less scalable… return results faster and scale
  to higher load"), no `keyterm` (Keywords ❌), and `language_confidence` is unavailable.
- `nova-3-medical`: English-only, 8 codes, and would need its own keyterm dictionary
  tuning. Irrelevant unless the app ships a medical mode.
- Nova-2 variants: 47 codes max, `multi` is Spanish+English only, no `keyterm`.

**8. Verify the 10-minute ceiling.** The app allows utterances up to 10 minutes;
Deepgram returns `504: Gateway Timeout` for requests exceeding 10 minutes of processing
time for Nova/Base/Enhanced. A 10-minute utterance sits exactly on that boundary. Worth a
targeted test at 9:30–10:00 before shipping that limit, and worth documenting the failure
mode if it triggers.

### D15. Caveats: `detect_language` combined with `keyterm` / `smart_format`

**Documented behaviour when a detected language is unsupported by the chosen model**
(https://developers.deepgram.com/docs/language-detection.md) — quoted verbatim:

> If you specify both `detect_language=true` and a `model` in your query parameter, Deepgram will attempt to use the specified model for the language that is detected. However, if the detected language is not available for that model, **Deepgram will automatically select the next highest model to complete the request.**

> To use the best Deepgram model available, use `model=nova-3-general&detect_language=true`. The order of precedence  will be: `Nova-3 -> Nova-2 -> Nova-1 -> Enhanced -> Base`.

> For example, you may send the request with the parameters `detect_language=true&model=nova-3-general`. If the detected language is supported by Base and Enhanced models, but not a Nova-3 model, Deepgram will process the request with the Enhanced model since that is the next highest model available for that language.

This is the dangerous interaction for this app: **a silent downgrade away from Nova-3 also
removes `keyterm` support**, because `keyterm` is "Only compatible with Nova-3"
(https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded.md). The
personal dictionary would stop biasing the transcript with no error surfaced. Deepgram
does **not** document what happens to `keyterm` when it falls back to a
non-Nova-3 model — it is not stated whether the parameter is rejected or silently
ignored. **Unverified; this is the highest-value thing to test.**

The app already defends against this, and its code comment says so
(`DeepgramProvider.swift:85-91`): detection is restricted to the catalogue, every
catalogue language is a native Nova-3 language, hence the fallback is unreachable. That
reasoning is **sound per the docs** — and it stays sound under recommendation 2 only if
every language added to the dropdown is also added to the `detect_language` restriction
list *and* is one of the 35 detectable codes (see recommendation 5).

Documented ways to restrict detection, verbatim:

> **Restricting the detectable languages** — You can also restrict the set of detectable languages. This is useful if when you know your audio files only contain English or Spanish audio. To restrict the set of detectable languages, use a multi-valued query parameter with the language codes as the values.
> For example, `detect_language=en&detect_language=es` will choose either English or Spanish as the detected language.

Precedence between `language` and `detect_language`, verbatim:

> **Interaction with `language` query parameter** — If the `language` parameter is set with a language option and `detect_language` is set to `true`, language detection will override the `language` option specified.

Corroborating, https://developers.deepgram.com/docs/language.md:

> When a specific language is set using the `language` parameter (e.g., `language=en`), Deepgram will only attempt to transcribe speech in that specified language. Speech in other, non-specified languages will not be transcribed. If you expect your audio to contain multiple languages and want Deepgram to transcribe across them, consider using `language=multi` with one of our [multilingual models](/docs/multilingual-code-switching).

**`detect_language` + `smart_format`: no documented caveat.** Smart Formatting is listed
as "All available languages" (https://developers.deepgram.com/docs/smart-format.md,
https://developers.deepgram.com/docs/stt-pre-recorded-feature-overview.md) and no
interaction with detection is described anywhere I could reach.

**`keyterm` + `smart_format`: one documented interaction** (https://developers.deepgram.com/docs/keyterm.md):

> When smart formatting is applied to the transcript, words that start sentences may be automatically capitalized regardless of keyterm formatting.

and

> Note that while the model was trained with formatted keyterms, the final transcription may not always exactly match the keyterm's formatting.

**Two `keyterm` traps worth re-checking against the code** (both from
https://developers.deepgram.com/docs/keyterm.md). The app currently sends one
`keyterm` query item per term, which is correct:

> **Do** — repeat the parameter for separate terms — `?keyterm=term1&keyterm=term2`
> **Don't** — add a weight or intensifier — `?keyterm=term:0.15`
> **Don't** — separate terms with a comma — `?keyterm=term1,term2`

> None of the **Don't** forms return an error—the API accepts the value and treats it as a single literal keyterm, so it silently boosts nothing instead of failing.

That silent-failure mode is the reason the "one `URLQueryItem` per term" approach must
never be refactored into a joined string.

Also relevant to the budget logic in `KeytermBudget.swift`: the docs give two different
ceilings in one page —

> Instantly increase accuracy and recognition of up to 100 important terminology, product and company names, industry jargon, phrases and more.

> Key Terms are limited to 500 tokens per request; anything beyond that will return an error like so:
> `Keyterm limit exceeded. The maximum number of tokens across all keyterms is 500.`

plus best-practice guidance "Stay well under the 500 token limit; focus on the most
important 20-50 terms". The app's choice of a 400-token budget (500 − 100 margin) and
`maxTerms = 100` is consistent with all three statements.

**Language-detection quirks that affect a dictation UI:**

> `language_confidence` is not supported for Whisper models and will not be included in the API response for Whisper requests.

> The `language_confidence` score can be used as a metric to determine whether the transcript is accurate. For example, if the `language_confidence` falls below a certain threshold, you may want to default to another language or reject the transcript.

> It is critical to know that the `language_confidence` score only takes into account the 35 supported languages.

**English spelling caveat** (https://developers.deepgram.com/docs/language.md) — matters
because the catalogue collapses `en-US`/`en-GB`/`en-AU`/`en-IN`/`en-NZ` into `en`:

> Transcription outputs from the English models are provided with standardized American spelling of words. For example, "color" will always be spelled as such with both `language=en-US` and `language=en-GB`, never using the British spelling "colour". If your use case requires a different spelling, you should perform post-processing on results in order to enforce your preferred spelling standard.

So collapsing the English variants loses nothing in output — the model returns American
spelling regardless of which English code is sent. The existing collapse is correct.

**`dictation` requires `punctuate`** (https://developers.deepgram.com/docs/dictation.md):

> The Punctuation feature must be enabled for Dictation to work. Be sure to add `dictation=true&punctuate=true` to your request.

Dictation is documented as "**English (all available regions)**" only, and the app's
`supportsSpokenPunctuation` gate matches that. Command list: period, comma, colon,
question mark, exclamation mark, new line, new paragraph.

**Model default mismatch (minor):** `/docs/model.md` says "`model` *string* Default:
`base-general`", while `/docs/pre-recorded-audio.md` says "Removing this parameter
defaults to `model=base`." The app always sends an explicit `model`, so this cannot bite.

---

## Confidence

### Claims resting on a direct quote (high confidence)

- Every quoted sentence, table row and price above, with its URL. All were fetched live
  during this session.
- The complete Nova-3 language row, the `nova-3-medical` row, and the `multi` member
  list (section B1–B3) — quoted verbatim from `/docs/models-languages-overview.md`.
- The 35-code `detect_language` list (B4) — verbatim bullet list; my count of the bullets
  (35) matches the doc's own statement "the 35 supported languages".
- `keyterm` is Nova-3-only on pre-recorded — two independent quotes (OpenAPI parameter
  description for `/v1/listen`, and `/docs/keyterm.md`), plus the inverse statement that
  `keywords` "is not supported with Nova-3 models".
- Flux is not pre-recorded capable — the `🚫` row in the Flux-vs-Nova-3 matrix, plus
  "Flux requires the `/v2/listen` endpoint — Using `/v1/listen` will not work with Flux",
  plus the AsyncAPI spec showing `/v2/listen` is `wss://` only.
- `multi` = code-switching and `detect_language` = auto-detect — distinct parameter names,
  distinct documented semantics, distinct response fields.
- All pricing figures in C1–C3, the keyterm add-on, the $200 credit, and true per-second
  billing — from enumerated rate rows in the pricing page payload and the page's own
  FAQ structured data.
- The two contradictory Nova-3 WER figures (54.2% vs 53.4%) — both quoted verbatim from
  the two different pages. The *contradiction* is a documented fact.
- The app's own current behaviour (10-language catalogue, `detect_language` restricted to
  it, `keyterm` one-item-per-term, 400-token budget) — read directly from the source files.

### Claims that are inference (medium confidence)

- **"Nova-3 is the best choice for this use case and nothing beats it."** Grounded in the
  quoted recommendations ("Our highest-performing general-purpose ASR", "Recommended for
  most use cases", the Flux matrix showing Nova-3 ✅ on pre-recorded and Flux 🚫), but
  Deepgram publishes no head-to-head benchmark for *short dictation utterances*, so this
  is my reading of their positioning, not a measurement.
- **`detect_language`, `dictation`, `numerals` and `punctuate` are included in the
  per-minute rate.** Inferred from their *absence* from the complete 5-row pre-recorded
  add-on table. The pricing page never says "included" for them explicitly; only Smart
  Formatting and Diarization carry the literal word "Included". The absence of a price
  row is strong but not affirmative evidence.
- **"Nova-2/Enhanced/Base have no published pre-recorded price."** I verified they are
  absent from every rate row in the pricing page payload. They may still be billable on
  legacy agreements; the FAQ only quotes *streaming* rates for them. Absence of a
  published rate is not proof of absence of a rate.
- **The silent-downgrade → lost-`keyterm` chain.** The model fallback ("Deepgram will
  automatically select the next highest model") and the `keyterm` restriction ("Only
  compatible with Nova-3") are each directly quoted. The *consequence* — that the
  dictionary silently stops working — is inference, because Deepgram does not document
  what happens to a `keyterm` parameter sent to a non-Nova-3 model.
- **The 105-code / 63-language counts in B1.** The row is quoted verbatim; the counts are
  my arithmetic on it, not a documented figure.
- **`de-CH` and `zh-HK` deserve separate rows.** Deepgram lists them as separate named
  languages; that Cantonese audio needs `zh-HK` rather than `zh` is my inference from the
  naming, not a quoted statement.

### Claims I could NOT verify

- **Any Nova-3 vs Nova-2 accuracy, WER or latency comparison.** No such table exists on
  the pages I could reach. The only published WER numbers are "compared to competitors"
  and mutually inconsistent between two Deepgram pages. The latency doc explicitly
  excludes batch ("This guide focuses exclusively on streaming"), so **there is no
  published pre-recorded latency figure for Nova-3 at all.**
- **Pricing impact of `mip_opt_out`.** The OpenAPI description says "Refer to our Docs for
  pricing impacts before setting this to true" but neither
  `/docs/the-deepgram-model-improvement-partnership-program.md` nor the pricing page
  states a price or a discount. Since this app handles personal dictation, whether
  opting out costs more is a real open question.
- **Whether `keyterm` errors or is silently ignored when Deepgram falls back to a
  non-Nova-3 model.** Documented nowhere I could reach. This is the highest-value
  empirical test.
- **`nova-3-atc`-style custom medical pricing** and any `nova-3-medical` specific rate.
  No rate row exists; presumably billed as Nova-3 Monolingual. Unconfirmed.
- **Whether the pre-recorded language list differs from the streaming list for Nova-3.**
  Deepgram publishes one undifferentiated Nova-3 row. The brief asked for the
  "pre-recorded" list specifically; the docs do not make that distinction, and I have
  flagged that rather than inventing a split.
- **`web_search`-only sources** (Deepgram blog, help centre, third-party benchmarks) were
  unreachable: `web_search` returns `HTTP 402 Insufficient Balance` on this machine. The
  developer docs and the marketing pricing page were fully reachable via `web_fetch`, so
  the gap is limited to external benchmarking content, not to Deepgram's own published
  facts.

### Page-existence note

`/docs/nova-3.md` and `/docs/deepgram-pricing.md` do **not** exist — both return HTTP 200
with a "Page Not Found" body, confirming the trap in the brief. The working equivalents
are `/docs/model.md` (model options and Nova-3 prose) and `/docs/models-languages-overview.md`
(languages). `/docs/flux.md` redirects to `/docs/flux/feature-overview.md`, and
`/docs/features-overview.md` redirects to `/docs/stt-streaming-feature-overview.md`
(not the pre-recorded one — `/docs/stt-pre-recorded-feature-overview.md` is the correct
pre-recorded matrix).
