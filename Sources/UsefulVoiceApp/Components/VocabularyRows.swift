import SwiftUI
import UsefulVoiceCore

/// The five views of the one Vocabulary list.
enum VocabularyFilter: String, CaseIterable, Identifiable {
    case all, words, fixes, snippets, suggestions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .words: return "Words"
        case .fixes: return "Fixes"
        case .snippets: return "Snippets"
        case .suggestions: return "Suggestions"
        }
    }
}

/// One rule in the list, whatever its type. Words, fixes and snippets share a row.
enum VocabularyItem: Identifiable {
    case word(MemoryTerm)
    case fix(ReplacementRule)
    case snippet(MemorySnippet)

    var id: UUID {
        switch self {
        case .word(let term): return term.id
        case .fix(let rule): return rule.id
        case .snippet(let snippet): return snippet.id
        }
    }

    var uses: Int {
        switch self {
        case .word(let term): return term.usageCount
        case .fix(let rule): return rule.usageCount
        case .snippet(let snippet): return snippet.usageCount
        }
    }

    var typeLabel: String {
        switch self {
        case .word: return "Word"
        case .fix: return "Fix"
        case .snippet: return "Snippet"
        }
    }

    var sortName: String {
        switch self {
        case .word(let term): return term.phrase
        case .fix(let rule): return rule.match
        case .snippet(let snippet): return snippet.trigger
        }
    }

    /// Words have no `isEnabled` in the data, so only fixes and snippets can pause.
    var canPause: Bool {
        if case .word = self { return false }
        return true
    }

    var isPaused: Bool {
        switch self {
        case .word: return false
        case .fix(let rule): return !rule.isEnabled
        case .snippet(let snippet): return !snippet.isEnabled
        }
    }
}

