/**
 * Keeps secrets out of anything that is logged or shown. Redaction is by VALUE first (the
 * actual stored key strings, all four providers), then by pattern for key-shaped strings that
 * were never stored. Always redact before truncating: a cut can leave half a key that no
 * longer matches.
 */

let knownSecrets: () => string[] = () => [];

/** The main process says where the stored keys can be read, so every error path redacts them all. */
export function setSecretSource(source: () => string[]): void {
  knownSecrets = source;
}

const PATTERNS: RegExp[] = [
  /\bsk-[A-Za-z0-9_-]{8,}/g,
  /\bAIza[0-9A-Za-z_-]{16,}/g,
  /\bxi-[A-Za-z0-9_-]{8,}/g,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi,
  /\b[A-Za-z0-9_-]{32,}\b/g,
];

export function redactSecrets(text: string, extra: ReadonlyArray<string | undefined> = []): string {
  let result = text;
  const values = [...knownSecrets(), ...extra].filter((value): value is string => typeof value === 'string' && value.length >= 4);
  // Longest first, so a key that contains another is replaced whole.
  for (const value of values.sort((a, b) => b.length - a.length)) result = result.split(value).join('[redacted]');
  for (const pattern of PATTERNS) result = result.replace(pattern, '[redacted]');
  return result;
}
