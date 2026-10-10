import SwiftUI
import AppKit
import UsefulVoiceCore

/// Vocabulary: one list of rules. Every rule reads as a sentence and so does the
/// Add row. Words, fixes and snippets share the list; suggestions learned from the
/// owner's edits get their own view.
struct VocabularyPage: View {
    @ObservedObject var memory: LanguageMemoryViewModel
    @EnvironmentObject private var toasts: AppToastCenter

    @State private var filter: VocabularyFilter
    @State private var heard = ""
    @State private var written = ""
    @State private var word = ""
    @State private var soundsLike = ""
    @State private var removed: RemovedRule?
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var showImport = false
    @State private var importKind: ImportKind = .json
    @State private var importText = ""
    @State private var importMessage = ""
    @FocusState private var addFocus: AddField?

    /// What Undo puts back after a remove. Only the latest remove is undoable.
    private struct RemovedRule: Identifiable {
        let id = UUID()
        let message: String
        let restore: () -> Void
    }

    /// How long "Removed ... Undo" stays up.
    private static let undoSeconds: Double = 5

    init(viewModel: UsefulVoiceViewModel) {
        self.memory = viewModel.languageMemory
        _filter = State(initialValue: Self.startFilter)
    }

    /// `UV_VOCAB_FILTER=all|words|fixes|snippets|suggestions` picks the opening view
    /// for an offscreen render. It does nothing in a normal launch.
    private static let startFilter: VocabularyFilter = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UV_SNAPSHOT"] != nil,
              let raw = environment["UV_VOCAB_FILTER"],
              let filter = VocabularyFilter(rawValue: raw) else { return .all }
        return filter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let issue = memory.statusMessage {
                statusBanner(issue)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }
            controls
                .padding(.horizontal, 28)
            if filter != .suggestions {
                addRow
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
            }
            content
        }
        .pageColumn(maxWidth: 1200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .keepsFirstFieldUnfocused()
        .overlay(alignment: .bottomTrailing) {
            if let removed {
                NotesUndoToast(message: removed.message) {
                    removed.restore()
                    self.removed = nil
                }
                .padding(20)
                .transition(.brandRise())
            }
        }
        .brandAnimation(BrandMotion.hudEnter, value: removed?.id)
        .task(id: removed?.id) {
            guard let id = removed?.id else { return }
            AccessibilityNotification.Announcement("\(removed?.message ?? "") Undo available.").post()
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled, removed?.id == id else { return }
            removed = nil
        }
        .sheet(isPresented: $showImport) { importSheet }
    }

    // MARK: - Header and controls

    private var header: some View {
        HStack(spacing: 8) {
            Text("Vocabulary")
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            PageMoreMenu(help: "Import and export") {
                Button("Copy full backup") {
                    copy(memory.exportSnapshotJSON(), toast: "Backup copied")
                }
                Button("Copy words as CSV") {
                    copy(memory.exportTermsCSV(), toast: "Words CSV copied")
                }
                Button("Copy fixes as CSV") {
                    copy(memory.exportReplacementsCSV(), toast: "Fixes CSV copied")
                }
                Divider()
                Button("Import vocabulary") {
                    importText = ""
                    importMessage = ""
                    showImport = true
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            VocabularyFilterControl(selection: $filter, counts: counts)
            Spacer(minLength: 12)
            PremiumSearchField(placeholder: "Search rules", text: $memory.query)
                .frame(width: 220)
        }
    }

    /// Counts ignore the search text so they read as totals, not matches.
    private var counts: [VocabularyFilter: Int] {
        let words = memory.terms.count
        let fixes = memory.replacements.count
        let snippets = memory.snippets.count
        return [
            .all: words + fixes + snippets,
            .words: words,
            .fixes: fixes,
            .snippets: snippets,
            .suggestions: memory.suggestions.count,
        ]
    }

    // MARK: - Status

    /// Shows a persistence problem plainly: the store used to swallow every write
    /// failure, so a page could report success while the file on disk was unchanged.
    private func statusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.uv(.meta, .semibold))
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text("Changes are not being saved")
                    .font(.uv(.meta, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.uv(.meta))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if memory.saveIssue != nil && memory.loadIssue == nil {
                Button("Dismiss") { memory.dismissSaveIssue() }
                    .buttonStyle(.brandGhost)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .strokeBorder(Theme.lineStrong, lineWidth: 1))
    }

    // MARK: - Add row

    /// "When I say [ ] write [ ] [Add]". A word has only "write"; with both fields it
    /// is a fix. Words and Fixes keep their own sentence, snippets say "expand to".
    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: 10) {
            switch filter {
            case .words:
                sentenceLabel("Always write")
                field("Word or phrase", text: $word, width: 220, focus: .first)
                sentenceLabel("sounds like")
                field("Optional", text: $soundsLike, width: 200, focus: .second)
            case .snippets:
                sentenceLabel("When I say")
                field("Trigger", text: $trigger, width: 200, focus: .first)
                sentenceLabel("expand to")
                field("Text", text: $expansion, width: 280, focus: .second)
            case .all, .fixes:
                sentenceLabel("When I say")
                field("What it hears", text: $heard, width: 200, focus: .first)
                sentenceLabel("write")
                field("What you want", text: $written, width: 200, focus: .second)
                if filter == .all && trimmed(heard).isEmpty && !trimmed(written).isEmpty {
                    sentenceLabel("sounds like")
                    field("Optional", text: $soundsLike, width: 160, focus: .third)
                }
            case .suggestions:
                EmptyView()
            }
            Button("Add", action: add)
                .buttonStyle(.brandPrimary)
                .disabled(!canAdd)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liftCard()
    }

    private func sentenceLabel(_ text: String) -> some View {
        Text(text)
            .font(.uv(.body))
            .foregroundStyle(Theme.inkMuted)
            .fixedSize()
    }

    private enum AddField: Hashable { case first, second, third }

    private func field(_ placeholder: String, text: Binding<String>, width: CGFloat,
                       focus: AddField) -> some View {
        TextField(placeholder, text: text)
            .premiumInputChrome()
            .frame(width: width)
            .onSubmit(add)
            .focused($addFocus, equals: focus)
    }

    private var canAdd: Bool {
        switch filter {
        case .words: return !trimmed(word).isEmpty
        case .snippets: return !trimmed(trigger).isEmpty && !trimmed(expansion).isEmpty
        case .all: return !trimmed(written).isEmpty
        case .fixes: return !trimmed(heard).isEmpty && !trimmed(written).isEmpty
        case .suggestions: return false
        }
    }

    private func add() {
        guard canAdd else { return }
        switch filter {
        case .words:
            addWord(trimmed(word))
            word = ""
        case .snippets:
            memory.addSnippet(trigger: trimmed(trigger), expansion: trimmed(expansion))
            trigger = ""
            expansion = ""
            toasts.show("Snippet added")
        case .all, .fixes:
            if trimmed(heard).isEmpty {
                addWord(trimmed(written))
            } else {
                memory.addReplacement(match: trimmed(heard), replacement: trimmed(written))
                toasts.show("Fix added")
            }
            heard = ""
            written = ""
            soundsLike = ""
        case .suggestions:
            break
        }
    }

    /// The optional "sounds like" text is stored as pronunciations, comma separated,
    /// the way the old page did.
    private func addWord(_ phrase: String) {
        let pronunciations = soundsLike
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        memory.addTerm(phrase: phrase, pronunciations: pronunciations, priority: .high)
        soundsLike = ""
        toasts.show(pronunciations.isEmpty
                    ? "Added \u{201C}\(phrase)\u{201D}"
                    : "Added \u{201C}\(phrase)\u{201D} with sound-alike fixes")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch filter {
        case .suggestions: suggestions
        default: rules
        }
    }

    private var items: [VocabularyItem] {
        var list: [VocabularyItem] = []
        if filter == .all || filter == .words { list += memory.filteredTerms.map(VocabularyItem.word) }
        if filter == .all || filter == .fixes { list += memory.filteredReplacements.map(VocabularyItem.fix) }
        if filter == .all || filter == .snippets { list += memory.filteredSnippets.map(VocabularyItem.snippet) }
        return list.sorted { a, b in
            if a.uses != b.uses { return a.uses > b.uses }
            return a.sortName.localizedCaseInsensitiveCompare(b.sortName) == .orderedAscending
        }
    }

    @ViewBuilder
    private var rules: some View {
        let shown = items
        if shown.isEmpty {
            emptyState
                .padding(.horizontal, 28)
                .padding(.top, 20)
            Spacer(minLength: 0)
        } else {
            VocabularyTableHeader(showType: filter == .all)
                .padding(.horizontal, 28)
                .padding(.top, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { item in
                        VocabularyRuleRow(
                            item: item,
                            showType: filter == .all,
                            onTogglePause: { togglePause(item) },
                            onRemove: { remove(item) }
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let searching = !memory.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if searching && (counts[filter] ?? 0) > 0 {
            VocabularyEmptyCard(title: "No matches", detail: "Try a different spelling.")
        } else {
            switch filter {
            case .words:
                VocabularyEmptyCard(
                    title: "No words yet",
                    detail: "Add names and terms Useful Voice should spell your way.",
                    actionTitle: "Add word",
                    action: { addFocus = .first })
            case .fixes:
                VocabularyEmptyCard(
                    title: "No fixes yet",
                    detail: "A fix rewrites something it hears wrongly. Teach one from any dictation.",
                    actionTitle: "Add fix",
                    action: { addFocus = .first })
            case .snippets:
                VocabularyEmptyCard(
                    title: "No snippets yet",
                    detail: "A snippet types a longer text when you say its trigger.",
                    actionTitle: "Add snippet",
                    action: { addFocus = .first })
            case .all, .suggestions:
                VocabularyEmptyCard(
                    title: "No rules yet",
                    detail: "Add a word, a fix or a snippet above, and Useful Voice will apply it to every dictation.")
            }
        }
    }

    private var suggestions: some View {
        let shown = memory.filteredSuggestions
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if shown.isEmpty {
                    if memory.suggestions.isEmpty {
                        VocabularyEmptyCard(
                            title: "No suggestions yet",
                            detail: "When you fix the same words more than once, Useful Voice offers to remember them here.")
                    } else {
                        VocabularyEmptyCard(title: "No matches", detail: "Try a different spelling.")
                    }
                } else {
                    ForEach(shown) { suggestion in
                        VocabularySuggestionCard(
                            suggestion: suggestion,
                            onAdd: {
                                memory.acceptSuggestion(suggestion.id, as: suggestion.kind)
                                toasts.show(addedMessage(for: suggestion.kind))
                            },
                            onDismiss: {
                                memory.dismissSuggestion(suggestion.id)
                                toasts.show("Suggestion dismissed", kind: .info)
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    private func addedMessage(for kind: MemorySuggestionKind) -> String {
        switch kind {
        case .replacement: return "Fix added"
        case .term: return "Word added"
        case .snippetCandidate: return "Snippet added"
        }
    }

    // MARK: - Row actions

    private func togglePause(_ item: VocabularyItem) {
        switch item {
        case .word:
            break
        case .fix(let rule):
            let next = !rule.isEnabled
            memory.setReplacementEnabled(rule.id, isEnabled: next)
            toasts.show(next ? "Fix resumed" : "Fix paused", kind: .info)
        case .snippet(let snippet):
            let next = !snippet.isEnabled
            memory.setSnippetEnabled(snippet.id, isEnabled: next)
            toasts.show(next ? "Snippet resumed" : "Snippet paused", kind: .info)
        }
    }

    /// Removes at once and offers Undo for 5 s. Undo re-adds the same value with its id,
    /// use count and every other field. Only the latest remove can be undone.
    private func remove(_ item: VocabularyItem) {
        switch item {
        case .word(let term):
            memory.removeTerm(id: term.id)
            removed = RemovedRule(message: "Removed \u{201C}\(term.phrase)\u{201D}.") {
                // Never overwrite a word added again since the remove.
                guard !memory.terms.contains(where: { $0.phrase.caseInsensitiveCompare(term.phrase) == .orderedSame })
                else { return toasts.show("Can't undo: \u{201C}\(term.phrase)\u{201D} is already back") }
                memory.updateTerm(term)
            }
        case .fix(let rule):
            memory.removeReplacement(id: rule.id)
            removed = RemovedRule(message: "Removed \u{201C}\(rule.match)\u{201D}.") {
                guard !memory.replacements.contains(where: { $0.match.caseInsensitiveCompare(rule.match) == .orderedSame })
                else { return toasts.show("Can't undo: a fix for \u{201C}\(rule.match)\u{201D} exists now") }
                memory.updateReplacement(rule)
            }
        case .snippet(let snippet):
            memory.removeSnippet(id: snippet.id)
            removed = RemovedRule(message: "Removed \u{201C}\(snippet.trigger)\u{201D}.") {
                guard !memory.snippets.contains(where: { $0.trigger.caseInsensitiveCompare(snippet.trigger) == .orderedSame })
                else { return toasts.show("Can't undo: a snippet for \u{201C}\(snippet.trigger)\u{201D} exists now") }
                memory.updateSnippet(snippet)
            }
        }
    }

    // MARK: - Import

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import vocabulary")
                .font(.uv(.figure, .semibold))
                .foregroundStyle(Theme.ink)

            BrandedSegmentedControl(
                selection: $importKind,
                options: ImportKind.allCases.map { ($0.title, $0) }
            )

            TextEditor(text: $importText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1))
                .frame(minHeight: 230)

            if !importMessage.isEmpty {
                Text(importMessage)
                    .font(.uv(.meta))
                    .foregroundStyle(importMessage.hasPrefix("Imported") ? Theme.success : Theme.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { showImport = false }
                    .buttonStyle(.brandSecondary)
                Button("Import") { performImport() }
                    .buttonStyle(.brandPrimary)
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
        .background(Theme.surface)
    }

    private func performImport() {
        switch importKind {
        case .json:
            guard let result = memory.importSnapshotJSON(importText) else {
                importMessage = "The JSON backup could not be read."
                return
            }
            importMessage = resultMessage(result)
            toasts.show("Vocabulary imported")
        case .wordsCSV:
            importMessage = resultMessage(memory.importTermsCSV(importText))
            toasts.show("Words imported")
        case .correctionsCSV:
            importMessage = resultMessage(memory.importReplacementsCSV(importText))
            toasts.show("Fixes imported")
        }
    }

    private func resultMessage(_ result: LanguageMemoryImportResult) -> String {
        "Imported \(result.inserted) new and updated \(result.updated). \(result.duplicates) duplicates skipped."
    }

    // MARK: - Helpers

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copy(_ value: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        toasts.show(toast)
    }
}

private enum ImportKind: String, CaseIterable, Identifiable {
    case json, wordsCSV, correctionsCSV
    var id: String { rawValue }
    var title: String {
        switch self {
        case .json: return "Backup"
        case .wordsCSV: return "Words CSV"
        case .correctionsCSV: return "Fixes CSV"
        }
    }
}
