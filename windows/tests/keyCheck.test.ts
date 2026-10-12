import { describe, expect, it } from 'vitest';
import { isSendableKey, keyCheckFailure } from '../src/core/firstRun/keyCheck.js';
import { ProviderError } from '../src/core/transcription/deepgramProvider.js';

// Failure modes, written before the code:
//  1. A pasted key with a newline, a space inside, a non-ASCII character or a control
//     character can't be an HTTP header value: refuse it before any request, with a fixed
//     'rejected' answer, instead of letting fetch throw an error that may echo the key.
//  2. Whatever goes wrong, the message handed to the renderer is fixed text chosen by
//     kind, never the raw error: a transport error can quote the request, key included.
//  3. A refused key, a dead network and everything else stay three distinct answers.

describe('isSendableKey', () => {
  it.each(['abc123', 'a1b2c3d4e5f60718293a4b5c6d7e8f90', 'Key-With_Symbols.1'])('accepts %j', (key) => {
    expect(isSendableKey(key)).toBe(true);
  });
  it.each(['', 'has space', 'new\nline', 'tab\tkey', 'clé', 'emoji🙂', 'nul\u0000', 'del\u007f'])('refuses %j', (key) => {
    expect(isSendableKey(key)).toBe(false);
  });
});

describe('keyCheckFailure', () => {
  const secret = 'SECRET-KEY-VALUE';
  it('maps a refused key', () => {
    expect(keyCheckFailure(new ProviderError('unauthorized', `rejected ${secret}`)).kind).toBe('rejected');
  });
  it('maps a dead network and a timeout', () => {
    expect(keyCheckFailure(new ProviderError('transport', `Could not reach Deepgram: ${secret}`)).kind).toBe('network');
    expect(keyCheckFailure(new ProviderError('timedOut', 'x')).kind).toBe('network');
  });
  it('maps everything else to failed, including non-provider errors', () => {
    expect(keyCheckFailure(new ProviderError('outOfCredits', 'x')).kind).toBe('failed');
    expect(keyCheckFailure(new ProviderError('serverError', 'x')).kind).toBe('failed');
    expect(keyCheckFailure(new Error(`boom ${secret}`)).kind).toBe('failed');
    expect(keyCheckFailure('weird').kind).toBe('failed');
  });
  it('never returns the raw message', () => {
    for (const error of [
      new ProviderError('unauthorized', secret), new ProviderError('transport', secret),
      new ProviderError('outOfCredits', secret), new ProviderError('badRequest', secret), new Error(secret),
    ]) {
      expect(keyCheckFailure(error).message).not.toContain(secret);
    }
  });
});
