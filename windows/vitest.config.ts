import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // The core is pure TypeScript with no Electron, Node or DOM dependency, so
    // the whole suite runs in a plain Node environment on any platform. That is
    // what makes the Windows port verifiable from macOS.
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    reporters: ['default'],
    coverage: {
      provider: 'v8',
      include: ['src/core/**/*.ts'],
    },
  },
});
