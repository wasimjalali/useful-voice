import { ProviderError } from '../transcription/deepgramProvider.js';

/** What the setup flow's key check answers when it fails. */
export interface KeyCheckFailure {
  kind: 'rejected' | 'network' | 'failed';
  message: string;
}

/**
 * Whether a pasted key can go in an `Authorization` header at all: printable ASCII, no
 * spaces. Anything else is refused before a request, so no error can echo it.
 */
export function isSendableKey(key: string): boolean {
  return /^[\x21-\x7e]+$/.test(key);
}

/**
 * The failure to show for an error from the check. The message is fixed text chosen by
 * kind, never the error's own: a transport error can quote the request, key included.
 */
export function keyCheckFailure(error: unknown): KeyCheckFailure {
  const kind = error instanceof ProviderError ? error.kind : null;
  if (kind === 'unauthorized') return { kind: 'rejected', message: 'Deepgram rejected the key.' };
  if (kind === 'transport' || kind === 'timedOut') return { kind: 'network', message: 'Could not reach Deepgram.' };
  if (kind === 'outOfCredits') return { kind: 'failed', message: 'Your Deepgram account is out of credits.' };
  if (kind === 'rateLimited') return { kind: 'failed', message: 'Deepgram is busy. Try again in a moment.' };
  if (kind === 'serverError') return { kind: 'failed', message: 'Deepgram is having trouble. Try again in a moment.' };
  return { kind: 'failed', message: 'Deepgram could not check the key.' };
}
