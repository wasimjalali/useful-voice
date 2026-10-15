# Distribution

Useful Voice lives in three repos.

| Repo | Visibility | What it holds |
|---|---|---|
| `wasimjalali/useful-voice` | Private | Development. Full history, including old Sadaa-era docs and screenshots. |
| `wasimjalali/usefulvoice` | Public | The source: one snapshot commit per release, authored by the GitHub noreply address. MIT, no CLA. |
| `wasimjalali/useful-voice-releases` | Public | Release assets, the appcast and Issues. No source. |

The history of the private repo carries the owner's personal address and screenshots of real
windows, so the public source repo gets snapshots, never history.

## Release order

1. **Hygiene.** Check that nothing new in the tree shows real data, and add its path to `EXCLUDE`
   in `scripts/publish-source.mjs` if it does.
2. **Create `usefulvoice`** with an initial commit, so it has a `main` (for example `gh repo create wasimjalali/usefulvoice --public --add-readme`; the script refuses a repo with no `main`). Then publish the first snapshot with the script below.
3. **Point the landing page** at `usefulvoice` (and at `useful-voice-releases` for downloads).
4. **Only then make `useful-voice` private.** Making it private first breaks every link to it.

The in-app Report a bug, What's new and Privacy rows stay hidden until `releasesRepoLive` is
set to `true` (`Sources/UsefulVoiceCore/ReleaseLinks.swift` on macOS,
`windows/src/core/releaseLinks.ts` on Windows). Flip it in the PR that creates
`useful-voice-releases`.

## Publishing the source

After a release merges to `main`:

```sh
gh repo clone wasimjalali/usefulvoice /tmp/uv-source   # once
node scripts/publish-source.mjs --clone /tmp/uv-source --version X.Y.Z   # builds the commit; read it, then:
node scripts/publish-source.mjs --clone /tmp/uv-source --version X.Y.Z --push-existing
```

Use a fresh clone for each version. `--push` does both steps in one run.

The first run builds the snapshot in a temporary worktree, so the clone is untouched if a step fails,
and commits it to a new `source-vX.Y.Z` branch cut from the public `main`. `--push-existing` then
re-checks the branch (exactly one commit on `origin/main`, authored and committed by the noreply
address, and a tree with identical contents to the filtered source tree, path by path, that passes the same guards), pushes
`refs/heads/source-vX.Y.Z` to the same name on origin without tags whatever the clone's push config
says, and opens a PR on the public repo. Merge it there. A failed push leaves the commit on the
local branch, so `--push-existing` is also the retry. If the push worked but the PR step failed, it
skips the push (the remote branch is the same commit) and opens the PR, or prints the one that exists.

The script refuses:

- a private tree with uncommitted changes
- a tracked path with a newline, a Unicode line or paragraph separator or another control or format
  character
- a file named like a secret
- a clone that isn't clean (modified, staged, untracked or ignored files)
- a clone whose fetch or push URL, after `insteadOf`, `pushInsteadOf` and `pushurl` rewrites, isn't the
  public repo
- a version whose `source-vX.Y.Z` branch already exists on origin, or locally (except with
  `--push-existing`)

It copies `git ls-files` only, minus the paths in `EXCLUDE` (old Sadaa audits and plans, `docs/images/`
until screenshots with synthetic data are approved, and any media that could show real windows).

A new file that shows real data or the owner's account belongs on `EXCLUDE` before it is committed.

## Windows release

The `Windows release` workflow (`.github/workflows/release-windows.yml`) builds the files on
every PR and push to `main` that touches `windows/`, and proves them end to end on clean
`windows-latest` runners. It never publishes.

| File | What it is |
|---|---|
| `Useful-Voice-X.Y.Z-x64.exe` | NSIS installer, per-user, no admin prompt |
| `Useful-Voice-X.Y.Z-x64.exe.blockmap` | Lets the updater fetch only the blocks that changed |
| `Useful-Voice-Windows-Setup.exe` | The same installer under a fixed name, for the site's `releases/latest/download/` link |
| `Useful-Voice-X.Y.Z-portable.exe` | Portable build. It never updates itself |
| `latest.yml` | The update feed: version, file name, SHA-512 and size of the installer |
| `install.ps1` | The one-line installer, pinned to this installer's URL and SHA-256 |
| `SHA256SUMS-windows.txt` | SHA-256 of both installer names, the portable exe, `install.ps1` and `latest.yml` |

