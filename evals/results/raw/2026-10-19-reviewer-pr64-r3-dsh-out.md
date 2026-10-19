Read-only review of the PR head `8c73deb`. Worktree clean, nothing edited.

## S1-S7 verdict

Windows implements all seven shared rules, matching the macOS code:

- **S1** `geminiTranscribeProvider.ts:79-92` requires a first candidate with `finishReason == "STOP"` and no `blockReason`; everything else throws "Gemini didn't return a complete transcript.", the audio is retained (`dictationService.ts:690-693`), and STOP with no text is silence. Matches `GeminiTranscriptionProvider.swift:171-172`.
- **S2** The only transcript log is `transcriptionLogLine` (`dictationService.ts:1030-1035`), used at `:689`; the status handler logs the kind (`index.ts:1313-1314`). Body excerpts stay in the user message and are redacted before truncation (`deepgramProvider.ts:343-347`).
- **S3** `formatterGuard.ts:10-12,38-40` gives the word-boundary preamble and filler-exempt input; `aiFormatter.ts:224,230` treats a missing finish/stop reason as `truncated`; `<>` stripped in both prompts.
- **S4** `formatterGuard.ts:62-68`: Han, Kana, Thai, Lao, Khmer, Myanmar, six code points, Hangul excluded.
- **S5** `aiFormatter.ts:213-219` maps a timeout during the body read to `timeout`; `dictationService.ts:751-757` logs it.
- **S6** exact copy, always under the list: `models.ts:229`, `SettingsPage.swift:234`.
- **S7** `selection.ts:24-28`, `models.ts:49-53,109-113`: unreadable key shows Add key / Off; logged once (`index.ts:388-391`); the formatter throws `noKey` and the dictation goes out plain.

## Findings

1. **HUD names Deepgram whatever the chosen provider is.** severity: low. `windows/src/core/hudModel.ts`, 254-263. Scenario: Gemini audio with its key removed shows "Add your Deepgram key" in the HUD while the window banner correctly says "No Gemini key"; a Parakeet model that isn't downloaded also tells the user to add a Deepgram key; ElevenLabs out-of-credits shows "Deepgram credit is used up". macOS uses the failing provider (`HUDDisplay.swift:99-104,120-121`).

2. **ElevenLabs out-of-credits is reported as a rejected key.** severity: low. `windows/src/core/transcription/elevenlabsProvider.ts`, 111-119. Scenario: Scribe answers 401/403 with `quota_exceeded`; Windows says "ElevenLabs rejected your API key" with no retry, while macOS maps it to out of credits (`ElevenLabsProvider.swift:125-130`). A 403 permission problem gets the same wrong copy.

3. **A new provider key is reported saved before the write finishes.** severity: low. `windows/src/main/settingsStore.ts`, 225-245; `windows/src/main/index.ts`, 1625-1642. Scenario: `setKey`/`clearKey` fire `void this.save()` and the handlers return success, so a write that fails after the lock retries (disk full, AV lock) still toasts "Saved" or "Key removed". The key disappears on relaunch, or a removed key comes back. `firstrun:save-key` awaits and reports.

4. **An unreadable key is reported as "Dictations aren't being saved".** severity: low. `settingsStore.ts`, 121-133; `index.ts`, 2050-2053. Scenario: `settings.json` copied from another Windows account; load sets `saveError`, `app:save-status` returns not-ok, and the banner claims dictations aren't being saved although `data.json` saves normally. S7 only wants Add key plus one log line.

5. **First run applies a model recomputed at Continue, not the one shown.** severity: low. `index.ts`, 1741-1752; `firstRun.ts`, 337-350. Scenario: saved model is `deepgram:nova-3-medical`; open Run setup again; a Parakeet download started earlier completes under the overlay and saves `parakeet:v2`; the card still says "Deepgram Nova-3 Medical" but Continue applies `deepgram:nova-3`. The renderer also swallows an apply-engine failure and moves on.

6. **First run still says local models are "Coming to Windows".** severity: low. `firstRun.ts`, 538-567. Scenario: a privacy-minded new user sees two disabled Whisper rows and "Deepgram receives your audio" while this PR ships Parakeet v2/v3 in Settings. The copy predates the round-2 commits, but the PR makes it false.

7. **Two Parakeet language sources.** severity: low. `parakeetLanguages.ts:1-26` and `parakeetSupport.ts:12-50`. Same 25 codes, two different refusal messages, and the underscore handling differs; only the router's copy can currently reach a user.

## DISMISSED

- **Silent provider fallback**: the router throws `notConfigured` and never falls through (`transcriberRouter.ts:44-78`). A stale id falls back to Nova-3 in `currentVoiceModel`, but ids are normalised on load and update (`settingsBounds.ts:83-85`) and the test pins that behaviour.
- **Audio to an unchosen cloud provider**: the router checks the chosen provider's own key and sends only to it; Parakeet calls no `fetch`.
- **Key in URL/log/renderer**: all four providers keep keys in headers; the renderer gets booleans only (`settingsStore.ts:208-216`, `preload/types.ts:90-96`); the e2e log records URL and method only (`e2eStub.ts:30-40`).
- **Deepgram `classifyHttpError` called without the key** (`deepgramProvider.ts:510`): its message is never logged, the saved key is in the global secret source, and first-run key-check messages are discarded.
- **Pending switch before Parakeet states load**: `models.ts:82-92` can leave `pendingVoiceModel` set, but the state IPC resolves in milliseconds and a later click works; not reachable by a person.
- **`I have'nt` boundary**: Windows treats the apostrophe as a boundary, macOS does not (`formatterGuard.ts:10` vs `AIFormatter.swift:63-66`). Contrived, both reject or accept sanely.
- **Deepgram plaintext fallback while DPAPI is unavailable**: pre-existing and warned in the file; the r2 fix correctly protects the extra keys (`settingsStore.ts:350-365`).
- **`hasCandidate` requiring a string `blockReason`**: matches the API's shape; a non-string would already be a malformed response.
- **`firstrun:save-key` no longer setting the model**: correct; Continue applies it and the e2e test pins both the medical and the ElevenLabs cases.

**Gates not run**: vitest could not start under the read-only sandbox (EPERM writing `vitest.config.ts.timestamp-*`). I read the tests and ran an in-memory regex probe for S3/S4 (preamble, fillers, Han/Thai/Korean counts), which matched the macOS implementations case for case.