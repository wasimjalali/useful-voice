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
node scripts/publish-source.mjs --clone /tmp/uv-source --version X.Y.Z   # read the commit, then:
node scripts/publish-source.mjs --clone /tmp/uv-source --version X.Y.Z --push
```

The script refuses a dirty tree, a clone that isn't clean (no modified, staged, untracked or ignored files, so use a fresh clone), a clone whose fetch or push URL (after `insteadOf` and `pushurl` rewrites) isn't the public repo, and a version whose `source-vX.Y.Z` branch already exists locally or on origin. It builds the snapshot in a temporary worktree, so the clone is untouched if a step fails, and a finished commit stays on the local branch if the push fails. It copies `git ls-files` only,
minus the paths in `EXCLUDE` (old Sadaa audits and plans, `docs/images/` until screenshots with synthetic data are approved, and any media that could show
real windows), and stops if a tracked file is named like a secret. It commits to `source-vX.Y.Z`,
cut from the public `main`. `--push` pushes that branch and opens a PR on the public repo; merge it
there.

A new file that shows real data or the owner's account belongs on `EXCLUDE` before it is committed.
