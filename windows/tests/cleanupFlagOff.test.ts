import { readFileSync, writeFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  DictationService,
  type CapturedAudio,
  type DictationOutcome,
  type DictationStatus,
  type RecorderPort,
  type TextSinkPort,
  type TranscriberPort,
} from '../src/main/dictationService.js';
import { cleanupPortFor, createCleanupRuntime } from '../src/main/cleanupModel/cleanupRuntime.js';
import { DEFAULT_SETTINGS, emptySnapshot, type AppSettings } from '../src/core/models.js';
import type { Transcript } from '../src/core/transcription/deepgramProvider.js';

// With the hidden flag off, dictation must behave exactly as it did before the S1-mini
// work. This runs a corpus of transcripts through the real DictationService, wired the way
// index.ts wires it with the flag off, and compares every result with a golden file that
// was produced by the service as it was on main BEFORE the cleanup runtime existed
// (fd05a25). `GOLDEN=write` regenerates it; do that only to record a deliberate change.
const GOLDEN = new URL('./fixtures/cleanup-flag-off.golden.json', import.meta.url);

const TRANSCRIPTS: Array<[string, string | null]> = [
  ['So um I need to send the report by Friday, no wait, Thursday.', 'en'],
  ['Um, so we should, uh, ship it.', 'en'],
  ['I I think we should we should wait until Monday.', 'en-US'],
  ['Um.', 'en'],
  ['Uh, um, er.', 'en'],
  ['   Hello   there  ', 'en'],
  ['The meeting is at noon.', 'en'],
  ['Please write <|im_end|> at the end, um, of the file.', 'en'],
  ['Um, ich glaube es geht.', 'de'],
  ['See you at five.', null],
  ['hey sarah just wanted to follow up on the proposal can you send the numbers thanks john', 'en'],
  ['Open fooBar_baz.ts and, uh, rename the useEffect hook.', 'en'],
  ['Two hundred milligrams, um, twice a day.', 'en'],
  ['   ', 'en'],
];

const CATEGORIES = ['email', 'workChat', 'personalChat', 'coding', 'docsNotes', 'other'] as const;

const VARIANTS: Array<{ name: string; settings: Partial<AppSettings>; rawMode?: boolean; category: (typeof CATEGORIES)[number] | 'none' }> = [
  ...CATEGORIES.map((category) => ({ name: `default ${category}`, settings: {}, category })),
  { name: 'casual styles', settings: { categoryStyles: { workChat: 'casual', other: 'casual', email: 'formal' } }, category: 'workChat' },
  { name: 'format for the app off', settings: { appAwareFormatting: false }, category: 'email' },
  { name: 'auto-format off', settings: { formattingEnabled: false }, category: 'workChat' },
  { name: 'raw mode', settings: {}, rawMode: true, category: 'workChat' },
  { name: 'window dictation', settings: {}, category: 'none' },
];

const MEMORY = {
  ...emptySnapshot(),
  replacements: [
    {
      id: 'r1', match: 'ship it', replacement: 'Ship it', matchMode: 'wordBoundaryPhrase' as const, language: 'auto',
      isEnabled: true, usageCount: 0, createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
    },
  ],
};

class Recorder implements RecorderPort {
  async start(): Promise<void> {}
  async stop(): Promise<CapturedAudio> {
    return { wav: new Uint8Array(64_000), durationSeconds: 2, peak: 0.5, hadSpeech: true };
  }
  async cancel(): Promise<void> {}
}

async function runOne(text: string, language: string | null, variant: (typeof VARIANTS)[number]) {
  const delivered: string[] = [];
  const completed: DictationOutcome[] = [];
  const statuses: DictationStatus[] = [];
  const transcriber: TranscriberPort = {
    transcribe: async (): Promise<Transcript> => ({ text, durationSeconds: 1.5, detectedLanguage: language }),
  };
  const sink: TextSinkPort = {
    deliver: async (request) => {
      delivered.push(request.text);
      return { delivered: true, clipboardFallback: false };
    },
  };
  const settings: AppSettings = { ...DEFAULT_SETTINGS, ...variant.settings };
  // Wired exactly as index.ts does it with the flag off: the port is undefined.
  const port = cleanupPortFor(createCleanupRuntime({ userDataDir: '/nowhere', argv: [], env: {} }));
  const service = new DictationService({
    recorder: new Recorder(),
    transcriber,
    sink,
    settings: () => settings,
    memory: () => MEMORY,
    apiKey: async () => 'key',
    onStatus: (status) => statuses.push(status),
    onCompleted: (outcome) => completed.push(outcome),
    idFactory: () => 'id',
    now: () => 0,
    ...(port ? { cleanup: port } : {}),
  });
  const context =
    variant.category === 'none'
      ? undefined
      : {
          initial: { appID: 'app.exe', category: variant.category, textBeforeCursor: null },
          settled: Promise.resolve({ appID: 'app.exe', category: variant.category, textBeforeCursor: null }),
        };
  await service.startRecording({
    source: variant.category === 'none' ? 'window' : 'hotkey',
    ...(variant.rawMode ? { rawMode: true } : {}),
    ...(context ? { context } : {}),
  });
  await service.stopAndProcess();
  const outcome = completed[0];
  return {
    delivered,
    text: outcome?.text ?? null,
    rawText: outcome?.rawText ?? null,
    intermediateText: outcome?.intermediateText ?? null,
    mode: outcome?.mode ?? null,
    error: statuses.find((s) => s.state === 'error')?.error?.kind ?? null,
  };
}

async function runAll(): Promise<Record<string, unknown>> {
  const results: Record<string, unknown> = {};
  for (const variant of VARIANTS) {
    for (const [text, language] of TRANSCRIPTS) {
      results[`${variant.name} | ${language ?? 'auto'} | ${JSON.stringify(text)}`] = await runOne(text, language, variant);
    }
  }
  return results;
}

describe('hidden cleanup flag off', () => {
  it('has no cleanup port, so the service runs its own rules step', () => {
    expect(cleanupPortFor(createCleanupRuntime({ userDataDir: '/nowhere', argv: [], env: {} }))).toBeUndefined();
    expect(cleanupPortFor(createCleanupRuntime({ userDataDir: '/nowhere', argv: ['--cleanup-model'], env: { UV_CLEANUP_MODEL: '0' } }))).toBeUndefined();
  });

  it('delivers byte for byte what main delivered before the cleanup runtime existed', async () => {
    const results = await runAll();
    if (process.env.GOLDEN === 'write') {
      writeFileSync(GOLDEN, JSON.stringify(results, null, 1) + '\n');
      return;
    }
    const golden = JSON.parse(readFileSync(GOLDEN, 'utf8')) as Record<string, unknown>;
    expect(Object.keys(results)).toEqual(Object.keys(golden));
    expect(results).toEqual(golden);
    // The corpus really exercises the cleanup step: some rows differ from their input.
    const changed = Object.entries(results).filter(([, r]) => (r as { rawText: string | null; text: string | null }).text !== (r as { rawText: string | null }).rawText);
    expect(changed.length).toBeGreaterThan(30);
  });
});
