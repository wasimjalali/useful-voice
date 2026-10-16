import type { InsertAttempt } from '../core/delivery/deliveryFlow.js';
import type { ForegroundWindowInfo } from '../core/delivery/foregroundLine.js';
import type { AutoSendKey } from '../core/apps/appCategory.js';
import type { AddressRead } from './deliveryGlue.js';
import * as windows from './windowsPlatform.js';

/**
 * What a dictation asks of the desktop around it: who is in front, the browser address, the
 * text before the caret, and the keystrokes. One seam, so the Playwright suite can stand in
 * a scripted desktop (`e2eDesktop.ts`, `--e2e` only) and drive a whole hotkey dictation
 * without pasting into, or pressing Return in, whatever is in front of the machine.
 */
export interface Desktop {
  foregroundWindow(budgetMs?: number): Promise<ForegroundWindowInfo | null>;
  browserAddress(handle: number, appId: string | undefined, budgetMs?: number): Promise<AddressRead>;
  /** Up to 200 characters before the caret in the focused field, or null. Never logged or stored. */
  textBeforeCursor(handle: number): Promise<string | null>;
  reactivateWindow(handle: number, focusHandle: number | undefined, budgetMs: number): Promise<'ok' | 'gone' | 'refused'>;
  pasteClipboard(handle: number, deadlineEpochMs: number, kill?: AbortSignal): Promise<InsertAttempt>;
  typeText(batches: number[][], handle: number, deadlineEpochMs: number, kill?: AbortSignal): Promise<InsertAttempt>;
  /** `focusHandle` is the child control captured at the press: the key goes only while it still has focus. */
  sendKey(handle: number, key: AutoSendKey, deadlineEpochMs: number, kill?: AbortSignal, focusHandle?: number): Promise<InsertAttempt>;
}

export const windowsDesktop: Desktop = {
  foregroundWindow: windows.foregroundWindow,
  browserAddress: windows.browserAddress,
  textBeforeCursor: windows.textBeforeCursor,
  reactivateWindow: windows.reactivateWindow,
  pasteClipboard: windows.pasteClipboard,
  typeText: windows.typeText,
  sendKey: windows.sendKey,
};
