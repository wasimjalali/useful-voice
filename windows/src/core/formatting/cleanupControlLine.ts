/**
 * The control line S1-mini reads on top of every transcript. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/CleanupControlLine.swift` rule for rule.
 *
 * S1-mini by Superwhisper (Apache 2.0 plus one term: it must always be credited as
 * "S1-mini" by "Superwhisper", with that exact capitalisation). The vocabulary below is
 * the model card of superwhisper/s1-mini-GGUF at revision
 * 34add00a48a2e5d24e5a4ee5405a99620a3a240c ("Input format"), quoted:
 *
 *   System prompt:
 *     You are a text normalizer for speech-to-text transcripts. The input begins with a
 *     control line specifying the styling, structure, and context settings; clean the
 *     transcript to match those settings and output only the cleaned text.
 *
 *   The user message is a control line, then a newline, then the transcript:
 *     [Styling: <value>] [Structure: <value>] [Context: <value>]
 *     <raw transcript>
 *
 *   | Styling   | casual, semi-casual, semi-formal, formal                          |
 *   | Structure | prose, lists                                                      |
 *   | Context   | general, email                                                    |
 *
 *   "The system prompt and the control line are part of the input format the model was
 *   trained on. Skip either one, change the system prompt's wording, or send values
 *   outside the trained sets, and the model can hallucinate or produce garbled output."
 *
 * So this file only ever produces trained values, and the system prompt is copied
 * byte for byte. The category and style are raw strings, so this does not depend on the
 * app-awareness `AppCategory` type; the caller passes its raw value.
 *
 * Mapping (the card calls semi-formal "a good default"):
 *   - styling: the user's style when it is one of "casual", "semi-casual", "semi-formal",
 *     "formal" (spaces, underscores and "semiformal" spellings accepted), otherwise
 *     semi-formal for every app category. The eval ran the category-specific alternative:
 *     semi-casual for chat and coding apps lowercased the first word and dropped the final
 *     full stop, and restraint on clean text fell from 76% to 42%. `casual` also strips
 *     apostrophes, so both stay opt-in by style.
 *   - context: email -> email; everything else -> general.
 *   - structure: always prose. The card says lists is "deliberately conservative", but
 *     bullets are an edit the user did not ask for, so it is never chosen here.
 */

export const S1_MINI_SYSTEM_PROMPT =
  'You are a text normalizer for speech-to-text transcripts. The input begins with a control line ' +
  'specifying the styling, structure, and context settings; clean the transcript to match those ' +
  'settings and output only the cleaned text.';

export type S1Styling = 'casual' | 'semi-casual' | 'semi-formal' | 'formal';
export type S1Structure = 'prose' | 'lists';
export type S1Context = 'general' | 'email';

export interface S1Settings {
  styling: S1Styling;
  structure: S1Structure;
  context: S1Context;
}

export function s1Settings(category: string | null | undefined, style: string | null | undefined): S1Settings {
  const cat = normalise(category);
  return {
    styling: parseStyling(style) ?? 'semi-formal',
    structure: 'prose',
    context: cat === 'email' || cat === 'mail' ? 'email' : 'general',
  };
}

export function s1ControlLine(category: string | null | undefined, style: string | null | undefined): string {
  const s = s1Settings(category, style);
  return `[Styling: ${s.styling}] [Structure: ${s.structure}] [Context: ${s.context}]`;
}

/** The user message: control line, newline, transcript. */
export function s1UserMessage(category: string | null | undefined, style: string | null | undefined, text: string): string {
  return `${s1ControlLine(category, style)}\n${text}`;
}

function normalise(value: string | null | undefined): string {
  return (value ?? '').trim().toLowerCase().replace(/[\s_]+/g, '-');
}

function parseStyling(style: string | null | undefined): S1Styling | null {
  switch (normalise(style)) {
    case 'casual':
      return 'casual';
    case 'semi-casual':
    case 'semicasual':
      return 'semi-casual';
    case 'semi-formal':
    case 'semiformal':
      return 'semi-formal';
    case 'formal':
      return 'formal';
    default:
      return null;
  }
}
