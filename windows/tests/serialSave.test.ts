import { describe, expect, it } from 'vitest';
import { serialSaver } from '../src/core/apps/serialSave.js';

describe('serialSaver', () => {
  it('builds each patch from what the previous save stored', async () => {
    let stored: Record<string, string> = {};
    const release: Array<() => void> = [];
    const saver = serialSaver<Record<string, string>>(
      (patch) =>
        new Promise<boolean>((resolve) => {
          release.push(() => {
            stored = patch;
            resolve(true);
          });
        }),
    );
    const first = saver(() => ({ ...stored, a: '1' }));
    const second = saver(() => ({ ...stored, b: '2' }));
    await Promise.resolve();
    expect(release).toHaveLength(1);
    release[0]!();
    await first;
    await new Promise((r) => setTimeout(r, 0));
    expect(release).toHaveLength(2);
    release[1]!();
    await second;
    expect(stored).toEqual({ a: '1', b: '2' });
  });

  it('keeps going after a save fails', async () => {
    const seen: number[] = [];
    const saver = serialSaver<number>(async (patch) => {
      seen.push(patch);
      if (patch === 1) throw new Error('disk full');
      return true;
    });
    const failed = saver(() => 1);
    const next = saver(() => 2);
    await expect(failed).rejects.toThrow('disk full');
    await expect(next).resolves.toBe(true);
    expect(seen).toEqual([1, 2]);
  });
});
