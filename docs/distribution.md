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

## The website

voice.usefulbuild.com is the static site in `site/` (`site/public/`, deployed as the `useful-voice`
Worker by `site/wrangler.jsonc`). It replaces `workers/public-hosts/voice` in useful-brain: the Worker
keeps the same name, so the first deploy from here takes over the domain in place. Retire the
useful-brain copy after that deploy, in a useful-brain PR that also drops the checks for it in
`src/lib/cf/wrangler-config.test.ts`. Until then, a `wrangler deploy` from useful-brain's copy
would put the old page back.

It ships in its coming-soon state: `data-release="soon"` on `<html>` hides the install sections.
The install commands and buttons link to these assets on
`https://github.com/wasimjalali/useful-voice-releases/releases/latest/download/`, so every release
must carry them under exactly these names:

| Asset | Used by |
|---|---|
| `install.sh` | `curl -fsSL .../install.sh \| sh` (Mac) |
| `Useful-Voice-macOS.dmg` | Download for Mac |
| `install.ps1` | `irm .../install.ps1 \| iex` (Windows) |
| `Useful-Voice-Windows-Setup.exe` | Download for Windows |

The page and the privacy page say updates arrive in the app and that it checks GitHub for them.
Don't flip the page until the release ships the in-app updaters (Sparkle on macOS, WAS-32; the
Windows auto-updater, WAS-34), or change those lines in the same PR.

On release day, after the first release with all four assets is public: remove
`data-release="soon"` from `site/public/index.html`, add the DMG as `downloadUrl` in its JSON-LD (the
comment above it has the line), run the checks, then deploy. The coming-soon checks skip themselves
once the attribute is gone, and a check fails if the `downloadUrl` is missing. From the repo root:

```sh
(cd site && npm ci && npx playwright test)        # screenshots and the HTML report land in verify/site/
npx wrangler whoami                               # must show the Karko AI account
npx wrangler deploy --config site/wrangler.jsonc
```

Where Playwright's own Chromium isn't installed, point it at another build with
`PLAYWRIGHT_CHROMIUM=/path/to/chrome`.

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

## Building a macOS release

`scripts/release-mac.mjs` (ported from Useful Bot) builds everything a release publishes into
`dist/release`, on the release Mac:

```sh
node scripts/release-mac.mjs --version X.Y.Z
```

| File | What it is |
|---|---|
| `Useful-Voice-macOS.zip` | The app, signed for Sparkle with the update key. Sparkle and `install.sh` download it. |
| `Useful-Voice-macOS.dmg` | The same app beside an Applications link over the branded background (`bundle/dmg/`), for browser downloads. |
| `appcast.xml` | One-item Sparkle feed pointing at this release's zip. Written last: its presence marks a whole release. |
| `install.sh` | The curl installer (`scripts/install.sh`) with this release's zip URL and SHA-256 baked in. |
| `release-notes.md` | A draft from `bundle/release-notes.md`: fill in New, Better and Fixed, then paste it into the GitHub release. |

The version comes from `--version`; the build number (`CFBundleVersion`, which Sparkle compares) is
`git rev-list --count HEAD`, so it only grows. That holds only along `main`, so a release is built
from `main` after the PR is merged and pulled: the script fetches `origin/main` and refuses a `HEAD`
that isn't on it, and refuses a shallow clone. A change that a release needs, such as a new
`ED_PUBLIC_KEY`, goes in a PR first, is merged, and the release is built from `main` afterwards.
The script refuses a dirty tree (untracked files count, build output in `dist/` and `.build/` is ignored), a missing
"Useful Voice Release" identity, and an update key in the Keychain that differs from the public key
in the script. It builds through `make bundle` with the version, the certificate and the feed, checks
the designated requirement is `identifier "ai.useful.voice" and certificate root = H"0911ad55..."`
(UV-004), then mounts the DMG read-only and checks its layout, the app's signature, version, feed,
designated requirement and that it is the same build as the zip (CDHash). Nothing is uploaded.

Signing follows UV-004: the free self-signed "Useful Voice Release" certificate, no hardened runtime,
no notarization. That is why `install.sh` clears every extended attribute from the copy it installs
(the quarantine flag included, after checking the SHA-256 and the signature) and the DMG window says
Open Anyway. The dry run checks the installed app has no extended attributes, but a `curl` download
carries no quarantine flag, so it doesn't prove the clear on a flagged file. The Makefile's `bundle-release`, `notarize` and
`dmg` targets are the Developer ID path (Option A), not used.

