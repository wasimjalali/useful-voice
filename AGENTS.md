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
  built app with `--e2e --uv-data-dir=<scratch>`: hidden windows, fixture data, no tray or
  global hotkeys). `E2E_OUT=<dir>` moves the HTML report, traces, videos and screenshots
  (default `windows/e2e-results/`). CI runs it on `windows-latest` and uploads the report.
  The video needs Playwright's ffmpeg (`npx playwright install ffmpeg`); without it Playwright never
  resumes the windows and they hang blank, with no error.
- Windows first run (`components/firstRun.ts`, gate in `core/firstRun/gate.ts`): `--force-first-run` shows it and
  saves nothing (settings.json and data.json frozen for the whole process); `--first-run-step=<welcome|engine|errKey|deepgramKey|microphone|errMic|tryIt|tryItDone|done>`
  jumps to a step with sample data. Under `--e2e` only, `main/e2eStub.ts` fakes Deepgram (a key starting `valid` works,
  `offline` fails like a dead network, anything else is a 401) and Chromium's fake microphone is on. E2E fixtures seed
  `firstRunCompleted: true` unless a spec asks otherwise (`e2e/first-run.spec.ts`).
- Windows dictation E2E (`e2e/dictation.spec.ts`, `e2e/hud-a11y.spec.ts`, helpers in `e2e/harness.ts`): real recordings from the
  fake microphone through the e2e stub. Under `--e2e` main exposes `globalThis.__uv` (`index.ts`) and `globalThis.__uvTray.menu()`
  (`tray.ts`, the menu the tray would show, since no icon is created). Chromium's fake microphone beeps all the time, so a
  silence-limit spec swaps the recorder window's `getUserMedia` for a scripted tone (`useScriptedMicrophone`). The shortest
  limits the app allows are 15 s of silence and 30 s of recording, so those two specs take 20 s and 35 s. Never press the
  hotkey to completion in a spec: it would paste into whatever is in front of the machine.
- App-aware E2E: `e2e/app-aware.spec.ts` drives whole hotkey dictations through a scripted desktop. `__uv.useFakeDesktop({foreground:{processName,title}, address, textBefore, foregroundAfterPaste, focusMovesBeforeKey})` replaces who is in front, the browser page and the text before the caret; pastes, typed text and send keys are recorded in `__uv.fakeCalls()` and never sent (a send key to a different focused field is recorded as `sendKeyBlocked`). `__uv.fakeDesktop(patch)` changes the scripted state mid-dictation, `__uv.setTranscript(text)` sets what the Deepgram stub returns, `__uv.ownProcess()` gives our own process.

## Windows renderer layout

`windows/src/renderer/`: `renderer.ts` (entry) wires `shell.ts` (rail, header, banners,
navigation with `navigate(page, anchor?)`) to `pages/{stream,notes,vocabulary,insights,settings}.ts`;
shared pieces live in `components/` and styles in `styles/` (`tokens.css` with the
`[data-theme]` light and dark blocks, `components.css`, `components/*.css`, `pages/*.css`; the
build concatenates every file in that order). `hud.ts` draws the HUD and floating language
picker windows. `--preview-features` shows controls whose backend has not shipped
(`components/flags.ts`).

App-aware formatting on Windows lives in `src/core/apps/appAwareness.ts` (context capture, formatter wrapper,
settings normalisers, send key), `src/core/apps/ownField.ts`, `src/core/apps/serialSave.ts`, `src/main/desktop.ts`,
`src/core/delivery/deliveryFlow.ts` (auto-send step) and `renderer/pages/settings.ts` (the Apps group). On macOS the
settings are one JSON UserDefaults key, `appFormatting` (`AppFormattingSettings`); the controller scenarios are in
`Tests/UsefulVoiceCoreTests/AppAwareDictationTests.swift`. The text before the cursor is read at the press (macOS caps
the read at 150 ms), kept in memory only. On both platforms a dictation into Useful Voice's own window carries no appID,
category, cursor read or category formatting and never presses a send key; a hotkey press with Useful Voice in front
pastes only into a focused editable field of ours, otherwise it's copied.

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
  dist/UsefulVoice.app/Contents/MacOS/UsefulVoice
