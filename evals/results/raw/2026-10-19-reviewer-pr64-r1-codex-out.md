```json
[
  {
    "finding": "Token-truncated formatter responses are accepted and pasted. Check completion status before applying the length guard, and fall back to the raw transcript when generation was truncated.",
    "severity": "high",
    "file": "windows/src/core/formatting/aiFormatter.ts",
    "line": 203,
    "scenario": "An Anthropic response with stop_reason='max_tokens' and 60% of the original text passes the guard. Reproduced with a 25,500-character input: formatting returned 15,299 characters, silently dropping 10,201 characters from delivery. The 4,096-token ceiling makes this reachable on long dictations."
  },
  {
    "finding": "Formatter HTTP errors can persist dictation text in diagnostics. redact() removes the API key but retains arbitrary response-body content, which dictationService logs verbatim. Log a fixed reason and HTTP status instead.",
    "severity": "high",
    "file": "windows/src/core/formatting/aiFormatter.ts",
    "line": 194,
    "scenario": "A provider returns a validation error containing rejected input text. Reproduced with HTTP 400 and error.message='Invalid request content: <transcript>': the resulting FormatterError contains the transcript, and dictationService.ts:742 forwards it into diagnostics.log. The log is also exposed through app:diagnostics."
  },
  {
    "finding": "New provider keys silently fall back to unencrypted storage without updating the encryption warning. The UI still claims they're encrypted with the Windows account.",
    "severity": "high",
    "file": "windows/src/main/settingsStore.ts",
    "line": 336,
    "scenario": "With safeStorage.isEncryptionAvailable() false, save a Gemini key. Reproduced: providerKeys.gemini contains reversible base64 with plaintext=true, while isApiKeyEncrypted remains true and saveError is null. Unlike the Deepgram path, the new loop never propagates plaintextFallback into plaintextKeyWarning. Refuse the save or surface the fallback accurately."
  },
  {
    "finding": "Deleting either Parakeet version kills the shared worker even when it's transcribing with the other version.",
    "severity": "low",
    "file": "windows/src/main/parakeet.ts",
    "line": 181,
    "scenario": "Both versions are downloaded. Start a v3 dictation, then delete unused v2 in Settings. Reproduced: remove('v2') kills the v3 worker and rejects its pending recognition with 'engine stopped unexpectedly'. Only stop a worker that's using the model being removed."
  },
  {
    "finding": "The new third-party notices aren't included in the Windows package or accessible through the app, leaving the required NVIDIA attribution unavailable to installed users.",
    "severity": "low",
    "file": "windows/package.json",
    "line": 48,
    "scenario": "Build the installer using the declared files globs: they include dist and package.json, but not windows/THIRD_PARTY_NOTICES.md. The renderer's About group only exposes version and release links. Downloading Parakeet provides no in-app attribution path. Package the notices and expose them."
  },
  {
    "finding": "The local-model E2E test starts real model downloads because the E2E fetch stub doesn't intercept GitHub.",
    "severity": "low",
    "file": "windows/e2e/models.spec.ts",
    "line": 310,
    "scenario": "The test clicks the Parakeet row, which invokes the real downloader, then injects simulated progress events. Reproduced against installProviderStubs: the archive URL reaches the underlying fetch. The test can download roughly 480 MB per model and race real download failures against its injected states. Stub the download lifecycle before clicking."
  }
]
```

Anthropic documents `max_tokens` as a truncated response requiring explicit handling. [Stop reason documentation](https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons#max_tokens).

**DISMISSED**

- **Stored keys returned to the renderer:** settings responses expose presence booleans. I found no bridge method that returns saved plaintext keys.
- **Keys in request URLs:** the new provider and formatter requests authenticate through headers.
- **Request shapes:** the catalog matches the amended choices. Scribe uses multipart fields and filtered keyterms. Gemini uses inline WAV and bounds base64 size. Anthropic omits temperature, uses the specified thinking modes and retries once without thinking after a matching 400.
- **Ordinary formatter failure losing dictation:** missing keys, rejected output, network errors and deadlines fall back to raw text. Cancellation checks prevent late delivery.
- **IPC path injection:** provider names and Parakeet versions are allowlisted before reaching storage or filesystem paths.
- **Archive traversal and shell injection:** extraction uses an argument array without a shell. The Windows bsdtar invocation doesn't enable `-P`, which disables its default traversal protections. [bsdtar security documentation](https://man.freebsd.org/cgi/man.cgi?query=tar&sektion=1&format=html).
- **Partial models marked ready:** extraction uses a staging directory, verifies required files and writes a manifest before renaming into place. Ignored Range requests restart the file; 416 clears the partial.
- **Worker crashes hanging requests indefinitely:** exit handling rejects pending requests, and recognition timeouts stop the worker.

Verified five scenarios with read-only, in-memory checks using mocked I/O. `git diff --check` passed. Full build, test suite, packaging and live UI checks weren't run; this checkout has no installed dependencies. No files changed.