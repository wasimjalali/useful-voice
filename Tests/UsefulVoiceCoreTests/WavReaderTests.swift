import Foundation
import Testing
@testable import UsefulVoiceCore

@Suite("WAV reading for local transcription")
struct WavReaderTests {
    private func makeWav(samples: [Int16], sampleRate: Int = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-reader-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: url, sampleRate: sampleRate)
        try writer.append(samples: samples)
        try writer.finish()
        return url
    }

    @Test func roundTripsInt16ToNormalizedFloat() throws {
        let pcm: [Int16] = [0, 32767, -32768, 16384, -16384]
        let url = try makeWav(samples: pcm)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try WavReader.readFloatSamples(from: url)
        #expect(samples.count == pcm.count)
        #expect(abs(samples[0] - 0) < 0.0001)
        #expect(abs(samples[1] - 1.0) < 0.0001)
        #expect(abs(samples[2] - -1.0) < 0.0001)
        #expect(abs(samples[3] - 0.5) < 0.0001)
    }

    @Test func rejectsNonWavData() {
        #expect(throws: WavReadError.self) {
            _ = try WavReader.readFloatSamples(from: Data("not a wav".utf8))
        }
    }

    @Test func rejectsNon16kRate() throws {
        let url = try makeWav(samples: [0, 1, 2], sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try WavReader.readFloatSamples(from: url)
            Issue.record("expected a throw")
        } catch let error as WavReadError {
            #expect(error == .unsupportedSampleRate(44_100))
        }
    }
}
