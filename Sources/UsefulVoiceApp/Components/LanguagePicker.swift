import AppKit
import SwiftUI
import UsefulVoiceCore

/// A searchable, height-bounded language picker: 300 by 400 pt, a surface panel
/// with the pop shadow (the board's "Language picker").
///
/// Replaces the system `Menu` the language rows used to use. A `Menu` cannot be
/// searched or styled, and a menu of sixty languages with no way to filter them is
/// slower to use than a two-item toggle.
///
/// Layout, from the board: a focused search field, then Auto-detect and Multiple
/// languages, a hairline, and the languages by their own name with the English
/// name on the right. The current language carries a check, the row under the
/// pointer or the arrow keys is tinted, and a footer teaches the keys.
///
/// Keys work while the search field has focus: Up and Down move the highlight,
/// Return picks it and Escape calls `onCancel` (the popover closes itself).
struct LanguagePicker: View {
    @Binding var selection: LanguagePin
    /// The accessible name of the picker, for screen readers.
    var title: String = "Language"
    /// Draws the card (corner radius, edge and pop shadow). A popover already has
    /// its own chrome, so the settings control turns this off.
    var chrome = true
    /// Called when Escape is pressed. Nil leaves Escape to the host (a popover).
    var onCancel: (() -> Void)?

    static let size = CGSize(width: 300, height: 400)

    @State private var query = ""
    @State private var highlighted: String?
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    /// `initialHighlight` is a row id ("lang:de"); it defaults to the current selection.
    init(selection: Binding<LanguagePin>, title: String = "Language", chrome: Bool = true,
         onCancel: (() -> Void)? = nil, initialHighlight: String? = nil) {
        self._selection = selection
        self.title = title
        self.chrome = chrome
        self.onCancel = onCancel
        let current = selection.wrappedValue
        let selectedRow = current.isAuto || current.isMultilingual
            ? "mode:\(current.rawValue)" : "lang:\(current.rawValue)"
        self._highlighted = State(initialValue: initialHighlight ?? selectedRow)
    }

    // MARK: Rows

    private enum Row: Identifiable {
        case mode(pin: LanguagePin, title: String, symbol: String)
        case language(DeepgramLanguage)

        var id: String {
            switch self {
            case .mode(let pin, _, _): return "mode:\(pin.rawValue)"
            case .language(let language): return "lang:\(language.code)"
            }
        }

