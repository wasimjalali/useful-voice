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

Agent shells (Claude Code, Codex) may export `ELECTRON_RUN_AS_NODE=1`. With it set,
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
UV_START_SECTION=insights UV_SNAPSHOT="$PWD/verify/<branch>/ui-insights.png@1280x860" \
  dist/UsefulVoice.app/Contents/MacOS/Sadaa
```

`UV_START_SECTION` is a rail section's raw value (`stream`, `notes`, `vocabulary`, `insights`,
`settings`; the old `home`/`history`, `scratchpad` and `languageMemory` still map). `UV_APPEARANCE=light|dark` overrides the Appearance setting
for the render and saves nothing. A snapshot run skips the single-instance guard, the status item and
(unless `UV_FIRST_RUN=force`) the first-run flow, so it runs beside your installed copy. The pages show your real data, so keep
screenshots out of commits: put them in `verify/<branch>/` (gitignored). Build the bundle first (`make bundle`). A snapshot run also creates
`usage-stats.json` in the real data folder if it does not exist yet, the same as a normal launch.
To render fixture data instead of yours, point both `HOME` and `CFFIXED_USER_HOME` at a scratch
folder that holds `Library/Application Support/Sadaa/` (setting `HOME` alone still reads the real folder).

Snapshot-only state hooks (they act only when `UV_SNAPSHOT` is set):

| Variable | Values |
|---|---|
| `UV_STREAM_SAMPLE` | `1` (sample dictations), `empty`, `deleted`, or a count |
| `UV_STREAM_QUERY`, `UV_STREAM_SCOPE` | a search, a filter chip |
| `UV_STREAM_PREVIEW` | `selected`, `original`, `focus`, `select`, `dialog`, `toast`, `teach`, `note`, `menu`, `datejump` |
| `UV_DOCK_STATE` | `idle`, `recording`, `silence`, `transcribing`, `local`, `doneHotkey`, `doneWindow`, `errorMic`, `copied`, `offline` |
| `UV_STATUS_POPOVER` | `1` opens the status popover |
| `UV_BANNER` | `mic`, `accessibility`, `keyMissing`, `keyInvalid`, `offline`, `modelMissing` |
| `UV_VOCAB_FILTER` | `all`, `words`, `fixes`, `snippets`, `suggestions` |
| `UV_INSIGHTS_RANGE`, `UV_INSIGHTS_FIXTURE` | `7d`/`30d`/`all`; `empty`/`firstWeek`/`full` |
| `UV_SETTINGS_ANCHOR`, `UV_SETTINGS_STATE` | a group id; `noKey`, `invalidKey`, `confirmDelete` |
| `UV_HUD_STATE` | `recording`, `recordingLoud`, `silence`, `transcribing`, `local`, `localFa`, `inserting`, `done`, `doneSaved`, `copied`, `cancelled`, `errorNetwork`, `errorMic`, `language`, `picker` (renders the HUD alone; try `480x210`, picker `360x440`) |
| `UV_MENU_HEADER` | `idle`, `recording` (the menu bar header row, `260x76`) |

`UV_PREVIEW_FEATURES=1` shows controls whose backend has not shipped (Correct this one, delete
with Undo, hotkey capture).

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

- Squash-merge PRs (`gh pr merge <n> --squash --delete-branch`); never commit to `main` directly.
- Audit reports live in `docs/audit/`; `00-findings-and-fixes.md` is the index.
- `windows/package-lock.json` is marked `-diff` in `.gitattributes`; inspect it
  with `python3 -c "import json; ..."` rather than `git diff`.