The `Release dry run` workflow builds a whole release on every PR that touches this pipeline, ad hoc
signed with a throwaway key made on the runner, and installs it through the generated `install.sh`.
`--ad-hoc` refuses the real key account, so a test build can never pass for a release.

Release builds check the feed daily (`SUEnableAutomaticChecks`), a plain request to GitHub with no
system profile. A found update never opens a window on its own, since it would take focus from the
app being dictated into: the menu bar item changes to Install update X.Y.Z instead.

### The update key

The Sparkle EdDSA key exists. It was made on the release Mac under the Keychain account
`useful-voice`, and its public half is `ED_PUBLIC_KEY` in `scripts/release-mac.mjs`. The private half
lives only in that Keychain and the password manager. Never make a second key: every installed copy
only trusts this one. The first release run asks whether `sign_update` may use the "useful-voice"
Keychain item: click Always Allow (it is the only tool besides `generate_keys` that reads it).

To print the public key again, or to back the private key up:

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account useful-voice -p
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account useful-voice -x "$TMPDIR/useful-voice-sparkle.key"
```

Store the exported private key in the password manager, then delete the file.

### Publishing (owner only)

The default feed and install URLs read the assets of the release marked latest on
`useful-voice-releases`. So every release marked latest must carry `appcast.xml`, `install.sh` and the
macOS zip (and the DMG, plus the Windows files once a Windows build ships), or the one-liner and
in-app updates break. A Windows-only release must not be marked latest unless it carries the macOS files too.

1. Create the GitHub release `vX.Y.Z` on `useful-voice-releases` and attach the zip, the DMG,
   `appcast.xml` and `install.sh`.
2. Paste the filled `release-notes.md` as its notes.
3. Publish the source snapshot (above).

Before the first public release, check the update path end to end on a clean user: install the
previous version through the curl one-liner, grant Accessibility and Microphone, then update through
Sparkle (menu bar, Install update or Check for updates…) and dictate with the hotkey without re-granting. Back up
`~/Library/Application Support/UsefulVoice/` before switching your own Mac to the release build.

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
installed, the real one installs under Windows PowerShell 5.1. Run again under PowerShell 7 while
the app is running, it is refused (exit non-zero, app left running, install untouched); with the
app stopped, it reinstalls.
`update` installs an older build (0.0.9, same code) whose feed points at that copy and checks
it updates itself to the new version through `electron-updater` and starts again. That test
uses electron-updater's generic provider, so the GitHub provider's lookup of the newest `v` release
is first exercised live, once two releases exist.

### Publishing (owner only)

1. Bump `windows/package.json` `version` with the Mac version and merge to `main`.
2. Download the release set from the `Windows release` run on that `main` commit:
   `gh run download <run id> --repo wasimjalali/useful-voice --name useful-voice-windows-release --dir /tmp/uv-win`
3. Check it: `cd /tmp/uv-win && shasum -a 256 -c SHA256SUMS-windows.txt`.
4. Attach every file to the `vX.Y.Z` release in `wasimjalali/useful-voice-releases`, next to
   the Mac files, while it is still a draft:
   `gh release upload vX.Y.Z /tmp/uv-win/* --repo wasimjalali/useful-voice-releases`
5. Publish the release. Installed apps see it on their next check.

Two rules keep Windows installs working:

- **Every release carries the Windows files.** The updater reads `latest.yml` from the newest
  published release, and the one-liner fetches `releases/latest/download/install.ps1`. A
  Mac-only release would break both until the next one.
- **Tags are `vX.Y.Z`.** The updater's GitHub provider expects the `v` prefix.

A per-machine install (all users, under Program Files, uninstall entry in HKLM) does not update
itself: its silent update needs a UAC prompt, and a declined prompt would leave no app. The app
turns updates off when it runs from under `%ProgramFiles%`, `%ProgramW6432%` or
`%ProgramFiles(x86)%` and logs why. Those installs update by re-running the installer. A
per-machine install in a custom folder is not detected.

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
  runs it. That catches a corrupted or swapped download, not a compromised release (the hash and
  the installer come from the same repo). A file fetched with `Invoke-WebRequest` carries no mark
  of the web (the CI install test records this on every run: "Zone.Identifier stream: False"),
  and SmartScreen's prompt is for files that carry it, so this path should not show "Windows
  protected your PC". Confirm on a real Windows machine before the site promises it.
- **Re-running the one-liner.** If Useful Voice is running, `install.ps1` refuses and changes
  nothing: "Useful Voice is running. Quit it from its tray icon, then run this again." It never
  kills the app, so a recording, the notes draft and unsaved history are not lost.
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