        var pin: LanguagePin {
            switch self {
            case .mode(let pin, _, _): return pin
            case .language(let language): return LanguagePin(rawValue: language.code)
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The mode rows matching the query. Filtered like language rows rather than
    /// pinned, so a filter never shows a row that does not match what was typed.
    private var modeRows: [Row] {
        let all: [Row] = [
            .mode(pin: .auto, title: "Auto-detect", symbol: "translate"),
            .mode(pin: .multilingual, title: "Multiple languages", symbol: "globe"),
        ]
        guard !trimmedQuery.isEmpty else { return all }
        return all.filter { row in
            guard case .mode(_, let title, _) = row else { return false }
            return title.lowercased().contains(trimmedQuery)
        }
    }

    /// Matches the English name, the native name and the raw code, so someone who
    /// knows the language as "Deutsch" or as "de" finds it either way.
    private var languageRows: [Row] {
        let all = DeepgramLanguageCatalog.all
        guard !trimmedQuery.isEmpty else { return all.map(Row.language) }
        return all.filter { language in
            language.name.lowercased().contains(trimmedQuery)
                || language.nativeName.lowercased().contains(trimmedQuery)
                || language.code.lowercased().contains(trimmedQuery)
        }.map(Row.language)
    }

    private var allRows: [Row] { modeRows + languageRows }

    private var selectedID: String {
        selection.isAuto || selection.isMultilingual ? "mode:\(selection.rawValue)" : "lang:\(selection.rawValue)"
    }

    // MARK: Body

    var body: some View {
        card
            .frame(width: Self.size.width, height: Self.size.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .onAppear {
                // After the window is key, or the field refuses focus.
                DispatchQueue.main.async { searchFocused = true }
                installKeys()
            }
            .onDisappear { removeKeys() }
            .onChange(of: query) { _, _ in highlighted = allRows.first?.id }
    }

    @ViewBuilder private var card: some View {
        if chrome {
            panel
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Theme.edge, lineWidth: 1))
                .themeShadow(.pop)
        } else {
            panel
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            list
            footer
        }
        .background(Theme.surface)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.uv(.ui, .medium))
                .foregroundStyle(searchFocused ? Theme.ink : Theme.inkMuted)
            TextField("Search languages", text: $query)
                .textFieldStyle(.plain)
                .font(.uv(.ui))
                .foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .onSubmit { chooseHighlighted() }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(searchFocused ? Theme.ink : Theme.controlEdge, lineWidth: 1)
        )
        .overlay {
            // The soft ring around a focused field, outside the border.
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.12), lineWidth: 3)
                .padding(-3)
                .opacity(searchFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .padding(10)
        .brandAnimation(BrandMotion.control, value: searchFocused)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(modeRows) { row in rowView(row) }
                    if !modeRows.isEmpty && !languageRows.isEmpty {
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    ForEach(languageRows) { row in rowView(row) }
                    if allRows.isEmpty { emptyState }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
            .task {
                // After the first layout pass, so the row exists to scroll to.
                try? await Task.sleep(nanoseconds: 60_000_000)
                if let id = highlighted { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func rowView(_ row: Row) -> some View {
        let isOn = row.id == selectedID
        let isHighlighted = highlighted == row.id
        return Button {
            selection = row.pin
        } label: {
            HStack(spacing: 8) {
                switch row {
                case .mode(_, let title, let symbol):
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 18)
                    Text(title)
                        .font(.uv(.ui, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                case .language(let language):
                    Text(language.nativeName)
                        .font(.uv(.ui, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    // The English name only when it adds something: "English /
                    // English" is noise in a list the person is scanning.
                    if language.nativeName != language.name {
                        Text(language.name)
                            .font(.uv(.meta))
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                    }
                }
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isHighlighted ? Theme.sunken : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = row.id } }
        .clickableCursor()
        .id(row.id)
        .accessibilityLabel(accessibilityName(row))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func accessibilityName(_ row: Row) -> String {
        switch row {
        case .mode(_, let title, _): return title
        case .language(let language): return "\(language.name), \(language.nativeName)"
        }
    }

    private var emptyState: some View {
        Text("No language matches \u{201C}\(query)\u{201D}")
            .font(.uv(.meta, .medium))
            .foregroundStyle(Theme.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            hint("\u{2191}\u{2193}", "Move")
            hint("Return", "Select")
            hint("Esc", "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .background(Theme.surface)
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            BrandKbd(key)
            Text(label)
                .font(.uv(.label))
                .foregroundStyle(Theme.inkMuted)
        }
    }

    // MARK: Keys

    private func move(_ delta: Int) {
        let rows = allRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : rows.count)
        highlighted = rows[min(max(current + delta, 0), rows.count - 1)].id
    }

    private func chooseHighlighted() {
        let rows = allRows
        guard let row = rows.first(where: { $0.id == highlighted }) ?? rows.first else { return }
        selection = row.pin
    }

    /// Arrow keys and Return reach the search field first, and a text field uses
    /// them for the caret, so they are taken here, before the field sees them.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: move(1); return nil
            case 126: move(-1); return nil
            case 36, 76: chooseHighlighted(); return nil
            case 53:
                guard let onCancel else { return event }
                onCancel()
                return nil
            default: return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// A settings row control that shows the current language and opens
/// `LanguagePicker` in a popover.
///
/// Uses a popover rather than a `Menu` because a menu is drawn by AppKit and
/// cannot be styled or searched.
struct LanguagePickerButton: View {
    @Binding var selection: LanguagePin
    @State private var isPresented = false
    @State private var hovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selection.displayName)
                    .font(.uv(.meta, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.uv(.label, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering || isPresented ? Theme.sunken : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(isPresented ? Theme.ink : Theme.controlEdge, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .brandAnimation(BrandMotion.control, value: hovering)
        .brandAnimation(BrandMotion.control, value: isPresented)
        .clickableCursor()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            LanguagePicker(selection: Binding(
                get: { selection },
                set: { selection = $0; isPresented = false }), chrome: false)
        }
        .accessibilityLabel("Language")
        .accessibilityValue(selection.displayName)
    }
}
