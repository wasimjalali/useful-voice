import { expect, test, type Page } from '@playwright/test';
import { seedUserData } from './fixtures.js';
import { collect, hook, launch, remove, setKey, type Running } from './harness.js';

// Where main puts the dictation HUD and when it counts a new appearance, on the built app.
// No window is ever shown under `--e2e`: main runs the real placement logic against a stand-in
// window and records every frame it pushes with the window origin it chose (`__uv.hudFrames`).
// The caret is faked (`__uv.setCaret`, with a delay), the recordings are real ones from
// Chromium's fake microphone, and every dictation here ends by cancelling or failing: the
// hotkey is never pressed to completion, so nothing is pasted anywhere.

const SECOND = 1000;

interface Frame {
  kind: string;
  seq?: number;
  appearance?: number;
  placement?: { kind: 'bottom' } | { kind: 'caret'; flipped: boolean };
  origin?: { x: number; y: number };
  stopsIn?: number;
}
interface WorkArea {
  x: number;
  y: number;
  width: number;
  height: number;
}
interface Caret {
  x: number;
  y: number;
  w: number;
  h: number;
}

let run: Running | null = null;

test.afterEach(async () => {
  const current = run;
  run = null;
  if (!current) return;
  try {
    await current.stop();
  } finally {
    await remove(current.userData);
  }
});

async function start(name: string, key = 'valid-e2e-key'): Promise<Running> {
  const userData = await seedUserData({ emptyHistory: true });
  run = await launch(name, userData);
  await collect(run.win);
  await setKey(run.win, key);
  return run;
}

const frames = (r: Running): Promise<Frame[]> => hook(r.app, 'hudFrames') as Promise<Frame[]>;
const workArea = (r: Running): Promise<WorkArea> => r.app.evaluate(({ screen }) => screen.getPrimaryDisplay().workArea);
const setCaret = (r: Running, rect: Caret | null, delayMs = 0): Promise<unknown> => hook(r.app, 'setCaret', { rect, delayMs });
const lastRecording = async (r: Running): Promise<Frame | undefined> => (await frames(r)).filter((f) => f.kind === 'recording').at(-1);

/** Where the window goes for a caret placement on the right of the caret (14 gap, 28 inset). */
const rightOf = (c: Caret): number => c.x + c.w + 14 - 28;
/** And for a flipped one: trailing edge 14 left of the caret, 28 from the window's right edge. */
const leftOf = (c: Caret): number => c.x - 14 - (520 - 28);
const centredY = (c: Caret): number => Math.round(c.y + c.h / 2 - 48);

const startButton = (win: Page) => win.getByRole('button', { name: 'Start dictating' });
const stopButton = (win: Page) => win.getByRole('button', { name: 'Stop and transcribe' });

test('a recording near the right edge sits beside the caret, and a later countdown on the same dictation moves it to the left', async () => {
  const r = await start('hud-place-flip');
  const wa = await workArea(r);
  expect(wa.width).toBeGreaterThanOrEqual(900);
  // 204 from the right edge: 170 of room fits (so no flip at the start) but the 210 wide bubble with
  // its "Stops in" label does not, and the left side has plenty.
  const caret: Caret = { x: wa.x + wa.width - 204, y: wa.y + 300, w: 0, h: 20 };
  await setCaret(r, caret);
  await hook(r.app, 'pressHotkey');

  await expect.poll(() => lastRecording(r), { timeout: 15 * SECOND }).toBeTruthy();
  const first = (await lastRecording(r))!;
  expect(first.placement).toEqual({ kind: 'caret', flipped: false });
  expect(first.origin).toEqual({ x: rightOf(caret), y: centredY(caret) });

  await hook(r.app, 'hudTelemetry', { level: 0.2, elapsedSeconds: 5, silenceRemaining: 5 });
  await expect.poll(async () => (await lastRecording(r))?.stopsIn, { timeout: 10 * SECOND }).toBe(5);
  const later = (await lastRecording(r))!;
  // Same dictation, same appearance, same seq: only the side changed.
  expect(later.appearance).toBe(first.appearance);
  expect(later.seq).toBe(first.seq);
  expect(later.placement).toEqual({ kind: 'caret', flipped: true });
  expect(later.origin).toEqual({ x: leftOf(caret), y: centredY(caret) });

  await hook(r.app, 'cancel');
  await expect.poll(() => hook(r.app, 'serviceState')).toBe('idle');
});

