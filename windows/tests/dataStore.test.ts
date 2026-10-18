import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DataStore, CURRENT_VERSION } from '../src/core/settings/dataStore.js';
import { readJson, writeJsonAtomic } from '../src/core/settings/jsonStore.js';
import type { MemoryTerm, Note, ReplacementRule } from '../src/core/models.js';

let directory: string;
let storePath: string;

beforeEach(async () => {
  directory = await fs.mkdtemp(path.join(os.tmpdir(), 'useful-voice-test-'));
  storePath = path.join(directory, 'data.json');
});

afterEach(async () => {
  await fs.rm(directory, { recursive: true, force: true });
});

function term(partial: Partial<MemoryTerm> & { phrase: string }): MemoryTerm {
  return {
    id: partial.id ?? 'term-1',
    phrase: partial.phrase,
    aliases: partial.aliases ?? [],
    pronunciations: partial.pronunciations ?? [],
    language: partial.language ?? 'auto',
    priority: partial.priority ?? 'normal',
    notes: partial.notes ?? '',
    usageCount: partial.usageCount ?? 0,
    createdAt: partial.createdAt ?? '2026-01-01T00:00:00.000Z',
    updatedAt: partial.updatedAt ?? '2026-01-01T00:00:00.000Z',
  };
}

function rule(partial: Partial<ReplacementRule> & { match: string; replacement: string }): ReplacementRule {
  return {
    id: partial.id ?? 'rule-1',
    match: partial.match,
    replacement: partial.replacement,
    matchMode: partial.matchMode ?? 'wordBoundaryPhrase',
    language: partial.language ?? 'auto',
    isEnabled: partial.isEnabled ?? true,
    usageCount: partial.usageCount ?? 0,
    createdAt: partial.createdAt ?? '2026-01-01T00:00:00.000Z',
    updatedAt: partial.updatedAt ?? '2026-01-01T00:00:00.000Z',
  };
}

function note(partial: Partial<Note> & { id: string }): Note {
  return {
    id: partial.id,
    title: partial.title ?? 'Title',
    body: partial.body ?? 'Body',
    createdAt: partial.createdAt ?? '2026-01-01T00:00:00.000Z',
    updatedAt: partial.updatedAt ?? '2026-01-01T00:00:00.000Z',
  };
}

