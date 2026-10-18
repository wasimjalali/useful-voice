import Testing
@testable import UsefulVoiceCore

@Suite struct HotkeyEventProcessorTests {
    // Device-dependent bits and class flags, as they appear in CGEventFlags.rawValue.
    static let classCommand: UInt64 = 0x100000
    static let classShift: UInt64 = 0x20000
    static let lcmd: UInt64 = 0x08
    static let rcmd: UInt64 = 0x10
    static let lshift: UInt64 = 0x02
    static let rshift: UInt64 = 0x04

    static let rightCommand: Int64 = 54
    static let leftCommand: Int64 = 55
    static let rightShift: Int64 = 60

    private func tap(_ processor: inout HotkeyEventProcessor,
                     keycode: Int64 = rightCommand,
                     downFlags: UInt64, upFlags: UInt64,
                     at time: Double = 10.0, recording: Bool = false) -> [HotkeyEventProcessor.Fire] {
        var fired: [HotkeyEventProcessor.Fire] = []
        let down = processor.process(.flagsChanged(keycode: keycode, rawFlags: downFlags),
                                     activationKeycode: Self.rightCommand,
                                     languageSwitchKeycode: Self.rightShift,
                                     isRecording: recording, now: time)
        let up = processor.process(.flagsChanged(keycode: keycode, rawFlags: upFlags),
                                   activationKeycode: Self.rightCommand,
                                   languageSwitchKeycode: Self.rightShift,
                                   isRecording: recording, now: time + 0.1)
        fired += down.fire.map { [$0] } ?? []
        fired += up.fire.map { [$0] } ?? []
        return fired
    }

    private func send(_ processor: inout HotkeyEventProcessor,
                      _ input: HotkeyEventProcessor.Input,
                      at time: Double = 10.05, recording: Bool = false) -> HotkeyEventProcessor.Outcome {
        processor.process(input, activationKeycode: Self.rightCommand,
                          languageSwitchKeycode: Self.rightShift,
                          isRecording: recording, now: time)
    }

    // MARK: - Plain taps

    @Test func rightCommandTapToggles() {
        var processor = HotkeyEventProcessor()
        let fired = tap(&processor,
                        downFlags: Self.classCommand | Self.rcmd,
                        upFlags: 0)
        #expect(fired == [.toggle])
    }

    @Test func languageKeyTapSwitchesLanguage() {
        var processor = HotkeyEventProcessor()
        let fired = tap(&processor, keycode: Self.rightShift,
                        downFlags: Self.classShift | Self.rshift, upFlags: 0)
        #expect(fired == [.languageSwitch])
    }

    // MARK: - (a) what cancels a pending tap

