import { defineConfig } from '@playwright/test';

// E2E: launches the built app (`npm run build` first) with Playwright's Electron
// driver on a scratch user-data folder. The HTML report, traces and videos are the
// artifact (video and trace are recorded by the spec itself); `E2E_OUT` moves them (the orchestrator points it at verify/<branch>/).
const out = process.env.E2E_OUT ?? 'e2e-results';

export default defineConfig({
  testDir: 'e2e',
  timeout: 90_000,
  workers: 1,
  outputDir: `${out}/artifacts`,
  reporter: [['list'], ['html', { outputFolder: `${out}/report`, open: 'never' }]],
});
