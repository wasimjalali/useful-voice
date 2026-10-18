/**
 * The clipboard half of the delivery contract, as pure logic.
 *
 * Delivery must never lose a dictation: after every attempt the text is either
 * pasted into the user's app or still on the clipboard. Putting the user's previous
 * clipboard back is therefore a *decision*, not a cleanup step — and getting that
 * decision wrong is what lost transcripts on macOS, where the restore ran on a timer
 * that could fire before the paste had landed.
 *
 * Two questions, answered separately:
 *
 *   Was it delivered? Yes as soon as the paste keystroke went out. Ctrl+V never
 *   clears the Windows clipboard, so the clipboard still holding our text proves
 *   nothing either way: reading it as "the paste did not land" reported every
 *   successful paste as undelivered and made people paste twice. If the keystroke
 *   could not be sent, the text stays on the clipboard and the person is told so.
 *
 *   May the previous clipboard be put back? Only when ALL of these hold:
 *
 *   1. the target is one whose paste can be attributed (not a terminal or an
 *      Electron app whose text cannot be read)
 *   2. focus stayed on the same window while pasting
 *   3. the clipboard still holds exactly our text right before the restore, so a
 *      newer copy the person made is never overwritten
 *   4. the original was captured completely (a file list, say, was not)
 *   5. the original held something worth restoring (restoring whitespace would
 *      destroy the dictation for no user data)
 *
 *   Otherwise the dictation stays on the clipboard, so the person can paste it again.
 *
 * This module is deliberately pure: the observations (which window had focus, what
 * the clipboard holds) arrive as data, so the policy is testable without Electron
 * on any platform. The observers and the clipboard write itself live in
 * `src/main/windowsPlatform.ts`.
 */

/** The peer window a paste is aimed at. */
export interface PasteTarget {
  /** Process name, e.g. "notepad.exe". */
  processName: string;
  /**
   * The window handle.
   *
   * Identity is taken from the handle and not from the title: titles change while
   * the user types, and two windows of the same app can carry the same title.
   */
  handle: number;
}

/**
 * A clipboard snapshot reduced to the fields the restore decision depends on.
 *
 * Structural, so the Windows layer's richer snapshot (which also carries the raw
 * format buffers) can be passed to `decideClipboardRestore` unchanged.
 */
export interface ClipboardContents {
  text: string;
  html: string;
  rtf: string;
  /**
   * True when something on the clipboard could not be captured exactly.
   *
   * Set by the snapshotter, never inferred here: only it knows which clipboard
   * formats exist and whether each one could be read back faithfully.
   */
  incomplete: boolean;
}

/**
 * Apps whose edit controls do not expose text, where a paste can never be verified
 * by reading content.
 *
 * For these the app keeps the dictation on the clipboard, because claiming success
 * it cannot prove is what caused the original clipboard-loss bug on macOS. Terminals
 * and Electron-based editors are the usual suspects: their text lives in a canvas or
 * a private buffer that no clipboard or window-title check can confirm.
 */
export const UNVERIFIABLE_PROCESSES = new Set([
  'windowsterminal',
  'conhost',
  'mintty',
  'alacritty',
  'wezterm',
  'kitty',
  'powershell',
  'pwsh',
  'cmd',
  'code',            // VS Code: Electron, though its AX tree is usually present
  'brave',
  'chrome',
  'firefox',
  'msedge',
  'slack',
  'discord',
  'notion',
]);

/**
 * Whether a paste into this window could ever be confirmed.
 *
 * A null target means the foreground window could not be read, which is treated the
 * same as an unverifiable app: unconfirmed delivery keeps the text on the clipboard
 * rather than claiming it landed.
 */
export function isProbablyVerifiable(target: PasteTarget | null): boolean {
  if (!target) return false;
  const name = target.processName.replace(/\.exe$/i, '').toLowerCase();
  if (name.length === 0) return false;
  return !UNVERIFIABLE_PROCESSES.has(name);
}

/**
 * Whether the captured clipboard is worth putting back.
 *
 * Whitespace-only text counts as nothing: a clipboard holding a few spaces carries
 * no user data, while overwriting the transcript with it would cost the dictation.
 * HTML or RTF without plain text still counts, because that is a real document.
 */
export function hasRestorableContent(contents: ClipboardContents): boolean {
  return contents.text.trim().length > 0 || contents.html.length > 0 || contents.rtf.length > 0;
}

/**
 * Why the clipboard was or was not put back, for the diagnostics log.
 *
 * Kept as a union rather than free text so the caller can react to a reason (the
 * incomplete-snapshot warning is worth telling the user about) instead of matching
 * on a message string.
 */
export type RestoreReason =
  /** The paste automation itself failed, so nothing was sent. */
  | 'paste-failed'
  /** The target hides its text; the paste went out but cannot be attributed. */
  | 'unverifiable-target'
  /** Focus moved before the paste settled, so it cannot be attributed. */
  | 'focus-moved'
  /** The clipboard no longer holds our text: the person copied something newer. */
  | 'clipboard-changed'
  /** The paste went out, but the original clipboard could not be captured exactly. */
  | 'snapshot-incomplete'
  /** The paste went out, and the original clipboard held nothing worth keeping. */
  | 'nothing-to-restore'
  /** The paste went out and the original clipboard may be put back. */
  | 'restored';

/**
 * `delivered` and `restore` are separate on purpose.
 *
 * A paste can be sent while the restore is still refused (an unverifiable target, an
 * incomplete snapshot), and the caller needs both facts: one decides whether the app
 * may say "pasted", the other whether it may overwrite the clipboard.
 */
