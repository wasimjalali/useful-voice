import { describe, expect, it } from 'vitest';
import { serialTypeOutUpdater, withTypeOut } from '../src/core/delivery/typeOutList.js';

/**
 * Settings' type-out switches. Ways it could fail: two switches flipped before the
 * first save returns, and the second save drops the first change (a lost update); a
 * failed save that blocks every later one; a toggle that reorders or duplicates entries.
 */

/** A store whose saves take a while, like the IPC round trip. */
function slowStore(initial: string[], failOn?: (list: string[]) => boolean) {
  let saved = [...initial];
  const writes: string[][] = [];
  return {
    read: () => saved,
    save: (list: string[]) =>
      new Promise<boolean>((resolve) => {
        writes.push(list);
        setTimeout(() => {
          if (failOn?.(list)) return resolve(false);
          saved = list;
          resolve(true);
        }, 20);
      }),
    saved: () => saved,
    writes,
  };
}

describe('withTypeOut', () => {
  it('adds at the end, removes in place, never duplicates', () => {
    expect(withTypeOut(['putty'], 'cmd', true)).toEqual(['putty', 'cmd']);
    expect(withTypeOut(['putty', 'cmd', 'wsl'], 'cmd', false)).toEqual(['putty', 'wsl']);
    expect(withTypeOut(['putty'], 'putty', true)).toEqual(['putty']);
  });
});

describe('serialTypeOutUpdater', () => {
  it('keeps both changes when two switches flip before the first save returns', async () => {
    const store = slowStore([]);
    const set = serialTypeOutUpdater(store.read, store.save);
    const both = await Promise.all([set('windowsterminal', true), set('putty', true)]);
    expect(both).toEqual([true, true]);
    expect(store.saved()).toEqual(['windowsterminal', 'putty']);
  });

  it('builds each save from the one before, on and off mixed', async () => {
    const store = slowStore(['putty', 'cmd']);
    const set = serialTypeOutUpdater(store.read, store.save);
    await Promise.all([set('putty', false), set('wsl', true), set('cmd', false)]);
    expect(store.saved()).toEqual(['wsl']);
    expect(store.writes).toEqual([['cmd'], ['cmd', 'wsl'], ['wsl']]);
  });

  it('a failed save reports false and does not block the next one', async () => {
    const store = slowStore([], (list) => list.includes('bad'));
    const set = serialTypeOutUpdater(store.read, store.save);
    const [first, second] = await Promise.all([set('bad', true), set('putty', true)]);
    expect(first).toBe(false);
    expect(second).toBe(true);
    expect(store.saved()).toEqual(['putty']);
  });
});
