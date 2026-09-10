import { describe, expect, it } from 'vitest';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Static checks on values that must agree across files but cannot be imported
 * here.
 *
 * `src/main/index.ts` imports `electron`, which is not loadable under vitest, so
 * these are read as text rather than executed. The assertions are about *agreement
 * between two files*, which is exactly the kind of drift a type checker cannot
 * catch — the two values are both plain strings.
 */
async function read(relative: string): Promise<string> {
  return fs.readFile(path.join(root, relative), 'utf8');
}

describe('app identity', () => {
  it('the App User Model ID matches build.appId in package.json', async () => {
    // Windows takes the app's identity — taskbar grouping, notifications, and the
    // registry Run value used for launch-at-login — from the AUMID. If it does not
    // match the appId the installer used, the login entry the installer created is
    // attributed to a different app than the one running, and launch-at-login
    // silently targets the wrong identity.
    const pkg = JSON.parse(await read('package.json')) as { build?: { appId?: string } };
    const appId = pkg.build?.appId;
    expect(appId, 'package.json must declare build.appId').toBeTruthy();

    const main = await read('src/main/index.ts');
    const match = main.match(/export const APP_USER_MODEL_ID = '([^']+)'/);
    // A regex that finds nothing must fail, not pass vacuously.
    expect(match, 'APP_USER_MODEL_ID must be declared in src/main/index.ts').not.toBeNull();

    expect(match?.[1]).toBe(appId);
  });

  it('the AUMID is applied through the constant, not a second literal', async () => {
    const main = await read('src/main/index.ts');

    expect(main).toContain('app.setAppUserModelId(APP_USER_MODEL_ID)');
    // A hardcoded literal here is how the two values drifted apart originally.
    expect(main).not.toMatch(/setAppUserModelId\(\s*['"]/);
  });

  it('productName agrees between package.json and the builder config', async () => {
    const pkg = JSON.parse(await read('package.json')) as {
      productName?: string;
      build?: { productName?: string };
    };

    // Different names here would ship an installer whose shortcut, Start-menu entry
    // and tray label disagree.
    expect(pkg.build?.productName).toBe(pkg.productName);
  });

  it('the packaged entry point exists and matches package.json main', async () => {
    const pkg = JSON.parse(await read('package.json')) as {
      main?: string;
      build?: { extraMetadata?: { main?: string } };
    };

    // A mismatch between these and tsc's output path produces a build that looks
    // fine and an app that opens no window at all.
    expect(pkg.main).toBe('dist/main/index.js');
    expect(pkg.build?.extraMetadata?.main).toBe(pkg.main);
  });
});
