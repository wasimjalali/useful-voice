import { describe, expect, it } from 'vitest';
import { isLoopbackFeed, updatesDisabledReason } from '../src/main/updater.js';

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

describe('updatesDisabledReason, per-machine installs', () => {
  const base = { isPackaged: true, platform: 'win32' as const, e2e: false, portable: false, installed: true };
  const programFilesDirs = ['C:\\Program Files', 'C:\\Program Files', 'C:\\Program Files (x86)'];

  it('turns updates off under Program Files, whatever the case or slashes', () => {
    for (const exeDir of [
      'C:\\Program Files\\Useful Voice',
      'c:/program files/Useful Voice',
      'C:\\Program Files (x86)\\Useful Voice\\x',
    ]) {
      expect(updatesDisabledReason({ ...base, exeDir, programFilesDirs })).toMatch(/per-machine/);
    }
  });

  it('keeps updates on for a per-user install and for look-alike folders', () => {
    for (const exeDir of [
      'C:\\Users\\a\\AppData\\Local\\Programs\\Useful Voice',
      'C:\\Program Files Extra\\Useful Voice',
      'D:\\Program Files\\Useful Voice',
    ]) {
      expect(updatesDisabledReason({ ...base, exeDir, programFilesDirs })).toBeNull();
    }
  });

  it('does not decide without the folders', () => {
    expect(updatesDisabledReason({ ...base })).toBeNull();
    expect(updatesDisabledReason({ ...base, exeDir: 'C:\\Program Files\\Useful Voice', programFilesDirs: [] })).toBeNull();
  });
});
