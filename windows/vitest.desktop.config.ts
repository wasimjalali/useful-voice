import { defineConfig } from 'vitest/config';
import { DESKTOP_TESTS } from './vitest.config.js';

/** The real-desktop tests, one file at a time with nothing else running (see `vitest.config.ts`). */
export default defineConfig({
  test: {
    environment: 'node',
    include: DESKTOP_TESTS,
    fileParallelism: false,
    reporters: ['default'],
  },
});
