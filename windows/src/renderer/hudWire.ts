import type { HudFrame } from '../core/hudModel.js';

// The wire frame the main process sends on `hud:view`. These mirror the types exported
// from `core/hudModel.ts` by the main-process half; switch this import when that lands.

export type HudPlacement = { kind: 'bottom' } | { kind: 'caret'; flipped: boolean };
export type HudColorway = 'ink' | 'paper' | 'signal' | 'accent';
export interface HudStyle {
  colorway: HudColorway;
  accent: string;
  systemDark: boolean;
}
export type HudWireFrame = HudFrame & { placement: HudPlacement; style: HudStyle };

export const DEFAULT_PLACEMENT: HudPlacement = { kind: 'bottom' };
export const DEFAULT_STYLE: HudStyle = { colorway: 'ink', accent: '#F2A93B', systemDark: false };