    @Test func unrelatedKeyUpDoesNotCancelPendingTap() {
        var processor = HotkeyEventProcessor()
        _ = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                           rawFlags: Self.classCommand | Self.rcmd), at: 10.0)
        // A key released from before the tap (typing finished a hair earlier).
        let keyUp = send(&processor, .keyUp(keycode: 0), at: 10.05)
        #expect(keyUp.consume == false)
        let up = send(&processor, .flagsChanged(keycode: Self.rightCommand, rawFlags: 0), at: 10.1)
        #expect(up.fire == .toggle)
    }

    @Test func keyDownCancelsPendingTap() {
        var processor = HotkeyEventProcessor()
        _ = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                           rawFlags: Self.classCommand | Self.rcmd), at: 10.0)
        _ = send(&processor, .keyDown(keycode: 8), at: 10.05) // Cmd+C
        let up = send(&processor, .flagsChanged(keycode: Self.rightCommand, rawFlags: 0), at: 10.1)
        #expect(up.fire == nil)
    }

    @Test func mouseDownAndDragCancelPendingTap() {
        for input in [HotkeyEventProcessor.Input.pointerDown, .scroll(momentumPhase: 0)] {
            var processor = HotkeyEventProcessor()
            _ = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                               rawFlags: Self.classCommand | Self.rcmd), at: 10.0)
            _ = send(&processor, input, at: 10.05)
            let up = send(&processor, .flagsChanged(keycode: Self.rightCommand, rawFlags: 0), at: 10.1)
            #expect(up.fire == nil)
        }
    }

    @Test func trackpadMomentumScrollDoesNotCancelPendingTap() {
        var processor = HotkeyEventProcessor()
        _ = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                           rawFlags: Self.classCommand | Self.rcmd), at: 10.0)
        _ = send(&processor, .scroll(momentumPhase: 2), at: 10.05) // momentum continues
        let up = send(&processor, .flagsChanged(keycode: Self.rightCommand, rawFlags: 0), at: 10.1)
        #expect(up.fire == .toggle)
    }

    @Test func otherModifierChangingCancelsPendingTap() {
        var processor = HotkeyEventProcessor()
        _ = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                           rawFlags: Self.classCommand | Self.rcmd), at: 10.0)
        _ = send(&processor, .flagsChanged(keycode: 56, rawFlags: Self.classCommand | Self.rcmd | Self.lshift), at: 10.03)
        let up = send(&processor, .flagsChanged(keycode: Self.rightCommand, rawFlags: Self.lshift), at: 10.1)
        #expect(up.fire == nil)
    }

    // MARK: - (b) holding the other side of the same modifier

    @Test func rightCommandTapWhileLeftCommandHeldStillToggles() {
        var processor = HotkeyEventProcessor()
        // Left Command goes down first.
        _ = send(&processor, .flagsChanged(keycode: Self.leftCommand,
                                           rawFlags: Self.classCommand | Self.lcmd), at: 9.0)
        // Right Command down and up while Left is still held: the class flag stays set throughout.
        let fired = tap(&processor,
                        downFlags: Self.classCommand | Self.lcmd | Self.rcmd,
                        upFlags: Self.classCommand | Self.lcmd)
        #expect(fired == [.toggle])
        // And the next ordinary tap after letting go of Left is not eaten by stale state.
        _ = send(&processor, .flagsChanged(keycode: Self.leftCommand, rawFlags: 0), at: 11.0)
        let again = tap(&processor, downFlags: Self.classCommand | Self.rcmd, upFlags: 0, at: 12.0)
        #expect(again == [.toggle])
    }

    @Test func isDownReadsTheKeysOwnSide() {
        let both = Self.classCommand | Self.lcmd
        #expect(HotkeyEventProcessor.isDown(keycode: 54, rawFlags: both) == false)
        #expect(HotkeyEventProcessor.isDown(keycode: 55, rawFlags: both) == true)
        #expect(HotkeyEventProcessor.isDown(keycode: 54, rawFlags: both | Self.rcmd) == true)
        #expect(HotkeyEventProcessor.isDown(keycode: 60, rawFlags: Self.classShift | Self.rshift) == true)
        #expect(HotkeyEventProcessor.isDown(keycode: 60, rawFlags: Self.classShift | Self.lshift) == false)
    }

    @Test func isDownFallsBackToClassFlagWithoutDeviceBits() {
        // Synthetic events (remappers, remote desktop) can carry only the class flag.
        #expect(HotkeyEventProcessor.isDown(keycode: 54, rawFlags: Self.classCommand) == true)
        #expect(HotkeyEventProcessor.isDown(keycode: 54, rawFlags: 0) == false)
        // Device bits of another modifier class do not count as this class's bits.
        #expect(HotkeyEventProcessor.isDown(keycode: 54, rawFlags: Self.classCommand | Self.lshift) == true)
        // Fn has no device bit: the class flag is all there is.
        #expect(HotkeyEventProcessor.isDown(keycode: 63, rawFlags: 0x800000) == true)
        #expect(HotkeyEventProcessor.isDown(keycode: 63, rawFlags: 0) == false)
    }

    // MARK: - (c) reset after the tap was disabled

    @Test func resetClearsStaleDownStateAndPendingTap() {
        var processor = HotkeyEventProcessor()
        // The down arrives, then the tap is disabled and the up is lost.
        _ = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                           rawFlags: Self.classCommand | Self.rcmd), at: 10.0)
        processor.reset()
        // After re-enable the stray up must not fire a toggle from the lost tap...
        let strayUp = send(&processor, .flagsChanged(keycode: Self.rightCommand, rawFlags: 0), at: 10.1)
        #expect(strayUp.fire == nil)
        // ...and the next real tap works.
        let fired = tap(&processor, downFlags: Self.classCommand | Self.rcmd, upFlags: 0, at: 20.0)
        #expect(fired == [.toggle])
    }

    @Test func withoutResetAStaleDownEatsTheNextTapsDown() {
        // Documents why reset exists: the lost up leaves lastDownState = down, so the
        // next down is read as a repeat and ignored.
        var processor = HotkeyEventProcessor()
        _ = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                           rawFlags: Self.classCommand | Self.rcmd), at: 10.0)
        let down = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                                  rawFlags: Self.classCommand | Self.rcmd), at: 20.0)
        #expect(down.fire == nil)
    }

    // MARK: - (d) Esc

    @Test func escKeyDownIsConsumedWhileRecordingAndCancels() {
        var processor = HotkeyEventProcessor()
        let down = send(&processor, .keyDown(keycode: 53), recording: true)
        #expect(down.consume == true)
        #expect(down.fire == .cancel)
    }

    @Test func escKeyUpFollowsItsConsumedKeyDown() {
        var processor = HotkeyEventProcessor()
        _ = send(&processor, .keyDown(keycode: 53), recording: true)
        // The recording already ended by the time the key is released.
        let up = send(&processor, .keyUp(keycode: 53), recording: false)
        #expect(up.consume == true)
        // Only the one matching key-up is eaten.
        let second = send(&processor, .keyUp(keycode: 53), recording: false)
        #expect(second.consume == false)
    }

    @Test func autoRepeatedEscKeyDownAfterCancelIsStillConsumed() {
        var processor = HotkeyEventProcessor()
        _ = send(&processor, .keyDown(keycode: 53), recording: true)
        let repeatDown = send(&processor, .keyDown(keycode: 53), recording: false)
        #expect(repeatDown.consume == true)
        #expect(repeatDown.fire == nil)
    }

    @Test func escOutsideRecordingPassesThrough() {
        var processor = HotkeyEventProcessor()
        let down = send(&processor, .keyDown(keycode: 53), recording: false)
        let up = send(&processor, .keyUp(keycode: 53), recording: false)
        #expect(down.consume == false && down.fire == nil)
        #expect(up.consume == false)
    }

    @Test func escKeyDownDuringRecordingDoesNotSpoilAPendingTap() {
        // Existing behaviour kept: Esc while recording is ours and not "another key".
        var processor = HotkeyEventProcessor()
        _ = send(&processor, .flagsChanged(keycode: Self.rightCommand,
                                           rawFlags: Self.classCommand | Self.rcmd), at: 10.0, recording: true)
        _ = send(&processor, .keyDown(keycode: 53), at: 10.05, recording: true)
        let up = send(&processor, .flagsChanged(keycode: Self.rightCommand, rawFlags: 0), at: 10.1, recording: true)
        #expect(up.fire == .toggle)
    }
}
