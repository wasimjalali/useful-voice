import { describe, expect, it } from 'vitest';
import {
  HARD_TOKEN_LIMIT,
  MAX_TERM_LENGTH,
  MAX_TERMS,
  SAFETY_MARGIN_TOKENS,
  TOKEN_BUDGET,
  estimateListTokens,
  estimateTokens,
  exceedsBudget,
  isSendableKeyterm,
} from '../src/core/transcription/keytermBudget.js';

describe('budget constants', () => {
  it('stays below the provider ceiling', () => {
    expect(HARD_TOKEN_LIMIT).toBe(500);
    expect(TOKEN_BUDGET).toBeLessThan(HARD_TOKEN_LIMIT);
    expect(TOKEN_BUDGET + SAFETY_MARGIN_TOKENS).toBeLessThanOrEqual(HARD_TOKEN_LIMIT);
  });
});

describe('estimateTokens', () => {
  it('never returns zero for a non-empty term', () => {
    expect(estimateTokens('Kubernetes')).toBeGreaterThanOrEqual(1);
    expect(estimateTokens('a')).toBeGreaterThanOrEqual(1);
  });

  it('costs nothing for empty input', () => {
    expect(estimateTokens('')).toBe(0);
    expect(estimateTokens('   ')).toBe(0);
  });

  it('grows with phrase length', () => {
    expect(estimateTokens('next js app router')).toBeGreaterThan(estimateTokens('next'));
  });

  it('charges extra for separators that tokenize on their own', () => {
    expect(estimateTokens('GPT-4')).toBeGreaterThan(estimateTokens('GPT4'));
  });

  /**
   * The macOS implementation assumed ~5 characters per token for every script,
   * which undercounts CJK by roughly 5x. Japanese and Chinese are reachable
   * through the `auto` language pin, so a CJK dictionary could exceed the
   * provider's 500-token ceiling while the estimator reported a safe margin.
   */
  it('charges far more for CJK than for Latin of the same length', () => {
    const japanese = 'こんにちは世界';
    const latin = 'abcdefg';
    expect(japanese.length).toBe(latin.length);
    expect(estimateTokens(japanese)).toBeGreaterThan(estimateTokens(latin) * 3);
  });

  it('charges a per-character cost for Han and Hangul', () => {
    expect(estimateTokens('中文字符测试')).toBeGreaterThanOrEqual(6);
    expect(estimateTokens('한국어테스트')).toBeGreaterThanOrEqual(5);
  });

  it('charges more for Cyrillic and Greek than for Latin', () => {
    expect(estimateTokens('Привет')).toBeGreaterThan(estimateTokens('Privet'));
  });

  it('keeps a realistic dictionary inside the budget', () => {
    // 100 two-word terms is the count ceiling; they must also fit the tokens.
    const terms = Array.from({ length: MAX_TERMS }, (_, i) => `term${i} name`);
    expect(estimateListTokens(terms)).toBeLessThanOrEqual(TOKEN_BUDGET);
  });

  it('detects a list that would be rejected outright', () => {
    const huge = Array.from({ length: 600 }, (_, i) => `word${i}`);
    expect(exceedsBudget(huge)).toBe(true);
    expect(exceedsBudget(['one', 'two'])).toBe(false);
  });

  it('detects too many terms even when they are cheap', () => {
    const manyShort = Array.from({ length: MAX_TERMS + 1 }, () => 'a');
    expect(exceedsBudget(manyShort)).toBe(true);
  });
});

describe('isSendableKeyterm', () => {
  it('accepts real dictionary terms', () => {
    expect(isSendableKeyterm('Kubernetes')).toBe(true);
    expect(isSendableKeyterm('gpt-4o')).toBe(true);
    expect(isSendableKeyterm('Claude Code')).toBe(true);
    expect(isSendableKeyterm('Zürich')).toBe(true);
    expect(isSendableKeyterm('Müller')).toBe(true);
  });

  it('rejects empty and whitespace-only input', () => {
    expect(isSendableKeyterm('')).toBe(false);
    expect(isSendableKeyterm('   ')).toBe(false);
  });

  it('rejects punctuation-only input', () => {
    expect(isSendableKeyterm('!!!')).toBe(false);
    expect(isSendableKeyterm('---')).toBe(false);
  });

  it('rejects terms longer than the cap', () => {
    expect(isSendableKeyterm('a'.repeat(MAX_TERM_LENGTH))).toBe(true);
    expect(isSendableKeyterm('a'.repeat(MAX_TERM_LENGTH + 1))).toBe(false);
  });

  it('rejects control characters that would corrupt the query string', () => {
    expect(isSendableKeyterm('bad\u0000term')).toBe(false);
    expect(isSendableKeyterm('bad\u0007term')).toBe(false);
    expect(isSendableKeyterm('bad\u001fterm')).toBe(false);
  });
});
