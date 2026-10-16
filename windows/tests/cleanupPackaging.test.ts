import { existsSync, readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { S1_MINI_CREDIT, S1_MINI_REVISION } from '../src/core/formatting/s1MiniModel.js';

const root = new URL('../', import.meta.url);
const read = (p: string) => readFileSync(new URL(p, root), 'utf8');
const pkg = JSON.parse(read('package.json')) as {
  dependencies: Record<string, string>;
  build: { files: string[]; asarUnpack: string[]; extraResources: { from: string; to: string }[] };
};

// The packaging smoke in CI (`electron-builder --win --dir`) proves the app builds. These
// pin the choices that keep the runtime small and loadable, so a config edit can't undo
// them quietly.
describe('S1-mini runtime packaging', () => {
  it('pins node-llama-cpp exactly', () => {
    expect(pkg.dependencies['node-llama-cpp']).toMatch(/^\d+\.\d+\.\d+$/);
  });

  it('ships only the CPU win-x64 binaries, not the CUDA and Vulkan builds', () => {
    const files = pkg.build.files;
    expect(files).toContain('!node_modules/@node-llama-cpp/*/bins/**/*');
    expect(files).toContain('node_modules/@node-llama-cpp/win-x64/bins/**/*');
    expect(files.indexOf('node_modules/@node-llama-cpp/win-x64/bins/**/*')).toBeGreaterThan(
      files.indexOf('!node_modules/@node-llama-cpp/*/bins/**/*'),
    );
    expect(files.some((f) => /cuda|vulkan/.test(f) && !f.startsWith('!'))).toBe(false);
  });

  it('keeps the native binaries outside the asar archive, where they can be loaded', () => {
    expect(pkg.build.asarUnpack).toContain('node_modules/@node-llama-cpp/*/bins/**/*');
    expect(pkg.build.asarUnpack).toContain('node_modules/node-llama-cpp/bins/**/*');
  });

  it('installs the license files next to the app', () => {
    const resources = pkg.build.extraResources;
    expect(resources).toContainEqual({ from: 'licenses', to: 'licenses' });
    expect(resources).toContainEqual({ from: 'THIRD_PARTY_NOTICES.md', to: 'THIRD_PARTY_NOTICES.md' });
  });
});

describe('S1-mini license and credit', () => {
  it('keeps the license and notice files verbatim', () => {
    for (const file of [
      'licenses/s1-mini/LICENSE',
      'licenses/s1-mini/NOTICE',
      'licenses/node-llama-cpp/LICENSE',
      'licenses/node-llama-cpp/LICENSE-win-x64-binaries',
      'licenses/llama.cpp/LICENSE',
    ]) {
      expect(existsSync(new URL(file, root)), file).toBe(true);
    }
    expect(read('licenses/s1-mini/NOTICE')).toContain('"S1-mini" by "Superwhisper"');
    expect(read('licenses/s1-mini/LICENSE')).toContain('Apache License');
  });

  it('credits "S1-mini by Superwhisper" exactly in the notices, at the pinned revision', () => {
    expect(S1_MINI_CREDIT).toBe('S1-mini by Superwhisper');
    const notices = read('THIRD_PARTY_NOTICES.md');
    expect(notices).toContain('## S1-mini by Superwhisper');
    expect(notices).toContain(S1_MINI_REVISION);
    expect(notices).toContain('Apache License 2.0 plus one additional term');
  });
});
