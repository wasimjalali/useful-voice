import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct SilenceWatchdogTests {
    @Test func testFiresAfterContinuousSilence() {
        var watchdog = SilenceWatchdog(threshold: 0.01, timeout: 60)
        #expect(watchdog.observe(rms: 0.5, at: 0) == false)    // loud
        #expect(watchdog.observe(rms: 0.001, at: 30) == false) // quiet, 30s
        #expect(watchdog.observe(rms: 0.001, at: 59) == false) // quiet, 59s
        #expect(watchdog.observe(rms: 0.001, at: 61) == true)  // quiet past timeout
    }

    @Test func testSpeechResetsTheClock() {
        var watchdog = SilenceWatchdog(threshold: 0.01, timeout: 60)
        #expect(watchdog.observe(rms: 0.001, at: 0) == false)
        #expect(watchdog.observe(rms: 0.5, at: 59) == false)   // speech resets
        #expect(watchdog.observe(rms: 0.001, at: 118) == false)
        #expect(watchdog.observe(rms: 0.001, at: 120) == true)
    }
}