```

`UV_START_SECTION` is a rail section's raw value (`stream`, `notes`, `vocabulary`, `insights`,
`settings`; the old `home`/`history`, `scratchpad` and `languageMemory` still map). `UV_APPEARANCE=light|dark` overrides the Appearance setting
for the render and saves nothing. A snapshot run skips the single-instance guard, the status item and
(unless `UV_FIRST_RUN=force`) the first-run flow, so it runs beside your installed copy. The pages show your real data, so keep
screenshots out of commits: put them in `verify/<branch>/` (gitignored). Build the bundle first (`make bundle`). A snapshot run also creates
`usage-stats.json` in the real data folder if it does not exist yet, the same as a normal launch.
To render fixture data instead of yours, point both `HOME` and `CFFIXED_USER_HOME` at a scratch
folder that holds `Library/Application Support/UsefulVoice/` (setting `HOME` alone still reads the real folder).

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
| `UV_SETTINGS_ANCHOR`, `UV_SETTINGS_STATE` | a group id (`apps` opens Settings > Apps); `noKey`, `invalidKey`, `confirmDelete` |
| `UV_HUD_STATE` | `recording`, `recordingLoud`, `silence`, `transcribing`, `local`, `localFa`, `inserting`, `done`, `doneSaved`, `copied`, `copiedAppChanged`, `lineBreaks`, `cancelled`, `errorNetwork`, `errorMic`, `errorTimedOut`, `errorSecure`, `language`, `picker` (renders the HUD alone; try `480x210`, picker `360x440`) |
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
  dist/UsefulVoice.app/Contents/MacOS/UsefulVoice
```

A snapshot run skips the Keychain read at launch (it only needs to know a key exists).

## Identity and the one-time migration

The app is `ai.useful.voice` (executable `UsefulVoice`, data in `~/Library/Application Support/UsefulVoice/`,
Keychain service `ai.useful.voice`), signed by `make bundle` with the self-signed "Useful Voice Release"
certificate. Never create a new one: a new certificate resets every user's Accessibility and Microphone grants.
On another Mac, import the `.p12` from the password manager (`scripts/setup-signing.sh` prints how).
The rename itself needs one Accessibility and Microphone re-grant per user (macOS keys those grants to the bundle id);
the existing "Accessibility is off" banner already shows until it is done, so there is no extra notice.
Builds before the rename were `ai.karko.sadaa` with data in `Sadaa/`; `Sources/UsefulVoiceCore/Migration/IdentityMigration.swift`
moves the files, preferences and Keychain item once at launch (snapshot and `UV_FIRST_RUN=force` runs never migrate; they read
`Sadaa/` while it still holds data). An old-identity copy still running is asked to quit first; if it stays, the app shows an
alert ("An older copy of Useful Voice is still running") and exits before any store, hotkey tap or write, and the next launch
migrates. If `Sadaa/` is a symbolic link and `UsefulVoice/` already exists, the link cannot be renamed, so the app keeps using the
`Sadaa` link for good (even when its target is unmounted), logged once; with no `UsefulVoice/` the link itself is renamed.
`UV_MIGRATE_ONLY=1` runs only the migration, prints a JSON summary and exits. It refuses to start (exit 2) unless
`CFFIXED_USER_HOME` points at a scratch home (it moves real files) AND `UV_MIGRATION_TEST_PREFIX` is non-empty (it must never
touch the production Keychain or preferences). The prefix covers only the defaults domains and Keychain services; files follow
the scratch home. Two further hooks work only with migrate-only plus a prefix: `UV_MIGRATION_TEST_SEED_KEY=<dummy>` stores a
dummy key under the prefixed old service (an item the app made itself reads without a Keychain prompt), and
`UV_MIGRATION_TEST_EXPECT_KEY=<dummy>` adds `newKeyMatches` (a boolean, never the key) to the summary. No environment variable
controls the old-copy handling. `scripts/e2e-identity-migration.sh <app bundle> <source data folder> <out dir>` runs the whole
thing on a copy of a data folder (it refuses a source containing symbolic links) and writes a counts-only report.
Windows keeps `%APPDATA%\Useful Voice`; `build.nsis.guid` is pinned to the old appId's GUID so installers upgrade in place
(the `windows-upgrade` CI job proves it).

## Repo conventions

- Squash-merge PRs (`gh pr merge <n> --squash --delete-branch`); never commit to `main` directly.
- Audit reports live in `docs/audit/`; `00-findings-and-fixes.md` is the index.
- macOS releases: `node scripts/release-mac.mjs --version X.Y.Z` writes the zip, DMG, `appcast.xml`,
  `install.sh` and a release notes draft to `dist/release`; publishing is manual (`docs/distribution.md`).
- Public source goes out as one snapshot per release: `node scripts/publish-source.mjs --clone <usefulvoice clone> --version X.Y.Z [--push]`
  (see `docs/distribution.md`). A file that must never be public goes in its `EXCLUDE` list. In-app release
  links stay hidden until `releasesRepoLive` (macOS `ReleaseLinks.swift`, Windows `core/releaseLinks.ts`) is on.
- `windows/package-lock.json` is marked `-diff` in `.gitattributes`; inspect it
  with `python3 -c "import json; ..."` rather than `git diff`.
