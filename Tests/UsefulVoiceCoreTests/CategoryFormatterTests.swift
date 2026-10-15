import Testing
import Foundation
@testable import UsefulVoiceCore

/// The same cases drive `windows/tests/categoryFormatter.test.ts`, so the two platforms cannot drift.
/// The fixture lives in `Tests/Fixtures/app-awareness/formatter-cases.json`.
@Suite struct CategoryFormatterTests {
    private struct Case: Decodable {
        let id: String
        let category: String
        let style: String?
        let userName: String?
        let before: String?
        let words: [String]?
        let input: String
        let expected: String
    }
    private struct Fixture: Decodable { let cases: [Case] }

    private func cases() throws -> [Case] {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: tests.appendingPathComponent("Fixtures/app-awareness/formatter-cases.json"))
        return try JSONDecoder().decode(Fixture.self, from: data).cases
    }

    private func run(_ c: Case) -> String {
        CategoryFormatter.format(c.input,
                                 category: AppCategory(rawValue: c.category) ?? .other,
                                 style: c.style.flatMap { FormattingStyle(rawValue: $0) },
                                 userName: c.userName,
                                 textBeforeCursor: c.before,
                                 dictionaryWords: c.words ?? [])
    }

    // MARK: shared cases

    @Test func fixtureHasTheCasesItShould() throws {
        let all = try cases()
        #expect(all.count == 257)
        let prefixes = Set(all.map { String($0.id.split(separator: "-")[0]) })
        for p in ["empty", "blank", "code", "nocode", "style", "cont", "email"] {
            #expect(prefixes.contains(p), "\(p)")
        }
        // Every category and style name in the fixture must be a real one.
        for c in all {
            #expect(AppCategory(rawValue: c.category) != nil, "\(c.id)")
            if let style = c.style { #expect(FormattingStyle(rawValue: style) != nil, "\(c.id)") }
        }
    }

    @Test func givesTheExpectedTextForEverySharedCase() throws {
        var failures: [String] = []
        for c in try cases() {
            let got = run(c)
            if got != c.expected { failures.append("\(c.id): got \(got.debugDescription), want \(c.expected.debugDescription)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func formattingASecondTimeChangesNothingMore() throws {
        // Email layout, Coding conversion and the chat full stop are all one-way, so a second
        // pass over their own output must not keep rewriting.
        var unstable: [String] = []
        for c in try cases() where c.before == nil && c.category != "email" {
            let once = run(c)
            let twice = CategoryFormatter.format(once,
                                                 category: AppCategory(rawValue: c.category) ?? .other,
                                                 style: c.style.flatMap { FormattingStyle(rawValue: $0) },
                                                 dictionaryWords: c.words ?? [])
            if once != twice { unstable.append("\(c.id): \(once.debugDescription) then \(twice.debugDescription)") }
        }
        #expect(unstable.isEmpty, "\(unstable.joined(separator: "\n"))")
    }

    // MARK: restraint

    @Test func leavesAlreadyCleanTextAloneInEveryCategory() {
        for category in AppCategory.allCases {
            for text in ["Hello there", "Thanks for the update", "ok", "See you at 5 pm"] {
                #expect(CategoryFormatter.format(text, category: category, style: .formal) == text,
                        "\(category): \(text)")
            }
        }
    }

    @Test func neverAddsAGreetingSignOffOrNameThatWasNotDictated() {
        let text = "We reviewed the plan this morning and agreed that the schedule is tight but still workable if nobody changes the scope again this month and the team stays on track."
        let out = CategoryFormatter.format(text, category: .email, userName: "Wasim")
        #expect(out == text)
        #expect(!out.contains("Wasim"))
    }

    @Test func doesNotTouchSpokenSymbolsOutsideCoding() {
        let text = "a dot on the map, src slash app dot tsx"
        for category in AppCategory.allCases where category != .coding {
            #expect(CategoryFormatter.format(text, category: category, style: .formal) == text, "\(category)")
        }
    }

    @Test func keepsEveryWordInCodingWhenNoSymbolConverts() {
        let prose = "look at the docs and tag the release, he slash she, a dot on the map"
        #expect(CategoryCoding.format(prose) == prose)
    }

    // MARK: continuation helpers

    @Test func isMidSentence() {
        #expect(!CategoryContinuation.isMidSentence(nil))
        #expect(!CategoryContinuation.isMidSentence(""))
        #expect(!CategoryContinuation.isMidSentence("   "))
        #expect(CategoryContinuation.isMidSentence("Hello"))
        #expect(CategoryContinuation.isMidSentence("Hello "))
        #expect(CategoryContinuation.isMidSentence("Hello,"))
        for end in [".", "!", "?", ":"] {
            #expect(!CategoryContinuation.isMidSentence("Hello\(end)"), "\(end)")
        }
        #expect(!CategoryContinuation.isMidSentence("Hello\n"))
        #expect(!CategoryContinuation.isMidSentence("Hello \n  "))
        #expect(!CategoryContinuation.isMidSentence("Hello\r\n"))
        #expect(!CategoryContinuation.isMidSentence("He said \"ok.\""))
        #expect(!CategoryContinuation.isMidSentence("(done.)"))
        #expect(CategoryContinuation.isMidSentence("(see below)"))
        #expect(!CategoryContinuation.isMidSentence("- "))
        #expect(CategoryContinuation.isMidSentence("Buy - "))
    }

    @Test func isAtLineStart() {
        #expect(!CategoryContinuation.isAtLineStart(nil))
        #expect(CategoryContinuation.isAtLineStart(""))
        #expect(CategoryContinuation.isAtLineStart("  "))
        #expect(CategoryContinuation.isAtLineStart("Hi\n"))
        #expect(CategoryContinuation.isAtLineStart("Hi\n  "))
        #expect(CategoryContinuation.isAtLineStart("Hi\r\n"))
        #expect(!CategoryContinuation.isAtLineStart("Hi"))
        #expect(!CategoryContinuation.isAtLineStart("Hi. "))
    }

    @Test func needsLeadingSpace() {
        func needs(_ before: String, _ dictation: String) -> Bool {
            CategoryContinuation.needsLeadingSpace(textBeforeCursor: before, dictation: dictation)
        }
        #expect(!needs("", "Hello"))
        #expect(!needs("Hello", ""))
        #expect(needs("Hello", "world"))
        #expect(!needs("Hello ", "world"))
        #expect(!needs("Hello\n", "world"))
        #expect(!needs("Hello", " world"))
        #expect(!needs("Hello", ", world"))
        #expect(needs("Hello", "(world)"))
        #expect(!needs("a (", "world"))
        #expect(!needs("say \"", "world"))
        #expect(needs("say \"hi\"", "world"))
        #expect(!needs("src/", "app"))
    }

    @Test func lowercaseAndCapitalizeFirstWord() {
        func lower(_ t: String, _ words: [String] = []) -> String {
            CategoryContinuation.lowercaseFirstWord(t, dictionaryWords: words)
        }
        func upper(_ t: String, _ words: [String] = []) -> String {
            CategoryContinuation.capitalizeFirstWord(t, dictionaryWords: words)
        }
        #expect(lower("Hello") == "hello")
        #expect(lower("  Hello") == "  hello")
        #expect(lower("") == "")
        #expect(lower("hello") == "hello")
        #expect(lower("I am") == "I am")
        #expect(lower("I\u{2019}d go") == "I\u{2019}d go")
        #expect(lower("NASA") == "NASA")
        #expect(lower("iPhone") == "iPhone")
        #expect(lower("Sam", ["sam"]) == "Sam")
        #expect(lower("Sam", [" "]) == "sam")
        #expect(upper("thanks") == "Thanks")
        #expect(upper("iPhone") == "iPhone")
        #expect(upper("npm", ["npm"]) == "npm")
        #expect(upper("5 pm") == "5 pm")
        #expect(upper("") == "")
    }

    @Test func continuationLeavesUnknownContextAloneAndCanSkipLowercasing() {
        #expect(CategoryContinuation.apply(textBeforeCursor: nil, dictation: "Hello", dictionaryWords: []) == "Hello")
        #expect(CategoryContinuation.apply(textBeforeCursor: "and", dictation: "Hello", dictionaryWords: []) == " hello")
        #expect(CategoryContinuation.apply(textBeforeCursor: "and", dictation: "Hello", dictionaryWords: [],
                                           lowercase: false) == " Hello")
    }

    // MARK: style helpers

    @Test func dropTrailingFullStop() {
        #expect(CategoryStyling.dropTrailingFullStop("Sounds good.") == "Sounds good")
        #expect(CategoryStyling.dropTrailingFullStop("Sounds good") == "Sounds good")
        #expect(CategoryStyling.dropTrailingFullStop("Sounds good?") == "Sounds good?")
        #expect(CategoryStyling.dropTrailingFullStop("") == "")
        #expect(CategoryStyling.dropTrailingFullStop(".") == ".")
        #expect(CategoryStyling.dropTrailingFullStop("Wait..") == "Wait..")
    }

    @Test func applyStyle() {
        #expect(CategoryStyling.apply("Sounds good.", style: .formal, dictionaryWords: []) == "Sounds good.")
        #expect(CategoryStyling.apply("Sounds good.", style: .casual, dictionaryWords: []) == "Sounds good")
        #expect(CategoryStyling.apply("Sounds good.", style: .veryCasual, dictionaryWords: []) == "sounds good")
    }

    // MARK: email layout

    @Test func emailNeeds25WordsOrAGreeting() {
        func body(_ n: Int) -> String {
            "Word " + Array(repeating: "word", count: n - 2).joined(separator: " ") + " word."
        }
        let atLimit = body(23) + " Thanks, Sam"
        #expect(atLimit.split(separator: " ").count == 25)
        #expect(CategoryEmail.structure(atLimit, userName: nil) == body(23) + "\n\nThanks,\nSam")
        let underLimit = body(22) + " Thanks, Sam"
        #expect(underLimit.split(separator: " ").count == 24)
        #expect(CategoryEmail.structure(underLimit, userName: nil) == underLimit)
        #expect(CategoryEmail.structure("Hi Sam, " + body(2), userName: nil) == "Hi Sam,\n\nWord word.")
    }

    @Test func emailKeepsTextWithALineBreak() {
        #expect(CategoryEmail.structure("Hi Sam,\nthanks", userName: "Wasim") == "Hi Sam,\nthanks")
    }
}
