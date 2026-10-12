import { describe, expect, it } from 'vitest';
import { decideFirstRun, firstRunLaunch, shouldOpenAtLaunch, FIRST_RUN_STEPS } from '../src/core/firstRun/gate.js';

// Failure modes, written before the code:
//  1. A completed install must never see the flow again, key or no key.
//  2. A fresh install (no flag, no key) must see it.
//  3. An existing user upgrading (key saved, no flag) must NOT see it, and is marked completed.
//  4. A key that is stored but cannot be decrypted right now still counts as configured,
//     or an upgrade would wrongly walk an existing user through setup.
//  5. A forced run always shows and never marks anything, whatever the state.
//  6. The step jump is honoured only when the flow shows, and only for a known step.
//  7. Flags match exactly: a prefix or a stray value must not force the flow or pick a step.

describe('decideFirstRun', () => {
  it('skips a completed install, with or without a key', () => {
    expect(decideFirstRun({ completed: true, keyStored: false, forced: false })).toBe('skip');
    expect(decideFirstRun({ completed: true, keyStored: true, forced: false })).toBe('skip');
  });

  it('shows on a fresh install', () => {
    expect(decideFirstRun({ completed: false, keyStored: false, forced: false })).toBe('show');
  });

  it('skips and marks completed for an existing user with a saved key', () => {
    expect(decideFirstRun({ completed: false, keyStored: true, forced: false })).toBe('skipAndMarkCompleted');
  });

  it('forced always shows and never asks to mark', () => {
    for (const completed of [true, false]) {
      for (const keyStored of [true, false]) {
        expect(decideFirstRun({ completed, keyStored, forced: true })).toBe('show');
      }
    }
  });
});

describe('firstRunLaunch', () => {
  it('reads the force flag exactly', () => {
    expect(firstRunLaunch(['app', '--force-first-run']).forced).toBe(true);
    expect(firstRunLaunch(['app', '--force-first-run=1']).forced).toBe(false);
    expect(firstRunLaunch(['app', '--force-first-run-now']).forced).toBe(false);
    expect(firstRunLaunch(['app']).forced).toBe(false);
  });

  it('reads a known step and ignores anything else', () => {
    expect(firstRunLaunch(['--first-run-step=microphone']).step).toBe('microphone');
    expect(firstRunLaunch(['--first-run-step=nope']).step).toBeNull();
    expect(firstRunLaunch(['--first-run-step=']).step).toBeNull();
    expect(firstRunLaunch([]).step).toBeNull();
  });

  it('knows every step the flow can jump to', () => {
    expect(FIRST_RUN_STEPS).toEqual([
      'welcome', 'engine', 'errKey', 'deepgramKey', 'microphone', 'errMic', 'tryIt', 'tryItDone', 'done',
    ]);
  });
});

// Failure modes for the launch rule: the app is tray-only, so a fresh install that never
// opens its window would never show the flow at all (the bug this rule fixes).
//  1. pending flow, launched by the person: the window must open.
//  2. pending flow, launched by the login entry: nobody clicked, so no window is pulled in
//     front of them; the flow stays pending and shows when they first open the window.
//  3. nothing pending: a normal tray-only launch, never a window.

describe('shouldOpenAtLaunch', () => {
  it('opens the window for a pending flow the person launched', () => {
    expect(shouldOpenAtLaunch({ pending: true, autoStarted: false })).toBe(true);
  });
  it('stays tray-only when the login entry launched it', () => {
    expect(shouldOpenAtLaunch({ pending: true, autoStarted: true })).toBe(false);
  });
  it('stays tray-only when nothing is pending', () => {
    expect(shouldOpenAtLaunch({ pending: false, autoStarted: false })).toBe(false);
    expect(shouldOpenAtLaunch({ pending: false, autoStarted: true })).toBe(false);
  });
});
