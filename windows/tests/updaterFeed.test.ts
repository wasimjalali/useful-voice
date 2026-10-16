import { describe, expect, it } from 'vitest';
import { isLoopbackFeed } from '../src/main/updater.js';

describe('isLoopbackFeed', () => {
  it('accepts the CI test feed', () => {
    expect(isLoopbackFeed('provider: generic\nurl: http://127.0.0.1:8720/\nupdaterCacheDirName: x\n')).toBe(true);
    expect(isLoopbackFeed('provider: generic\nurl: "http://localhost:8720/"\n')).toBe(true);
  });

  it('rejects the release feed and look-alike hosts', () => {
    expect(isLoopbackFeed('provider: github\nowner: wasimjalali\nrepo: useful-voice-releases\n')).toBe(false);
    expect(isLoopbackFeed('provider: generic\nurl: https://example.com/\n')).toBe(false);
    expect(isLoopbackFeed('provider: generic\nurl: http://127.0.0.1.evil.example/\n')).toBe(false);
    expect(isLoopbackFeed('')).toBe(false);
  });
});
