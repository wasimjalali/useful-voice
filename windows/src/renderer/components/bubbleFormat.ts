/**
 * Formatting for the Stream: German-region numbers, 24 hour times, day labels like
 * "Thu 8. Oct", native language names, the word diff behind "Show original" and the
 * excerpt shown for a long dictation that matches a search.
 */

import { findLanguage } from '../../core/transcription/languages.js';

const numberFormat = new Intl.NumberFormat('de-DE');

/** 1000 -> "1.000". */
export function formatCount(value: number): string {
  return numberFormat.format(value);
}

export function pluralize(count: number, singular: string, plural = `${singular}s`): string {
  return `${formatCount(count)} ${count === 1 ? singular : plural}`;
}

export function countWords(text: string): number {
  return text.split(/\s+/).filter((token) => token.length > 0).length;
}

const pad = (value: number): string => String(value).padStart(2, '0');

/** "17:14". */
export function formatTime(iso: string): string {
  const date = new Date(iso);
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** "24 s" under a minute, "1,2 min" above. */
export function formatDuration(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)} s`;
  return `${(seconds / 60).toFixed(1).replace('.', ',')} min`;
}

/** m:ss for the dock timer. */
export function formatClock(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds));
  return `${Math.floor(whole / 60)}:${pad(whole % 60)}`;
}

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** The local calendar day of a timestamp, as YYYY-MM-DD. */
export function dayKey(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function startOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

/** "Today", "Yesterday", "Thu 8. Oct", and "Thu 8. Oct 2025" for another year. */
export function dayLabel(date: Date, now = new Date()): string {
  const diff = Math.round((startOfDay(now).getTime() - startOfDay(date).getTime()) / 86_400_000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  const base = `${WEEKDAYS[date.getDay()]} ${date.getDate()}. ${MONTHS[date.getMonth()]}`;
  return date.getFullYear() === now.getFullYear() ? base : `${base} ${date.getFullYear()}`;
}

/** Monday 00:00 of the week containing `now`. */
export function startOfWeek(now = new Date()): Date {
  const day = startOfDay(now);
  const offset = (day.getDay() + 6) % 7;
  day.setDate(day.getDate() - offset);
  return day;
}

export function isSameDay(a: Date, b: Date): boolean {
  return dayKey(a) === dayKey(b);
}

/** Codes that name a mode rather than a language. */
export function isLanguageCode(code: string): boolean {
  return code !== '' && code !== 'auto';
}

/** The language's own name: "Deutsch", "فارسی". */
export function languageLabel(code: string): string {
  if (code === 'multi') return 'Multilingual';
  const known = findLanguage(code) ?? findLanguage(code.split('-')[0] ?? code);
  if (known) return known.nativeName;
  try {
    const own = new Intl.DisplayNames([code], { type: 'language' }).of(code);
    if (own && own !== code) return own.charAt(0).toLocaleUpperCase(code) + own.slice(1);
  } catch {
    // An unknown tag: fall through to the code itself.
  }
  return code;
}

const RTL_FIRST_STRONG = /^[^\p{L}]*[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/u;

/** Whether the text starts in a right-to-left script (the bubble then sets a larger size). */
export function isRtlText(text: string): boolean {
  return RTL_FIRST_STRONG.test(text);
}

export interface DiffToken {
  kind: 'same' | 'removed' | 'added';
  text: string;
}

/** Above this many word pairs the diff is skipped (the original is then shown whole). */
const MAX_DIFF_CELLS = 300_000;

/** The letters and digits of a word, for telling a changed word from changed punctuation. */
const letters = (word: string): string => word.replace(/[^\p{L}\p{N}]/gu, '');

/**
 * A word-level diff from what the engine heard to the text that was kept, for "Show
 * original". Words line up ignoring case and punctuation; a word whose letters changed
 * (including its case) shows as removed then added, while a word that only gained a comma
 * or full stop counts as unchanged. Returns null for a dictation too long to diff cheaply.
 */
export function wordDiff(raw: string, final: string): DiffToken[] | null {
  const a = raw.split(/\s+/).filter(Boolean);
  const b = final.split(/\s+/).filter(Boolean);
  if (a.length * b.length > MAX_DIFF_CELLS) return null;
  const keyA = a.map((word) => letters(word).toLowerCase());
  const keyB = b.map((word) => letters(word).toLowerCase());

  // Longest common subsequence table, filled from the end so the walk below runs forward.
  const cols = b.length + 1;
  const table = new Uint16Array((a.length + 1) * cols);
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      table[i * cols + j] = keyA[i] === keyB[j]
        ? (table[(i + 1) * cols + j + 1] ?? 0) + 1
        : Math.max(table[(i + 1) * cols + j] ?? 0, table[i * cols + j + 1] ?? 0);
    }
  }

  const out: DiffToken[] = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    const left = a[i];
    const right = b[j];
    if (left !== undefined && right !== undefined && keyA[i] === keyB[j]) {
      if (letters(left) === letters(right)) {
        out.push({ kind: 'same', text: right });
      } else {
        out.push({ kind: 'removed', text: left }, { kind: 'added', text: right });
      }
      i++;
      j++;
    } else if (left !== undefined && (right === undefined || (table[(i + 1) * cols + j] ?? 0) >= (table[i * cols + j + 1] ?? 0))) {
      out.push({ kind: 'removed', text: left });
      i++;
    } else if (right !== undefined) {
      out.push({ kind: 'added', text: right });
      j++;
    }
  }
  return out;
}

/** Roughly this many characters make a dictation "long" enough to excerpt around a match. */
const EXCERPT_THRESHOLD = 240;

export interface Excerpt {
  text: string;
  /** True when the text was cut. */
  cut: boolean;
}

/** A window of about 200 characters around the first match, on word boundaries. */
export function excerptAround(text: string, query: string): Excerpt {
  if (text.length <= EXCERPT_THRESHOLD || query === '') return { text, cut: false };
  const at = text.toLowerCase().indexOf(query.toLowerCase());
  if (at < 0) return { text, cut: false };
  let start = Math.max(0, at - 60);
  let end = Math.min(text.length, at + query.length + 140);
  if (start > 0) {
    const space = text.indexOf(' ', start);
    if (space !== -1 && space < at) start = space + 1;
  }
  if (end < text.length) {
    const space = text.lastIndexOf(' ', end);
    if (space > at + query.length) end = space;
  }
  const cut = start > 0 || end < text.length;
  return {
    text: `${start > 0 ? '…' : ''}${text.slice(start, end)}${end < text.length ? '…' : ''}`,
    cut,
  };
}

/** Accelerators as shown to the user: "Control+Alt+Space" -> "Ctrl+Alt+Space". */
export function formatAccelerator(accelerator: string): string {
  return accelerator
    .split('+')
    .map((part) => {
      if (part === 'Control' || part === 'CommandOrControl' || part === 'CmdOrCtrl') return 'Ctrl';
      if (part === 'Super' || part === 'Meta') return 'Win';
      return part;
    })
    .join('+');
}
