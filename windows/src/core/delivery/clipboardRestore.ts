/**
 * The clipboard half of the delivery contract, as pure logic.
 *
 * Delivery must never lose a dictation: after every attempt the text is either
 * pasted into the user's app or still on the clipboard. Putting the user's previous
 * clipboard back is therefore a *decision*, not a cleanup step — and getting that
 * decision wrong is what lost transcripts on macOS, where the restore ran on a timer
 * that could fire before the paste had landed.
 *
 * The rules, in the order they are applied:
 *
 *   1. no paste was sent                 -> keep the text on the clipboard
 *   2. the target cannot be verified     -> keep (never claim an unprovable success)
 *   3. focus moved while pasting         -> keep (the paste cannot be attributed)
 *   4. the clipboard still holds our text -> keep (nothing consumed it, so it very
 *      likely never landed)
 *   5. the paste landed but the original could not be captured exactly (a file
 *      list, say) or held nothing worth restoring -> keep (a partial restore would
 *      destroy user data, and restoring whitespace would destroy the dictation)
 *   6. otherwise                         -> restore the original clipboard
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
  /** The paste automation itself failed, so nothing was consumed. */
  | 'paste-failed'
  /** The target hides its text; success cannot be proven. */
  | 'unverifiable-target'
  /** Focus moved before the paste settled, so it cannot be attributed. */
  | 'focus-moved'
  /** The clipboard still holds our text, so nothing ate the paste. */
  | 'paste-not-consumed'
  /** The paste landed, but the original clipboard could not be captured exactly. */
  | 'snapshot-incomplete'
  /** The paste landed, and the original clipboard held nothing worth keeping. */
  | 'nothing-to-restore'
  /** The paste landed and the original clipboard is back. */
  | 'restored';

/**
 * `delivered` and `restore` are separate on purpose.
 *
 * A paste can be proven to have landed while the restore is still refused (an
 * incomplete snapshot), and the caller needs both facts: one decides whether the app
 * may say "pasted", the other whether it may overwrite the clipboard.
 */
export interface RestoreDecision {
  /** True only when the paste was proven to arrive in the window it was aimed at. */
  delivered: boolean;
  /** True when the previous clipboard may be written back. Implies `delivered`. */
  restore: boolean;
  reason: RestoreReason;
}

/** What the main process observed around one paste attempt. */
export interface PasteObservation {
  /** The clipboard as it was before the transcript was copied onto it. */
  clipboard: ClipboardContents;
  /** The window that had focus when dictation started, null if it could not be read. */
  target: PasteTarget | null;
  /** Whether the paste automation ran without error. */
  pasteSent: boolean;
  /**
   * The window that had focus once the paste was given time to settle, null if it
   * could not be read.
   */
  focusAfter: PasteTarget | null;
  /**
   * Whether the clipboard still holds exactly the transcript we copied.
   *
   * Only consulted for a verifiable target that kept focus: it is the one observable
   * that distinguishes "the target consumed the paste" from "nothing happened".
   */
  clipboardStillHoldsText: boolean;
}

/**
 * Decide what may happen to the clipboard after a paste attempt.
 *
 * Never throws and never touches Electron, so it can run (and be tested) anywhere.
 */
export function decideClipboardRestore(observation: PasteObservation): RestoreDecision {
  const { clipboard, target, pasteSent, focusAfter, clipboardStillHoldsText } = observation;

  if (!pasteSent) {
    // The automation failed before it could reach any window, so the text has to
    // stay on the clipboard and the caller says so rather than pretending it landed.
    return { delivered: false, restore: false, reason: 'paste-failed' };
  }

  if (target === null || !isProbablyVerifiable(target)) {
    return { delivered: false, restore: false, reason: 'unverifiable-target' };
  }

  if (focusAfter === null || focusAfter.handle !== target.handle) {
    // Focus moved while we were pasting, so the paste cannot be attributed to the
    // window we aimed at: it may have landed somewhere the user never intended.
    return { delivered: false, restore: false, reason: 'focus-moved' };
  }

  if (clipboardStillHoldsText) {
    // Nothing consumed the clipboard, so the paste very likely did not land — for
    // example the target's edit control was not focused at all. Restoring here would
    // throw the transcript away, which is precisely the macOS bug.
    return { delivered: false, restore: false, reason: 'paste-not-consumed' };
  }

  // The paste is proven: the same window kept focus and something consumed the text.
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
