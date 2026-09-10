import type {
  DictationRecord,
  LanguageMemorySnapshot,
  MemoryLanguage,
  MemorySnippet,
  MemorySuggestion,
  MemoryTerm,
  Note,
  ReplacementRule,
} from '../models.js';
import { canonical, matches } from '../dictionary/termMatcher.js';
import { readJson, writeJsonAtomic, type LoadOutcome } from './jsonStore.js';

/**
 * Schema version of the persisted store.
 *
 * The macOS implementation wrote a version field but never validated it, which is
 * worse than not having one: a file written by a NEWER build decoded successfully
 * (unknown keys are ignored), and the next save silently rewrote it in the old
 * shape, discarding whatever the newer build had added. It also meant a version
 * rollback quarantined the file and started empty, losing the whole dictionary.
 */
export const CURRENT_VERSION = 1;

export interface Persisted<TPayload> {
  version: number;
  payload: TPayload;
}

export interface ScopePayload {
  terms: MemoryTerm[];
  replacements: ReplacementRule[];
  snippets: MemorySnippet[];
  suggestions: MemorySuggestion[];
  history: DictationRecord[];
  notes: Note[];
}

export function emptyScope(): ScopePayload {
  return {
    terms: [],
    replacements: [],
    snippets: [],
    suggestions: [],
    history: [],
    notes: [],
  };
}

/** Observers are told about every persistence failure, so the UI can show it. */
export type SaveFailureListener = (error: Error) => void;

/** Debounce window for history writes, in milliseconds. */
const HISTORY_WRITE_DEBOUNCE_MS = 500;

/**
 * The single source of truth for user data.
 *
 * In-memory state is authoritative and every mutation writes through to disk with
 * a bounded debounce. The macOS build re-encoded and rewrote the ENTIRE store
 * synchronously on the main thread at the end of every dictation, which was a
 * visible hitch that grew with history size.
 */
export class DataStore {
  private payload: ScopePayload = emptyScope();
  private loaded = false;
  private writable = true;
  private loadOutcome: LoadOutcome = { status: 'fresh' };
  private writeTimer: NodeJS.Timeout | null = null;
  private writeInFlight: Promise<void> | null = null;
  private readonly failureListeners = new Set<SaveFailureListener>();
  /** Set when the last write attempt failed, cleared on the next success. */
  private lastError: Error | null = null;

  constructor(private readonly filePath: string) {}

  /** Read the file once at startup. */
  async load(): Promise<LoadOutcome> {
    const result = await readJson<Persisted<ScopePayload>>(this.filePath);
    this.loadOutcome = result.outcome;

    if (result.value && typeof result.value === 'object' && 'payload' in result.value) {
      const version = Number((result.value as Persisted<ScopePayload>).version);
      if (Number.isFinite(version) && version > CURRENT_VERSION) {
        // A newer build wrote this. Refuse to read it AND refuse to write: an
        // older build must never downgrade a newer file.
        this.loadOutcome = { status: 'incompatible', version };
        this.writable = false;
        this.payload = emptyScope();
        this.loaded = true;
        return this.loadOutcome;
      }
      this.payload = normalisePayload(result.value.payload);
    } else if (result.value && typeof result.value === 'object') {
      // Pre-versioned file from an earlier release: accept it and upgrade on save.
      this.payload = normalisePayload(result.value as unknown as ScopePayload);
      this.loadOutcome = { status: 'loaded', migratedFrom: 0 };
    }

    this.writable = result.writable;
    this.loaded = true;
    return this.loadOutcome;
  }

  get isLoaded(): boolean {
    return this.loaded;
  }

  get isWritable(): boolean {
    return this.writable;
  }

  get outcome(): LoadOutcome {
    return this.loadOutcome;
  }

  get saveError(): Error | null {
    return this.lastError;
  }

  onSaveFailure(listener: SaveFailureListener): () => void {
    this.failureListeners.add(listener);
    return () => this.failureListeners.delete(listener);
  }

  snapshot(): Readonly<ScopePayload> {
    return this.payload;
  }

