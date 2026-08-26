import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct WavWriterTests {
    @Test func testWritesValidWavFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sampleRate: 16000)
        try writer.append(samples: [0, 1000, -1000, 32767])
        try writer.append(samples: [100, -100])
        try writer.finish()

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 6 * 2) // header + 6 samples * 2 bytes
        #expect(String(decoding: Data(data[0..<4]), as: UTF8.self) == "RIFF")
        #expect(String(decoding: Data(data[8..<12]), as: UTF8.self) == "WAVE")
        let rate = Data(data[24..<28]).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(rate == 16000)
        let dataSize = Data(data[40..<44]).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(dataSize == 12)
        let s2 = Data(data[46..<48]).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        #expect(s2 == 1000)
    }
}
