# Useful Voice

**Type with your voice, anywhere on your Mac.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)](https://swift.org)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20Windows%2010%2B-lightgrey)

Useful Voice is a fast, personal dictation app for macOS and Windows. Tap a hotkey in any app, speak, and the text lands at your cursor. Pick your engine: Deepgram Nova-3 in the cloud, or a Whisper model that runs entirely on your Mac.

<!-- Hero screenshot goes here once the owner approves captures made with synthetic data. -->

## What you get

**Dictate anywhere.** Tap your key (Right Command by default), speak, tap again. The text is inserted at your cursor. If the insert can't be confirmed, the text stays on your clipboard, so a missed insert is one paste away. Esc cancels. Recording stops by itself after 60 seconds of silence.

**It lands where you started.** The app, window and text field you were in when you pressed the key are locked in. If you click elsewhere while it transcribes, Useful Voice brings that field back before it pastes. If it can't (the app quit, say), it pastes nowhere else: the text stays on your clipboard. Settings > Pasting chooses whether your old clipboard comes back after a paste, and which apps get the text typed out as keystrokes instead (for terminals and apps that block paste).

**Teach it your words.** Add names and specialist spellings to your dictionary. They help recognition and fix casing on your Mac. Add a "sounds like" form and misheard variants are rewritten after transcription. Fix a recurring mistake once and it stays fixed.

**Keep what you said.** Notes are local and searchable, with pins, tags and Markdown copy. Your dictation history keeps every transcript, and Insights shows words, time saved and your streak.

**Your engine, your call.** Use Deepgram Nova-3 for fast cloud transcription. Or run Whisper large-v3-turbo (recommended) or large-v3 on your Mac, with no API key and no audio leaving your device. Both handle 99 languages with auto-detect.

## Before you install

| | |
|---|---|
| Works on | macOS 14 or later on Apple silicon. Windows 10 or later (see [windows/README.md](windows/README.md) for what's verified there) |
| Engines | Deepgram Nova-3 (cloud). On macOS also local Whisper large-v3-turbo and large-v3. The Windows app uses Deepgram |
| Stays on your device | Your dictionary, notes, history, settings and, on macOS, the last 10 recordings. Your Deepgram key sits in the macOS Keychain (Windows: encrypted with DPAPI). With a local Whisper model, your audio never leaves your Mac |
| Leaves your device | With Deepgram, each recording's audio goes to Deepgram, plus up to 400 tokens of your dictionary words, fix results and snippet triggers as keyterms. "Sounds like" forms stay on your Mac. Picking a local model downloads its weights from Hugging Face |
| Tracking | None. No analytics, no crash reports, no ads |
| Updates | Windows: the installed app asks GitHub for a newer release twice a day, downloads it and installs it when you quit or pick Restart to update in the tray. The Mac app doesn't check yet |

## Install

Build it from source today. Clone this repository and run these in its folder. You need macOS 14 or later, Apple silicon and the Command Line Tools (full Xcode isn't needed).

```sh
make bundle                  # builds dist/UsefulVoice.app (ad-hoc signed on your Mac)
open dist/UsefulVoice.app
```

One-line installers and a downloadable app arrive with v0.1.0, the first release.

On first launch a short setup walks you through your engine, the microphone and Accessibility. Deepgram gives new accounts $200 in free credit, and setup links to the signup. You can run the setup again from Settings.

Windows builds from source too. See [windows/README.md](windows/README.md).

## Development

Everything below is for working on Useful Voice itself.

| Platform | Check |
|---|---|
| macOS | `make test` (Swift Testing suite) and `swift build` |
| Windows | `cd windows && npm run verify` (typecheck, vitest, build, Electron self-test) |
| Windows packaging | `cd windows && npx electron-builder --win --dir` |
| Windows E2E | `cd windows && env -u ELECTRON_RUN_AS_NODE npm run e2e` |

Use `make test`, not bare `swift test`. The Makefile adds the framework paths Swift Testing needs under the Command Line Tools.

The code is split in three:

- `Sources/UsefulVoiceCore` is the testable core: settings, providers, audio, the dictionary, language memory, history and the dictation pipeline.
- `Sources/UsefulVoiceApp` is the macOS app: menu bar, HUD, hotkey, text insertion and the pages.
- `windows/` is the Electron and TypeScript app. Its `src/core` mirrors the Swift core.

The design notes and audit reports are in [docs/audit](docs/audit), starting with [00-findings-and-fixes.md](docs/audit/00-findings-and-fixes.md). Release and source publishing are covered in [docs/distribution.md](docs/distribution.md).

## License

[MIT](LICENSE). Contributions are welcome as pull requests, and there's no CLA to sign.

Third-party code and models are listed in [windows/THIRD_PARTY_NOTICES.md](windows/THIRD_PARTY_NOTICES.md). The optional AI cleanup, hidden and off by default, uses S1-mini by Superwhisper (Apache 2.0).