  memorySnapshot(): LanguageMemorySnapshot {
    return {
      terms: this.payload.terms,
      replacements: this.payload.replacements,
      snippets: this.payload.snippets,
      suggestions: this.payload.suggestions,
    };
  }

  // ---- terms -------------------------------------------------------------

  /**
   * Insert or merge a term.
   *
   * Merging rather than replacing is deliberate. The macOS `upsertReplacement`
   * and `upsertSnippet` replaced the record wholesale, so importing a backup
   * silently re-enabled rules the user had paused, reset their usage counts, and
   * changed their ids (breaking per-dictation history links).
   */
  upsertTerm(term: MemoryTerm): MemoryTerm {
    const index = this.payload.terms.findIndex(
      (existing) => existing.id === term.id || matches(existing.phrase, term.phrase),
    );
    if (index < 0) {
      const toInsert = normaliseTerm(term);
      this.payload.terms.unshift(toInsert);
      this.scheduleSave();
      return toInsert;
    }

    const existing = this.payload.terms[index] as MemoryTerm;
    const merged: MemoryTerm = {
      // Keep the existing identity: history and usage counters reference it.
      id: existing.id,
      phrase: existing.phrase,
      aliases: unique([...existing.aliases, ...term.aliases]),
      pronunciations: unique([...existing.pronunciations, ...term.pronunciations]),
      language: existing.language === 'auto' ? term.language : existing.language,
      priority: strongerPriority(existing.priority, term.priority),
      notes: term.notes.length > 0 ? term.notes : existing.notes,
      usageCount: Math.max(existing.usageCount, term.usageCount),
      createdAt: existing.createdAt,
      updatedAt: newest(existing.updatedAt, term.updatedAt),
    };
    this.payload.terms[index] = merged;
    this.scheduleSave();
    return merged;
  }

  upsertReplacement(rule: ReplacementRule): ReplacementRule {
    const index = this.payload.replacements.findIndex(
      (existing) => existing.id === rule.id || matches(existing.match, rule.match),
    );
    if (index < 0) {
      this.payload.replacements.unshift(rule);
      this.scheduleSave();
      return rule;
    }
    const existing = this.payload.replacements[index] as ReplacementRule;
    const merged: ReplacementRule = {
      id: existing.id,
      match: existing.match,
      // An explicit edit of the same record may change the replacement text; an
      // import of a different record may not.
      replacement: rule.id === existing.id ? rule.replacement : existing.replacement,
      matchMode: existing.matchMode,
      language: existing.language,
      // A DIFFERENT record must never re-enable a rule the user paused.
      isEnabled: rule.id === existing.id ? rule.isEnabled : existing.isEnabled,
      usageCount: Math.max(existing.usageCount, rule.usageCount),
      createdAt: existing.createdAt,
      updatedAt: newest(existing.updatedAt, rule.updatedAt),
    };
    this.payload.replacements[index] = merged;
    this.scheduleSave();
    return merged;
  }

  upsertSnippet(snippet: MemorySnippet): MemorySnippet {
    const index = this.payload.snippets.findIndex(
      (existing) => existing.id === snippet.id || matches(existing.trigger, snippet.trigger),
    );
    if (index < 0) {
      this.payload.snippets.unshift(snippet);
      this.scheduleSave();
      return snippet;
    }
    const existing = this.payload.snippets[index] as MemorySnippet;
    const merged: MemorySnippet = {
      id: existing.id,
      trigger: existing.trigger,
      expansion: snippet.id === existing.id ? snippet.expansion : existing.expansion,
      language: existing.language,
      isEnabled: snippet.id === existing.id ? snippet.isEnabled : existing.isEnabled,
      usageCount: Math.max(existing.usageCount, snippet.usageCount),
      createdAt: existing.createdAt,
      updatedAt: newest(existing.updatedAt, snippet.updatedAt),
    };
    this.payload.snippets[index] = merged;
    this.scheduleSave();
    return merged;
  }

  removeTerm(id: string): boolean {
    return this.removeWhere(this.payload.terms, (term) => term.id === id);
  }

