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
        /// `StopSignal` was set (the app is quitting).
        case stopped

        public var description: String {
            switch self {
            case .modelLoadFailed(let why): return "model load failed: \(why)"
            case .contextFailed: return "could not create a context"
            case .tokenizeFailed: return "could not tokenize the prompt"
            case .promptTooLong(let n, let limit): return "prompt of \(n) tokens is over the limit of \(limit)"
            case .decodeFailed(let code): return "decode failed (\(code))"
            case .deadlineExceeded: return "deadline exceeded"
            case .outputTruncated: return "output truncated"
            case .stopped: return "stopped"
            }
        }
    }

    /// Set from any thread to stop a model load (llama.cpp's progress callback answers false)
    /// or a running decode (its abort callback answers true) as soon as llama.cpp next asks.
    /// Used at quit, so the process does not exit with a thread inside llama.cpp. Once set it
    /// stays set.
    public final class StopSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        public init() {}
        public var isSet: Bool { lock.withLock { stopped } }
        public func set() { lock.withLock { stopped = true } }
    }

    public struct Stats: Equatable, Sendable {
        public var promptTokens: Int
        public var outputTokens: Int
        public var contextSize: Int
        /// Context creation plus prompt processing, up to the first generated token.
        public var prefillSeconds: Double
        public var totalSeconds: Double
        /// Of `prefillSeconds`: building the context (KV cache, compute buffers).
        public var contextSeconds: Double
        /// Of `prefillSeconds`: the decode of the whole prompt.
        public var promptDecodeSeconds: Double
        /// llama.cpp's own timers for the prompt and for the generated tokens, in ms.
        public var nativePromptMs: Double
        public var nativeGenerateMs: Double
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

    /// Where the model runs.
    public enum Placement: String, Sendable, CaseIterable {
        /// Only the CPU backend (plus Accelerate for big matmuls): no device list, no GPU
        /// offload of weights, cache or operations. The default for the cleanup model.
        case cpuOnly
        /// Weights on the CPU, but every device left in the list. llama.cpp may still send
        /// large matmuls to the GPU ("op offload"). Kept for measurement.
        case cpuWithDevices
        /// Every layer on Metal.
        case metal
    }

    /// Measurement only: run without the deadline abort callback to see what it costs.
    public static var debugDisableAbortCallback = false

    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let threads: Int32
    private let microBatch: UInt32?
    public var threadCount: Int32 { threads }
    public let placement: Placement
    public let modelPath: String
    private let stop: StopSignal?

    /// Loads the weights. See `Placement`; the CPU is the default for the cleanup model, and
    /// llama.cpp can only stop a running decode on the CPU. The PR notes have the numbers.
    public init(modelPath: String, placement: Placement = .cpuOnly, threads: Int32? = nil, microBatch: UInt32? = nil, stop: StopSignal? = nil) throws {
        _ = Self.backendReady
        var params = llama_model_default_params()
        params.n_gpu_layers = placement == .metal ? -1 : 0
        if let stop {
            // Returning false makes llama.cpp abandon the load at once. The signal outlives the
            // load: this initialiser holds it until `llama_model_load_from_file` returns.
            params.progress_callback = { _, data in
                guard let data else { return true }
                return !Unmanaged<StopSignal>.fromOpaque(data).takeUnretainedValue().isSet
            }
            params.progress_callback_user_data = Unmanaged.passUnretained(stop).toOpaque()
        }
        // A list that ends at once is "no devices"; NULL would mean "all of them".
        var noDevices: [ggml_backend_dev_t?] = [nil]
        let loadedModel: OpaquePointer? = noDevices.withUnsafeMutableBufferPointer { list in
            if placement == .cpuOnly { params.devices = list.baseAddress }
            return modelPath.withCString { llama_model_load_from_file($0, params) }
        }
        guard let loaded = loadedModel else {
            if stop?.isSet == true { throw RuntimeError.stopped }
            throw RuntimeError.modelLoadFailed("llama.cpp could not load \((modelPath as NSString).lastPathComponent)")
        }
        guard let vocab = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            throw RuntimeError.modelLoadFailed("the model has no vocabulary")
        }
        self.model = loaded
        self.vocab = vocab
        self.placement = placement
        self.modelPath = modelPath
        self.threads = threads ?? Self.defaultThreadCount()
        self.microBatch = microBatch
        self.stop = stop
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
        try complete(segments: [PromptSegment(text: prompt, parseSpecial: true)], deadline: deadline, maxPromptTokens: maxPromptTokens)
    }

    /// A piece of the prompt and whether its text may contain the model's control tokens
    /// (`<|im_start|>` and the like). The person's own words are never parsed for them.
    public struct PromptSegment: Equatable, Sendable {
        public var text: String
        public var parseSpecial: Bool

        public init(text: String, parseSpecial: Bool) {
            self.text = text
            self.parseSpecial = parseSpecial
        }
    }

    /// Like `complete(prompt:)`, with each segment tokenized on its own and the tokens joined.
    public func complete(
        segments: [PromptSegment], deadline: ContinuousClock.Instant, maxPromptTokens: Int = 1536
    ) throws -> Completion {
        let start = ContinuousClock.now
        var tokens = try tokenize(segments: segments)
        guard tokens.count <= maxPromptTokens else {
            throw RuntimeError.promptTooLong(tokens: tokens.count, limit: maxPromptTokens)
        }
        let promptTokens = tokens.count
        let outputRoom = promptTokens + promptTokens / 2 + 64
        let contextSize = ((promptTokens + outputRoom + 255) / 256) * 256

        let abortBox = AbortBox(deadline: deadline, stop: stop)
        let abortUnmanaged = Unmanaged.passRetained(abortBox)
        defer { abortUnmanaged.release() }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextSize)
        cparams.n_batch = UInt32(contextSize)
        if let microBatch { cparams.n_ubatch = microBatch }
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        cparams.no_perf = false
        if placement == .cpuOnly {
            cparams.offload_kqv = false
            cparams.op_offload = false
        }
        if !Self.debugDisableAbortCallback {
            cparams.abort_callback = { data in
                guard let data else { return false }
                let box = Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue()
                return ContinuousClock.now >= box.deadline || box.stop?.isSet == true
            }
            cparams.abort_callback_data = abortUnmanaged.toOpaque()
        }
        let contextStart = ContinuousClock.now
        guard let ctx = llama_init_from_model(model, cparams) else { throw RuntimeError.contextFailed }
        defer { llama_free(ctx) }
        let contextEnd = ContinuousClock.now
        var promptDecodedAt: ContinuousClock.Instant?

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var output: [UInt8] = []
        var produced = 0
        var finished = false
        var firstTokenAt: ContinuousClock.Instant?
        var pending = tokens
        while true {
            if stop?.isSet == true { throw RuntimeError.stopped }
            if ContinuousClock.now >= deadline { throw RuntimeError.deadlineExceeded }
            let status = pending.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
            }
            if status != 0 {
                if stop?.isSet == true { throw RuntimeError.stopped }
                if ContinuousClock.now >= deadline { throw RuntimeError.deadlineExceeded }
                throw RuntimeError.decodeFailed(status)
            }
            if promptDecodedAt == nil { promptDecodedAt = ContinuousClock.now }
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
        let perf = llama_perf_context(ctx)
        return Completion(
            text: String(decoding: output, as: UTF8.self),
            stats: Stats(
                promptTokens: promptTokens, outputTokens: produced, contextSize: contextSize,
                prefillSeconds: Self.seconds(start.duration(to: firstTokenAt ?? end)),
                totalSeconds: Self.seconds(start.duration(to: end)),
                contextSeconds: Self.seconds(contextStart.duration(to: contextEnd)),
                promptDecodeSeconds: Self.seconds(contextEnd.duration(to: promptDecodedAt ?? end)),
                nativePromptMs: perf.t_p_eval_ms,
                nativeGenerateMs: perf.t_eval_ms))
    }

    /// Measurement only: one context, no abort callback, the prompt decoded `repeats` times with
    /// the cache cleared between, then `steps` single-token decodes. Returns milliseconds per call.
    public func probe(prompt: String, repeats: Int, steps: Int) throws -> [String] {
        var tokens = try tokenize(prompt)
        var cparams = llama_context_default_params()
        cparams.n_ctx = 512
        cparams.n_batch = 512
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        if placement == .cpuOnly { cparams.offload_kqv = false; cparams.op_offload = false }
        let t0 = ContinuousClock.now
        guard let ctx = llama_init_from_model(model, cparams) else { throw RuntimeError.contextFailed }
        defer { llama_free(ctx) }
        var lines = ["context \(Self.seconds(t0.duration(to: .now)) * 1000) ms, prompt \(tokens.count) tokens"]
        for r in 0..<repeats {
            llama_memory_clear(llama_get_memory(ctx), true)
            let t = ContinuousClock.now
            let status = tokens.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            lines.append("prompt decode #\(r) status \(status) \(Self.seconds(t.duration(to: .now)) * 1000) ms")
        }
        var one: [llama_token] = [tokens.last ?? 0]
        var gen: [Double] = []
        for _ in 0..<steps {
            let t = ContinuousClock.now
            _ = one.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, 1)) }
            gen.append(Self.seconds(t.duration(to: .now)) * 1000)
        }
        lines.append("single-token decodes ms \(gen.map { String(format: "%.0f", $0) }.joined(separator: " "))")
        return lines
    }

    /// The tokens of the segments, each tokenized on its own and joined.
    public func tokenize(segments: [PromptSegment]) throws -> [Int32] {
        var tokens: [llama_token] = []
        for segment in segments { tokens += try tokenize(segment.text, parseSpecial: segment.parseSpecial) }
        return tokens
    }

    private func tokenize(_ text: String, parseSpecial: Bool = true) throws -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var capacity = byteCount + 16
        for _ in 0..<2 {
            var tokens = [llama_token](repeating: 0, count: Int(capacity))
            let n = text.withCString { llama_tokenize(vocab, $0, byteCount, &tokens, capacity, false, parseSpecial) }
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
    let stop: LlamaRuntime.StopSignal?
    init(deadline: ContinuousClock.Instant, stop: LlamaRuntime.StopSignal?) {
        self.deadline = deadline
        self.stop = stop
    }
}
