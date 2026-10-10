import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const MIN = 60_000;

function record(id: string, text: string, language: string, minutesAgo: number, appName = 'Slack') {
  const createdAt = new Date(Date.now() - minutesAgo * MIN).toISOString();
  return {
    id, text, rawText: text, intermediateText: text, language, appName,
    durationSeconds: Math.max(3, Math.round(text.split(/\s+/).length / 2.2)),
    mode: 'formatted', createdAt, replacementRuleIds: [], memoryHitIds: [], snippetIds: [],
  };
}

/** A scratch user-data folder with a realistic mix: English, German and Persian, over several days. */
export async function seedUserData(): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'uv-e2e-'));
  const history = [
    record('h1', 'Can you check whether the build is green before the release?', 'en', 4, 'Cursor'),
    record('h2', 'Please add the Windows installer to the launch checklist and ping the Barry team.', 'en', 35),
    record('h3', 'Und dann bitte die Kubernetes Konfiguration für das Staging prüfen.', 'de', 90),
    record('h4', 'Wir treffen uns morgen um zehn Uhr im Büro, bitte bring die Unterlagen mit.', 'de', 60 * 26),
    record('h5', 'لطفا گزارش هفتگی را تا فردا بفرستید.', 'fa', 60 * 50, 'Mail'),
    record('h6', 'The second bot should pick up the handoff and reply in the same thread.', 'en', 60 * 75, ''),
  ];
  const notes = [
    { id: 'n1', title: 'Launch checklist', body: '- [ ] Record the demo\n- [ ] Ship the installer',
      createdAt: new Date(Date.now() - 500 * MIN).toISOString(), updatedAt: new Date(Date.now() - 30 * MIN).toISOString() },
  ];
  const payload = { terms: [], replacements: [], snippets: [], suggestions: [], history, notes };
  await fs.writeFile(path.join(dir, 'data.json'), JSON.stringify({ version: 1, payload }, null, 2));
  return dir;
}