export interface RestoreDecision {
  /** True when the paste keystroke was sent. False only when the text is still just on the clipboard. */
  delivered: boolean;
  /** True when the previous clipboard may be written back. Implies `delivered`. */
  restore: boolean;
  reason: RestoreReason;
}

/** What the main process observed around one paste attempt. */
export interface PasteObservation {
  /** The clipboard as it was before the transcript was copied onto it. */
  clipboard: ClipboardContents;
  /** The window that had focus when the paste was sent, null if it could not be read. */
  target: PasteTarget | null;
  /** Whether the paste keystroke was sent without error. */
  pasteSent: boolean;
  /**
   * The window that had focus once the paste was given time to settle, null if it
   * could not be read.
   */
  focusAfter: PasteTarget | null;
  /**
   * Whether the clipboard holds exactly the transcript we copied, read right before
   * the restore.
   *
   * This guards the restore, not the delivery: if the person copied something newer
   * while the paste settled, their copy must not be overwritten.
   */
  clipboardHoldsOurText: boolean;
}

/**
 * Decide what may happen to the clipboard after a paste attempt.
 *
 * Never throws and never touches Electron, so it can run (and be tested) anywhere.
 */
export function decideClipboardRestore(observation: PasteObservation): RestoreDecision {
  const { clipboard, target, pasteSent, focusAfter, clipboardHoldsOurText } = observation;

  if (!pasteSent) {
    // The automation failed before it could reach any window, so the text has to
    // stay on the clipboard and the caller says so rather than pretending it landed.
    return { delivered: false, restore: false, reason: 'paste-failed' };
  }

  // From here the keystroke went out, so the dictation counts as pasted whatever the
  // clipboard holds. Only the restore is still in question, and every doubt keeps the
  // transcript on the clipboard, where the person can paste it again.
  if (target === null || !isProbablyVerifiable(target)) {
    return { delivered: true, restore: false, reason: 'unverifiable-target' };
  }

  if (focusAfter === null || focusAfter.handle !== target.handle) {
    // Focus moved while we were pasting, so the paste cannot be attributed to the
    // window we aimed at.
    return { delivered: true, restore: false, reason: 'focus-moved' };
  }

  if (!clipboardHoldsOurText) {
    // Something else is on the clipboard now, most likely a newer copy by the person.
    return { delivered: true, restore: false, reason: 'clipboard-changed' };
  }

  if (clipboard.incomplete) {
    // The clipboard held something we cannot reproduce exactly, so replacing it with
    // a partial copy would be data loss. The transcript stays instead.
    return { delivered: true, restore: false, reason: 'snapshot-incomplete' };
  }

  if (!hasRestorableContent(clipboard)) {
    // Nothing worth putting back (an empty clipboard, or only whitespace).
    return { delivered: true, restore: false, reason: 'nothing-to-restore' };
  }

  return { delivered: true, restore: true, reason: 'restored' };
}

/** The clipboard formats a snapshot can put back faithfully: plain text, HTML and RTF. */
export const RESTORABLE_FORMATS: readonly string[] = ['text/plain', 'text/html', 'text/rtf'];

/**
 * Whether the clipboard held anything the restore cannot reproduce.
 *
 * An image, a file list or a proprietary type is written back by nobody, so a snapshot
 * of a clipboard that holds one is incomplete however faithful its text part is.
 * Claiming otherwise replaced a copied image with its caption.
 */
export function hasUnrestorableFormat(formats: readonly string[]): boolean {
  return formats.some((format) => {
    const normalised = format.toLowerCase();
    return !RESTORABLE_FORMATS.some((known) => normalised === known || normalised.startsWith(`${known};`));
  });
}

/** The few clipboard operations the restore needs, so it runs against a fake in tests. */
export interface ClipboardPort {
  clear(): void;
  write(entry: { text?: string; html?: string; rtf?: string }): void;
  readText(): string;
  readHTML(): string;
  readRTF(): string;
}

export type RestoreOutcome =
  /** The clipboard holds the original again. */
  | 'restored'
  /** Nothing restorable was captured; the clipboard was not touched. */
  | 'nothing-to-restore'
  /** The restore failed, and the dictation was put back so it is not lost. */
  | 'failed-kept-dictation'
  /** The restore failed and the dictation could not be put back either. */
  | 'failed-lost';

/**
 * Put a snapshot back, and never leave the clipboard worse than the dictation.
 *
 * `clear()` is not atomic with the write that follows, so a failed write would leave
 * the clipboard empty and lose both the user's data and the dictation. When the write
 * fails or reads back wrong, the dictation text is written back instead.
 */
export function restoreSnapshotTo(
  port: ClipboardPort,
  snapshot: ClipboardContents,
  dictationText: string,
): RestoreOutcome {
  const entry: { text?: string; html?: string; rtf?: string } = {};
  if (snapshot.text.length > 0) entry.text = snapshot.text;
  if (snapshot.html.length > 0) entry.html = snapshot.html;
  if (snapshot.rtf.length > 0) entry.rtf = snapshot.rtf;
  if (Object.keys(entry).length === 0) return 'nothing-to-restore';

  try {
    port.clear();
    port.write(entry);
    const verified =
      snapshot.text.length > 0
        ? port.readText() === snapshot.text
        : snapshot.html.length > 0
          ? port.readHTML().length > 0
          : port.readRTF().length > 0;
    if (verified) return 'restored';
  } catch {
    // Fall through: the clipboard may be empty or half written.
  }

  try {
    port.clear();
    port.write({ text: dictationText });
    return 'failed-kept-dictation';
  } catch {
    return 'failed-lost';
  }
}
