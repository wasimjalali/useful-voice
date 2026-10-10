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
- Windows E2E: `cd windows && env -u ELECTRON_RUN_AS_NODE npm run e2e` (Playwright drives the
  built app with `--e2e --user-data-dir=<scratch>`: hidden windows, fixture data, no tray or
  global hotkeys). `E2E_OUT=<dir>` moves the HTML report, traces, videos and screenshots
  (default `windows/e2e-results/`). CI runs it on `windows-latest` and uploads the report.

## Windows renderer layout

`windows/src/renderer/`: `renderer.ts` (entry) wires `shell.ts` (rail, header, banners,
navigation with `navigate(page, anchor?)`) to `pages/{stream,notes,vocabulary,insights,settings}.ts`;
shared pieces live in `components/` and styles in `styles/` (`tokens.css` with the
`[data-theme]` light and dark blocks, `components.css`, `components/*.css`, `pages/*.css`; the
build concatenates every file in that order). `hud.ts` draws the HUD and floating language
picker windows. `--preview-features` shows controls whose backend has not shipped
(`components/flags.ts`).

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

`UV_START_SECTION` is a sidebar section's raw value (`home`, `languageMemory`, `insights`,
`scratchpad`, `history`, `settings`). `UV_APPEARANCE=light|dark` overrides the Appearance setting
for the render and saves nothing. A snapshot run skips the single-instance guard, the status item and
(unless `UV_FIRST_RUN=force`) the first-run flow, so it runs beside your installed copy. The pages show your real data, so keep
screenshots out of commits: put them in `verify/<branch>/` (gitignored). Build the bundle first (`make bundle`). A snapshot run also creates
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

- Squash-merge PRs (`gh pr merge <n> --squash --delete-branch`); never commit to `main` directly.
- Audit reports live in `docs/audit/`; `00-findings-and-fixes.md` is the index.
- `windows/package-lock.json` is marked `-diff` in `.gitattributes`; inspect it
  with `python3 -c "import json; ..."` rather than `git diff`.
