import { describe, expect, it } from 'vitest';
import {
  HOTKEY_REPEAT_WINDOW_MS,
  acceptsHotkeyEvent,
  createHotkeyRepeatGuard,
} from '../src/core/settings/hotkeyRepeat.js';

// Failure modes, written before the code:
//  1. a held key repeats every ~30 ms and toggles recording off and on again
//  2. the window is measured from the last ACCEPTED event, so a key held for a second
//     re-toggles every window
//  3. a real second press right after the window is swallowed
//  4. the very first press is dropped

describe('acceptsHotkeyEvent', () => {
  it('accepts the first press', () => {
    expect(acceptsHotkeyEvent(null, 5)).toBe(true);
  });

  it('ignores an event inside the window', () => {
    expect(acceptsHotkeyEvent(1000, 1000 + HOTKEY_REPEAT_WINDOW_MS - 1)).toBe(false);
  });

  it('accepts an event exactly at and after the window', () => {
    expect(acceptsHotkeyEvent(1000, 1000 + HOTKEY_REPEAT_WINDOW_MS)).toBe(true);
    expect(acceptsHotkeyEvent(1000, 5000)).toBe(true);
  });

  it('treats a clock that went backwards as a repeat', () => {
    expect(acceptsHotkeyEvent(1000, 900)).toBe(false);
  });
});

describe('createHotkeyRepeatGuard', () => {
  function guardAt(times: number[]): boolean[] {
    let index = 0;
    const guard = createHotkeyRepeatGuard(() => times[index++] as number);
    return times.map(() => guard());
  }

  it.each([250, 500, 1000])('lets a key held past a %d ms repeat delay through once', (delay) => {
    const times = [0];
    for (let t = delay; t <= delay + 2000; t += 33) times.push(t);
    const results = guardAt(times);
    expect(results[0]).toBe(true);
    expect(results.slice(1).filter(Boolean)).toHaveLength(0);
  });

  it('lets a held key through once, however long it is held', () => {
    // A press, then auto-repeat every 33 ms for two seconds, after Windows' shortest
    // keyboard repeat delay (250 ms).
    const times = [0];
    for (let t = 250; t <= 2250; t += 33) times.push(t);
    const results = guardAt(times);
    expect(results[0]).toBe(true);
    expect(results.slice(1).filter(Boolean)).toHaveLength(0);
  });

  it('slides the window on ignored events', () => {
    // 0 accepted; 200 ignored; 400 is 400 after the first but only 200 after the
    // ignored one, so it is still a repeat.
    expect(guardAt([0, 200, 400, 600, 800])).toEqual([true, false, false, false, false]);
  });

  it('accepts a deliberate second press after the key was released', () => {
    expect(guardAt([0, 1500, 3000])).toEqual([true, true, true]);
  });

  it('accepts a press once the repeats have stopped for a full window', () => {
    expect(guardAt([0, 100, 200, 200 + HOTKEY_REPEAT_WINDOW_MS])).toEqual([true, false, false, true]);
  });
});
