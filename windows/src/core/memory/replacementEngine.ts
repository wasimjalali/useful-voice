import type { MatchMode, MemoryLanguage, ReplacementRule } from '../models.js';
import { canonical, languageMatches, wordBoundaryPattern } from '../dictionary/termMatcher.js';

export interface ReplacementOutcome {
  text: string;
  /** Rules that actually changed something, for history and usage counters. */
  appliedRuleIds: string[];
}

/**
 * Records which parts of the working text were produced by a rule.
 *
 * Rules cascade, and a later rule matching text an earlier rule just wrote is
 * usually wrong: with `code -> CODE` and `claude code -> Claude Code`, the longer
 * rule runs first (longest match wins), and then the shorter rule rewrites the
 * "code" inside its own output into "Claude CODE". Regions a rule produced are
 * almost never intended as input for another rule.
 *
 * An offset table is used rather than inline marker characters. Markers get
 * consumed when a later rule's match spans them (a match from "cloud code" to
 * "code" would swallow a marker sitting between the two), which silently loses
 * the protection — and a marker left in the delivered text would be worse.
 *
 * Boundaries stay valid across replacements because `replaceSpan` adjusts them:
 * a replacement inside a span enlarges it by the length difference, a
 * replacement that overlaps a span boundary absorbs it, and a replacement that
 * covers a span entirely deletes it (that span's text no longer exists).
 */
class ProtectedSpans {
  private readonly starts: number[] = [];
  private readonly ends: number[] = [];

  /** True when the range `[start, end)` begins inside a produced region. */
  covers(start: number, _end: number): boolean {
    for (let i = 0; i < this.starts.length; i += 1) {
      const spanStart = this.starts[i] as number;
      const spanEnd = this.ends[i] as number;
      // Strictly inside: a match starting exactly at spanStart has been
      // consumed by another rule and replaced, so it is not protected.
      if (start > spanStart && start < spanEnd) return true;
    }
    return false;
  }

  add(start: number, end: number): void {
    if (end <= start) return;
    this.starts.push(start);
    this.ends.push(end);
  }

  /** Record a replacement of `[start, end)` with `newLength` characters. */
  replaceSpan(start: number, end: number, newLength: number): void {
    const delta = newLength - (end - start);
    for (let i = 0; i < this.starts.length; i += 1) {
      let spanStart = this.starts[i] as number;
      let spanEnd = this.ends[i] as number;

      if (spanEnd <= start) continue; // entirely before the edit
      if (spanStart >= end) {
        // Entirely after the edit: shift by the length change.
        this.starts[i] = spanStart + delta;
        this.ends[i] = spanEnd + delta;
        continue;
      }

      // Overlapping. Grow or shrink by the delta, then clamp to the edit.
      spanStart = Math.min(spanStart, start);
      spanEnd = Math.max(spanEnd + delta, end + delta);
      this.starts[i] = spanStart;
      this.ends[i] = spanEnd;
    }
  }
}

/**
 * A rule compiled once and reused.
 *
 * Rules are applied twice per dictation (before and after snippet expansion) and
 * a dictionary can hold thousands of them, so compiling the pattern on every
 * pass was measurable on the macOS build and would be worse here.
 */
interface CompiledRule {
  rule: ReplacementRule;
  regex: RegExp | null;
  /** The literal phrase, used for the non-regex fallback path. */
  literal: string;
  replacement: string;
}

export class RuleSet {
  private readonly compiled: CompiledRule[];

  constructor(rules: readonly ReplacementRule[], language: MemoryLanguage) {
    const prepared: CompiledRule[] = [];
    for (const rule of rules) {
      if (!rule.isEnabled) continue;
      if (!languageMatches(rule.language, language)) continue;
      const match = rule.match.trim();
      const replacement = rule.replacement.trim();
      if (match.length === 0) continue;

      prepared.push({
        rule,
        regex: compileRule(match, rule.matchMode),
        literal: match,
        replacement,
      });
    }
    // Longest match first, so multi-word phrases win over their own fragments:
    // without this, a rule for "code" fires inside "Claude Code" and the longer
    // rule never gets a chance. Ties break on the canonical match so the result
    // does not depend on the input array's order (the previous locale-aware
    // comparison made rule order locale-dependent, so the same dictionary could
    // produce different text for different users).
    prepared.sort((a, b) => {
      if (a.literal.length !== b.literal.length) return b.literal.length - a.literal.length;
      const left = canonical(a.literal);
      const right = canonical(b.literal);
      if (left !== right) return left < right ? -1 : 1;
      return a.rule.id < b.rule.id ? -1 : a.rule.id > b.rule.id ? 1 : 0;
    });
    this.compiled = prepared;
  }

