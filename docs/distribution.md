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
`git rev-list --count HEAD`, so it only grows. The script refuses a dirty tree, a missing
"Useful Voice Release" identity, and an update key in the Keychain that differs from the public key
in the script. It builds through `make bundle` with the version, the certificate and the feed, checks
the designated requirement is `identifier "ai.useful.voice" and certificate root = H"0911ad55..."`
(UV-004), then mounts the DMG read-only and checks its layout, the app's signature, version, feed,
designated requirement and that it is the same build as the zip (CDHash). Nothing is uploaded.

Signing follows UV-004: the free self-signed "Useful Voice Release" certificate, no hardened runtime,
no notarization. That is why `install.sh` clears the quarantine flag (after checking the SHA-256 and
the signature) and the DMG window says Open Anyway. The Makefile's `bundle-release`, `notarize` and
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

1. Create the GitHub release `vX.Y.Z` on `useful-voice-releases` and attach the zip, the DMG,
   `appcast.xml` and `install.sh` (the default feed and install URLs read the latest release's assets).
2. Paste the filled `release-notes.md` as its notes.
3. Publish the source snapshot (above).

Before the first public release, check the update path end to end on a clean user: install the
previous version through the curl one-liner, grant Accessibility and Microphone, then update through
Sparkle (menu bar, Install update or Check for updates…) and dictate with the hotkey without re-granting. Back up
`~/Library/Application Support/UsefulVoice/` before switching your own Mac to the release build.
