import { configDefaults, defineConfig } from 'vitest/config';

/**
 * Tests that drive the real desktop (a real Edge window read with UI Automation) and time
 * it. They run on their own afterwards (`vitest.desktop.config.ts`; `npm test` runs both,
 * `npx vitest run --config vitest.desktop.config.ts` runs them alone, a plain `vitest` never):
 * beside the other files they share the runner with tests that compile C# and start
 * dozens of PowerShells, and their timings measure that instead of the read.
 */
export const DESKTOP_TESTS = ['tests/browserAddress.test.ts'];

export default defineConfig({
  test: {
    // The core is pure TypeScript with no Electron, Node or DOM dependency, so
    // the whole suite runs in a plain Node environment on any platform. That is
    // what makes the Windows port verifiable from macOS.
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    exclude: [...configDefaults.exclude, ...DESKTOP_TESTS],
    reporters: ['default'],
    coverage: {
      provider: 'v8',
      include: ['src/core/**/*.ts'],
    },
  },
});
