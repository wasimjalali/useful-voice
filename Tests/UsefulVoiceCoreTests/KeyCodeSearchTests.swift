import Testing
@testable import UsefulVoiceCore

@Suite struct KeyCodeSearchTests {
    /// US QWERTY: physical key 9 is V.
    private let qwerty: [UInt16: String] = [0: "a", 9: "v", 8: "c", 47: ".", 40: "k"]
    /// Dvorak: V sits on the physical period key (47); key 9 types the quote mark.
    private let dvorak: [UInt16: String] = [0: "a", 9: "'", 8: "j", 47: "v", 40: "t"]
    /// Colemak keeps V where QWERTY has it.
    private let colemak: [UInt16: String] = [0: "a", 9: "v", 8: "c", 40: "e"]
    /// Russian: no Latin V anywhere.
    private let russian: [UInt16: String] = [0: "ф", 9: "м", 8: "с"]

    private func search(_ layout: [UInt16: String]) -> UInt16? {
        KeyCodeSearch.keyCode(producing: "v") { layout[$0] }
    }

    @Test func qwertyFindsKeyNine() {
        #expect(search(qwerty) == 9)
    }

    @Test func dvorakFindsThePhysicalPeriodKey() {
        #expect(search(dvorak) == 47)
    }

    @Test func colemakFindsKeyNine() {
        #expect(search(colemak) == 9)
    }

    @Test func aLayoutWithoutTheLetterFindsNothing() {
        #expect(search(russian) == nil)
    }

    @Test func matchingIgnoresCase() {
        #expect(KeyCodeSearch.keyCode(producing: "v") { $0 == 12 ? "V" : nil } == 12)
    }

    @Test func theLowestKeyWinsWhenTwoKeysTypeTheLetter() {
        #expect(KeyCodeSearch.keyCode(producing: "v") { $0 == 70 || $0 == 20 ? "v" : nil } == 20)
    }

    @Test func multiCharacterAndEmptyResultsDoNotMatch() {
        #expect(KeyCodeSearch.keyCode(producing: "v") { _ in "vv" } == nil)
        #expect(KeyCodeSearch.keyCode(producing: "v") { _ in "" } == nil)
    }

    @Test func onlyTheFirst128KeyCodesAreTried() {
        var tried: [UInt16] = []
        _ = KeyCodeSearch.keyCode(producing: "v") { tried.append($0); return nil }
        #expect(tried == Array(0..<128))
    }
}
