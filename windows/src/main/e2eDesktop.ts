import type { Desktop } from './desktop.js';
import type { InsertResult } from '../core/delivery/deliveryFlow.js';
import type { ForegroundWindowInfo } from '../core/delivery/foregroundLine.js';

/**
 * A scripted desktop for the Playwright suite. Installed only under `--e2e`, and only when
 * a spec asks for it (`__uv.useFakeDesktop`), so a spec that does not is unchanged.
 *
 * It answers "who is in front", "what page", "what is before the caret" from what the spec
 * set, and instead of sending Ctrl+V, typing or pressing Return it records the call. A
 * paste records what is on the clipboard at that moment, which is what Ctrl+V would insert.
 * The clipboard itself stays the real one.
 */

export interface FakeForegroundInput {
  processName: string;
  title?: string;
  handle?: number;
  processId?: number;
  focusHandle?: number;
}

export type FakeCall =
  | { kind: 'paste'; handle: number; inserted: string }
  | { kind: 'typeOut'; handle: number; typed: string }
  | { kind: 'sendKey'; handle: number; key: string; focusHandle?: number }
  | { kind: 'sendKeyBlocked'; handle: number; key: string; focusHandle?: number }
  | { kind: 'reactivate'; handle: number };

export interface FakeDesktopPatch {
  foreground?: FakeForegroundInput | null;
  address?: string | null;
  textBefore?: string | null;
  pasteResult?: InsertResult;
  reactivate?: 'ok' | 'gone' | 'refused';
  /** Who is in front once a paste has gone in: the window changed under the dictation. */
  foregroundAfterPaste?: FakeForegroundInput | null;
  /**
   * Which field of the same window has the keyboard focus the instant a send key would go
   * out, after the last look at the foreground: the race the script's own focus check closes.
   * `null` puts it back.
   */
  focusMovesBeforeKey?: number | null;
}

export class FakeDesktop implements Desktop {
  private front: ForegroundWindowInfo | null = null;
  private page: string | null = null;
  private before: string | null = null;
  private paste: InsertResult = 'sent';
  private reactivation: 'ok' | 'gone' | 'refused' = 'refused';
  private afterPaste: FakeForegroundInput | null = null;
  private keyFocus: number | null = null;
  private readonly recorded: FakeCall[] = [];

  constructor(private readonly readClipboard: () => string) {}

  set(patch: FakeDesktopPatch): void {
    if (patch.foreground !== undefined) {
      const f = patch.foreground;
      this.front = f
        ? {
            handle: f.handle ?? 0x500,
            processName: f.processName,
            title: f.title ?? f.processName,
            processId: f.processId ?? 4242,
            focusHandle: f.focusHandle ?? (f.handle ?? 0x500) + 1,
          }
        : null;
    }
    if (patch.address !== undefined) this.page = patch.address;
    if (patch.textBefore !== undefined) this.before = patch.textBefore;
    if (patch.pasteResult !== undefined) this.paste = patch.pasteResult;
    if (patch.reactivate !== undefined) this.reactivation = patch.reactivate;
    if (patch.foregroundAfterPaste !== undefined) this.afterPaste = patch.foregroundAfterPaste;
    if (patch.focusMovesBeforeKey !== undefined) this.keyFocus = patch.focusMovesBeforeKey;
  }

  calls(): FakeCall[] {
    return [...this.recorded];
  }

  async foregroundWindow(): Promise<ForegroundWindowInfo | null> {
    return this.front ? { ...this.front } : null;
  }

  async browserAddress(): Promise<{ address: string | null; timedOut: boolean }> {
    return { address: this.page, timedOut: false };
  }

  async textBeforeCursor(): Promise<string | null> {
    return this.before;
  }

  async reactivateWindow(handle: number): Promise<'ok' | 'gone' | 'refused'> {
    this.recorded.push({ kind: 'reactivate', handle });
    return this.reactivation;
  }

  async pasteClipboard(handle: number): Promise<{ result: InsertResult }> {
    if (this.paste !== 'sent') return { result: this.paste };
    this.recorded.push({ kind: 'paste', handle, inserted: this.readClipboard() });
    if (this.afterPaste) {
      const next = this.afterPaste;
      this.afterPaste = null;
      this.set({ foreground: next });
    }
    return { result: 'sent' };
  }

  async typeText(batches: number[][], handle: number): Promise<{ result: InsertResult; typedUnits: number }> {
    this.recorded.push({ kind: 'typeOut', handle, typed: String.fromCharCode(...batches.flat()) });
    return { result: 'sent', typedUnits: batches.flat().length };
  }

  async sendKey(handle: number, key: string, _deadline?: number, _kill?: AbortSignal, focusHandle?: number): Promise<{ result: InsertResult }> {
    // Like the script: no key unless the captured field still has the focus.
    const current = this.keyFocus ?? this.front?.focusHandle;
    if (focusHandle !== undefined && current !== undefined && current !== focusHandle) {
      this.recorded.push({ kind: 'sendKeyBlocked', handle, key, focusHandle });
      return { result: 'moved' };
    }
    this.recorded.push({ kind: 'sendKey', handle, key, focusHandle });
    return { result: 'sent' };
  }
}
