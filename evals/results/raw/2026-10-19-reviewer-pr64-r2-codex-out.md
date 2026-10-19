[
  {
    "finding": "F6 remains incomplete: Gemini accepts truncated transcripts.",
    "severity": "high",
    "file": "windows/src/core/transcription/geminiTranscribeProvider.ts",
    "line": 87,
    "scenario": "A MAX_TOKENS or SAFETY response containing text bypasses the failure check. A runtime probe confirmed that MAX_TOKENS returns the partial transcript as success, allowing it to be pasted without retaining the recording for Retry. Reject blocked or unfinished responses regardless of text length. Missing candidates also become silence despite the comment requiring STOP."
  },
  {
    "finding": "F5 remains incomplete: transcription response bodies reach diagnostics.",
    "severity": "high",
    "file": "windows/src/core/transcription/elevenlabsProvider.ts",
    "line": 120,
    "scenario": "A 400 response echoing private vocabulary becomes the error message. dictationService preserves it and index.ts:1297 writes it to diagnostics.log. A runtime probe confirmed the echoed content survives classification. Gemini has the same path. Keep the redacted detail for display if needed, but log structured provider/status/reason fields separately."
  },
  {
    "finding": "F4 misses timeouts while reading the formatter response body.",
    "severity": "low",
    "file": "windows/src/core/formatting/aiFormatter.ts",
    "line": 209,
    "scenario": "When headers arrive before the deadline but the body stalls, response.json() rejects on timeout and the catch reports malformed JSON. A runtime probe reproduced this. The Anthropic 400-body path similarly converts a body timeout to HTTP 400. Check cancellation and timeout signals around body reads."
  },
  {
    "finding": "Setup's advertised voice model can differ from the model used for practice.",
    "severity": "low",
    "file": "windows/src/main/index.ts",
    "line": 298,
    "scenario": "With Gemini or Parakeet selected, run setup again while a Deepgram key is already saved. The engine page says Deepgram Nova-3 is selected, but Continue skips firstrun:save-key, so practice still uses the saved model. Forced setup also keeps the saved model after accepting a temporary Deepgram key. Give practice an explicit model choice and preserve the normal selection."
  }
]

**DISMISSED**

- **F1:** Both formatter providers reject explicit truncation outcomes. Runtime probes passed. Anthropic token limits correctly clamp to 512–8192.
- **F2/F3:** Overlap rejection, marker rejection, curly-apostrophe preambles, leading-filler exemption and the unspaced-script character gate passed targeted runtime probes.
- **Key exposure:** Settings/preload responses expose presence flags, not saved keys. Provider/version IPC arguments are checked against allowlists. New extra-provider keys are refused when encryption is unavailable.
- **Conditional encryption fallback:** Mocking encryption availability changing after key admission produced plaintext on a later save. I haven’t established a reachable Windows transition, so I’m not counting that synthetic case as a defect.
- **F7/F8:** Removing the formatter provider’s key sets formatting Off. README privacy text describes cloud transcription, formatter text and vocabulary uploads.
- **Archive traversal/injection:** Version-derived paths and shell-free argument arrays prevent renderer-controlled paths or shell injection. Extraction preserves bsdtar’s default traversal protections by omitting `-P`. See the [upstream security documentation](https://raw.githubusercontent.com/libarchive/libarchive/master/tar/bsdtar.1).
- **Download lifecycle:** Interrupted downloads retain partials, ignored Range requests restart writes, extraction failures remove corrupt archives and verified models move by same-filesystem rename.
- **Worker fixes:** Parakeet errors carry the correct provider and avoid offline classification. Cross-version removal checks inflight and loaded versions. Exit, timeout and disposal paths settle pending requests.
- **Packaging/notices/E2E stub:** Native unpack globs and notices resources are configured. The About handler uses a fixed path. Parakeet E2E replaces downloads, extraction and worker startup.

Reviewed at `e045e42`; checkout unchanged. Targeted runtime probes ran without file writes. Full typecheck, Vitest, packaging and E2E weren’t run because dependencies aren’t installed in this read-only checkout.