# Useful Voice for Windows

Voice-to-text dictation for Windows, powered by Deepgram Nova-3. Press a hotkey,
speak, and the text appears wherever you are typing.

This is the Windows port of the macOS app in the repository root. Both share the
same design system, the same dictionary/language-memory model, and the same
Deepgram request shape, so a backup taken on one is readable by the other.

---

## What works, and how it was verified

Read this section before trusting anything else. The Windows app could not be run
on Windows during its development (the work was done on macOS), so the verification
is split by what is actually provable on each platform.

### Verified by execution

| Area | Evidence |
| --- | --- |
| All platform-free logic | `npm test`: **616 tests, 25 files**, run on macOS |
| Type safety | `npm run typecheck`: clean |
| Build | `npm run build`: main, preload and renderer all emitted |
| Preload↔renderer contract | `npm run self-test`: API exposed, 75 methods, no Node leak |
| Renderer loads under CSP | `npm run self-test`: shell paints, 5 nav items |
| Audio-capable recorder window | `npm run self-test`: `getUserMedia` and `AudioContext` present |
| Keyterm ceiling | `npm run self-test`: 400 terms compressed to 400 tokens, 384 dropped |
| Installer + portable packaging | `npm run dist`: real PE32 artifacts, icon embedded |
| Packaged entry point | `app.asar` contains `dist/main/index.js`, `preload`, `renderer` |

`npm run verify` runs typecheck → tests → build → self-test in one command.

### NOT verified: requires a Windows machine

These are honestly unverified. They are the parts that touch Windows itself:

- **Microphone capture and permission prompts** on a real device.
- **Global hotkey registration** and its behaviour when another app owns the
  combination.
- **Clipboard save/restore and Ctrl+V delivery** into Notepad, Word, browsers,
  Electron apps and terminals.
- **Tray icon rendering** at real Windows DPI settings.
- **The installer flow** (`Useful Voice-0.1.0-x64.exe`) and the portable build on a
  clean machine.
- **DPAPI key encryption** on a real user profile.

The self-test covers as much of this as can be checked off-Windows, but the list
above is the checklist for the first run on real hardware.

---

## Running it

```bash
cd windows
npm install
npm run verify      # typecheck + tests + build + self-test
npm start           # launch the app
```

Then open **Settings** and paste a Deepgram API key from
<https://console.deepgram.com/>. The key is required before dictation will work;
the app says so plainly rather than failing silently.

## Building installers

```bash
npm run dist            # NSIS installer + portable exe  -> release/
npm run dist:portable   # portable exe only
```

Artifacts land in `release/`:

- `Useful Voice-0.1.0-x64.exe`: per-user installer (no admin prompt) with a
  Start-menu shortcut and an uninstaller that **keeps your data**.
- `Useful Voice-0.1.0-portable.exe`: single file, no installation.
- `latest.yml`: the update feed the installed app reads (see below).

