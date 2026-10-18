import Foundation

/// Checks a model's formatted text before it replaces the transcript. Pure.
public enum FormatterGuard {
    static let preambles = ["here is", "here's", "sure", "certainly", "i've", "i have", "of course"]

    /// The text to use, or nil when the output can't be trusted (the transcript is
    /// delivered unformatted instead).
    ///
    /// Trims, strips one wrapping code fence and one wrapping `<dictation>` tag,
    /// then rejects: empty output, output over twice the input plus 40 characters,
    /// output under 0.4x an input of 20 or more characters, and an assistant
    /// preamble the dictation itself didn't start with.
    public static func accept(input: String, output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripFence(text)
        text = stripDictationTag(text)
        guard !text.isEmpty else { return nil }

        let inputLength = input.trimmingCharacters(in: .whitespacesAndNewlines).count
        if text.count > inputLength * 2 + 40 { return nil }
        if inputLength >= 20, Double(text.count) < Double(inputLength) * 0.4 { return nil }

        let lowered = text.lowercased()
        let inputLowered = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for preamble in preambles where lowered.hasPrefix(preamble) {
            // A dictation that really starts that way ("Sure, send it") is not a preamble.
            if !inputLowered.hasPrefix(preamble) { return nil }
        }
        return text
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
        model.apiModel == "claude-sonnet-4-6" ? 10 : 6
    }

    public static func maxTokens(forInput text: String) -> Int {
        min(4096, max(256, text.utf16.count))
    }

    /// 3.8 Flash rejects `minimal`, so its lowest level is `low`.
    static func geminiThinkingLevel(_ apiModel: String) -> String {
        apiModel == "gemini-3.8-flash" ? "low" : "minimal"
    }

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
        switch model.apiModel {
        case "claude-haiku-5-5":
            // Thinking is on by default on 5.x and costs seconds; sampling params are refused.
            if includeThinkingField { body["thinking"] = ["type": "disabled"] }
        default:
            body["temperature"] = 0
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Joined non-thought parts of the first candidate.
    static func parseGemini(_ data: Data) -> String? {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String?; let thought: Bool? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let parts = decoded.candidates?.first?.content?.parts else { return nil }
        let text = parts.filter { $0.thought != true }.compactMap(\.text).joined()
        return text.isEmpty ? nil : text
    }

    /// Joined `text` blocks; never assumes `content[0]` is text.
    static func parseAnthropic(_ data: Data) -> String? {
        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let blocks = decoded.content else { return nil }
        let text = blocks.filter { $0.type == "text" }.compactMap(\.text).joined()
        return text.isEmpty ? nil : text
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

    /// Transcripts of this many words or fewer are left alone.
    public static let minimumWords = 3

    public static func shouldFormat(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).count >= minimumWords
    }

    /// Formats `text`. Cancelling the calling task cancels the request.
    public func format(_ text: String, vocabulary: [String]) async -> FormatterOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.shouldFormat(trimmed) else { return .skipped("short transcript") }
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return log(.skipped("no \(model.providerName) key"))
        }
        do {
            let output = try await withDeadline(seconds: FormatterRequest.deadline(for: model)) {
                try await self.run(text: trimmed, vocabulary: vocabulary, key: key)
            }
            guard let accepted = FormatterGuard.accept(input: trimmed, output: output) else {
                return log(.failed("output rejected by the guard"))
            }
            return .formatted(accepted)
        } catch is CancellationError {
            return .failed("cancelled")
        } catch let error as FormatterError {
            return log(.failed(error.reason))
        } catch let urlError as URLError {
            return log(.failed(urlError.code == .cancelled ? "cancelled"
                               : urlError.code == .timedOut ? "timed out" : "network error \(urlError.code.rawValue)"))
        } catch {
            return log(.failed("unexpected error"))
        }
    }

    private func log(_ outcome: FormatterOutcome) -> FormatterOutcome {
        switch outcome {
        case .skipped(let reason), .failed(let reason):
            if reason != "short transcript", reason != "cancelled" {
                diagnostics.warning("formatter", "\(model.apiModel): \(reason); delivered the unformatted text")
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
            guard let output = FormatterRequest.parseGemini(data) else { throw FormatterError(reason: "empty response") }
            return output
        case "anthropic":
            var request = try FormatterRequest.anthropic(model: model, apiKey: key, text: text, vocabulary: vocabulary)
            do {
                let data = try await send(request)
                guard let output = FormatterRequest.parseAnthropic(data) else { throw FormatterError(reason: "empty response") }
                return output
            } catch let error as HTTPFailure where error.status == 400 && error.body.lowercased().contains("thinking") {
                // The model rejected the thinking field: once more without it.
                request = try FormatterRequest.anthropic(model: model, apiKey: key, text: text,
                                                         vocabulary: vocabulary, includeThinkingField: false)
                let data = try await send(request)
                guard let output = FormatterRequest.parseAnthropic(data) else { throw FormatterError(reason: "empty response") }
                return output
            } catch let error as HTTPFailure {
                throw FormatterError(reason: "HTTP \(error.status)")
            }
        default:
            throw FormatterError(reason: "unknown provider")
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
    private func withDeadline<T: Sendable>(seconds: TimeInterval,
                                           _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task<T, Error> { try await work() }
        let timer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
