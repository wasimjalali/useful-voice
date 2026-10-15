import Foundation

/// The control line S1-mini reads on top of every transcript.
/// `windows/src/core/formatting/cleanupControlLine.ts` mirrors this file rule for rule.
///
/// S1-mini by Superwhisper (Apache 2.0 plus one term: it must always be credited as
/// "S1-mini" by "Superwhisper", with that exact capitalisation). The vocabulary below is
/// the model card of superwhisper/s1-mini-GGUF at revision
/// 34add00a48a2e5d24e5a4ee5405a99620a3a240c ("Input format"), quoted:
///
///   System prompt:
///     You are a text normalizer for speech-to-text transcripts. The input begins with a
///     control line specifying the styling, structure, and context settings; clean the
///     transcript to match those settings and output only the cleaned text.
///
///   The user message is a control line, then a newline, then the transcript:
///     [Styling: <value>] [Structure: <value>] [Context: <value>]
///     <raw transcript>
///
///   | Styling   | casual, semi-casual, semi-formal, formal |
///   | Structure | prose, lists                             |
///   | Context   | general, email                           |
///
///   "The system prompt and the control line are part of the input format the model was
///   trained on. Skip either one, change the system prompt's wording, or send values
///   outside the trained sets, and the model can hallucinate or produce garbled output."
///
/// So this file only ever produces trained values, and the system prompt is copied
/// byte for byte. The category and style are raw strings, so this does not depend on the
/// app-awareness `AppCategory` type; the caller passes its raw value.
///
/// Mapping (the card calls semi-formal "a good default"; `casual` lowercases everything
/// and strips apostrophes, which would undo Deepgram's formatting, so it is only used when
/// the user's style asks for it by name):
///   - style: "casual", "semi-casual", "semi-formal", "formal" (spaces, underscores and
///     "semiformal" spellings accepted). Anything else falls back to the category default.
///   - category default styling: chat, messaging, social, coding, coding-agent, code, ide,
///     terminal -> semi-casual
///     (keeps the speaker's phrasing, no "gonna" -> "going to"); every other category ->
///     semi-formal.
///   - context: email -> email; everything else -> general.
///   - structure: always prose. The card says lists is "deliberately conservative", but
///     bullets are an edit the user did not ask for, so it is never chosen here.
public enum CleanupControlLine {
    public static let systemPrompt =
        "You are a text normalizer for speech-to-text transcripts. The input begins with a control line "
        + "specifying the styling, structure, and context settings; clean the transcript to match those "
        + "settings and output only the cleaned text."

    public enum Styling: String, Equatable, Sendable {
        case casual
        case semiCasual = "semi-casual"
        case semiFormal = "semi-formal"
        case formal
    }

    public enum Structure: String, Equatable, Sendable {
        case prose
        case lists
    }

    public enum Context: String, Equatable, Sendable {
        case general
        case email
    }

    public struct Settings: Equatable, Sendable {
        public var styling: Styling
        public var structure: Structure
        public var context: Context
    }

    public static func settings(category: String?, style: String?) -> Settings {
        let cat = normalise(category)
        let fallback: Styling = semiCasualCategories.contains(cat) ? .semiCasual : .semiFormal
        return Settings(
            styling: parseStyling(style) ?? fallback,
            structure: .prose,
            context: cat == "email" || cat == "mail" ? .email : .general)
    }

    public static func line(category: String?, style: String?) -> String {
        let s = settings(category: category, style: style)
        return "[Styling: \(s.styling.rawValue)] [Structure: \(s.structure.rawValue)] [Context: \(s.context.rawValue)]"
    }

    /// The user message: control line, newline, transcript.
    public static func userMessage(category: String?, style: String?, text: String) -> String {
        "\(line(category: category, style: style))\n\(text)"
    }

    private static let semiCasualCategories: Set<String> = ["chat", "messaging", "social", "coding", "coding-agent", "code", "ide", "terminal"]

    private static func normalise(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
    }

    private static func parseStyling(_ style: String?) -> Styling? {
        switch normalise(style) {
        case "casual": return .casual
        case "semi-casual", "semicasual": return .semiCasual
        case "semi-formal", "semiformal": return .semiFormal
        case "formal": return .formal
        default: return nil
        }
    }
}