Releases are built by CI, not by hand: the `Windows release` workflow builds these, runs
`scripts/release.mjs` to make the release set (dashed file names, `install.ps1` pinned to the
installer's SHA-256, `SHA256SUMS-windows.txt`) and tests the one-line installer and an update
from an older build. Publishing is manual; see "Windows release" in
[docs/distribution.md](../docs/distribution.md).

### Updates

The installed app uses `electron-updater` with the GitHub provider: it reads `latest.yml` from
the newest release of `wasimjalali/useful-voice-releases` a minute after launch and then every
12 hours, downloads the installer in the background, checks its SHA-512 and installs it
silently when the app quits, or at once from the tray's "Restart to update". The portable exe,
development runs, `release/win-unpacked` (no uninstaller beside the exe), per-machine installs
under Program Files (they update by re-running the installer) and `--e2e` runs never check. "Restart to update" is greyed out while a dictation is running or held for retry; the
update still installs on the next Quit. Each install attempt is appended to `update.log` beside
`diagnostics.log`, so it survives the restart. Log lines go to `diagnostics.log` under
`[update]`.

### Code signing

The build works without a certificate; Windows SmartScreen will warn about an
unsigned installer. To sign, set `CSC_LINK` and `CSC_KEY_PASSWORD` (or
`WIN_CSC_LINK`/`WIN_CSC_KEY_PASSWORD`) and electron-builder will sign
automatically. `build.win.signtoolOptions.publisherName` is already set to
`Useful Build`.

`build.win.verifyUpdateCodeSignature` is `false` while builds are unsigned: with it on,
`app-update.yml` carries that publisher name and electron-updater refuses every unsigned
update. Turn it back on in the first signed release, never before: an installed build with it
on refuses every later update that is not signed by `Useful Build`.

---

## Architecture

```
windows/
  src/
    core/        platform-free TypeScript, no Electron, no Node, no DOM
    main/        Electron main process: key, files, hotkey, delivery
    preload/     the only bridge exposed to the renderer
    renderer/    UI, and the audio capture host
  tests/         vitest suites for src/core and the dictation state machine
  scripts/       renderer/preload bundling, icon generation
```

### Why `src/core` is separate

Everything in `src/core` is pure TypeScript with no Electron, Node or DOM imports.
That is what makes the entire test suite runnable on any machine, and it is why the
dictation state machine (where the subtle bugs live) is fully covered instead of
being assumed correct.

### Why audio capture happens in a hidden window

`getUserMedia` and the Web Audio API are browser APIs; Electron does not expose
them to the main process. So a hidden `recorder` window hosts capture, and the main
process asks for it over IPC. The renderer is served from `file://` under a strict
CSP with `contextIsolation` on and `nodeIntegration` off.

**The preload is deliberately CommonJS.** Electron's preload loader ignores
`"type": "module"`, so an ESM preload must be `.mjs`; a compiled `.js` preload
containing `import` statements fails to load and leaves a dead UI with no visible
error. `scripts/build-renderer.mjs` bundles the preload as CommonJS and asserts
that it did.

### Where the security boundary is

The renderer can call 75 named IPC channels and nothing else. It cannot read the
filesystem, and it can never read the API key. It can only ask whether one is
configured. The key is encrypted with DPAPI via Electron's `safeStorage`, so it is
unreadable from another Windows account or from a copy of the file on another
machine.

---

## Design decisions worth knowing

**Delivery never loses your text.** After a dictation the text is either pasted
into your app or left on the clipboard, never neither. Once the Ctrl+V keystroke
has gone out the dictation counts as pasted, and it stays on the clipboard: your
previous clipboard is not put back, because nothing proves the app has taken the
text yet and an app that is slow to respond would paste the old clipboard instead.
If you cancel before the keystroke, your previous clipboard comes back only when
nothing newer was copied meanwhile and it was captured exactly (text, HTML or RTF;
an image or a file list is not). Just before it sends the key, the paste checks that
Useful Voice is not the window in front (unless the dictation began in one of its text
fields) and that the clipboard still holds the dictation; if you copied something else in
the meantime, nothing is pasted, your copy is left alone and the dictation is saved in
Useful Voice. A paste that was already on its way when something went wrong counts as
pasted. Losing a dictation is worse than losing a clipboard.

**A silent recording is rejected.** A silent clip can make a speech model echo its
own prompt bias (your dictionary) back as a fake transcript. Clips whose peak
never crosses the speech threshold are refused with an explanation instead.

**The keyterm list is capped at 400 tokens per request.** Deepgram Nova-3 hard-fails
a request over 500 tokens across all keyterms, which would break *every* dictation
at once. The budget, with a safety margin, is enforced in code and checked by both
a test and the self-test.

**Edits are never silently discarded.** If a store cannot read its file at launch it
refuses to write, rather than starting empty and overwriting your data on the next
edit. Write failures surface in the UI.

---

## Keyboard and tray

- **Hotkey**: default `Control+Alt+Space`, changeable in Settings. Press to start,
  press again to stop. If another app already owns the combination the app tells
  you, instead of silently never starting.
- **Tray icon**: filled while recording. Left-click opens the window. The menu
  offers start/stop, cancel, retry, copy-last and the pages.
- **Closing the window does not quit.** The app is tray-resident so the hotkey keeps
  working. Quit from the tray menu.

## Data and privacy

Everything lives in `%APPDATA%\Useful Voice`:

| File | Contents |
| --- | --- |
| `settings.json` | preferences; the API key inside is DPAPI-encrypted |
| `data.json` | dictionary, corrections, shortcuts, history, notes |
| `diagnostics.log` | recent problems: never transcript text, never the key |

Audio is held in memory only while transcribing and is never written to disk. Each
recording's audio is uploaded to Deepgram for transcription, along with your
dictionary's correct spellings as keyterms. Nothing else leaves your PC, and there
is no analytics or tracking. Uninstalling keeps this folder on purpose; Settings
shows the path so you can remove it yourself.

## Known gaps

- **Not code-signed.** SmartScreen will warn until a certificate is configured.
- **Geist is not bundled.** The UI asks for Geist and falls back to Segoe UI, the
  same allowance the macOS build makes with SF Pro. Bundling the font files would
  remove the difference.
- **Paste confirmation is indirect.** Ctrl+V never clears the clipboard, so the app
  cannot see whether the target took the text: it reports "pasted" when the keystroke
  went out, and leaves the dictation on the clipboard so a second Ctrl+V works.
  Reading the target's text needs a UI-automation dependency, which was avoided so the
  app ships no native module.
