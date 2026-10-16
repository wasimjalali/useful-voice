import Darwin
import Foundation
import MachO
import Testing
import UsefulVoiceCore
import UsefulVoiceLlama
@testable import UsefulVoiceApp

/// whisper.framework and llama.framework each bundle their own ggml. These tests prove that
/// both load into one process, that llama.cpp can run S1-mini next to a loaded whisper.cpp
/// context, and record what that costs on the runner. The model tests need the real weights:
/// CI downloads them and sets `UV_S1_MINI_PATH` (the pinned S1-mini GGUF) and
/// `UV_WHISPER_TINY_PATH` (ggml-tiny.en.bin); without them those tests are skipped, not passed.
private func modelPath(_ key: String) -> String? {
    guard let path = ProcessInfo.processInfo.environment[key],
          FileManager.default.fileExists(atPath: path) else { return nil }
    return path
}

private func loadedImages() -> [String] {
    (0..<_dyld_image_count()).compactMap { i in _dyld_get_image_name(i).map { String(cString: $0) } }
}

/// Resident and physical footprint of this process, in MB.
private func memoryMB() -> (resident: Double, footprint: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
}

private func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

struct LlamaWhisperLinkTests {
    @Test func bothFrameworksLoadInOneProcess() {
        let whisperInfo = WhisperRuntimeInfo.systemInfo()
        let llamaInfo = LlamaRuntime.systemInfo()
        print("COEXIST whisper system info: \(whisperInfo)")
        print("COEXIST llama \(LlamaRuntime.version()) system info: \(llamaInfo)")
        #expect(!whisperInfo.isEmpty)
        #expect(!llamaInfo.isEmpty)
        let images = loadedImages()
        let whisper = images.filter { $0.contains("/whisper.framework/") }
        let llama = images.filter { $0.contains("/llama.framework/") }
        print("COEXIST images: \(whisper) \(llama)")
        #expect(whisper.count == 1)
        #expect(llama.count == 1)
    }
}

@Suite("S1-mini next to whisper.cpp (needs the real weights)", .serialized,
       .enabled(if: modelPath("UV_S1_MINI_PATH") != nil && modelPath("UV_WHISPER_TINY_PATH") != nil))
struct LlamaWhisperCoexistenceTests {
    private let s1 = modelPath("UV_S1_MINI_PATH") ?? ""
    private let tiny = modelPath("UV_WHISPER_TINY_PATH") ?? ""
    private let control = "[Styling: semi-formal] [Structure: prose] [Context: general]"
    private let cardInput = "so um i need to like send the the report by uh friday no wait make that thursday"

    private func prompt(_ text: String) -> String {
        S1MiniModel.prompt(controlLine: control, text: text)
    }

