import SwiftUI
import AppKit
import UsefulVoiceCore

struct LanguageMemoryPage: View {
    @ObservedObject var viewModel: LanguageMemoryViewModel
    @EnvironmentObject private var toasts: AppToastCenter

    @State private var section: DictionarySection = .words
    @State private var languageFilter: MemoryLanguage?
    @State private var showAllSuggestions = false
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
                if let issue = viewModel.statusMessage { statusBanner(issue) }
                if !viewModel.suggestions.isEmpty { suggestions }
                libraryCard
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .pageColumn(maxWidth: 1000)
        }
        .background(Theme.surface)
        .sheet(isPresented: $showImport) { importSheet }
    }

    // MARK: - Status

    /// Shows a persistence problem plainly, in the same idiom as the scratchpad
    /// editor's save error.
    ///
    /// This exists because the store used to swallow every write failure: the page
    /// reported success while the dictionary on disk was unchanged, and a failed
    /// read was silently replaced by an empty file. A user had no way to tell that
    /// their words were not being kept.
    private func statusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text("Changes are not being saved")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if viewModel.saveIssue != nil && viewModel.loadIssue == nil {
                Button("Dismiss") { viewModel.dismissSaveIssue() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.lineStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        CommandPageHeader(
            title: "Dictionary"
        ) {
            BrandedMenuButton(help: "Import and export") {
                Button("Copy full backup") {
                    copy(viewModel.exportSnapshotJSON(), toast: "Backup copied")
                }
                Button("Copy words as CSV") {
                    copy(viewModel.exportTermsCSV(), toast: "Words CSV copied")
                }
                Button("Copy fixes as CSV") {
                    copy(viewModel.exportReplacementsCSV(), toast: "Fixes CSV copied")
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
        let all = viewModel.suggestions
        let shown = showAllSuggestions ? all : Array(all.prefix(3))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Suggestions")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(all.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                Spacer()
                if all.count > 3 {
                    Button(showAllSuggestions ? "Show fewer" : "Show all") {
                        showAllSuggestions.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .clickableCursor()
                }
            }

            ForEach(shown) { suggestion in
                HStack(spacing: 10) {
                    suggestionLabel(suggestion)
                    if suggestion.evidenceCount > 1 {
                        Text("seen \(suggestion.evidenceCount) times")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkFaint)
                    }
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
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(suggestion.proposed)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
        } else {
            Text(suggestion.proposed)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
    }

    // MARK: - Library

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            addRow
            switch section {
            case .words:
                entriesList(
                    count: shownTerms.count,
                    emptyIcon: "textformat",
                    emptyTitle: "No words yet",
                    emptyDetail: "Add names and terms to spell them right."
                ) {
                    ForEach(shownTerms) { term in
                        MemoryTermRow(term: term) {
                            viewModel.removeTerm(id: term.id)
                            toasts.show("Word removed", kind: .info)
                        }
                    }
                }
            case .fixes:
                entriesList(
                    count: shownReplacements.count,
                    emptyIcon: "arrow.left.arrow.right",
                    emptyTitle: "No fixes yet",
                    emptyDetail: "Teach a mistake once and it's fixed every time."
                ) {
                    ForEach(shownReplacements) { rule in
                        ReplacementRuleRow(
                            rule: rule,
                            onToggleEnabled: {
                                let next = !rule.isEnabled
                                viewModel.setReplacementEnabled(rule.id, isEnabled: next)
                                toasts.show(next ? "Fix resumed" : "Fix paused", kind: .info)
                            },
                            onDelete: {
                                viewModel.removeReplacement(id: rule.id)
                                toasts.show("Fix removed", kind: .info)
                            }
                        )
                    }
                }
            case .snippets:
                entriesList(
                    count: shownSnippets.count,
                    emptyIcon: "text.append",
                    emptyTitle: "No snippets yet",
                    emptyDetail: "Say a short trigger to type a longer text."
                ) {
                    ForEach(shownSnippets) { snippet in
                        MemorySnippetRow(
                            snippet: snippet,
                            onToggleEnabled: {
                                let next = !snippet.isEnabled
                                viewModel.setSnippetEnabled(snippet.id, isEnabled: next)
                                toasts.show(next ? "Snippet resumed" : "Snippet paused", kind: .info)
                            },
                            onDelete: {
                                viewModel.removeSnippet(id: snippet.id)
                                toasts.show("Snippet removed", kind: .info)
                            }
                        )
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                tabs.frame(maxWidth: 360)
                Spacer(minLength: 0)
                languagePicker.frame(width: 160)
                PremiumSearchField(placeholder: "Search", text: $viewModel.query)
                    .frame(width: 220)
            }
            VStack(alignment: .leading, spacing: 10) {
                tabs
                HStack(spacing: 10) {
                    PremiumSearchField(placeholder: "Search", text: $viewModel.query)
                    languagePicker.frame(width: 160)
                }
            }
        }
    }

    private var tabs: some View {
        BrandedSegmentedControl(
            selection: $section,
            options: DictionarySection.allCases.map { ("\($0.title) \(count(of: $0))", $0) }
        )
    }

    private var languagePicker: some View {
        BrandedMenuPicker(
            title: "All languages",
            selection: $languageFilter,
            options: [(label: "All languages", value: MemoryLanguage?.none)]
                + MemoryLanguage.allCases
                    .filter { $0 != .auto }
                    .map { (label: $0.displayName, value: Optional($0)) }
        )
    }

    // MARK: - Add row

    @ViewBuilder
    private var addRow: some View {
        switch section {
        case .words:
            HStack(spacing: 8) {
                TextField("Add a word, like Kubernetes or Useful Voice", text: $word)
                    .premiumInputChrome()
                    .onSubmit { addWord() }
                TextField("Sounds like (optional)", text: $soundsLike)
                    .premiumInputChrome()
                    .frame(maxWidth: 240)
                    .onSubmit { addWord() }
                addButton(disabled: trimmed(word).isEmpty, action: addWord)
            }
        case .fixes:
            HStack(spacing: 8) {
                TextField("Heard", text: $heard)
                    .premiumInputChrome()
                    .onSubmit { addCorrection() }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                TextField("Write this", text: $replacement)
                    .premiumInputChrome()
                    .onSubmit { addCorrection() }
                addButton(
                    disabled: trimmed(heard).isEmpty || trimmed(replacement).isEmpty,
                    action: addCorrection
                )
            }
        case .snippets:
            HStack(spacing: 8) {
                TextField("Trigger", text: $snippetTrigger)
                    .premiumInputChrome()
                    .frame(maxWidth: 240)
                    .onSubmit { addSnippet() }
                TextField("Expanded text", text: $snippetExpansion)
                    .premiumInputChrome()
                    .onSubmit { addSnippet() }
                addButton(
                    disabled: trimmed(snippetTrigger).isEmpty || trimmed(snippetExpansion).isEmpty,
                    action: addSnippet
                )
            }
        }
    }

    private func addButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button("Add", action: action)
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
            .controlSize(.large)
            .clickableCursor()
            .disabled(disabled)
    }

    // MARK: - Lists

    private func inLanguage(_ language: MemoryLanguage) -> Bool {
        guard let languageFilter else { return true }
        return language == .auto || language == languageFilter
    }

    private var shownTerms: [MemoryTerm] { viewModel.filteredTerms.filter { inLanguage($0.language) } }
    private var shownReplacements: [ReplacementRule] { viewModel.filteredReplacements.filter { inLanguage($0.language) } }
    private var shownSnippets: [MemorySnippet] { viewModel.filteredSnippets.filter { inLanguage($0.language) } }

    /// Tab counts ignore the search text so they read as totals, not matches.
    private func count(of section: DictionarySection) -> Int {
        switch section {
        case .words: return viewModel.terms.filter { inLanguage($0.language) }.count
        case .fixes: return viewModel.replacements.filter { inLanguage($0.language) }.count
        case .snippets: return viewModel.snippets.filter { inLanguage($0.language) }.count
        }
    }

    @ViewBuilder
    private func entriesList<Content: View>(
        count: Int,
        emptyIcon: String,
        emptyTitle: String,
        emptyDetail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if count > 0 {
            LazyVStack(spacing: 0) {
                content()
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        } else if viewModel.query.isEmpty && languageFilter == nil {
            CommandEmptyState(icon: emptyIcon, title: emptyTitle, detail: emptyDetail)
        } else {
            CommandEmptyState(icon: "magnifyingglass", title: "No matches", detail: "Try a different spelling.")
        }
    }

    // MARK: - Import

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import dictionary")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(Theme.ink)

            BrandedSegmentedControl(
                selection: $importKind,
                options: ImportKind.allCases.map { ($0.title, $0) }
            )

            TextEditor(text: $importText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 10))
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

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addWord() {
        let phrase = trimmed(word)
        guard !phrase.isEmpty else { return }
        let pronunciations = split(soundsLike)
        viewModel.addTerm(
            phrase: phrase,
            pronunciations: pronunciations,
            aliases: [],
            priority: .high,
            language: languageFilter ?? .auto,
            notes: ""
        )
        word = ""
        soundsLike = ""
        if pronunciations.isEmpty {
            toasts.show("Added “\(phrase)”")
        } else {
            toasts.show("Added “\(phrase)” with sound-alike fixes")
        }
    }

    private func addCorrection() {
        guard !trimmed(heard).isEmpty, !trimmed(replacement).isEmpty else { return }
        let result = viewModel.learnCorrection(observed: heard, corrected: replacement)
        guard !result.pairs.isEmpty else { return }
        heard = ""
        replacement = ""
        let n = result.replacementCount
        if n == 0 {
            toasts.show("Saved as a dictionary word")
        } else {
            toasts.show(n == 1 ? "Fix learned" : "\(n) fixes learned")
        }
    }

    private func addSnippet() {
        let trigger = trimmed(snippetTrigger)
        let expansion = trimmed(snippetExpansion)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }
        viewModel.addSnippet(trigger: trigger, expansion: expansion, language: languageFilter ?? .auto)
        snippetTrigger = ""
        snippetExpansion = ""
        toasts.show("Snippet saved")
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
            toasts.show("Fixes imported")
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
    case words, fixes, snippets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: return "Words"
        case .fixes: return "Fixes"
        case .snippets: return "Snippets"
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
