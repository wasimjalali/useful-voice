# Local Whisper — manual test checklist (Apple Silicon)

Run through this once on a real machine before shipping. Target baseline: an
Apple M1 with 8 GB RAM. Steps marked **[8 GB]** specifically cover low-memory
behaviour.

Build a bundled app and run it — not `swift run` — so the packaged
`whisper.framework` path is what you're testing:

```bash
make bundle
open dist/UsefulVoice.app
```

## Model download and management

- [ ] Settings › Transcription: tap a **Whisper** model row. With no model
      downloaded, the row shows a download button, tapping it starts the download without
      switching engine, and dictation (on Deepgram) is unaffected. To see the error, pick a
      model, delete it, and dictate with the local engine still selected: it reports a clear
      "no model downloaded" error, never a silent failure.
- [ ] Download **large-v3-turbo**. Progress bar advances continuously; the row
      shows size-on-disk growing or a final size (~1.6 GB) when done.
- [ ] Interrupt a download mid-flight by turning Wi-Fi off, then retry. It
      resumes or restarts cleanly with no partial-file corruption error.
- [ ] Quit the app (Cmd-Q) mid-download and relaunch: the row offers **Resume
      download** and continues from the bytes already fetched (quit pauses the
      download and saves resume data, waiting up to 3 seconds). A force-quit or
      crash does not save resume data, so that download restarts from zero.
- [ ] After download completes, the row shows "Active" only **after** checksum
      verification. (If you want to see the failure path, corrupt the file in
      `~/Library/Application Support/UsefulVoice/models/` and re-run activation
      — it must refuse and surface an error.)
- [ ] Download **large-v3** (~3.1 GB). Both rows now list downloaded size;
      exactly one shows "Active".
- [ ] Delete large-v3: confirmation dialog appears; file disappears from
      `~/Library/Application Support/UsefulVoice/models/`; row returns to
      "Download 3.1 GB".
- [ ] Re-download after delete works end-to-end.
- [ ] Quit and relaunch: the active model and engine choice persist.

## Transcription — turbo (the default pick)

- [ ] English dictation (~15 s spoken): transcript inserts at cursor. Note how long
      transcription takes on an M1/8 GB for the record (no target set yet).
- [ ] Partial results appear in the HUD while transcribing.
- [ ] **Auto-detect** language: dictate English, then Persian — detected
      language follows the speech.
- [ ] Language pin = **Persian**: Persian dictation transcribes correctly;
      Persian text inserts with correct RTL text.
- [ ] Dari is not in the language list: pin **Persian** and dictate Dari
      speech; it transcribes without error.
- [ ] Local transcripts come back punctuated and capitalized without any toggle.
- [ ] Dictionary word taught (a name or specialist spelling): correction
      applies to local transcripts.
- [ ] Fix-a-recurring-mistake correction applies to local transcripts.

## Transcription — large-v3 (heavier model)

- [ ] Activate large-v3 and dictate English: completes without crash or hang.
      Slower than turbo is expected and fine.
- [ ] **[8 GB]** Watch memory pressure in Activity Monitor during a ~30 s
      dictation: no sustained red pressure, no swap storm that wedges the app.
- [ ] Persian dictation on large-v3 works.

## Engine switching and regression

- [ ] Mid-session switch: dictate on Whisper, switch to Deepgram in Settings,
      dictate again — the second dictation uses Deepgram (visible by behaviour/
      diagnostics) and no audio or text from the first dictation is lost.
- [ ] Switch back to Whisper; dictate; still works.
- [ ] The menu-bar Auto-format item hides while Whisper is the engine.
- [ ] The model unloads after switching to Deepgram and after 10 idle minutes
      (memory drops in Activity Monitor).
- [ ] Deepgram regression: existing dictation, formatting, dictionary keyterms,
      and the **Test connection** probe all still work. API key flow unchanged (Settings
      still shows the key field, key lives in Keychain only).
- [ ] Retry path: Library › reprocess a retained recording under each engine.
- [ ] Error paths: local selected + model deleted → graceful error, no crash;
      Deepgram selected + no key → existing key flow shown.

## Packaging

- [ ] `dist/UsefulVoice.app` launches from Finder (double-click), not just from
      a terminal — proves `whisper.framework` resolves inside the bundle.
- [ ] `codesign --verify --strict --verbose=2 dist/UsefulVoice.app` passes.
- [ ] No crash reports in Console.app from a dyld/loader failure.

## Real session

- [ ] Do a real ~5-minute dictation session (notes, a message, some Persian
      mixed in if you speak it) on turbo. Confirm it feels like the Deepgram
      experience: tap, talk, text lands.
