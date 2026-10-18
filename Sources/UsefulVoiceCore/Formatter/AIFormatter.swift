import Foundation

/// Checks a model's formatted text before it replaces the transcript. Pure.
public enum FormatterGuard {
    static let preambles = ["here is", "here's", "sure", "certainly", "i've", "i have", "of course"]
    static let leadingFillers = ["umm", "uhh", "hmm", "erm", "um", "uh", "er"]

    /// The text to use, or nil when the output can't be trusted (the transcript is
    /// delivered unformatted instead).
    ///
    /// Trims, strips one wrapping code fence and one wrapping `<dictation>` tag,
    /// then rejects: empty output, output over twice the input plus 40 characters,
    /// output under 0.4x an input of 20 or more characters, an output of five or
    /// more words where under 60% of the words come from the input, leaked prompt
    /// tags, and an assistant preamble the dictation itself didn't start with.
    public static func accept(input: String, output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripFence(text)
        text = stripDictationTag(text)
        guard !text.isEmpty else { return nil }

        let inputLength = input.trimmingCharacters(in: .whitespacesAndNewlines).count
        if text.count > inputLength * 2 + 40 { return nil }
        if inputLength >= 20, Double(text.count) < Double(inputLength) * 0.4 { return nil }

        let lowered = text.lowercased()
        if lowered.contains("<vocabulary>") || lowered.contains("</dictation>") { return nil }

        let outputWords = words(in: text)
        if outputWords.count >= 5 {
            let inputWords = Set(words(in: input))
            let shared = outputWords.filter { inputWords.contains($0) }.count
            if Double(shared) < Double(outputWords.count) * 0.6 { return nil }
        }

        let spoken = withoutLeadingFillers(normalizeApostrophes(input.lowercased()))
        let reply = normalizeApostrophes(lowered)
        for preamble in preambles where startsWithPhrase(reply, preamble) {
            // A dictation that really starts that way ("Sure, send it") is not a preamble.
            if !startsWithPhrase(spoken, preamble) { return nil }
        }
        return text
    }

    /// Lowercase words: curly apostrophes made straight, all punctuation (apostrophes
    /// too) removed, split on whitespace. "can't" and "can\u{2019}t" are both "cant".
    static func words(in text: String) -> [String] {
        let strip = CharacterSet.punctuationCharacters.union(.symbols)
        return normalizeApostrophes(text.lowercased())
            .components(separatedBy: .whitespacesAndNewlines)
            .map { String($0.unicodeScalars.filter { !strip.contains($0) }.map(Character.init)) }
            .filter { !$0.isEmpty }
    }

    /// `text` begins with `phrase` as whole words: "i have" matches "I have it" but not
    /// "I haven't", and "sure" matches "Sure, ok" but not "Surely".
    private static func startsWithPhrase(_ text: String, _ phrase: String) -> Bool {
        guard text.hasPrefix(phrase) else { return false }
        guard let next = text.dropFirst(phrase.count).first else { return true }
        return !(next.isLetter || next.isNumber || next == "'")
    }

