## Findings

**1. Session-end resume budget is eaten by a re-added grace, so slow resumes still leave media paused — high**
`windows/src/main/index.ts:1108`, `windows/src/core/media/mediaPausePolicy.ts:207`, `windows/src/main/quitCoordinator.ts:64`
`onSessionEnd` starts `media.shutdown(1000)` first. Later `runQuit` calls `service.cancel()`, which unconditionally fires `recordingEvent('end')` → `recordingEnded()`. At that point `closed` is still false, so it schedules a fresh 400 ms grace; `runShutdown`'s `settled()` waits for it. Because `shutdown` is memoized (`shutdownDone ??=`), the later `shutdown(2500)` cannot extend the 1 s cap. Scenario: log out after dictating with two players, or with a cold/restarted media host. The resume has ~600 ms, then `runQuit` proceeds and `mediaEffects.dispose()` (`index.ts:1126`) kills the PowerShell host mid-`TryPlayAsync`; media stays paused. The unit test uses `graceMs: 0`, so it misses this.

**2. A failed per-session play is silently reported as a completed resume — low**
`windows/src/main/mediaScripts.ts:220`, `windows/src/core/media/mediaPausePolicy.ts:292`
The resume catch prints `UVSKIP:-`, discarding the id. `parseResumeOutput` only requires `UVRESUMED`, so the run counts as finished; `resumeHeld` deletes every held entry, and `shutdown()` returns true. Scenario: one player's `TryPlayAsync` throws or outruns its 3 s wait. That session stays paused, with no `UVREFUSED`/log, and the app exits claiming success. The pause script was fixed to name the session (`UVSKIP:<id>`); the resume script was not.

**3. A logoff now spawns a pending update installer — low**
`windows/src/main/index.ts:1149`
Routing `session-end` through `runQuit` means `installOnExit()` runs during logoff/shutdown. If an update is downloaded, the NSIS installer is spawned and `app.exit` follows while Windows is tearing the session down. A killed installer can leave a partial install, or hold up the logoff. The old `session-end` path only resumed media and never reached the installer.

**4. The new e2e bypasses the real `session-end` wiring — low**
`windows/e2e/pause-media.spec.ts:135`, `windows/src/main/index.ts:405`
`hook(r.app, 'sessionEnd')` calls `QuitCoordinator.onSessionEnd()` directly. The `browser-window-created` → `window.on('session-end')` listener, the part that failed in round 3, is never exercised; deleting or mistyping it would leave all tests green. Emitting `session-end` on an actual window would cover it.

## DISMISSED
- **`app.quit()` inside `session-end` failing to mark Electron as quitting:** verified in Electron v43.7.0 `native_window_views_win.cc`; `WM_ENDSESSION` checks `is_quitting()`, and `Widget::Close` posts `CloseNow`, so the flag is still true at that check.
- **`will-quit` `preventDefault` hanging the app:** `runQuit` always ends in `app.exit`; the undefined-`service`/`media` path cannot occur because the recorder window is created and `buildService()` completes synchronously in one turn.
- **Double resume / second `app.quit()` cutting it short:** `shutdown` is memoized and `before-quit` is always held while `sessionEnding`.
- **Injection through session ids or the host stdin protocol:** ids enter scripts only as validated base64, `ownAppId` is regex-checked, timeline numbers are regex-checked, and no raw id reaches a script.
- **Helper hang/leak or main-thread blocking:** media runs in its own PowerShell host with timeouts, dispose and the runner's post-dispose refusal; parsing is small and no sync file I/O runs in production.
- **Update restart regressed:** `restartToUpdate` still calls `runQuit` → `installOnExit`/`app.relaunch`; `before-quit` is not involved.
- **Slow, unconfirmed pauses left paused:** deliberate (`resumeVerdict`/`resumeScript`), never play a session that may have been paused by the person.
- **Note drafts on logoff:** `app.quit()` closes the windows before `runQuit`, so `saveRendererDrafts` is a no-op; data/settings still flush. This loss pre-dates 204081b.
- **`UVSKIP:-` from list/timeline:** ignored by the parsers, harmless.

Static review only: `windows/node_modules` is absent and this is a macOS host, so `npm run verify` and the Windows-only real-media tests were not run.