describe('load outcomes', () => {
  it('reports a clean start when the file does not exist', async () => {
    const store = new DataStore(storePath);
    const outcome = await store.load();
    expect(outcome.status).toBe('fresh');
    expect(store.isWritable).toBe(true);
  });

  it('round-trips data through disk', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertTerm(term({ phrase: 'Kubernetes' }));
    expect(await store.flush()).toBe(true);

    const reloaded = new DataStore(storePath);
    await reloaded.load();
    expect(reloaded.snapshot().terms.map((entry) => entry.phrase)).toEqual(['Kubernetes']);
  });

  /**
   * A read failure is NOT the same as "no data". The macOS store treated every
   * read error as an empty file and then overwrote the intact file on the next
   * mutation, so one transient lock at launch became permanent data loss.
   */
  it('refuses to write when the file exists but cannot be read', async () => {
    await writeJsonAtomic(storePath, { version: CURRENT_VERSION, payload: { terms: [] } });
    const store = new DataStore(storePath);
    // Simulate an unreadable file by making the path a directory. Reading it
    // fails with EISDIR, which is not ENOENT.
    const asDirectory = path.join(directory, 'adir');
    await fs.mkdir(asDirectory);
    const blocked = new DataStore(asDirectory);
    const outcome = await blocked.load();
    expect(outcome.status).toBe('unreadable');
    expect(blocked.isWritable).toBe(false);
    // The guard itself:
    expect(await blocked.flush()).toBe(false);
    expect(store.isWritable).toBe(true);
  });

  it('quarantines a corrupt file under a timestamped name', async () => {
    await fs.writeFile(storePath, '{ this is not json', 'utf8');
    const store = new DataStore(storePath);
    const outcome = await store.load();
    expect(outcome.status).toBe('corrupt');
    if (outcome.status === 'corrupt') {
      expect(outcome.quarantinedTo).toContain('corrupt-');
      // The evidence is preserved, not deleted.
      await expect(fs.access(outcome.quarantinedTo)).resolves.toBeUndefined();
    }
  });

  it('does not destroy a previous quarantine on a second incident', async () => {
    await fs.writeFile(storePath, 'garbage one', 'utf8');
    const first = new DataStore(storePath);
    const firstOutcome = await first.load();
    expect(firstOutcome.status).toBe('corrupt');

    await fs.writeFile(storePath, 'garbage two', 'utf8');
    const second = new DataStore(storePath);
    const secondOutcome = await second.load();
    expect(secondOutcome.status).toBe('corrupt');

    if (firstOutcome.status === 'corrupt' && secondOutcome.status === 'corrupt') {
      expect(firstOutcome.quarantinedTo).not.toBe(secondOutcome.quarantinedTo);
      await expect(fs.access(firstOutcome.quarantinedTo)).resolves.toBeUndefined();
      await expect(fs.access(secondOutcome.quarantinedTo)).resolves.toBeUndefined();
    }
  });

  /**
   * A file written by a newer build must never be downgraded. The macOS store
   * wrote a version field and never read it, so a newer file decoded (unknown keys
   * ignored) and the next save rewrote it in the old shape, discarding the newer
   * fields.
   */
  it('refuses to read or write a file from a newer schema version', async () => {
    await fs.writeFile(
      storePath,
      JSON.stringify({ version: CURRENT_VERSION + 5, payload: { terms: [] } }),
      'utf8',
    );
    const store = new DataStore(storePath);
    const outcome = await store.load();
    expect(outcome.status).toBe('incompatible');
    expect(store.isWritable).toBe(false);
    expect(await store.flush()).toBe(false);
    // The newer file is untouched.
    const raw = await fs.readFile(storePath, 'utf8');
    expect(raw).toContain(String(CURRENT_VERSION + 5));
  });

  it('accepts a pre-versioned file and records the upgrade', async () => {
    await fs.writeFile(
      storePath,
      JSON.stringify({ terms: [term({ phrase: 'Legacy Term' })], replacements: [], snippets: [], suggestions: [], history: [], notes: [] }),
      'utf8',
    );
    const store = new DataStore(storePath);
    const outcome = await store.load();
    expect(outcome.status).toBe('loaded');
    if (outcome.status === 'loaded') expect(outcome.migratedFrom).toBe(0);
    expect(store.snapshot().terms[0]?.phrase).toBe('Legacy Term');
  });
});

describe('save failures are reported, never swallowed', () => {
  it('reports a write failure to listeners and via saveError', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertTerm(term({ phrase: 'Kubernetes' }));

    // Make every subsequent write fail by turning the target into a directory.
    await fs.rm(storePath, { force: true });
    await fs.mkdir(storePath);

    const reported: Error[] = [];
    store.onSaveFailure((error) => reported.push(error));

    const ok = await store.flush();
    expect(ok).toBe(false);
    expect(store.saveError).not.toBeNull();
    expect(reported.length).toBeGreaterThan(0);
  });

  it('clears the error once a write succeeds again', async () => {
    const store = new DataStore(storePath);
    await store.load();
    await fs.mkdir(storePath);
    expect(await store.flush()).toBe(false);
    expect(store.saveError).not.toBeNull();

    await fs.rm(storePath, { recursive: true, force: true });
    expect(await store.flush()).toBe(true);
    expect(store.saveError).toBeNull();
  });

  it('never reports success for a write that did not happen', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertTerm(term({ phrase: 'X' }));
    await fs.mkdir(storePath);
    expect(await store.flush()).toBe(false);
  });
});