    static func normalizeApostrophes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
    }

    /// "um, sure ..." -> "sure ...": the filler the formatter would drop anyway.
    private static func withoutLeadingFillers(_ text: String) -> String {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers where rest.hasPrefix(filler) {
                let after = rest.dropFirst(filler.count)
                guard after.first.map({ !$0.isLetter && !$0.isNumber }) ?? true else { continue }
                rest = after.drop(while: { $0 == "," || $0 == "." || $0.isWhitespace })
                changed = true
            }
        }
        return String(rest)
    }

    private static func stripFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        var body = String(text.dropLast(3))
        body.removeFirst(3)
        // The opening fence may carry a language tag on its own line.
        if let newline = body.firstIndex(of: "\n"),
           body[body.startIndex..<newline].allSatisfy({ $0.isLetter || $0.isNumber }) {
            body = String(body[body.index(after: newline)...])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripDictationTag(_ text: String) -> String {
        let open = "<dictation>", close = "</dictation>"
        guard text.hasPrefix(open), text.hasSuffix(close) else { return text }
        return String(text.dropFirst(open.count).dropLast(close.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Builds and parses the Gemini and Anthropic formatting requests. Pure.
public enum FormatterRequest {
    public static let maximumVocabularyWords = 100

    /// `<vocabulary>a, b</vocabulary>\n<dictation>\n{text}\n</dictation>`; the
    /// vocabulary line only when there are words.
    public static func userMessage(text: String, vocabulary: [String]) -> String {
        let words = vocabulary
            .map { $0.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maximumVocabularyWords)
        var message = ""
        if !words.isEmpty { message += "<vocabulary>\(words.joined(separator: ", "))</vocabulary>\n" }
        message += "<dictation>\n\(text)\n</dictation>"
        return message
    }

    public static func deadline(for model: ModelEntry) -> TimeInterval {
        model.apiModel == "claude-sonnet-5-5" ? 10 : 6
    }

    /// Twice the dictation plus room, within 512...8192. Counts the dictation only.
    public static func maxTokens(forInput text: String) -> Int {
        min(8192, max(512, text.utf16.count * 2 + 256))
    }

    /// 3.8 Flash rejects `minimal`, so its lowest level is `low`.
    static func geminiThinkingLevel(_ apiModel: String) -> String { "low" }

    static func gemini(model: ModelEntry, apiKey: String, text: String, vocabulary: [String]) throws -> URLRequest {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.apiModel):generateContent")!
        let level = geminiThinkingLevel(model.apiModel)
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": FormatterPrompt.system]]],
            "contents": [["role": "user", "parts": [["text": userMessage(text: text, vocabulary: vocabulary)]]]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": level]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func anthropic(model: ModelEntry, apiKey: String, text: String, vocabulary: [String],
                          includeThinkingField: Bool = true) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model.apiModel,
            "max_tokens": maxTokens(forInput: text),
            "system": FormatterPrompt.system,
            "messages": [["role": "user", "content": userMessage(text: text, vocabulary: vocabulary)]],
        ]
        // Thinking is on by default on 5.x and costs seconds, and sampling params are
        // refused, so none are sent. Haiku accepts "disabled"; Sonnet 5.5 rejects it,
        // and "between_tools" (no tools are sent) skips the up-front thinking.
        if includeThinkingField {
            body["thinking"] = ["type": model.apiModel == "claude-sonnet-5-5" ? "between_tools" : "disabled"]
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// What a reply held: usable text, or the reason it can't be used.
    enum Reply: Equatable {
        case text(String)
        case failure(String)
    }

    /// Joined non-thought parts of the first candidate. A reply that stopped for any
    /// reason but STOP (cut short, blocked) is a failure: a truncated answer must
    /// never replace the dictation.
    static func parseGemini(_ data: Data) -> Reply {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String?; let thought: Bool? }
                    let parts: [Part]?
                }
                let content: Content?
                let finishReason: String?
            }
            struct Feedback: Decodable { let blockReason: String? }
            let candidates: [Candidate]?
            let promptFeedback: Feedback?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return .failure("unreadable response")
        }
        if decoded.promptFeedback?.blockReason != nil { return .failure("blocked") }
        guard let candidate = decoded.candidates?.first else { return .failure("empty response") }
        if candidate.finishReason != "STOP" {
            switch candidate.finishReason {
            case nil: return .failure("truncated")
            case "MAX_TOKENS": return .failure("truncated")
            case "SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "RECITATION", "IMAGE_SAFETY":
                return .failure("blocked")
            default: return .failure("stopped early")
            }
        }
        let text = (candidate.content?.parts ?? []).filter { $0.thought != true }.compactMap(\.text).joined()
        return text.isEmpty ? .failure("empty response") : .text(text)
    }

    /// Joined `text` blocks; never assumes `content[0]` is text. Anything but
    /// `end_turn` (a `max_tokens` cut, a refusal) is a failure.
    static func parseAnthropic(_ data: Data) -> Reply {
        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]?
            let stop_reason: String?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let blocks = decoded.content else { return .failure("unreadable response") }
        if decoded.stop_reason != "end_turn" {
            switch decoded.stop_reason {
            case nil: return .failure("truncated")
            case "max_tokens": return .failure("truncated")
            case "refusal": return .failure("blocked")
            default: return .failure("stopped early")
            }
        }
        let text = blocks.filter { $0.type == "text" }.compactMap(\.text).joined()
        return text.isEmpty ? .failure("empty response") : .text(text)
    }
}

/// The result of one formatting attempt. Anything but `.formatted` means the
/// unformatted transcript is delivered.
public enum FormatterOutcome: Equatable, Sendable {
    case formatted(String)
    /// Not attempted (too short, no key).
    case skipped(String)
    /// Attempted and unusable: error, timeout, guard reject.
    case failed(String)

    public var text: String? {
        if case .formatted(let text) = self { return text }
        return nil
    }
}

/// Runs the AI formatting step: one request to the chosen language model under a
/// deadline, then the guard. Never throws; the dictation is never lost.
public struct AIFormatter: Sendable {
    public let model: ModelEntry
    private let apiKey: @Sendable () -> String?
    private let session: URLSession
    private let diagnostics: Diagnostics

    public init(model: ModelEntry,
                apiKey: @escaping @Sendable () -> String?,
                session: URLSession = .shared,
                diagnostics: Diagnostics = .shared) {
        self.model = model
        self.apiKey = apiKey
        self.session = session
        self.diagnostics = diagnostics
    }

