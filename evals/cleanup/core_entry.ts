// Entry point the eval bundles with esbuild so the runner measures the shipped TypeScript
// core, not a copy. `core_cli.mjs` is the only importer.
export { applyCleanupRules } from '../../windows/src/core/formatting/cleanupRules.js';
export { evaluateCleanupOutput } from '../../windows/src/core/formatting/cleanupGuard.js';
export { s1ControlLine, S1_MINI_SYSTEM_PROMPT } from '../../windows/src/core/formatting/cleanupControlLine.js';
