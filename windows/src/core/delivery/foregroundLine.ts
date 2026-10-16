import type { PasteTarget } from './clipboardRestore.js';

/** A foreground window as the main process reads it. */
export interface ForegroundWindowInfo extends PasteTarget {
  /** Window title, for the HUD's "dictating into X" label. */
  title: string;
  /** The owning process, when it could be read. */
  processId?: number;
  /** The focused child window (GetGUIThreadInfo's hwndFocus), when there is one. */
  focusHandle?: number;
}

/**
 * Parse the line the foreground script prints: handle, process name, process id, focused
 * child handle and title, separated by the unit separator (`foregroundWindow` in
 * `src/main/windowsPlatform.ts`). Pure, so it is tested without Electron.
 */
export function parseForegroundLine(line: string): ForegroundWindowInfo | null {
  const [handleText, processName, pidText, focusText, ...titleParts] = line.split('\u001f');
  const handle = Number(handleText);
  if (!handleText || !Number.isFinite(handle)) return null;
  const info: ForegroundWindowInfo = {
    handle,
    processName: (processName ?? '').trim(),
    title: titleParts.join(' ').trim(),
  };
  const pid = Number(pidText);
  if (Number.isSafeInteger(pid) && pid > 0) info.processId = pid;
  const focus = Number(focusText);
  if (Number.isSafeInteger(focus) && focus > 0) info.focusHandle = focus;
  return info;
}

