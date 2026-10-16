import Foundation
import llama

/// A thin, synchronous wrapper over llama.cpp (the official XCFramework) for one job: run a
/// small instruction-tuned model greedily over a fully rendered prompt and return the text.
///
/// This target imports `llama` and nothing else (not even `whisper`): both frameworks bundle
/// their own copy of ggml, and keeping them in different Swift modules means the two header
/// sets are never visible in one place. The app links both dynamic frameworks into one
/// process; `LlamaWhisperCoexistenceTests` is the proof.
///
/// Not thread safe: callers serialise access (the app's `LocalCleanupModel` is an actor).
public final class LlamaRuntime: @unchecked Sendable {
    public enum RuntimeError: Error, Equatable, CustomStringConvertible {
        case modelLoadFailed(String)
        case contextFailed
        case tokenizeFailed
        case promptTooLong(tokens: Int, limit: Int)
        case decodeFailed(Int32)
        case deadlineExceeded
        /// The output filled the room reserved for it without the model ending its turn.
        /// A cut-off answer is never returned: it would drop words.
        case outputTruncated

        public var description: String {
            switch self {
            case .modelLoadFailed(let why): return "model load failed: \(why)"
            case .contextFailed: return "could not create a context"
            case .tokenizeFailed: return "could not tokenize the prompt"
            case .promptTooLong(let n, let limit): return "prompt of \(n) tokens is over the limit of \(limit)"
            case .decodeFailed(let code): return "decode failed (\(code))"
            case .deadlineExceeded: return "deadline exceeded"
            case .outputTruncated: return "output truncated"
            }
        }
    }

    public struct Stats: Equatable, Sendable {
        public var promptTokens: Int
        public var outputTokens: Int
        public var contextSize: Int
        /// Context creation plus prompt processing, up to the first generated token.
        public var prefillSeconds: Double
        public var totalSeconds: Double
    }

    public struct Completion: Equatable, Sendable {
        public var text: String
        public var stats: Stats
    }

    /// llama.cpp's backend init is process-wide and idempotent in practice, but it is only
    /// ever called once from here. The log callback silences llama.cpp's stderr chatter.
    private static let backendReady: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    /// What llama.cpp reports about its CPU and GPU features. Calling it is the cheapest proof
    /// the framework linked and initialised.
    public static func systemInfo() -> String {
        _ = backendReady
        return String(cString: llama_print_system_info())
    }

    public static func version() -> String {
        String(cString: llama_version())
    }

    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let threads: Int32
    public var threadCount: Int32 { threads }
    public let gpuLayers: Int32
    public let modelPath: String

    /// Loads the weights. `gpuLayers` is 0 for the CPU only; a negative number offloads every
    /// layer to Metal. The CPU is the default for the cleanup model: see the PR notes for the
    /// measurements, and note that llama.cpp can only stop a running decode on the CPU.
    public init(modelPath: String, gpuLayers: Int32 = 0) throws {
        _ = Self.backendReady
        var params = llama_model_default_params()
        params.n_gpu_layers = gpuLayers
        guard let loaded = modelPath.withCString({ llama_model_load_from_file($0, params) }) else {
            throw RuntimeError.modelLoadFailed("llama.cpp could not load \((modelPath as NSString).lastPathComponent)")
        }
        guard let vocab = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            throw RuntimeError.modelLoadFailed("the model has no vocabulary")
        }
        self.model = loaded
        self.vocab = vocab
        self.gpuLayers = gpuLayers
        self.modelPath = modelPath
        self.threads = Self.defaultThreadCount()
    }

    deinit {
        llama_model_free(model)
    }

    /// Performance cores only: efficiency cores slow a small model down when the work is
    /// split evenly across all of them.
    static func defaultThreadCount() -> Int32 {
        var perf: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &perf, &size, nil, 0) != 0 || perf < 1 {
            perf = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        }
        return min(max(perf, 1), 8)
    }

    /// Runs `prompt` greedily to the end of the model's turn.
    ///
    /// There is no cap on output tokens. The context is sized from the prompt (room for an
    /// answer up to 1.5 times its length plus 64 tokens), so a short dictation costs a small
    /// KV cache, and an answer that fills that room without ending is an error, not a
    /// result. `deadline` is checked between tokens and, on the CPU, inside a running decode.
    public func complete(
        prompt: String, deadline: ContinuousClock.Instant, maxPromptTokens: Int = 1536
    ) throws -> Completion {
        let start = ContinuousClock.now
        var tokens = try tokenize(prompt)
        guard tokens.count <= maxPromptTokens else {
            throw RuntimeError.promptTooLong(tokens: tokens.count, limit: maxPromptTokens)
        }
        let promptTokens = tokens.count
        let outputRoom = promptTokens + promptTokens / 2 + 64
        let contextSize = ((promptTokens + outputRoom + 255) / 256) * 256

        let abortBox = AbortBox(deadline: deadline)
        let abortUnmanaged = Unmanaged.passRetained(abortBox)
        defer { abortUnmanaged.release() }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextSize)
        cparams.n_batch = UInt32(contextSize)
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        cparams.no_perf = true
        cparams.abort_callback = { data in
            guard let data else { return false }
            return ContinuousClock.now >= Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue().deadline
        }
        cparams.abort_callback_data = abortUnmanaged.toOpaque()
        guard let ctx = llama_init_from_model(model, cparams) else { throw RuntimeError.contextFailed }
        defer { llama_free(ctx) }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var output: [UInt8] = []
        var produced = 0
        var finished = false
        var firstTokenAt: ContinuousClock.Instant?
        var pending = tokens
        while true {
            if ContinuousClock.now >= deadline { throw RuntimeError.deadlineExceeded }
            let status = pending.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
            }
            if status != 0 {
                if ContinuousClock.now >= deadline { throw RuntimeError.deadlineExceeded }
                throw RuntimeError.decodeFailed(status)
            }
            let next = llama_sampler_sample(sampler, ctx, -1)
            if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
            if llama_vocab_is_eog(vocab, next) { finished = true; break }
            output.append(contentsOf: piece(for: next))
            produced += 1
            if produced >= outputRoom { break }
            pending = [next]
        }
        guard finished else { throw RuntimeError.outputTruncated }
        tokens.removeAll()

        let end = ContinuousClock.now
        return Completion(
            text: String(decoding: output, as: UTF8.self),
            stats: Stats(
                promptTokens: promptTokens, outputTokens: produced, contextSize: contextSize,
                prefillSeconds: Self.seconds(start.duration(to: firstTokenAt ?? end)),
                totalSeconds: Self.seconds(start.duration(to: end))))
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var capacity = byteCount + 16
        for _ in 0..<2 {
            var tokens = [llama_token](repeating: 0, count: Int(capacity))
            let n = text.withCString { llama_tokenize(vocab, $0, byteCount, &tokens, capacity, false, true) }
            if n >= 0 {
                tokens.removeLast(tokens.count - Int(n))
                return tokens
            }
            if n == Int32.min { break }
            capacity = -n
        }
        throw RuntimeError.tokenizeFailed
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard n > 0 else { return [] }
        return buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

private final class AbortBox {
    let deadline: ContinuousClock.Instant
    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }
}