describe('upsert merge semantics', () => {
  it('merges a term instead of replacing it', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertTerm(term({ id: 'a', phrase: 'Claude Code', aliases: ['cloud code'], priority: 'high', usageCount: 5 }));
    store.upsertTerm(term({ id: 'b', phrase: 'claude code', aliases: ['claude'], priority: 'normal' }));

    const terms = store.snapshot().terms;
    expect(terms).toHaveLength(1);
    const merged = terms[0] as MemoryTerm;
    // Existing identity is kept: history and usage counters reference it.
    expect(merged.id).toBe('a');
    expect(merged.aliases.sort()).toEqual(['claude', 'cloud code']);
    expect(merged.priority).toBe('high');
    expect(merged.usageCount).toBe(5);
  });

  /**
   * The macOS replacement/snippet upserts replaced the record wholesale, so
   * importing a backup silently re-enabled rules the user had paused.
   */
  it('does not re-enable a paused rule when a different record is imported', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertReplacement(rule({ id: 'local', match: 'then', replacement: 'than', isEnabled: false }));
    store.upsertReplacement(rule({ id: 'imported', match: 'then', replacement: 'than', isEnabled: true }));

    const rules = store.snapshot().replacements;
    expect(rules).toHaveLength(1);
    expect(rules[0]?.isEnabled).toBe(false);
    expect(rules[0]?.id).toBe('local');
  });

  it('lets an explicit edit of the same record change its state', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertReplacement(rule({ id: 'r', match: 'then', replacement: 'than', isEnabled: true }));
    store.upsertReplacement(rule({ id: 'r', match: 'then', replacement: 'than', isEnabled: false }));
    expect(store.snapshot().replacements[0]?.isEnabled).toBe(false);
  });

  it('keeps the higher usage count rather than zeroing it', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertReplacement(rule({ id: 'r', match: 'alpha', replacement: 'A', usageCount: 7 }));
    store.upsertReplacement(rule({ id: 'other', match: 'alpha', replacement: 'A', usageCount: 0 }));
    expect(store.snapshot().replacements[0]?.usageCount).toBe(7);
  });

  it('normalises aliases so the same variant is not stored twice', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertTerm(term({ phrase: 'M\u00FCller', aliases: ['Mu\u0308ller'] }));
    expect(store.snapshot().terms[0]?.aliases).toHaveLength(1);
  });
});

describe('note deletion and undo', () => {
  it('returns the deleted note and its position', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertNote(note({ id: 'n1', title: 'One' }));
    store.upsertNote(note({ id: 'n2', title: 'Two' }));
    store.upsertNote(note({ id: 'n3', title: 'Three' }));
    // unshift puts newest first: n3, n2, n1
    const removed = store.deleteNote('n2');
    expect(removed?.note.title).toBe('Two');
    expect(removed?.index).toBe(1);
    expect(store.notes.map((entry) => entry.id)).toEqual(['n3', 'n1']);
  });

  it('restores a deleted note to its original position', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertNote(note({ id: 'n1' }));
    store.upsertNote(note({ id: 'n2' }));
    store.upsertNote(note({ id: 'n3' }));

    const removed = store.deleteNote('n2');
    expect(removed).not.toBeNull();
    if (removed) store.restoreNote(removed.note, removed.index);

    expect(store.notes.map((entry) => entry.id)).toEqual(['n3', 'n2', 'n1']);
  });

  it('persists a restore so it survives a reload', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertNote(note({ id: 'n1', title: 'Keep me', body: 'important' }));
    const removed = store.deleteNote('n1');
    if (removed) store.restoreNote(removed.note, removed.index);
    await store.flush();

    const reloaded = new DataStore(storePath);
    await reloaded.load();
    expect(reloaded.notes).toHaveLength(1);
    expect(reloaded.notes[0]?.title).toBe('Keep me');
    expect(reloaded.notes[0]?.body).toBe('important');
  });

  it('does not duplicate a note when restore is called twice', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertNote(note({ id: 'n1' }));
    const removed = store.deleteNote('n1');
    if (removed) {
      store.restoreNote(removed.note, removed.index);
      store.restoreNote(removed.note, removed.index);
    }
    expect(store.notes).toHaveLength(1);
  });

  it('returns null for an unknown id', async () => {
    const store = new DataStore(storePath);
    await store.load();
    expect(store.deleteNote('missing')).toBeNull();
  });
});

