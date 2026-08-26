import SwiftUI
import AppKit
import SadaaCore

struct LanguageMemoryPage: View {
    @ObservedObject var viewModel: LanguageMemoryViewModel
    @EnvironmentObject private var toasts: AppToastCenter

    @State private var section: DictionarySection = .words
    @State private var word = ""
    @State private var soundsLike = ""
    @State private var heard = ""
    @State private var replacement = ""
    @State private var snippetTrigger = ""
    @State private var snippetExpansion = ""
    @State private var showImport = false
    @State private var importKind: ImportKind = .json
    @State private var importText = ""
    @State private var importMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !viewModel.suggestions.isEmpty { suggestions }
                teachCard
                libraryCard
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Theme.surface)
        .sheet(isPresented: $showImport) { importSheet }
    }

    // MARK: - Header

    private var header: some View {
        CommandPageHeader(
            title: "Dictionary",
            subtitle: "Teach names once. Useful Voice biases recognition and fixes the same mistakes next time."
        ) {
            BrandedMenuButton(help: "Import and export") {
                Button("Copy full backup") {
                    copy(viewModel.exportSnapshotJSON(), toast: "Backup copied")
                }
                Button("Copy words as CSV") {
                    copy(viewModel.exportTermsCSV(), toast: "Words CSV copied")
                }
                Button("Copy corrections as CSV") {
                    copy(viewModel.exportReplacementsCSV(), toast: "Corrections CSV copied")
                }
                Divider()
                Button("Import dictionary") {
                    importText = ""
                    importMessage = ""
                    showImport = true
                }
            }
        }
    }

    // MARK: - Suggestions

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review suggestions")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(viewModel.suggestions.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }

            ForEach(viewModel.filteredSuggestions.prefix(4)) { suggestion in
                HStack(spacing: 10) {
                    suggestionLabel(suggestion)
                    Spacer(minLength: 8)
                    Button("Dismiss") {
                        viewModel.dismissSuggestion(suggestion.id)
                        toasts.show("Suggestion dismissed", kind: .info)
                    }
                    .buttonStyle(.borderless)
                    .clickableCursor()
                    Button("Add") {
                        viewModel.acceptSuggestion(suggestion.id, as: suggestion.kind)
                        toasts.show("Added to dictionary")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .controlSize(.small)
                    .clickableCursor()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func suggestionLabel(_ suggestion: MemorySuggestion) -> some View {
        if suggestion.kind == .replacement,
           !suggestion.observed.isEmpty,
           suggestion.observed.caseInsensitiveCompare(suggestion.proposed) != .orderedSame {
            HStack(spacing: 8) {
                Text(suggestion.observed)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(suggestion.proposed)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
        } else {
            Text(suggestion.proposed)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
    }

    // MARK: - Teach

    private var teachCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Teach Useful Voice")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    addWordBlock.frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider().overlay(Theme.line)
                    fixMistakeBlock.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    addWordBlock
                    Divider().overlay(Theme.line)
                    fixMistakeBlock
                }
            }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1))
    }

    private var addWordBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Add a word")
            HStack(spacing: 8) {
                TextField("Claude Code, Useful Voice, Kubernetes", text: $word)
                    .premiumInputChrome()
                    .onSubmit { addWord() }
                Button("Add") { addWord() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .clickableCursor()
                    .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Sounds like (optional)", text: $soundsLike)
                .premiumInputChrome()
                .onSubmit { addWord() }
            Text("Biases recognition and fixes casing locally.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
    }

    private var fixMistakeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Fix a mistake")
            HStack(spacing: 8) {
                TextField("Heard", text: $heard)
                    .premiumInputChrome()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                TextField("Write this", text: $replacement)
                    .premiumInputChrome()
            }
            HStack {
                Text("Learns an auto-correction for next time.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Learn") { addCorrection() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .clickableCursor()
                    .disabled(correctionDisabled)
            }
        }
    }

    private var correctionDisabled: Bool {
        heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Library

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandedSegmentedControl(
                    selection: $section,
                    options: DictionarySection.allCases.map { ($0.title, $0) }
                )
                .frame(maxWidth: 380)

                PremiumSearchField(placeholder: "Search", text: $viewModel.query)
                    .frame(maxWidth: 280)
                Spacer(minLength: 0)
                Text("\(entryCount)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceSubtle, in: Capsule())
            }

            switch section {
            case .words:
                entriesList(
                    emptyTitle: "No words yet",
                    emptyDetail: "Add names and specialist terms you want spelled exactly."
                ) {
                    ForEach(viewModel.filteredTerms) { term in
                        MemoryTermRow(term: term) {
                            viewModel.removeTerm(id: term.id)
                            toasts.show("Word removed", kind: .info)
                        }
                    }
                }
            case .corrections:
                entriesList(
                    emptyTitle: "No auto-corrections yet",
                    emptyDetail: "Teach a mistake once. Useful Voice fixes it on every future dictation."
                ) {
                    ForEach(viewModel.filteredReplacements) { rule in
                        ReplacementRuleRow(
                            rule: rule,
                            onToggleEnabled: {
                                let next = !rule.isEnabled
                                viewModel.setReplacementEnabled(rule.id, isEnabled: next)
                                toasts.show(next ? "Correction resumed" : "Correction paused", kind: .info)
                            },
                            onDelete: {
                                viewModel.removeReplacement(id: rule.id)
                                toasts.show("Correction removed", kind: .info)
                            }
                        )
                    }
                }
            case .shortcuts:
                shortcutsContent
            }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1))
    }

    private var entryCount: Int {
        switch section {
        case .words: return viewModel.filteredTerms.count
        case .corrections: return viewModel.filteredReplacements.count
        case .shortcuts: return viewModel.filteredSnippets.count
        }
    }

    @ViewBuilder
    private func entriesList<Content: View>(
        emptyTitle: String,
        emptyDetail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if entryCount == 0 && viewModel.query.isEmpty {
            CommandEmptyState(icon: "character.book.closed", title: emptyTitle, detail: emptyDetail)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else if entryCount == 0 {
            CommandEmptyState(
                icon: "magnifyingglass",
                title: "No matches",
                detail: "Try a shorter word or a different spelling."
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                content()
            }
            .background(Theme.surfaceSubtle.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Say a short trigger to expand reusable text.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)

            HStack(spacing: 8) {
                TextField("Trigger", text: $snippetTrigger).premiumInputChrome()
                TextField("Expanded text", text: $snippetExpansion).premiumInputChrome()
                Button("Add") {
                    viewModel.addSnippet(trigger: snippetTrigger, expansion: snippetExpansion)
                    snippetTrigger = ""
                    snippetExpansion = ""
                    toasts.show("Shortcut saved")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .clickableCursor()
                .disabled(snippetTrigger.isEmpty || snippetExpansion.isEmpty)
            }

            if viewModel.filteredSnippets.isEmpty {
                Text(viewModel.query.isEmpty ? "No shortcuts yet." : "No matching shortcuts.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.filteredSnippets) { snippet in
                        MemorySnippetRow(
                            snippet: snippet,
                            onToggleEnabled: {
                                let next = !snippet.isEnabled
                                viewModel.setSnippetEnabled(snippet.id, isEnabled: next)
                                toasts.show(next ? "Shortcut resumed" : "Shortcut paused", kind: .info)
                            },
                            onDelete: {
                                viewModel.removeSnippet(id: snippet.id)
                                toasts.show("Shortcut removed", kind: .info)
                            }
                        )
                        .padding(.horizontal, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    }
                }
                .background(Theme.surfaceSubtle.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
            }
        }
    }

    // MARK: - Import

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import dictionary")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.ink)

            BrandedSegmentedControl(
                selection: $importKind,
                options: ImportKind.allCases.map { ($0.title, $0) }
            )

            TextEditor(text: $importText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
                .frame(minHeight: 230)

            if !importMessage.isEmpty {
                Text(importMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(importMessage.hasPrefix("Imported") ? Theme.success : Theme.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { showImport = false }
                    .clickableCursor()
                Button("Import") { performImport() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .clickableCursor()
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
        .background(Theme.surface)
    }

    // MARK: - Actions

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.muted)
    }

    private func addWord() {
        let phrase = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        let pronunciations = split(soundsLike)
        viewModel.addTerm(
            phrase: phrase,
            pronunciations: pronunciations,
            aliases: [],
            priority: .high,
            language: .auto,
            notes: ""
        )
        word = ""
        soundsLike = ""
        section = .words
        if pronunciations.isEmpty {
            toasts.show("Added “\(phrase)”")
        } else {
            toasts.show("Added “\(phrase)” with sound-alike fixes")
        }
    }

    private func addCorrection() {
        let result = viewModel.learnCorrection(observed: heard, corrected: replacement)
        guard !result.pairs.isEmpty else { return }
        heard = ""
        replacement = ""
        section = .corrections
        let n = result.replacementCount
        if n == 0 {
            toasts.show("Saved as a dictionary word")
        } else {
            toasts.show(n == 1 ? "Correction learned" : "\(n) corrections learned")
        }
    }

    private func performImport() {
        switch importKind {
        case .json:
            guard let result = viewModel.importSnapshotJSON(importText) else {
                importMessage = "The JSON backup could not be read."
                return
            }
            importMessage = resultMessage(result)
            toasts.show("Dictionary imported")
        case .wordsCSV:
            importMessage = resultMessage(viewModel.importTermsCSV(importText))
            toasts.show("Words imported")
        case .correctionsCSV:
            importMessage = resultMessage(viewModel.importReplacementsCSV(importText))
            toasts.show("Corrections imported")
        }
    }

    private func resultMessage(_ result: LanguageMemoryImportResult) -> String {
        "Imported \(result.inserted) new and updated \(result.updated). \(result.duplicates) duplicates skipped."
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func copy(_ value: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        toasts.show(toast)
    }
}

private enum DictionarySection: String, CaseIterable, Identifiable {
    case words, corrections, shortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: return "Words"
        case .corrections: return "Fixes"
        case .shortcuts: return "Shortcuts"
        }
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