`windows/scripts/release.mjs` makes this set from electron-builder's output. It renames the
files with dashes (GitHub turns a space into a dot on upload, and `latest.yml` would then point
at a file that doesn't exist) and refuses when `latest.yml` and the installer disagree.

The tests: `install-script` serves a copy of the release on 127.0.0.1 the way GitHub serves
assets and runs `irm .../install.ps1 | iex`. A tampered installer is refused with nothing
installed, the real one installs under Windows PowerShell 5.1, then again under PowerShell 7.
`update` installs an older build (0.0.9, same code) whose feed points at that copy and checks
it updates itself to the new version through `electron-updater` and starts again. That test
uses electron-updater's generic provider, so the GitHub provider's lookup of the newest `v` release
is first exercised live, once two releases exist.

### Publishing (owner only)

1. Bump `windows/package.json` `version` with the Mac version and merge to `main`.
2. Download the release set from the `Windows release` run on that `main` commit:
   `gh run download <run id> --repo wasimjalali/useful-voice --name useful-voice-windows-release --dir /tmp/uv-win`
3. Check it: `cd /tmp/uv-win && sha256sum -c SHA256SUMS-windows.txt`.
4. Attach every file to the `vX.Y.Z` release in `wasimjalali/useful-voice-releases`, next to
   the Mac files, while it is still a draft:
   `gh release upload vX.Y.Z /tmp/uv-win/* --repo wasimjalali/useful-voice-releases`
5. Publish the release. Installed apps see it on their next check.

Two rules keep Windows installs working:

- **Every release carries the Windows files.** The updater reads `latest.yml` from the newest
  published release, and the one-liner fetches `releases/latest/download/install.ps1`. A
  Mac-only release would break both until the next one.
- **Tags are `vX.Y.Z`.** The updater's GitHub provider expects the `v` prefix.

The releases repo must stay public: the updater and the one-liner read it without a token.

### Install commands for the site

```powershell
irm https://github.com/wasimjalali/useful-voice-releases/releases/latest/download/install.ps1 | iex
```

The installer is also on the Releases page. It is not Authenticode-signed (buying a certificate
is the owner's call), so Windows warns about it:

- **Downloaded installer.** Microsoft Defender SmartScreen says "Windows protected your PC".
  Click **More info**, then **Run anyway**. Edge may first say the file "isn't commonly
  downloaded": open the **...** menu on the download, then **Keep**.
- **One-liner.** `install.ps1` checks the installer's SHA-256 against the release before it
  runs it, so a changed file never runs. A file fetched with `Invoke-WebRequest` carries no mark
  of the web (the CI install test records this on every run: "Zone.Identifier stream: False"),
  and SmartScreen's prompt is for files that carry it, so this path should not show "Windows
  protected your PC". Confirm on a real Windows machine before the site promises it.
- On Windows 11 with Smart App Control turned on, Microsoft documents that unsigned apps without
  a reputation are blocked, with no Run anyway. Signing is the only fix for those machines.

Copy for the site should come from this section, and change when signing changes.

### Signing later

When a certificate exists: set `WIN_CSC_LINK` and `WIN_CSC_KEY_PASSWORD` as CI secrets, then set
`build.win.verifyUpdateCodeSignature` back to `true` in the same release (see
`windows/README.md`, "Code signing"). Until then the update's integrity rests on the SHA-512 in
`latest.yml`, fetched over HTTPS from the releases repo.

### What the update check sends

A GET for `latest.yml` (and the installer when there is one) to github.com. GitHub sees the IP
address and the app's user agent, as it does for any download. electron-updater would also send a
random per-install ID; the app sends a fixed all-zero value instead (the library still keeps its
random ID in a local `.updaterId` file, which never leaves the machine). Nothing about the user,
their dictations or their settings is sent, and there is still no analytics.