describe('import', () => {
  it('keeps a newer local note instead of overwriting it', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertNote(note({ id: 'n1', title: 'Local newer', updatedAt: '2026-06-01T00:00:00.000Z' }));

    const summary = store.importPayload({
      notes: [note({ id: 'n1', title: 'Backup older', updatedAt: '2026-01-01T00:00:00.000Z' })],
    });

    expect(store.notes[0]?.title).toBe('Local newer');
    expect(summary.notesKeptLocal).toBe(1);
    expect(summary.notesUpdated).toBe(0);
  });

  it('accepts a newer imported note', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertNote(note({ id: 'n1', title: 'Local older', updatedAt: '2026-01-01T00:00:00.000Z' }));

    const summary = store.importPayload({
      notes: [note({ id: 'n1', title: 'Backup newer', updatedAt: '2026-06-01T00:00:00.000Z' })],
    });

    expect(store.notes[0]?.title).toBe('Backup newer');
    expect(summary.notesUpdated).toBe(1);
  });

  it('inserts a note with an unknown id', async () => {
    const store = new DataStore(storePath);
    await store.load();
    const summary = store.importPayload({ notes: [note({ id: 'new' })] });
    expect(store.notes).toHaveLength(1);
    expect(summary.notesInserted).toBe(1);
  });

  it('caps imported suggestions', async () => {
    const store = new DataStore(storePath);
    await store.load();
    const many = Array.from({ length: 200 }, (_, i) => ({
      id: `s${i}`,
      observed: `obs${i}`,
      corrected: `corr${i}`,
      evidenceCount: 1,
      createdAt: '2026-01-01T00:00:00.000Z',
    }));
    store.importPayload({ suggestions: many });
    expect(store.snapshot().suggestions.length).toBeLessThanOrEqual(20);
  });

  it('does not duplicate history records on re-import', async () => {
    const store = new DataStore(storePath);
    await store.load();
    const record = {
      id: 'h1', text: 'hello', rawText: 'hello', intermediateText: 'hello',
      language: 'en' as const, appName: 'Notepad', durationSeconds: 1,
      mode: 'raw' as const, createdAt: '2026-01-01T00:00:00.000Z',
      replacementRuleIds: [], memoryHitIds: [], snippetIds: [],
    };
    store.importPayload({ history: [record] });
    store.importPayload({ history: [record] });
    expect(store.history).toHaveLength(1);
  });
});

describe('history retention', () => {
  it('keeps only the newest records', async () => {
    const store = new DataStore(storePath);
    await store.load();
    for (let i = 0; i < DataStore.HISTORY_CAP + 50; i += 1) {
      store.appendHistory({
        id: `h${i}`, text: `t${i}`, rawText: '', intermediateText: '',
        language: 'en', appName: 'app', durationSeconds: 1, mode: 'raw',
        createdAt: new Date(2026, 0, 1, 0, 0, i).toISOString(),
        replacementRuleIds: [], memoryHitIds: [], snippetIds: [],
      });
    }
    expect(store.history).toHaveLength(DataStore.HISTORY_CAP);
  });
});

describe('usage counters', () => {
  it('increments the counters for fired entries', async () => {
    const store = new DataStore(storePath);
    await store.load();
    store.upsertTerm(term({ id: 't1', phrase: 'Kubernetes' }));
    store.upsertReplacement(rule({ id: 'r1', match: 'alpha', replacement: 'A' }));
    store.recordUsage({ termIds: ['t1'], replacementRuleIds: ['r1', 'synthetic-ignored'] });
    expect(store.snapshot().terms[0]?.usageCount).toBe(1);
    expect(store.snapshot().replacements[0]?.usageCount).toBe(1);
  });

  it('ignores unknown ids without throwing', async () => {
    const store = new DataStore(storePath);
    await store.load();
    expect(() => store.recordUsage({ termIds: ['nope'] })).not.toThrow();
  });
});

describe('jsonStore', () => {
  it('writes atomically and leaves no temp files behind', async () => {
    const target = path.join(directory, 'atomic.json');
    await writeJsonAtomic(target, { a: 1 });
    const entries = await fs.readdir(directory);
    expect(entries.filter((entry) => entry.includes('.tmp-'))).toHaveLength(0);
    const result = await readJson<{ a: number }>(target);
    expect(result.value?.a).toBe(1);
  });

  it('reports ENOENT as fresh rather than as a failure', async () => {
    const result = await readJson(path.join(directory, 'absent.json'));
    expect(result.outcome.status).toBe('fresh');
    expect(result.writable).toBe(true);
  });

  it('cleans up the temp file when the write fails', async () => {
    const asDirectory = path.join(directory, 'blocked');
    await fs.mkdir(asDirectory);
    await expect(writeJsonAtomic(asDirectory, { a: 1 })).rejects.toThrow();
    const entries = await fs.readdir(directory);
    expect(entries.filter((entry) => entry.includes('.tmp-'))).toHaveLength(0);
  });

  it('overwrites an existing file rather than appending', async () => {
    const target = path.join(directory, 'over.json');
    await writeJsonAtomic(target, { value: 'first' });
    await writeJsonAtomic(target, { value: 'second' });
    const result = await readJson<{ value: string }>(target);
    expect(result.value?.value).toBe('second');
  });
});
