import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct TermMatcherTests {

    // MARK: - canonical(_:)

    @Test func testCanonicalTrimsWhitespace() {
        #expect(TermMatcher.canonical("  hello  ") == "hello")
    }

    @Test func testCanonicalLowercases() {
        #expect(TermMatcher.canonical("Hello") == "hello")
    }

    @Test func testCanonicalStripsTrailingPeriod() {
        #expect(TermMatcher.canonical("Karko.") == "karko")
    }

    @Test func testCanonicalStripsLeadingPunctuation() {
        #expect(TermMatcher.canonical("(hello)") == "hello")
    }

    @Test func testCanonicalStripsMultiplePunctuation() {
        #expect(TermMatcher.canonical("\"hello!\"") == "hello")
    }

    @Test func testCanonicalStripsTrailingApostropheS() {
        #expect(TermMatcher.canonical("Karko's") == "karko")
    }

    @Test func testCanonicalStripsCurlySingleQuoteS() {
        // curly apostrophe + s
        #expect(TermMatcher.canonical("Karko\u{2019}s") == "karko")
    }

    @Test func testCanonicalStripsApostropheSCaseInsensitive() {
        #expect(TermMatcher.canonical("KARKO'S") == "karko")
    }

    @Test func testCanonicalCollapsesHyphenToSpace() {
        #expect(TermMatcher.canonical("Claude-Code") == "claude code")
    }

    @Test func testCanonicalCollapsesMultipleHyphens() {
        #expect(TermMatcher.canonical("foo--bar") == "foo bar")
    }

    @Test func testCanonicalCollapsesInternalSpaces() {
        #expect(TermMatcher.canonical("hello   world") == "hello world")
    }

    @Test func testCanonicalMixedHyphenAndSpace() {
        #expect(TermMatcher.canonical("foo - bar") == "foo bar")
    }

    @Test func testCanonicalCurlySingleQuotes() {
        // leading/trailing curly single quotes
        #expect(TermMatcher.canonical("\u{2018}hello\u{2019}") == "hello")
    }

    @Test func testCanonicalCurlyDoubleQuotes() {
        #expect(TermMatcher.canonical("\u{201C}hello\u{201D}") == "hello")
    }

    @Test func testCanonicalEmptyReturnsEmpty() {
        #expect(TermMatcher.canonical("") == "")
    }

    @Test func testCanonicalWhitespaceOnlyReturnsEmpty() {
        #expect(TermMatcher.canonical("   ") == "")
    }

    @Test func testCanonicalPunctOnlyReturnsEmpty() {
        #expect(TermMatcher.canonical("...") == "")
    }

    // MARK: - matches(_:_:)

    @Test func testMatchesIdentical() {
        #expect(TermMatcher.matches("Karko", "Karko"))
    }

    @Test func testMatchesCaseInsensitive() {
        #expect(TermMatcher.matches("Karko", "karko"))
    }

    @Test func testMatchesPossessiveVariant() {
        #expect(TermMatcher.matches("Karko's", "Karko"))
    }

    @Test func testMatchesPluralS() {
        #expect(TermMatcher.matches("Karkos", "Karko"))
    }

    @Test func testMatchesPluralES() {
        #expect(TermMatcher.matches("processes", "process"))
    }

    @Test func testMatchesHyphenVsSpace() {
        #expect(TermMatcher.matches("Claude-Code", "Claude Code"))
    }

    @Test func testMatchesTrailingPunct() {
        #expect(TermMatcher.matches("Karko.", "Karko"))
    }

    @Test func testNoMatchDifferentWords() {
        #expect(!TermMatcher.matches("Claude", "Karko"))
    }

    @Test func testNoMatchShorterBase() {
        // "car" vs "Karko" - not a plural relationship
        #expect(!TermMatcher.matches("car", "Karko"))
    }

    @Test func testMatchesBothDirections() {
        // plural tolerance is symmetric
        #expect(TermMatcher.matches("Karko", "Karkos"))
        #expect(TermMatcher.matches("Karkos", "Karko"))
    }
}