    @Test(.timeLimit(.minutes(5)))
    func s1MiniRunsBetweenTwoWhisperContexts() throws {
        #expect(WhisperRuntimeInfo.canLoad(modelAt: URL(fileURLWithPath: tiny), useGPU: true))
        let runtime = try LlamaRuntime(modelPath: s1)
        let result = try runtime.complete(prompt: prompt(cardInput), deadline: .now.advanced(by: .seconds(60)))
        print("COEXIST model card example -> \(result.text.debugDescription) \(result.stats)")
        // The card shows "I need to send the report by Thursday."; llama-server at the same
        // revision keeps the leading "So". Either way the correction is resolved.
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text.hasSuffix("need to send the report by Thursday."))
        #expect(!text.lowercased().contains("friday"))
        // whisper.cpp still works after llama.cpp loaded and ran, on the CPU and on Metal.
        #expect(WhisperRuntimeInfo.canLoad(modelAt: URL(fileURLWithPath: tiny), useGPU: false))
        #expect(WhisperRuntimeInfo.canLoad(modelAt: URL(fileURLWithPath: tiny), useGPU: true))
        let again = try runtime.complete(prompt: prompt(cardInput), deadline: .now.advanced(by: .seconds(60)))
        #expect(again.text == result.text)
    }

    @Test(.timeLimit(.minutes(5)))
    func aPassedDeadlineStopsTheRun() throws {
        let runtime = try LlamaRuntime(modelPath: s1)
        #expect(throws: LlamaRuntime.RuntimeError.deadlineExceeded) {
            try runtime.complete(prompt: prompt(cardInput), deadline: .now.advanced(by: .milliseconds(-1)))
        }
        // 5 ms is shorter than any real run: the abort fires inside the decode or between tokens.
        let started = ContinuousClock.now
        #expect(throws: LlamaRuntime.RuntimeError.deadlineExceeded) {
            try runtime.complete(prompt: prompt(cardInput), deadline: .now.advanced(by: .milliseconds(5)))
        }
        let took = ms(started.duration(to: .now))
        print("COEXIST 5 ms deadline stopped the run after \(took) ms")
        #expect(took < 1000)
        // The runtime is still usable afterwards.
        let ok = try runtime.complete(prompt: prompt(cardInput), deadline: .now.advanced(by: .seconds(60)))
        #expect(!ok.text.isEmpty)
    }

    @Test(.timeLimit(.minutes(5)))
    func pipelineWithTheRealModel() async throws {
        let generator = LlamaCleanupGenerator()
        let model = LocalCleanupModel(modelURL: URL(fileURLWithPath: s1), generator: generator, idleUnloadAfter: .seconds(60))
        await model.begin()
        #expect(await model.isLoaded)
        let gates = CleanupPipeline.Gates(flagOn: true, modelInstalled: true, physicalMemoryBytes: 16 << 30)
        let result = await CleanupPipeline.run(
            raw: cardInput, language: "en", category: nil, style: nil,
            gates: gates, model: model, deadline: .seconds(20))
        print("COEXIST pipeline -> \(result)")
        #expect(result.model != nil)
        let off = await CleanupPipeline.run(
            raw: cardInput, language: "en", category: nil, style: nil,
            gates: .init(flagOn: false, modelInstalled: true, physicalMemoryBytes: 16 << 30),
            model: model)
        #expect(off.model == .skipped(.flagOff))
        await model.unload()
        #expect(await !model.isLoaded)
    }

    /// Not an assertion test: the numbers the PR quotes. CPU first, then Metal (which may not
    /// start on a virtual runner). Resident memory is the whole test process, with whisper's
    /// tiny model loaded too in the "with whisper" rows.
    @Test(.timeLimit(.minutes(10)))
    func measure() throws {
        let sentences = [
            cardInput,
            "send it to john dot smith at example dot com by friday the third",
            "the meeting is at two thirty p m on march fifteenth no wait march sixteenth",
            "um so the budget is forty two thousand dollars actually forty five thousand and we need to confirm with sarah",
            "can you open the file source slash app dot ts and rename the function get user to fetch user",
        ]
        print("MEASURE baseline \(memoryMB())")
        for (label, layers) in [("cpu", Int32(0)), ("metal", Int32(-1))] {
            do {
                let t0 = ContinuousClock.now
                let runtime = try LlamaRuntime(modelPath: s1, gpuLayers: layers)
                let loadMs = ms(t0.duration(to: .now))
                print("MEASURE \(label) load \(loadMs) ms mem \(memoryMB())")
                var times: [Double] = []
                for s in sentences + sentences {
                    let t = ContinuousClock.now
                    let r = try runtime.complete(prompt: prompt(s), deadline: .now.advanced(by: .seconds(120)))
                    let took = ms(t.duration(to: .now))
                    times.append(took)
                    print("MEASURE \(label) run \(took) ms prompt \(r.stats.promptTokens) out \(r.stats.outputTokens) ctx \(r.stats.contextSize) prefill \(r.stats.prefillSeconds * 1000) ms -> \(r.text.debugDescription)")
                }
                let sorted = times.sorted()
                print("MEASURE \(label) median \(sorted[sorted.count / 2]) ms max \(sorted.last ?? 0) ms mem after \(memoryMB())")
                let tw = ContinuousClock.now
                let ok = WhisperRuntimeInfo.canLoad(modelAt: URL(fileURLWithPath: tiny), useGPU: label == "metal")
                print("MEASURE \(label) with whisper tiny loadable=\(ok) in \(ms(tw.duration(to: .now))) ms mem \(memoryMB())")
            } catch {
                print("MEASURE \(label) failed: \(error)")
                if label == "cpu" { throw error }
            }
            print("MEASURE after \(label) unload \(memoryMB())")
        }
    }
}
