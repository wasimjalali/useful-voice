import Foundation

/// Per-category formatting of one dictation, as deterministic rules.
/// `windows/src/core/formatting/categoryFormatter.ts` mirrors this file rule for rule.
///
/// It never invents content: no greeting, sign-off or name that was not dictated (or, for
/// the name, passed in), and it leaves text alone whenever a rule is unsure.
public enum CategoryFormatter {
    /// - Parameters:
    ///   - dictation: the text to format.
    ///   - category: the resolved category of the app (see `AppCategoryRegistry.resolve`).
    ///   - style: the user's chosen style for this category; nil means the category default.
    ///   - userName: the name for an email sign-off. Only used under a dictated sign-off, and only when not empty.
    ///   - textBeforeCursor: the text just before the cursor; nil means unknown.
    ///   - dictionaryWords: words whose capitalisation must be kept.
    public static func format(_ dictation: String,
                              category: AppCategory,
                              style: FormattingStyle? = nil,
                              userName: String? = nil,
                              textBeforeCursor: String? = nil,
                              dictionaryWords: [String] = []) -> String {
        if CategoryText.trimWS(dictation).isEmpty { return dictation }

        if category == .coding {
            return CategoryContinuation.apply(textBeforeCursor: textBeforeCursor,
                                              dictation: CategoryCoding.format(dictation),
                                              dictionaryWords: dictionaryWords, lowercase: false)
        }

        var text = dictation
        if category == .email {
            // A greeting and sign-off belong at the start of a line, never inside a sentence.
            let startsLine = textBeforeCursor == nil || CategoryContinuation.isAtLineStart(textBeforeCursor)
            if startsLine && !CategoryContinuation.isMidSentence(textBeforeCursor) {
                text = CategoryEmail.structure(text, userName: userName, dictionaryWords: dictionaryWords)
            }
        }
        text = CategoryStyling.apply(text, style: FormattingStyle.effective(requested: style, category: category),
                                     dictionaryWords: dictionaryWords)
        return CategoryContinuation.apply(textBeforeCursor: textBeforeCursor, dictation: text,
                                          dictionaryWords: dictionaryWords)
    }
}
