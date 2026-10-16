import { evaluateCleanupOutput, type GuardReason } from './cleanupGuard.js';
import { s1ControlLine } from './cleanupControlLine.js';
import type { CleanupModel } from './cleanupModel.js';
import {
  DEFAULT_CLEANUP_DEADLINE_MS,
  decideCleanupModel,
  type CleanupGates,
  type CleanupSkipReason,
} from './cleanupModelPolicy.js';
import { applyCleanupRules } from './cleanupRules.js';

/**
 * Rules, then (only when the gates allow) the local model with the guard. Mirrors
 * `Sources/UsefulVoiceCore/CleanupModel/CleanupPipeline.swift` rule for rule.
 *
 * The caller runs this at the cleanup marker, after vocabulary and before the user's own
 * rules. Dictation never waits on the model: it gets at most `deadlineMs` after this call
 * starts, and anything short of a guard-approved answer yields the rules-only text.
 *
 *   1. `applyCleanupRules` runs on the raw text (English only).
 *   2. Rules left nothing (the whole dictation was fillers): the raw text is the result, so
 *      History and the clipboard never get an empty entry. The model is not asked.
 *   3. `decideCleanupModel` (flag, model downloaded, at least 7 GiB reported, which is an
 *      8 GB machine, English): when it says
 *      skip, the rules text is the result.
 *   4. The model gets the rules text and the control line, up to the deadline. A timeout,
 *      null (error, nothing returned) or an answer the guard rejects (too many words
 *      dropped, content added, a changed number or negation, wrapper text, empty) is
 *      replaced by the rules text.
 */
export type CleanupSource = 'raw' | 'rules' | 'model';

export type CleanupModelOutcome =
  | { kind: 'skipped'; reason: CleanupSkipReason }
  | { kind: 'accepted' }
  | { kind: 'timedOut' }
  /** The model returned null: it could not load, it errored or it had nothing. */
  | { kind: 'failed' }
  | { kind: 'rejected'; reason: GuardReason };

export interface CleanupResult {
  text: string;
  source: CleanupSource;
  /** Absent when the rules left nothing and the model was never considered. */
  model?: CleanupModelOutcome;
}

export interface CleanupPipelineInput {
  raw: string;
  language: string | null | undefined;
  category: string | null | undefined;
  style: string | null | undefined;
  gates: CleanupGates;
  model: CleanupModel | null;
  deadlineMs?: number;
  /** The clock `deadline` is on. Tests pass their own. */
  now?: () => number;
}

export async function runCleanupPipeline(input: CleanupPipelineInput): Promise<CleanupResult> {
  const now = input.now ?? (() => performance.now());
  const start = now();
  const rulesText = applyCleanupRules(input.raw, input.language);
  if (rulesText === '') return { text: input.raw, source: 'raw' };
  const rulesSource: CleanupSource = rulesText === input.raw ? 'raw' : 'rules';
  const rulesResult = (model: CleanupModelOutcome): CleanupResult => ({ text: rulesText, source: rulesSource, model });

  const decision = decideCleanupModel(input.gates, input.language);
  if (!decision.run) return rulesResult({ kind: 'skipped', reason: decision.reason });
  if (!input.model) return rulesResult({ kind: 'skipped', reason: 'noModel' });

  const controlLine = s1ControlLine(input.category, input.style);
  const limit = start + (input.deadlineMs ?? DEFAULT_CLEANUP_DEADLINE_MS);
  const answer = await withDeadline(
    askModel(input.model, rulesText, controlLine, limit),
    Math.max(0, limit - now()),
  );
  if (answer === TIMED_OUT) return rulesResult({ kind: 'timedOut' });
  if (answer === null || answer === undefined) return rulesResult({ kind: 'failed' });

  const verdict = evaluateCleanupOutput(rulesText, answer);
  if (!verdict.accepted) return rulesResult({ kind: 'rejected', reason: verdict.reason });
  return { text: verdict.text, source: 'model', model: { kind: 'accepted' } };
}

const TIMED_OUT = Symbol('timedOut');

/** A model that throws, synchronously or not, is a failed model, not a failed dictation. */
async function askModel(model: CleanupModel, text: string, controlLine: string, deadline: number): Promise<string | null> {
  try {
    return await model.clean(text, controlLine, deadline);
  } catch {
    return null;
  }
}

/**
 * The work's value, or `TIMED_OUT` after `ms`, whichever comes first. The work is not
 * awaited after the limit, so a model that ignores the deadline cannot hold the dictation
 * up. Its late result is dropped.
 */
function withDeadline<T>(work: Promise<T>, ms: number): Promise<T | typeof TIMED_OUT> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(TIMED_OUT), ms);
    void work.then((value) => {
      clearTimeout(timer);
      resolve(value);
    });
  });
}
