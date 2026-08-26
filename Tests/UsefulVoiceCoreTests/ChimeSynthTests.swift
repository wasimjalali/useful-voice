import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct ChimeSynthTests {
    @Test func testStartChimeIsValidWav() {
        let data = ChimeSynth.startChime()
        #expect(data.count > 44)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data.subdata(in: 8..<12), as: UTF8.self) == "WAVE")
    }

    @Test func testChimeIsGentleAndClickFree() {
        let samples = ChimeSynth.chime(frequencies: [523.25, 659.26])
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 800)      // audible
        #expect(peak < 9_000)    // soothing, stays around quarter scale
        #expect(abs(Int(samples.first ?? 32_767)) < 350)   // no click in
        #expect(abs(Int(samples.last ?? 32_767)) < 350)    // no click out
    }

    @Test func testStartAndStopDiffer() {
        #expect(ChimeSynth.startChime() != ChimeSynth.stopChime())
    }

    @Test func testWavHeaderDescribesMono16Bit44k() {
        let data = ChimeSynth.wavData(samples: [0, 1000, -1000])
        #expect(data[22] == 1)   // mono
        let rate = UInt32(data[24]) | UInt32(data[25]) << 8
                 | UInt32(data[26]) << 16 | UInt32(data[27]) << 24
        #expect(rate == 44_100)
        #expect(data.count == 44 + 3 * 2)
    }
}
