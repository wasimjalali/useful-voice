/**
 * Decides whether the first-run flow opens at launch. Pure: the caller reads the
 * system state and passes it in, so every rule is unit-tested.
 */

export type FirstRunDecision =
  /** Open the flow at Welcome. */
  | 'show'
  /** Normal launch. */
  | 'skip'
  /** Normal launch, and record that setup is done: an existing user upgrading with a key saved. */
  | 'skipAndMarkCompleted';

export interface FirstRunInput {
  completed: boolean;
  /**
   * A Deepgram key is stored. Presence only: a key that cannot be decrypted right now
   * still counts, so an upgrade never walks an existing user through setup.
   */
  keyStored: boolean;
  forced: boolean;
}

export function decideFirstRun({ completed, keyStored, forced }: FirstRunInput): FirstRunDecision {
  if (forced) return 'show';
  if (completed) return 'skip';
  if (keyStored) return 'skipAndMarkCompleted';
  return 'show';
}

/** The steps `--first-run-step=<step>` can jump to, with the sample data each needs. */
export const FIRST_RUN_STEPS = [
  'welcome',
  'engine',
  'errKey',
  'deepgramKey',
  'microphone',
  'errMic',
  'tryIt',
  'tryItDone',
  'done',
] as const;

export type FirstRunStep = (typeof FIRST_RUN_STEPS)[number];

export interface FirstRunLaunch {
  forced: boolean;
  step: FirstRunStep | null;
}

/** `--force-first-run` and `--first-run-step=<step>` from the command line. */
export function firstRunLaunch(argv: readonly string[]): FirstRunLaunch {
  const forced = argv.includes('--force-first-run');
  const prefix = '--first-run-step=';
  const raw = argv.find((arg) => arg.startsWith(prefix))?.slice(prefix.length) ?? '';
  const step = (FIRST_RUN_STEPS as readonly string[]).includes(raw) ? (raw as FirstRunStep) : null;
  return { forced, step };
}