  removeReplacement(id: string): boolean {
    return this.removeWhere(this.payload.replacements, (rule) => rule.id === id);
  }

  removeSnippet(id: string): boolean {
    return this.removeWhere(this.payload.snippets, (snippet) => snippet.id === id);
  }

  setReplacementEnabled(id: string, isEnabled: boolean): void {
    const rule = this.payload.replacements.find((entry) => entry.id === id);
    if (!rule) return;
    rule.isEnabled = isEnabled;
    rule.updatedAt = new Date().toISOString();
    this.scheduleSave();
  }

  setSnippetEnabled(id: string, isEnabled: boolean): void {
    const snippet = this.payload.snippets.find((entry) => entry.id === id);
    if (!snippet) return;
    snippet.isEnabled = isEnabled;
    snippet.updatedAt = new Date().toISOString();
    this.scheduleSave();
  }

  setTermPriority(id: string, priority: MemoryTerm['priority']): void {
    const term = this.payload.terms.find((entry) => entry.id === id);
    if (!term) return;
    term.priority = priority;
    term.updatedAt = new Date().toISOString();
    this.scheduleSave();
  }

  private removeWhere<T extends { id: string }>(list: T[], predicate: (item: T) => boolean): boolean {
    const index = list.findIndex(predicate);
    if (index < 0) return false;
    list.splice(index, 1);
    this.scheduleSave();
    return true;
  }

  // ---- suggestions -------------------------------------------------------

  /** Add or bump a suggestion, keeping the list capped. */
  addSuggestion(suggestion: MemorySuggestion, cap = 20): void {
    const index = this.payload.suggestions.findIndex(
      (existing) => matches(existing.observed, suggestion.observed)
        && canonical(existing.corrected) === canonical(suggestion.corrected),
    );
    if (index >= 0) {
      const existing = this.payload.suggestions[index] as MemorySuggestion;
      existing.evidenceCount += 1;
    } else {
      this.payload.suggestions.push(suggestion);
    }
    // Rank by evidence so the cap keeps the most corroborated suggestions.
    this.payload.suggestions.sort((a, b) => {
      if (a.evidenceCount !== b.evidenceCount) return b.evidenceCount - a.evidenceCount;
      return a.createdAt.localeCompare(b.createdAt);
    });
    if (this.payload.suggestions.length > cap) {
      this.payload.suggestions = this.payload.suggestions.slice(0, cap);
    }
    this.scheduleSave();
  }

  removeSuggestion(id: string): boolean {
    return this.removeWhere(this.payload.suggestions, (suggestion) => suggestion.id === id);
  }

  // ---- usage -------------------------------------------------------------

  /**
   * Record which memory entries fired on a dictation.
   *
   * Counters are capped so that a frequently misheard term cannot climb forever
   * and permanently occupy keyterm budget ahead of things the user actually says.
   */
  recordUsage(ids: {
    termIds?: readonly string[];
    replacementRuleIds?: readonly string[];
    snippetIds?: readonly string[];
  }): void {
    const cap = 1_000_000;
    for (const id of ids.termIds ?? []) {
      const term = this.payload.terms.find((entry) => entry.id === id);
      if (term) term.usageCount = Math.min(term.usageCount + 1, cap);
    }
    for (const id of ids.replacementRuleIds ?? []) {
      // Synthetic rule ids (derived from a term) have no stored record; the term
      // itself is already credited above.
      const rule = this.payload.replacements.find((entry) => entry.id === id);
      if (rule) rule.usageCount = Math.min(rule.usageCount + 1, cap);
    }
    for (const id of ids.snippetIds ?? []) {
      const snippet = this.payload.snippets.find((entry) => entry.id === id);
      if (snippet) snippet.usageCount = Math.min(snippet.usageCount + 1, cap);
    }
    if (
      (ids.termIds?.length ?? 0) > 0
      || (ids.replacementRuleIds?.length ?? 0) > 0
      || (ids.snippetIds?.length ?? 0) > 0
    ) {
      this.scheduleSave();
    }
  }

  // ---- history -----------------------------------------------------------

