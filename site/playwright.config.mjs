import { defineConfig } from "@playwright/test";
import { fileURLToPath } from "node:url";

// Screenshots, the HTML report and traces go to E2E_OUT (default: the repo's gitignored
// verify/site/). PLAYWRIGHT_CHROMIUM lets a machine with a different browser build point
// at its own Chromium.
const out = process.env.E2E_OUT || fileURLToPath(new URL("../verify/site/", import.meta.url));
const port = 4510;

export default defineConfig({
  testDir: "./tests",
  outputDir: `${out}/results`,
  reporter: [["list"], ["html", { outputFolder: `${out}/report`, open: "never" }]],
  use: {
    baseURL: `http://localhost:${port}`,
    trace: "on",
    video: "on",
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {},
  },
  webServer: { command: "node tests/serve.mjs", port, reuseExistingServer: false, env: { PORT: String(port) } },
});