  get size(): number {
    return this.compiled.length;
  }

  apply(text: string): ReplacementOutcome {
    let output = text;
    const appliedRuleIds: string[] = [];
    const spans = new ProtectedSpans();

    for (const entry of this.compiled) {
      const next = applyOne(output, entry, spans);
      if (next !== output) {
        output = next;
        appliedRuleIds.push(entry.rule.id);
      }
    }

    return { text: output, appliedRuleIds };
  }
}

function compileRule(match: string, mode: MatchMode): RegExp | null {
  try {
    switch (mode) {
      case 'wordBoundaryPhrase':
        return new RegExp(wordBoundaryPattern(match), 'giu');
      case 'caseInsensitivePhrase':
        return new RegExp(escapedLiteral(match), 'giu');
      case 'exact':
        return new RegExp(`^(?:${escapedLiteral(match)})$`, 'iu');
    }
  } catch {
    // A phrase the engine cannot represent simply never matches. Throwing here
    // would turn one odd dictionary entry into a failed dictation.
    return null;
  }
}

function escapedLiteral(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function applyOne(text: string, entry: CompiledRule, spans: ProtectedSpans): string {
  // The replacement is a literal: dollar signs and other substitution
  // metacharacters in user text must survive verbatim. `String.replace` treats
  // `$&` and `$1` specially, so a function is used rather than a pattern string.
  const literal = entry.replacement;

  const replaceAt = (start: number, end: number): number => {
    spans.add(start, start + literal.length);
    spans.replaceSpan(start, end, literal.length);
    return literal.length;
  };

  if (entry.regex) {
    // Match collection and assembly are done by hand so offsets stay available
    // for the protection check and for adjusting existing spans.
    const pattern = entry.rule.matchMode === 'exact'
      ? new RegExp(entry.regex.source, 'iu')
      : new RegExp(entry.regex.source, entry.regex.flags);
    const matches: Array<{ start: number; end: number }> = [];
    if (entry.rule.matchMode === 'exact') {
      const single = pattern.exec(text);
      if (single) matches.push({ start: single.index, end: single.index + single[0].length });
    } else {
      let match: RegExpExecArray | null;
      while ((match = pattern.exec(text)) !== null) {
        matches.push({ start: match.index, end: match.index + match[0].length });
        // A zero-length match would loop forever.
        if (match[0].length === 0) pattern.lastIndex += 1;
      }
    }

    let output = '';
    let cursor = 0;
    let changed = false;
    for (const { start, end } of matches) {
      if (spans.covers(start, end)) continue;
      output += text.slice(cursor, start);
      replaceAt(start, end);
      output += literal;
      cursor = end;
      changed = true;
    }
    if (!changed) return text;
    output += text.slice(cursor);
    return output;
  }

  if (entry.rule.matchMode === 'exact') return text;

  // Fallback for a phrase that failed to compile as a pattern. Only a genuine
  // rename (match differs from replacement) is worth doing by hand; a case-only
  // fix cannot be done safely without the pattern, so it is skipped rather than
  // risking a substring replacement inside a larger word.
  if (literal === entry.literal) return text;
  const index = text.toLowerCase().indexOf(entry.literal.toLowerCase());
  if (index < 0 || spans.covers(index, index + entry.literal.length)) return text;
  replaceAt(index, index + entry.literal.length);
  return text.slice(0, index) + literal + text.slice(index + entry.literal.length);
}

/**
 * Apply a set of replacement rules to a transcript.
 *
 * Prefer `new RuleSet(rules, language).apply(text)` in hot paths: it compiles
 * once and can be reused across the two passes of one dictation. This
 * convenience wrapper exists for tests and one-off use.
 */
export function applyReplacements(
  rules: readonly ReplacementRule[],
  text: string,
  language: MemoryLanguage,
  excludeRuleIds: ReadonlySet<string> = new Set(),
): ReplacementOutcome {
  const usable = excludeRuleIds.size === 0
    ? rules
    : rules.filter((rule) => !excludeRuleIds.has(rule.id));
  return new RuleSet(usable, language).apply(text);
}
