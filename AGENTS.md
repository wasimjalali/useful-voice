# Useful Voice — agent notes

Cross-platform dictation app. macOS: Swift (`Sources/UsefulVoiceCore`,
`Sources/UsefulVoiceApp`). Windows: Electron + TypeScript (`windows/`, whose
`src/core` mirrors the Swift core). Transcription: Deepgram Nova-3 via
`POST /v1/listen`.

## Verification gates

- macOS: `make test` (Swift Testing suite) and `swift build`
- Windows: `cd windows && npm run verify` (typecheck + vitest + build +
  Electron self-test)
- Packaging smoke: `cd windows && npx electron-builder --win --dir`

## `ELECTRON_RUN_AS_NODE` gotcha

Agent shells (including Devin) may export `ELECTRON_RUN_AS_NODE=1`. With it set,
`electron` runs as plain Node and `import 'electron'` resolves to the empty
`electron:electron` pseudo-module — the self-test then dies before app code
with either a `cjsPreparseModuleExports` TypeError or
`SyntaxError: ... does not provide an export named 'app'`. Neither is an app
or Electron defect. Run Electron commands with the sentinel unset:

```sh
cd windows && env -u ELECTRON_RUN_AS_NODE npm run verify
```

## Screenshots without stealing focus

Any page can be rendered offscreen, at any window size, with no window and no focus change:

```sh
UV_START_SECTION=insights UV_SNAPSHOT="$PWD/ui-insights.png@1280x860" \
  dist/UsefulVoice.app/Contents/MacOS/Sadaa
```

`UV_START_SECTION` is a sidebar section's raw value (`home`, `languageMemory`, `insights`,
`scratchpad`, `history`, `settings`). Another running copy of the app makes the new process exit
immediately (single-instance guard), so quit it first. The pages show your real data, so keep
screenshots out of commits. Build the bundle first (`make bundle`). A snapshot run also creates
`usage-stats.json` in the real data folder if it does not exist yet, the same as a normal launch.

First-run flow: `UV_FIRST_RUN=force` opens it over the window and saves nothing: no completed flag,
engine, key, language, hotkey or download changes (downloads are not started or paused and the
download page shows sample progress). Real permission prompts still appear. The key check still
makes its network call. `UV_FIRST_RUN_STEP=<welcome|engine|deepgramKey|localDownload|microphone|accessibility|accessibilityOn|tryIt|tryItDone|tryItDownloading|tryItStopped|done|errKey|errDownload|errMic>`
jumps to a step with sample data and freezes polling, and combines with `UV_SNAPSHOT`:

```sh
UV_FIRST_RUN=force UV_FIRST_RUN_STEP=engine UV_SNAPSHOT="$PWD/fr-engine.png@1040x680" \
  dist/UsefulVoice.app/Contents/MacOS/Sadaa
```

A snapshot run skips the Keychain read at launch (it only needs to know a key exists).

## Repo conventions

- Squash-merge PRs (`gh pr merge --squash`); never commit to `main` directly.
- Audit reports live in `docs/audit/`; `00-findings-and-fixes.md` is the index.
- `windows/package-lock.json` is marked `-diff` in `.gitattributes`; inspect it
  with `python3 -c "import json; ..."` rather than `git diff`.