/// The filter control: the board's segmented track with a quiet count after each name.
struct VocabularyFilterControl: View {
    @Binding var selection: VocabularyFilter
    let counts: [VocabularyFilter: Int]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VocabularyFilter.allCases) { filter in
                let selected = filter == selection
                Button {
                    selection = filter
                } label: {
                    HStack(spacing: 6) {
                        Text(filter.title)
                            .font(.uv(.meta, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
                        Text(NotesFormat.count(counts[filter] ?? 0))
                            .font(.uv(.meta).monospacedDigit())
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                            .fill(selected ? Theme.segmentOn : Color.clear)
                            .themeShadow(selected ? .segment : .none)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityLabel("\(filter.title), \(counts[filter] ?? 0)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.line, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .brandAnimation(BrandMotion.control, value: selection)
        .fixedSize()
    }
}

/// Column widths the header and every row share.
enum VocabularyColumns {
    static let type: CGFloat = 78
    static let uses: CGFloat = 56
    static let actions: CGFloat = 124
}

/// "Type  Rule  Uses" above the rows. The type column exists only in All.
struct VocabularyTableHeader: View {
    let showType: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showType {
                Text("Type").frame(width: VocabularyColumns.type, alignment: .leading)
            }
            Text("Rule").frame(maxWidth: .infinity, alignment: .leading)
            Text("Uses").frame(width: VocabularyColumns.uses, alignment: .trailing)
            Color.clear.frame(width: VocabularyColumns.actions, height: 1)
        }
        .font(.uv(.ui, .medium))
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

/// A word, trigger or replacement set in a chip inside a sentence.
private struct VocabularyChip: View {
    let text: String
    /// Filled for what is heard, outlined for what is written.
    let filled: Bool
    let muted: Bool

    var body: some View {
        Text(text)
            .font(.uv(.body, .semibold))
            .foregroundStyle(muted ? Theme.inkMuted : Theme.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(filled ? Theme.sunken : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .strokeBorder(filled ? Color.clear : Theme.lineStrong, lineWidth: 1))
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }
}

/// One rule as a sentence. Pause and remove appear on hover and on keyboard focus.
/// A paused rule says "Paused" in muted ink (never faded).
struct VocabularyRuleRow: View {
    let item: VocabularyItem
    let showType: Bool
    let onTogglePause: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @FocusState private var focus: RowAction?

    private enum RowAction: Hashable { case pause, remove }

    private var showActions: Bool { hovering || focus != nil }
    private var paused: Bool { item.isPaused }

    var body: some View {
        HStack(spacing: 12) {
            if showType {
                Text(item.typeLabel)
                    .font(.uv(.ui))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: VocabularyColumns.type, alignment: .leading)
            }
            sentence
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(NotesFormat.count(item.uses))
                .font(.uv(.body).monospacedDigit())
                .foregroundStyle(paused ? Theme.inkMuted : Theme.ink)
                .frame(width: VocabularyColumns.uses, alignment: .trailing)
            actions
                .frame(width: VocabularyColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
        .background(hovering ? Theme.sunken : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(alignment: .bottom) {
            if !hovering { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    // MARK: Sentence

    @ViewBuilder
    private var sentence: some View {
        switch item {
        case .word(let term):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                lead("Always write")
                VocabularyChip(text: term.phrase, filled: false, muted: paused)
                hint(wordHint(term))
            }
        case .fix(let rule):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                lead("When I say")
                VocabularyChip(text: rule.match, filled: true, muted: paused)
                lead("write")
                VocabularyChip(text: rule.replacement, filled: false, muted: paused)
                hint(languageHint(rule.language))
            }
        case .snippet(let snippet):
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    lead("When I say")
                    VocabularyChip(text: snippet.trigger, filled: true, muted: paused)
                    lead("expand to")
                    hint(languageHint(snippet.language))
                }
                Text(snippet.expansion)
                    .font(.uv(.ui))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func lead(_ text: String) -> some View {
        Text(text)
            .font(.uv(.body))
            .foregroundStyle(Theme.inkMuted)
            .fixedSize()
    }

    @ViewBuilder
    private func hint(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.uv(.ui))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func wordHint(_ term: MemoryTerm) -> String {
        var parts: [String] = []
        if !term.pronunciations.isEmpty {
            parts.append("sounds like " + term.pronunciations.joined(separator: ", "))
        }
        if !term.aliases.isEmpty {
            parts.append("also heard as " + term.aliases.joined(separator: ", "))
        }
        let language = languageHint(term.language)
        if !language.isEmpty { parts.append(language) }
        return parts.joined(separator: "  ")
    }

    private func languageHint(_ language: MemoryLanguage) -> String {
        language == .auto ? "" : language.displayName
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            if item.canPause {
                ZStack(alignment: .trailing) {
                    Button(paused ? "Resume" : "Pause", action: onTogglePause)
                        .buttonStyle(.brandSecondary)
                        .controlSize(.small)
                        .focused($focus, equals: .pause)
                        .opacity(showActions ? 1 : 0)
                        .allowsHitTesting(showActions)
                        .accessibilityLabel(paused ? "Resume \(item.typeLabel.lowercased())" : "Pause \(item.typeLabel.lowercased())")
                    if paused && !showActions {
                        Text("Paused")
                            .font(.uv(.ui, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .allowsHitTesting(false)
                    }
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(PremiumIconButtonStyle())
            .focused($focus, equals: .remove)
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
            .help("Remove \(item.typeLabel.lowercased())")
            .accessibilityLabel("Remove \(item.typeLabel.lowercased())")
        }
    }
}

/// A suggestion learned from the owner's edits: what happened, then two verbs.
struct VocabularySuggestionCard: View {
    let suggestion: MemorySuggestion
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.uv(.title, .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Last time: \(Self.when(suggestion.lastSeenAt))")
                .font(.uv(.body))
                .foregroundStyle(Theme.inkMuted)
            HStack(spacing: 8) {
                Button(addLabel, action: onAdd)
                    .buttonStyle(.brandPrimary)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.brandGhost)
            }
            .padding(.top, 8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liftCard()
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        let times = suggestion.evidenceCount > 1 ? " \(NotesFormat.count(suggestion.evidenceCount)) times" : ""
        switch suggestion.kind {
        case .replacement:
            if !suggestion.observed.isEmpty,
               suggestion.observed.caseInsensitiveCompare(suggestion.proposed) != .orderedSame {
                return "You corrected \u{201C}\(suggestion.observed)\u{201D} to \u{201C}\(suggestion.proposed)\u{201D}\(times)"
            }
            return "You corrected \u{201C}\(suggestion.proposed)\u{201D}\(times)"
        case .term:
            return "You wrote \u{201C}\(suggestion.proposed)\u{201D}\(times)"
        case .snippetCandidate:
            return "You repeated \u{201C}\(suggestion.proposed)\u{201D}\(times)"
        }
    }

    private var addLabel: String {
        switch suggestion.kind {
        case .replacement: return "Add fix"
        case .term: return "Add word"
        case .snippetCandidate: return "Add snippet"
        }
    }

    /// "Today, 17:03", "Yesterday, 11:42", then "8. Oct, 11:42".
    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter()
        time.locale = Locale(identifier: "de_DE")
        time.dateFormat = "HH:mm"
        let clock = time.string(from: date)
        if calendar.isDateInToday(date) { return "Today, \(clock)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(clock)" }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US")
        day.dateFormat = "d. MMM"
        return "\(day.string(from: date)), \(clock)"
    }
}

/// The board's empty state: a hairline card with a title, one sentence and, where it
/// helps, one button.
struct VocabularyEmptyCard: View {
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.uv(.body))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.brandPrimary)
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }
}
