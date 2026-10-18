/**
 * The clipboard half of the delivery contract, as pure logic.
 *
 * Delivery must never lose a dictation: after every attempt the text is either
 * pasted into the user's app or still on the clipboard. Whether the previous clipboard
 * may be put back is therefore a *decision*, and the rules are deliberately strict:
 *
 *   After a SENT paste the previous clipboard is never put back. No API tells us that
 *   the target consumed Ctrl+V (it never clears the clipboard, and an app that stalls
 *   past any delay we pick would then paste the OLD clipboard, losing the dictation).
 *   The dictation stays on the clipboard and the paste is reported as delivered. If
 *   the keystroke could not be sent, it stays too and the person is told to paste.
 *
 *   Before the paste (a cancel arrived first) the previous clipboard goes back only
 *   when the clipboard still holds exactly our text, so a newer copy is never
 *   overwritten, and the snapshot is complete and has something worth restoring.
 *
 * This module is deliberately pure: the observations arrive as data, so the policy is
 * testable without Electron on any platform. The clipboard access itself lives in
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
 * Whether a cancel that arrived before the keystroke may put the previous clipboard back.
 *
 * `clipboardHoldsOurText` is read right before the restore. False means the person (or
 * another app) copied something after we wrote the dictation, and that newer copy is
 * theirs to keep.
 */
export function mayRestoreAfterCancel(snapshot: ClipboardContents, clipboardHoldsOurText: boolean): boolean {
  return clipboardHoldsOurText && !snapshot.incomplete && hasRestorableContent(snapshot);
}

/**
 * Whether the clipboard text is the text we wrote. Line endings are compared as LF on both
 * sides: Windows may hand back CRLF for text that was written as LF, and that is not a
 * change by the person.
 */
export function sameClipboardText(onClipboard: string, written: string): boolean {
  return onClipboard.replace(/\r\n/g, '\n') === written.replace(/\r\n/g, '\n');
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
