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
  /**
   * The page address when the app is a known browser and its address bar could be
   * read. Memory only, never logged. Compared (scheme, host, path and query) when the
   * focus at delivery also has one.
   */
  browserUrl?: string;
}

/**
 * - unknownTarget: nothing was captured at the hotkey press.
 * - targetGone: the target process quit.
 * - notRestored: focus moved and bringing the target back failed or brought back another window.
 * - pageChanged: the target window shows another page. Reactivating can't fix that.
 */
export type TargetLossReason = 'unknownTarget' | 'targetGone' | 'notRestored' | 'pageChanged';

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
 * Whether `current` (what has focus now) is the captured target: the same window and
 * focused child (`identityMatches`) showing the same page (`pageChanged`).
 */
export function targetMatches(target: DeliveryTarget, current: DeliveryTarget | null | undefined): boolean {
  return identityMatches(target, current) && !pageChanged(target, current);
}

/**
 * Whether `current` is the target's app, window and focused child.
 *
 * The app: the same process when both sides know it, and the same app id when both
 * know that too (a reused pid with another app is not the target). Without both pids,
 * the same app id. The window and the focused child: compared only when the target
 * recorded one; a current focus that cannot report one then does not match.
 */
export function identityMatches(target: DeliveryTarget, current: DeliveryTarget | null | undefined): boolean {
  if (!current || !isIdentified(target)) return false;
  if (target.processId !== undefined && current.processId !== undefined) {
    if (target.processId !== current.processId) return false;
    if (target.appId !== undefined && current.appId !== undefined && target.appId !== current.appId) return false;
  } else if (target.appId === undefined || target.appId !== current.appId) {
    return false;
  }
  if (target.windowHandle !== undefined && target.windowHandle !== current.windowHandle) return false;
  if (target.focusHandle !== undefined && target.focusHandle !== current.focusHandle) return false;
  return true;
}

/**
 * Whether both sides read an http(s) page address and the addresses differ. A side
 * without one is not compared. The fragment is ignored: an in-page anchor is the same page.
 */
export function pageChanged(target: DeliveryTarget, current: DeliveryTarget | null | undefined): boolean {
  const then = pageKey(target.browserUrl);
  const now = pageKey(current?.browserUrl);
  return then !== undefined && now !== undefined && then !== now;
}

/**
 * The comparable part of a page address: lowercased scheme and host, port, path and
 * query. Undefined for anything that isn't http or https.
 */
export function pageKey(address: string | undefined): string | undefined {
  if (!address) return undefined;
  let url: URL;
  try {
    url = new URL(address.trim());
  } catch {
    return undefined; // not an address at all: nothing to compare
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined;
  if (!url.hostname) return undefined;
  const port = url.port ? `:${url.port}` : '';
  return `${url.protocol}//${url.hostname.toLowerCase()}${port}${url.pathname || '/'}${url.search}`;
}

/** The first check at delivery. */
export function checkTarget(
  target: DeliveryTarget | null | undefined,
  current: DeliveryTarget | null | undefined,
  targetRunning: boolean,
): TargetCheck {
  if (!isIdentified(target)) return { kind: 'copyOnly', reason: 'unknownTarget' };
  if (identityMatches(target, current)) {
    return pageChanged(target, current) ? { kind: 'copyOnly', reason: 'pageChanged' } : { kind: 'insert' };
  }
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
  if (!reactivated || !identityMatches(target, current)) return { kind: 'copyOnly', reason: 'notRestored' };
  return pageChanged(target, current) ? { kind: 'copyOnly', reason: 'pageChanged' } : { kind: 'insert' };
}

/** How text goes in. Exactly one per delivery, so it can never land twice. */
export type InsertionMethod = 'paste' | 'typeOut' | 'copyOnly';

/** Any line break: LF, CR, VT, FF, NEL, line and paragraph separators. */
const LINE_BREAK = /[\n\r\u000B\u000C\u0085\u2028\u2029]/;

/**
 * Paste unless the user turned typing on for this app. An unknown app always pastes.
 * Text with a line break is never typed (a typed line break is an Enter key, which
 * sends the message in a chat app or runs the line in a terminal), nor pasted into an
 * app the user marked for typing (paste doesn't work there): it is copied only.
 */
export function insertionMethodFor(
  appId: string | undefined,
  typeOutApps: readonly string[],
  text: string,
): InsertionMethod {
  const key = appIdFor(appId);
  if (!key) return 'paste';
  if (!typeOutApps.some((app) => appIdFor(app) === key)) return 'paste';
  return LINE_BREAK.test(text) ? 'copyOnly' : 'typeOut';
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

/** Browsers whose address bar may be read at the hotkey press. */
export const KNOWN_BROWSERS = new Set(['chrome', 'msedge', 'brave', 'firefox']);

export function isKnownBrowser(appId: string | undefined): boolean {
  const key = appIdFor(appId);
  return key !== undefined && KNOWN_BROWSERS.has(key);
}
