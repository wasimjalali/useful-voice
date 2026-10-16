import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { PinnedModelFile } from '../src/core/formatting/s1MiniModel.js';

// `modelAvailability` runs on every dictation, so no filesystem failure may escape it.
const fsState = vi.hoisted(() => ({
  stat: (async () => ({ size: 100 })) as (...a: unknown[]) => Promise<{ size: number }>,
  open: (async () => {
    throw new Error('unset');
  }) as (...a: unknown[]) => Promise<unknown>,
}));

vi.mock('node:fs/promises', async (original) => {
  const real = await original<typeof import('node:fs/promises')>();
  return { ...real, stat: (...a: unknown[]) => fsState.stat(...a), open: (...a: unknown[]) => fsState.open(...a) };
});

const { modelAvailability } = await import('../src/main/cleanupModel/modelDownloader.js');

const pin: PinnedModelFile = { id: 't', fileName: 't.gguf', url: 'http://x/t', bytes: 100, sha256: 'x' };
const errno = (code: string) => Object.assign(new Error(code), { code });

beforeEach(() => {
  fsState.stat = async () => ({ size: 100 });
});

describe('modelAvailability never throws', () => {
  it('open fails with EBUSY: not usable', async () => {
    fsState.open = async () => {
      throw errno('EBUSY');
    };
    expect(await modelAvailability('/m', pin)).toBe('invalid');
  });

  it('the file vanishes between the stat and the open: missing', async () => {
    fsState.open = async () => {
      throw errno('ENOENT');
    };
    expect(await modelAvailability('/m', pin)).toBe('missing');
  });

  it('the read fails: not usable, and the handle is closed', async () => {
    const close = vi.fn(async () => undefined);
    fsState.open = async () => ({
      read: async () => {
        throw errno('EIO');
      },
      close,
    });
    expect(await modelAvailability('/m', pin)).toBe('invalid');
    expect(close).toHaveBeenCalled();
  });

  it('stat itself fails with a permission error: not usable', async () => {
    fsState.stat = async () => {
      throw errno('EACCES');
    };
    expect(await modelAvailability('/m', pin)).toBe('invalid');
  });

  it('a file with the right size and magic is usable', async () => {
    fsState.open = async () => ({
      read: async (buffer: Buffer) => {
        buffer.write('GGUF');
        return { bytesRead: 4 };
      },
      close: async () => undefined,
    });
    expect(await modelAvailability('/m', pin)).toBe('usable');
  });
});
