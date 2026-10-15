import { isAppCategory, type AppCategory } from './appCategory.js';
import {
  APP_SEEDS,
  BROWSER_BUNDLE_IDS,
  BROWSER_EXECUTABLES,
  CODING_APP_PREFIXES,
  URL_RULES,
} from './appCategorySeeds.js';

/**
 * Which category an app or web page belongs to. Mirrors
 * `Sources/UsefulVoiceCore/AppAwareness/AppCategoryRegistry.swift` rule for rule.
 *
 * Resolution order: the user's override for the app, then the web address (when the
 * delivery layer could read one), then the app's seed, then Other. Everything here is
 * pure: reading the foreground app and the browser address is the caller's job.
 */

/**
 * The lookup key for an app id: trimmed, lower case, and for a Windows path only the
 * file name (`C:\Program Files\Slack\slack.exe` becomes `slack.exe`).
 */
export function normalizeAppID(raw: string): string {
  let id = raw.trim().toLowerCase();
  const slash = Math.max(id.lastIndexOf('/'), id.lastIndexOf('\\'));
  if (slash >= 0) id = id.slice(slash + 1);
  return id;
}

const SEED_MAP: ReadonlyMap<string, AppCategory> = (() => {
  const map = new Map<string, AppCategory>();
  for (const { category, ids } of APP_SEEDS) {
    for (const id of ids) map.set(normalizeAppID(id), category);
  }
  return map;
})();

const BROWSER_SET: ReadonlySet<string> = new Set(
  [...BROWSER_BUNDLE_IDS, ...BROWSER_EXECUTABLES].map(normalizeAppID),
);

/** The seeded category for an app id (bundle id or executable name), or null. */
export function seededCategory(appID: string): AppCategory | null {
  const id = normalizeAppID(appID);
  if (id === '') return null;
  const exact = SEED_MAP.get(id);
  if (exact) return exact;
  for (const prefix of CODING_APP_PREFIXES) {
    if (id.startsWith(prefix.toLowerCase())) return 'coding';
  }
  return null;
}

/** Whether the app is a web browser, whose category comes from the page address. */
export function isBrowser(appID: string): boolean {
  return BROWSER_SET.has(normalizeAppID(appID));
}

export interface ParsedWebURL {
  /** Lower case, no `www.`, no port, no trailing dot. */
  host: string;
  /** Lower case, starts with `/` or is empty. No query or fragment. */
  path: string;
}

function isHostChar(c: string): boolean {
  return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c === '-' || c === '.';
}

/**
 * Splits an address into host and path. Accepts `http` and `https` addresses and bare
 * `host/path` text (a browser address bar often omits the scheme). Returns null for
 * anything else: other schemes, empty text, spaces in the host, a non-numeric port.
 */
export function parseWebURL(raw: string): ParsedWebURL | null {
  const text = raw.trim();
  if (text === '') return null;
  let rest = text;
  const schemeEnd = text.indexOf('://');
  if (schemeEnd >= 0) {
    const scheme = text.slice(0, schemeEnd).toLowerCase();
    if (scheme !== 'http' && scheme !== 'https') return null;
    rest = text.slice(schemeEnd + 3);
  }
  let end = rest.length;
  for (let i = 0; i < rest.length; i++) {
    const c = rest[i] as string;
    if (c === '/' || c === '?' || c === '#') {
      end = i;
      break;
    }
  }
  let authority = rest.slice(0, end);
  const remainder = rest.slice(end);
  let path = '';
  if (remainder.startsWith('/')) {
    let pathEnd = remainder.length;
    for (let i = 0; i < remainder.length; i++) {
      const c = remainder[i] as string;
      if (c === '?' || c === '#') {
        pathEnd = i;
        break;
      }
    }
    path = remainder.slice(0, pathEnd).toLowerCase();
  }
  const at = authority.lastIndexOf('@');
  if (at >= 0) authority = authority.slice(at + 1);
  if (authority.startsWith('[')) return null;
  const colon = authority.lastIndexOf(':');
  if (colon >= 0) {
    const port = authority.slice(colon + 1);
    for (const c of port) {
      if (c < '0' || c > '9') return null;
    }
    authority = authority.slice(0, colon);
  }
  let host = authority.toLowerCase();
  while (host.endsWith('.')) host = host.slice(0, -1);
  if (host.startsWith('www.')) host = host.slice(4);
  if (host === '') return null;
  for (const c of host) {
    if (!isHostChar(c)) return null;
  }
  return { host, path };
}

function pathMatches(path: string, prefix: string): boolean {
  if (path === prefix) return true;
  const base = prefix.endsWith('/') ? prefix : `${prefix}/`;
  return path.startsWith(base);
}

/** The category for a web address, or null when no rule matches or the text is not an address. */
export function categoryForURL(raw: string): AppCategory | null {
  const parsed = parseWebURL(raw);
  if (!parsed) return null;
  for (const rule of URL_RULES) {
    const hostMatches =
      parsed.host === rule.host || (rule.subdomains && parsed.host.endsWith(`.${rule.host}`));
    if (!hostMatches) continue;
    if (rule.pathPrefix !== null && !pathMatches(parsed.path, rule.pathPrefix)) continue;
    return rule.category;
  }
  return null;
}

export interface ResolveCategoryInput {
  /** macOS bundle id or Windows executable name (a full path is fine). */
  appID?: string | null;
  /** The browser address, when the delivery layer could read it. */
  url?: string | null;
  /** The user's per-app choices, keyed by app id. Keys match case-insensitively. */
  overrides?: Readonly<Record<string, AppCategory>> | null;
}

/** Override, then web address, then app seed, then Other. Never throws on bad input. */
export function resolveCategory(input: ResolveCategoryInput): AppCategory {
  const appID = input.appID ?? null;
  if (appID !== null && input.overrides) {
    const key = normalizeAppID(appID);
    if (key !== '') {
      // Sorted so two keys that differ only in case always resolve the same way.
      const keys = Object.keys(input.overrides).sort();
      for (const overrideKey of keys) {
        const category = input.overrides[overrideKey];
        if (normalizeAppID(overrideKey) === key && isAppCategory(category)) return category;
      }
    }
  }
  if (input.url !== null && input.url !== undefined) {
    const fromURL = categoryForURL(input.url);
    if (fromURL) return fromURL;
  }
  if (appID !== null) {
    const seeded = seededCategory(appID);
    if (seeded) return seeded;
  }
  return 'other';
}