test('a cancel during a slow caret lookup and an immediate new recording: the new one is its own appearance at its own caret', async () => {
  const r = await start('hud-place-stale');
  const wa = await workArea(r);
  const first: Caret = { x: wa.x + 120, y: wa.y + 200, w: 0, h: 20 };
  const second: Caret = { x: wa.x + 520, y: wa.y + 380, w: 0, h: 20 };
  // Main waits 150 ms for the first answer. That is shorter than a recorder start can take, so widen it here:
  // the first appearance is then reliably still waiting when the cancel and the new press land.
  await hook(r.app, 'setCaretWait', 1000);

  // All inside main, so the cancel lands while the first appearance is still waiting for its caret
  // (the lookup answers after 400 ms, the wait is 1 s): press, wait for the recording state, cancel,
  // and press again with the other caret.
  await r.app.evaluate(
    async (_electron, args) => {
      const uv = (globalThis as unknown as { __uv: Record<string, (value?: unknown) => unknown> }).__uv;
      const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));
      const until = async (state: string): Promise<void> => {
        const deadline = Date.now() + 15_000;
        while (uv.serviceState!() !== state && Date.now() < deadline) await sleep(4);
      };
      uv.setCaret!({ rect: args.first, delayMs: 400 });
      void uv.pressHotkey!();
      await until('recording');
      await uv.cancel!();
      await until('idle');
      uv.setCaret!({ rect: args.second, delayMs: 0 });
      void uv.pressHotkey!();
    },
    { first, second },
  );

  await expect.poll(async () => (await lastRecording(r))?.origin?.x, { timeout: 15 * SECOND }).toBe(rightOf(second));
  const recording = (await lastRecording(r))!;
  expect(recording.placement).toEqual({ kind: 'caret', flipped: false });
  expect(recording.origin?.y).toBe(centredY(second));
  // The first press was appearance 1; the new recording is a new one.
  expect(recording.appearance).toBe(2);

  // Let the stale lookup answer (400 ms after the first press) and settle: it must change nothing.
  await r.win.waitForTimeout(700);
  const all = await frames(r);
  expect(all.some((f) => f.origin?.x === rightOf(first))).toBe(false);
  const after = (await lastRecording(r))!;
  expect(after.origin).toEqual(recording.origin);
  expect(after.appearance).toBe(2);

  await hook(r.app, 'cancel');
  await expect.poll(() => hook(r.app, 'serviceState')).toBe('idle');
});

test("a retry's first transcribing frame over a visible error starts a new appearance", async () => {
  const r = await start('hud-place-retry', 'offline-e2e-key');
  await startButton(r.win).click();
  await expect(stopButton(r.win)).toBeVisible({ timeout: 15 * SECOND });
  await r.win.waitForTimeout(1.5 * SECOND);
  await stopButton(r.win).click();
  await expect.poll(async () => (await frames(r)).some((f) => f.kind === 'error'), { timeout: 30 * SECOND }).toBe(true);

  const error = (await frames(r)).filter((f) => f.kind === 'error').at(-1)!;
  // The dictation so far was one appearance: recording, transcribing, error.
  expect(error.appearance).toBe(1);
  expect((await frames(r)).filter((f) => f.appearance === 1).map((f) => f.kind)).toContain('transcribing');

  await setKey(r.win, 'valid-e2e-key');
  await r.win.getByRole('button', { name: 'Retry last recording' }).click();
  await expect.poll(async () => (await frames(r)).some((f) => f.kind === 'done'), { timeout: 30 * SECOND }).toBe(true);

  const all = await frames(r);
  const retried = all.filter((f) => (f.seq ?? 0) > (error.seq ?? 0) && f.kind === 'transcribing')[0]!;
  expect(retried.appearance).toBe(2);
  expect(retried.placement).toEqual({ kind: 'bottom' });
  // And the rest of the retry stays in it.
  expect(all.filter((f) => f.kind === 'done').at(-1)?.appearance).toBe(2);
});

test('a lookup that finds nothing, or answers too late, leaves the bubble at the bottom', async () => {
  const r = await start('hud-place-bottom');
  const wa = await workArea(r);
  const caret: Caret = { x: wa.x + 400, y: wa.y + 300, w: 0, h: 20 };

  await setCaret(r, null);
  await hook(r.app, 'pressHotkey');
  await expect.poll(() => lastRecording(r), { timeout: 15 * SECOND }).toBeTruthy();
  const none = (await lastRecording(r))!;
  expect(none.placement).toEqual({ kind: 'bottom' });
  await hook(r.app, 'cancel');
  await expect.poll(() => hook(r.app, 'serviceState')).toBe('idle');

  // An answer after the 150 ms wait is too late: the bubble does not jump to the caret afterwards.
  await setCaret(r, caret, 600);
  await hook(r.app, 'pressHotkey');
  await expect.poll(async () => (await lastRecording(r))?.appearance, { timeout: 15 * SECOND }).toBeGreaterThan(none.appearance ?? 0);
  await r.win.waitForTimeout(900);
  const late = (await lastRecording(r))!;
  expect(late.placement).toEqual({ kind: 'bottom' });
  expect(late.origin?.x).not.toBe(rightOf(caret));

  await hook(r.app, 'cancel');
  await expect.poll(() => hook(r.app, 'serviceState')).toBe('idle');
});
