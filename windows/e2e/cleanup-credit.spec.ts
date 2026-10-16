import { expect, test } from '@playwright/test';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { seedUserData } from './fixtures.js';
import { collect, launch, remove, type Running } from './harness.js';

// The hidden S1-mini cleanup flag shows one credit line in Settings > Formatting, and nothing
// at all without it. The flag is the `--cleanup-model` switch; no model is downloaded or loaded.

async function open(name: string, flags: string[]): Promise<Running> {
  const userData = await seedUserData({});
  await fs.writeFile(
    path.join(userData, 'settings.json'),
    JSON.stringify({ version: 1, firstRunCompleted: true, settings: {} }),
  );
  const run = await launch(name, userData, flags);
  await collect(run.win);
  await run.win.locator('.rail-item', { hasText: 'Settings' }).click();
  await run.win.locator('.s-index-item', { hasText: 'Formatting' }).click();
  await expect(run.win.locator('#settings-formatting')).toBeVisible();
  return run;
}

async function close(run: Running): Promise<void> {
  try {
    await run.stop();
  } finally {
    await remove(run.userData);
  }
}

test('Settings shows the S1-mini credit with the hidden flag on', async () => {
  const run = await open('cleanup-credit-on', ['--cleanup-model']);
  try {
    const credit = run.win.locator('#settings-formatting').getByText('AI cleanup: S1-mini by Superwhisper');
    await expect(credit).toHaveCount(1);
    await expect(credit).toBeVisible();
    // One line: no switch and no helper text beside it.
    await expect(run.win.locator('#settings-cleanup-credit')).toHaveText('AI cleanup: S1-mini by Superwhisper');
  } finally {
    await close(run);
  }
});

test('Settings shows nothing about AI cleanup with the flag off', async () => {
  const run = await open('cleanup-credit-off', []);
  try {
    await expect(run.win.locator('#settings-cleanup-credit')).toHaveCount(0);
    await expect(run.win.getByText('S1-mini')).toHaveCount(0);
    await expect(run.win.getByText('AI cleanup')).toHaveCount(0);
  } finally {
    await close(run);
  }
});