  get history(): readonly DictationRecord[] {
    return this.payload.history;
  }

  /** Retention cap on history records; matches the macOS build's 1000. */
  static readonly HISTORY_CAP = 1000;

  appendHistory(record: DictationRecord): void {
    this.payload.history.unshift(record);
    if (this.payload.history.length > DataStore.HISTORY_CAP) {
      this.payload.history = this.payload.history.slice(0, DataStore.HISTORY_CAP);
    }
    this.scheduleSave();
  }

  removeHistory(id: string): boolean {
    return this.removeWhere(this.payload.history, (record) => record.id === id);
  }

  clearHistory(): void {
    this.payload.history = [];
    this.scheduleSave();
  }

  // ---- notes -------------------------------------------------------------

  get notes(): readonly Note[] {
    return this.payload.notes;
  }

  upsertNote(note: Note): Note {
    const index = this.payload.notes.findIndex((existing) => existing.id === note.id);
    if (index < 0) {
      this.payload.notes.unshift(note);
      this.scheduleSave();
      return note;
    }
    this.payload.notes[index] = note;
    this.scheduleSave();
    return note;
  }

  /**
   * Delete a note, returning it and its position so the caller can offer a real
   * undo. Without the position, restoring would move the note to the top of the
   * list, which is a visible side effect of a mis-click the user just undid.
   */
  deleteNote(id: string): { note: Note; index: number } | null {
    const index = this.payload.notes.findIndex((existing) => existing.id === id);
    if (index < 0) return null;
    const [note] = this.payload.notes.splice(index, 1);
    if (!note) return null;
    this.scheduleSave();
    return { note, index };
  }

  /** Put a deleted note back where it was. */
  restoreNote(note: Note, index: number): void {
    if (this.payload.notes.some((existing) => existing.id === note.id)) return;
    const at = Math.max(0, Math.min(index, this.payload.notes.length));
    this.payload.notes.splice(at, 0, note);
    this.scheduleSave();
  }

  // ---- import ------------------------------------------------------------

  /**
   * Merge an imported payload without destroying newer local data.
   *
   * The macOS import overwrote by id unconditionally, so importing an old backup
   * discarded every edit made since. Newer wins here, and the result reports how
   * many local records were kept so the UI can say so.
   */
  importPayload(incoming: Partial<ScopePayload>): ImportSummary {
    const summary: ImportSummary = {
      termsInserted: 0, termsUpdated: 0,
      replacementsInserted: 0, replacementsUpdated: 0,
      snippetsInserted: 0, snippetsUpdated: 0,
      notesInserted: 0, notesUpdated: 0,
      notesKeptLocal: 0,
      skipped: [],
    };

    for (const term of incoming.terms ?? []) {
      const before = this.payload.terms.some((existing) => existing.id === term.id);
      this.upsertTerm(term);
      if (before) summary.termsUpdated += 1; else summary.termsInserted += 1;
    }
    for (const rule of incoming.replacements ?? []) {
      const before = this.payload.replacements.some((existing) => existing.id === rule.id);
      this.upsertReplacement(rule);
      if (before) summary.replacementsUpdated += 1; else summary.replacementsInserted += 1;
    }
    for (const snippet of incoming.snippets ?? []) {
      const before = this.payload.snippets.some((existing) => existing.id === snippet.id);
      this.upsertSnippet(snippet);
      if (before) summary.snippetsUpdated += 1; else summary.snippetsInserted += 1;
    }

    for (const note of incoming.notes ?? []) {
      const existing = this.payload.notes.find((entry) => entry.id === note.id);
      if (!existing) {
        this.payload.notes.push(note);
        summary.notesInserted += 1;
        continue;
      }
      if (note.updatedAt > existing.updatedAt) {
        const index = this.payload.notes.indexOf(existing);
        this.payload.notes[index] = note;
        summary.notesUpdated += 1;
      } else {
        summary.notesKeptLocal += 1;
      }
    }

    for (const record of incoming.history ?? []) {
      if (this.payload.history.some((entry) => entry.id === record.id)) continue;
      this.payload.history.push(record);
    }
    this.payload.history.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
    if (this.payload.history.length > DataStore.HISTORY_CAP) {
      this.payload.history = this.payload.history.slice(0, DataStore.HISTORY_CAP);
    }

    // Cap suggestions on import too: the suggestion path capped them, but the
    // import path did not, so a single import could add thousands.
    for (const suggestion of incoming.suggestions ?? []) {
      this.addSuggestion(suggestion);
    }

    this.scheduleSave();
    return summary;
  }

