import Testing
@testable import UsefulVoiceCore

@Suite struct RightOptionTapRecognizerTests {
    @Test func testQuickTapFires() {
        var recognizer = RightOptionTapRecognizer()
        #expect(recognizer.handle(.rightOptionDown(at: 10.0)) == false)
        #expect(recognizer.handle(.rightOptionUp(at: 10.2)) == true)
    }

    @Test func testSlowHoldDoesNotFire() {
        var recognizer = RightOptionTapRecognizer()
        #expect(recognizer.handle(.rightOptionDown(at: 10.0)) == false)
        #expect(recognizer.handle(.rightOptionUp(at: 11.0)) == false)
    }

    @Test func testComboWithOtherKeyDoesNotFire() {
        var recognizer = RightOptionTapRecognizer()
        #expect(recognizer.handle(.rightOptionDown(at: 10.0)) == false)
        #expect(recognizer.handle(.otherKeyDown) == false)
        #expect(recognizer.handle(.rightOptionUp(at: 10.1)) == false)
    }

    @Test func testUpWithoutDownDoesNotFire() {
        var recognizer = RightOptionTapRecognizer()
        #expect(recognizer.handle(.rightOptionUp(at: 10.0)) == false)
    }

    @Test func testRecognizerResetsAfterFiring() {
        var recognizer = RightOptionTapRecognizer()
        _ = recognizer.handle(.rightOptionDown(at: 10.0))
        #expect(recognizer.handle(.rightOptionUp(at: 10.1)) == true)
        #expect(recognizer.handle(.rightOptionDown(at: 12.0)) == false)
        #expect(recognizer.handle(.rightOptionUp(at: 12.1)) == true)
    }

    // A combo invalidates only its own down/up window; the next clean tap fires.
    @Test func testFreshTapAfterInvalidatedComboFires() {
        var recognizer = RightOptionTapRecognizer()
        #expect(recognizer.handle(.rightOptionDown(at: 10.0)) == false)
        #expect(recognizer.handle(.otherKeyDown) == false)
        #expect(recognizer.handle(.rightOptionUp(at: 10.1)) == false)
        #expect(recognizer.handle(.rightOptionDown(at: 12.0)) == false)
        #expect(recognizer.handle(.rightOptionUp(at: 12.1)) == true)
    }
}
