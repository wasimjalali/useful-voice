import SwiftUI
import UsefulVoiceCore

/// A searchable, height-bounded language picker.
///
/// Replaces the system `Menu` the language rows used to use. A `Menu` cannot be
/// searched or styled, which is why the language control looked like every other
/// macOS menu while the rest of the app follows the design system — and why the
/// list could not grow past three entries, since a menu of ten languages with no
/// way to filter them is slower to use than a two-item toggle.
///
/// Layout rules this follows deliberately:
/// - A **fixed maximum height** with internal scrolling, so a long list never
///   stretches the settings page or pushes the rows below it off-screen.
/// - The list is **left-aligned and full-width of the popover**, not centered, per
///   the design system's application-UI rule.
/// - Section label, hairline separators, `--sunken` hover, mono-ish code hints:
///   all from the existing token set, no new hues.
struct LanguagePicker: View {
    @Binding var selection: LanguagePin
    /// Shown above the list. Used to explain what auto-detection does where the
    /// picker is the primary control (the hotkey popup) rather than a settings row.
    var title: String = "Language"
    var showsAutoDetail: Bool = true

    /// Height of the scrolling list. Sized to show roughly seven rows before
    /// scrolling, which covers the catalogue without becoming a column.
    private let listHeight: CGFloat = 268

    @State private var query = ""
    @State private var hoveredCode: String?

    private var languages: [DeepgramLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return DeepgramLanguageCatalog.all }
        // Match the English name, the native name and the raw code, so someone who
        // knows the language as "Deutsch" or as "de" finds it either way.
        return DeepgramLanguageCatalog.all.filter { language in
            language.name.lowercased().contains(trimmed)
                || language.nativeName.lowercased().contains(trimmed)
                || language.code.lowercased().contains(trimmed)
        }
    }

    /// The mode rows (detection, code-switching) matching the current query.
    ///
    /// Filtered like language rows rather than pinned, so a filter never shows a
    /// row that does not match what was typed. Searching "German" should not leave
    /// "Detect automatically" sitting above the result.
    private var modes: [(pin: LanguagePin, detail: String)] {
        let all: [(LanguagePin, String, String)] = [
            (.auto, "Detect automatically", "Identifies the spoken language as you talk"),
            (.multilingual, "Multiple languages", "You switch language mid-sentence"),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all
            .filter { _, title, detail in
                guard !trimmed.isEmpty else { return true }
                return title.lowercased().contains(trimmed)
                    || detail.lowercased().contains(trimmed)
            }
            .map { (pin: $0.0, detail: $0.2) }
    }

    private var hasResults: Bool { !modes.isEmpty || !languages.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            search
            Divider().overlay(Theme.line)
            list
            if !hasResults { emptyState }
        }
        .frame(width: 292)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.lineStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 22, y: 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.inkFaint)
            Spacer(minLength: 0)
            if !selection.isAuto {
                Text(selection.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.inkFaint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Search

    private var search: some View {
        PremiumSearchField(placeholder: "Search languages", text: $query)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(modes, id: \.pin) { mode in
                    modeRow(mode.pin, detail: mode.detail)
                }
                if !modes.isEmpty && !languages.isEmpty {
                    Divider().overlay(Theme.line).padding(.vertical, 4)
                }
                ForEach(languages) { language in
                    languageRow(language)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(height: listHeight)
        // The list must scroll on its own; without this the popover would grow to
        // fit the catalogue and take the page with it.
        .scrollIndicators(.automatic)
    }

    /// A mode row: a two-line entry with its own explanation, visually distinct
    /// from the single-line language rows below it because it does something
    /// different rather than naming a language.
    private func modeRow(_ pin: LanguagePin, detail: String) -> some View {
        let isOn = selection == pin
        return Button {
            selection = pin
        } label: {
            HStack(alignment: .top, spacing: 9) {
                checkmark(isOn: isOn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    if showsAutoDetail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoveredCode == pin.rawValue ? Theme.sunken : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredCode = $0 ? pin.rawValue : nil }
        .clickableCursor()
        .accessibilityLabel(pin.displayName)
        .accessibilityHint(detail)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func languageRow(_ language: DeepgramLanguage) -> some View {
        let isOn = selection.rawValue == language.code
        return Button {
            selection = LanguagePin(rawValue: language.code)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                checkmark(isOn: isOn)
                Text(language.name)
                    .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                // Native name only when it adds information; "English / English"
                // is noise in a list the user is scanning.
                if language.nativeName != language.name {
                    Text(language.nativeName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(language.code)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoveredCode == language.code ? Theme.sunken : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredCode = $0 ? language.code : nil }
        .clickableCursor()
        .accessibilityLabel("\(language.name), \(language.nativeName)")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// A fixed-width gutter so labels align whether or not they are selected.
    private func checkmark(isOn: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.ink)
            .opacity(isOn ? 1 : 0)
            .frame(width: 12, alignment: .leading)
            .padding(.top, 2)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No language matches “\(query)”")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("The picker lists the languages this model can transcribe.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A settings row control that shows the current language and opens
/// `LanguagePicker` in a popover.
///
/// Uses a popover rather than a `Menu` because a menu is drawn by AppKit and
/// cannot be styled or searched — the reason the language control was the one
/// part of the page that did not match the design system.
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(hovering || isPresented ? Theme.sunken : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isPresented ? Theme.ink : Theme.lineStrong, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .clickableCursor()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            LanguagePicker(selection: $selection)
        }
        .accessibilityLabel("Language")
        .accessibilityValue(selection.displayName)
    }
}
