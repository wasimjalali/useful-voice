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

## Repo conventions

- Squash-merge PRs (`gh pr merge --squash`); never commit to `main` directly.
- Audit reports live in `docs/audit/`; `00-findings-and-fixes.md` is the index.
- `windows/package-lock.json` is marked `-diff` in `.gitattributes`; inspect it
  with `python3 -c "import json; ..."` rather than `git diff`.
