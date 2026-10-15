/**
 * The target lock, mirrored rule for rule from the Swift core
 * (`Sources/UsefulVoiceCore/Delivery/DeliveryTarget.swift`, `InsertionMethod.swift`).
 *
 * The old flow read the foreground window again at delivery, after transcription. By
 * then the user had often clicked into another composer, and the text landed there.
 * The target is now captured at the hotkey press and delivery aims at it, nowhere
 * else. Pure: the main process observes (which window is in front, can the target be
 * brought back) and acts; this only decides.
 */

/** Where a hotkey dictation's text is meant to land, captured at the hotkey press. */
export interface DeliveryTarget {
  /** Lowercased executable name without `.exe`, e.g. "slack". */
  appId?: string;
  /** What the HUD shows ("dictating into X"): the window title or the process name. */
  appName?: string;
  processId?: number;
  /** The top-level window handle. */
  windowHandle?: number;
  /** For display and logs. Never compared: titles change while the user types. */
  windowTitle?: string;
  /** The focused child window inside it (GetGUIThreadInfo's hwndFocus). */
  focusHandle?: number;
  /** The address bar's text when the app is a known browser. Memory only, never logged. */
  browserUrl?: string;
}

export type TargetLossReason = 'unknownTarget' | 'targetGone' | 'notRestored';

export type TargetCheck =
  | { kind: 'insert' }
  | { kind: 'reactivate' }
  | { kind: 'copyOnly'; reason: TargetLossReason };

/** Normalise a process name to the target's app id: lowercase, no `.exe`. */
export function appIdFor(processName: string | undefined): string | undefined {
  const id = (processName ?? '').trim().replace(/\.exe$/i, '').toLowerCase();
  return id.length > 0 ? id : undefined;
}

/** Whether anything identifies the app at all. */
export function isIdentified(target: DeliveryTarget | null | undefined): target is DeliveryTarget {
  return !!target && (target.processId !== undefined || target.appId !== undefined);
}

/**
 * Whether `current` (what has focus now) is the captured target.
 *
 * The app: the same process when both are known, else the same app id. The window and
 * the focused child: compared only when the target recorded one; a current focus that
 * cannot report one then does not match.
 */
export function targetMatches(target: DeliveryTarget, current: DeliveryTarget | null | undefined): boolean {
  if (!current || !isIdentified(target)) return false;
  if (target.processId !== undefined && current.processId !== undefined) {
    if (target.processId !== current.processId) return false;
  } else if (target.appId === undefined || target.appId !== current.appId) {
    return false;
  }
  if (target.windowHandle !== undefined && target.windowHandle !== current.windowHandle) return false;
  if (target.focusHandle !== undefined && target.focusHandle !== current.focusHandle) return false;
  return true;
}

/** The first check at delivery. */
export function checkTarget(
  target: DeliveryTarget | null | undefined,
  current: DeliveryTarget | null | undefined,
  targetRunning: boolean,
): TargetCheck {
  if (!isIdentified(target)) return { kind: 'copyOnly', reason: 'unknownTarget' };
  if (targetMatches(target, current)) return { kind: 'insert' };
  if (!targetRunning) return { kind: 'copyOnly', reason: 'targetGone' };
  return { kind: 'reactivate' };
}

/** The check after one reactivation attempt. Never asks to reactivate again. */
export function recheckTarget(
  target: DeliveryTarget | null | undefined,
  current: DeliveryTarget | null | undefined,
  reactivated: boolean,
): TargetCheck {
  if (!isIdentified(target)) return { kind: 'copyOnly', reason: 'unknownTarget' };
  if (!reactivated || !targetMatches(target, current)) return { kind: 'copyOnly', reason: 'notRestored' };
  return { kind: 'insert' };
}

/** How text goes in. Exactly one per delivery, so it can never land twice. */
export type InsertionMethod = 'paste' | 'typeOut';

/** Paste unless the user turned typing on for this app. An unknown app always pastes. */
export function insertionMethodFor(appId: string | undefined, typeOutApps: readonly string[]): InsertionMethod {
  const key = appIdFor(appId);
  if (!key) return 'paste';
  return typeOutApps.some((app) => appIdFor(app) === key) ? 'typeOut' : 'paste';
}

/** UTF-16 units per SendInput batch. */
export const TYPE_OUT_UNITS_PER_CHUNK = 20;

/**
 * Split text into UTF-16 batches for type-out. A boundary never splits a surrogate pair
 * (an emoji) or a CR from its LF.
 */
export function typeOutChunks(text: string, maxUnits = TYPE_OUT_UNITS_PER_CHUNK): number[][] {
  const limit = Math.max(2, maxUnits);
  const units: number[] = [];
  for (let i = 0; i < text.length; i += 1) units.push(text.charCodeAt(i));
  const result: number[][] = [];
  let start = 0;
  while (start < units.length) {
    let end = Math.min(start + limit, units.length);
    if (end < units.length) {
      const last = units[end - 1]!;
      const splitsPair = last >= 0xd800 && last <= 0xdbff;
      const splitsCrlf = last === 0x0d && units[end] === 0x0a;
      if (splitsPair || splitsCrlf) end -= 1;
    }
    result.push(units.slice(start, end));
    start = end;
  }
  return result;
}

/**
 * The text as Windows should type it: line breaks become a single CR, which a
 * `KEYEVENTF_UNICODE` key event delivers as Enter. A bare LF is ignored by most edit
 * controls.
 */
export function typeOutText(text: string): string {
  return text.replace(/\r\n|\n/g, '\r');
}

/** Browsers whose address bar may be read at the hotkey press. */
export const KNOWN_BROWSERS = new Set(['chrome', 'msedge', 'brave', 'firefox']);

export function isKnownBrowser(appId: string | undefined): boolean {
  const key = appIdFor(appId);
  return key !== undefined && KNOWN_BROWSERS.has(key);
}