  exportPayload(): Persisted<ScopePayload> {
    return { version: CURRENT_VERSION, payload: this.payload };
  }

  // ---- persistence -------------------------------------------------------

  /** Queue a write. Multiple mutations inside the window collapse into one. */
  private scheduleSave(): void {
    if (!this.writable) return;
    if (this.writeTimer) return;
    this.writeTimer = setTimeout(() => {
      this.writeTimer = null;
      void this.flush();
    }, HISTORY_WRITE_DEBOUNCE_MS);
    // Do not hold the process open just to persist.
    this.writeTimer.unref?.();
  }

  /**
   * Write now and wait for it. Returns whether the write succeeded, and reports
   * the failure to every listener instead of discarding it the way `try?` did.
   */
  async flush(): Promise<boolean> {
    if (this.writeTimer) {
      clearTimeout(this.writeTimer);
      this.writeTimer = null;
    }
    if (!this.writable) return false;
    // Serialise writes so a debounced save and an explicit flush cannot interleave
    // and produce a partially written file.
    if (this.writeInFlight) await this.writeInFlight;

    const run = (async () => {
      try {
        await writeJsonAtomic(this.filePath, this.exportPayload());
        this.lastError = null;
        return true;
      } catch (error) {
        const wrapped = error instanceof Error ? error : new Error(String(error));
        this.lastError = wrapped;
        for (const listener of this.failureListeners) {
          try {
            listener(wrapped);
          } catch {
            // A failing listener must not break persistence.
          }
        }
        return false;
      } finally {
        this.writeInFlight = null;
      }
    })();

    this.writeInFlight = run.then(() => undefined, () => undefined);
    return run;
  }

  /** Field path for tests and diagnostics. */
  get path(): string {
    return this.filePath;
  }
}

export interface ImportSummary {
  termsInserted: number;
  termsUpdated: number;
  replacementsInserted: number;
  replacementsUpdated: number;
  snippetsInserted: number;
  snippetsUpdated: number;
  notesInserted: number;
  notesUpdated: number;
  notesKeptLocal: number;
  /** Rows or records that could not be imported, with the reason. */
  skipped: string[];
  /** Set after an import of a CSV, where rows may be rejected individually. */
  invalid?: string[];
}

function normalisePayload(raw: Partial<ScopePayload>): ScopePayload {
  return {
    terms: (raw.terms ?? []).map(normaliseTerm),
    replacements: raw.replacements ?? [],
    snippets: raw.snippets ?? [],
    suggestions: raw.suggestions ?? [],
    history: (raw.history ?? []).sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    notes: raw.notes ?? [],
  };
}

function normaliseTerm(term: MemoryTerm): MemoryTerm {
  return {
    ...term,
    phrase: term.phrase.trim(),
    // Compose to NFC so the same word never exists twice in two normal forms.
    aliases: unique(term.aliases.map((alias) => alias.normalize('NFC'))),
    pronunciations: unique(term.pronunciations.map((value) => value.normalize('NFC'))),
  };
}

function unique(values: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const value of values) {
    const key = canonical(value);
    if (key.length === 0 || seen.has(key)) continue;
    seen.add(key);
    out.push(value);
  }
  return out;
}

function strongerPriority(a: MemoryTerm['priority'], b: MemoryTerm['priority']): MemoryTerm['priority'] {
  const rank: Record<MemoryTerm['priority'], number> = { always: 2, high: 1, normal: 0 };
  return rank[a] >= rank[b] ? a : b;
}

function newest(a: string, b: string): string {
  return a > b ? a : b;
}

export type { MemoryLanguage };