    /// Dictations under this many words are left alone.
    public static let minimumWords = 3
    /// Scripts written without spaces between words count characters instead.
    public static let minimumUnspacedCharacters = 6

    public static func shouldFormat(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.unicodeScalars.contains(where: Self.isUnspacedScript) {
            // Code points, not whitespace.
            return trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }.count >= minimumUnspacedCharacters
        }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).count >= minimumWords
    }

    /// Han, Hiragana, Katakana, Thai, Lao, Khmer and Myanmar. Not Hangul: Korean is
    /// written with spaces, so words apply.
    static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,          // kana, extensions, halfwidth
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, // Han
             0x0E00...0x0E7F, 0x0E80...0x0EFF,                           // Thai, Lao
             0x1000...0x109F, 0xA9E0...0xA9FF, 0xAA60...0xAA7F,          // Myanmar, Extended-B, Extended-A
             0x1780...0x17FF, 0x19E0...0x19FF:                           // Khmer, Khmer Symbols
            return true
        default:
            return false
        }
    }

    /// Formats `text`. Cancelling the calling task cancels the request.
    public func format(_ text: String, vocabulary: [String]) async -> FormatterOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.shouldFormat(trimmed) else { return .skipped("short transcript") }
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return log(.skipped("no \(model.providerName) key"))
        }
        let timedOut = DeadlineFlag()
        do {
            let output = try await withDeadline(seconds: FormatterRequest.deadline(for: model),
                                                timedOut: timedOut) {
                try await self.run(text: trimmed, vocabulary: vocabulary, key: key)
            }
            guard let accepted = FormatterGuard.accept(input: trimmed, output: output) else {
                return log(.failed("output rejected by the guard"))
            }
            return .formatted(accepted)
        } catch where timedOut.isSet {
            // The deadline fired: logged, unlike a cancel the person asked for.
            return log(.failed("timeout"))
        } catch is CancellationError {
            return .failed("cancelled")
        } catch let error as FormatterError {
            return log(.failed(error.reason))
        } catch let failure as HTTPFailure {
            return log(.failed("HTTP \(failure.status)"))
        } catch let urlError as URLError {
            return log(.failed(urlError.code == .cancelled ? "cancelled"
                               : urlError.code == .timedOut ? "timeout" : "network error \(urlError.code.rawValue)"))
        } catch {
            return log(.failed("unexpected error"))
        }
    }

    private func log(_ outcome: FormatterOutcome) -> FormatterOutcome {
        switch outcome {
        case .skipped(let reason), .failed(let reason):
            if reason != "short transcript", reason != "cancelled" {
                // Provider, model and a fixed reason only: a response body can echo the dictation.
                diagnostics.warning("formatter", "\(model.provider) \(model.apiModel): \(reason); delivered the unformatted text")
            }
        case .formatted: break
        }
        return outcome
    }

    struct FormatterError: Error { let reason: String }

    private func run(text: String, vocabulary: [String], key: String) async throws -> String {
        switch model.provider {
        case "gemini":
            let request = try FormatterRequest.gemini(model: model, apiKey: key, text: text, vocabulary: vocabulary)
            let data = try await send(request)
            return try Self.unwrap(FormatterRequest.parseGemini(data))
        case "anthropic":
            var request = try FormatterRequest.anthropic(model: model, apiKey: key, text: text, vocabulary: vocabulary)
            do {
                let data = try await send(request)
                return try Self.unwrap(FormatterRequest.parseAnthropic(data))
            } catch let error as HTTPFailure where error.status == 400 && error.body.lowercased().contains("thinking") {
                // The model rejected the thinking field: once more without it.
                request = try FormatterRequest.anthropic(model: model, apiKey: key, text: text,
                                                         vocabulary: vocabulary, includeThinkingField: false)
                let data = try await send(request)
                return try Self.unwrap(FormatterRequest.parseAnthropic(data))
            } catch let error as HTTPFailure {
                throw FormatterError(reason: "HTTP \(error.status)")
            }
        default:
            throw FormatterError(reason: "unknown provider")
        }
    }

    private static func unwrap(_ reply: FormatterRequest.Reply) throws -> String {
        switch reply {
        case .text(let text): return text
        case .failure(let reason): throw FormatterError(reason: reason)
        }
    }

    struct HTTPFailure: Error { let status: Int; let body: String }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FormatterError(reason: "bad response") }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPFailure(status: http.statusCode, body: String(decoding: data.prefix(2000), as: UTF8.self))
        }
        return data
    }

    /// A wall-clock deadline that also passes the caller's cancellation down.
    private func withDeadline<T: Sendable>(seconds: TimeInterval, timedOut: DeadlineFlag,
                                           _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task<T, Error> { try await work() }
        let timer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            timedOut.set()
            task.cancel()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Set when the deadline (not the person) ended the request.
final class DeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
