import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { UUID } from 'builder-util-runtime';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Same namespace and call as app-builder-lib/out/targets/nsis/NsisTarget.js:
//   UUID.v5(appInfo.id, ELECTRON_BUILDER_NS_UUID)
const ELECTRON_BUILDER_NS_UUID = UUID.parse('50e065bc-3134-11e6-9bab-38c9862bdaf3');
const LEGACY_APP_ID = 'ai.karko.usefulvoice';

describe('NSIS install identity', () => {
  it('pins build.nsis.guid to the GUID the legacy appId produced, so installs upgrade in place', () => {
    const pkg = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8')) as {
      build: { appId: string; nsis: { guid?: string } };
    };
    const legacyGuid = UUID.v5(LEGACY_APP_ID, ELECTRON_BUILDER_NS_UUID);
    expect(pkg.build.nsis.guid).toBe(legacyGuid);
    // The new appId would derive a different GUID; that is exactly why the pin is needed.
    expect(UUID.v5(pkg.build.appId, ELECTRON_BUILDER_NS_UUID)).not.toBe(legacyGuid);
  });
});
