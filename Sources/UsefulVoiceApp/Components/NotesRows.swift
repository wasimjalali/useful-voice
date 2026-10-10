import SwiftUI
import UsefulVoiceCore

/// Number and time wording shared by the Notes and Vocabulary pages: German-region
/// grouping (1.234) and the board's short relative times ("1 min ago", "3 wk ago").
enum NotesFormat {
    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()

    static func count(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func words(_ value: Int) -> String {
        "\(count(value)) \(value == 1 ? "word" : "words")"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        if days < 7 { return "\(days) d ago" }
        if days < 30 { return "\(days / 7) wk ago" }
        if days < 365 { return "\(days / 30) mo ago" }
        return "\(days / 365) y ago"
    }
}

/// One note in the 260 pt list: title, first line, then words and age. The selected
/// row carries a 2 pt ink bar on its leading edge as well as a tint.
struct NotesListRow: View {
    let note: ScratchpadNote
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if note.isPinned {
                        Image(systemName: "pin")
                            .font(.uv(.label, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Text(title)
                        .font(.uv(.ui, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                if let line = firstLine {
                    Text(line)
                        .font(.uv(.ui))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No text yet")
                        .font(.uv(.ui))
                        .italic()
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
                Text("\(NotesFormat.words(note.wordCount)) \u{00B7} \(NotesFormat.relative(note.updatedAt))")
                    .font(.uv(.meta).monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.sunken : (hovering ? Theme.sunken.opacity(0.5) : Color.clear))
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Theme.ink).frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .clickableCursor()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var title: String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private var firstLine: String? {
        note.body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// Tags as chips with an "Add tag" field after them. Plain text in, plain text out:
/// the page stores the tags as its comma separated draft.
struct NotesTagBar: View {
    let tags: [String]
    let onChange: ([String]) -> Void

    @State private var newTag = ""

    /// Each tag once, in order: a duplicate would break the chip identity.
    private var shownTags: [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(shownTags, id: \.self) { tag in
                NotesTagChip(tag: tag) {
                    onChange(shownTags.filter { $0 != tag })
                }
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.plain)
                .font(.uv(.ui))
                .foregroundStyle(Theme.ink)
                .frame(width: 96)
                .onSubmit(commit)
                // Tags are stored comma separated, so a comma can never be part of one.
                .onChange(of: newTag) { _, value in
                    if value.contains(",") { newTag = value.replacingOccurrences(of: ",", with: "") }
                }
            Spacer(minLength: 0)
        }
    }

    private func commit() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        onChange(shownTags + [tag])
    }
}

/// A tag chip. Its remove button shows on hover and on keyboard focus.
private struct NotesTagChip: View {
    let tag: String
    let onRemove: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.uv(.meta))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            if hovering || focused {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.uv(.label, .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focused)
                .clickableCursor()
                .help("Remove tag")
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.sunken, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.edge, lineWidth: 1))
        .onHover { hovering = $0 }
    }
}

/// The "..." menu used in the page headers and the note toolbar: a quiet 30 pt icon
/// button with the wash a hover gives every icon button.
struct PageMoreMenu<Content: View>: View {
    let help: String
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.uv(.ui, .semibold))
                .foregroundStyle(hovering ? Theme.ink : Theme.inkMuted)
                .frame(width: 30, height: 30)
                .background(hovering ? Theme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .clickableCursor()
    }
}

/// The dark "Note deleted. Undo" capsule from the board (a-84). It sits on the page
/// for five seconds after a delete.
struct NotesUndoToast: View {
    /// Names the one thing Undo brings back: always the most recent delete.
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.uv(.ui, .medium))
                .foregroundStyle(Theme.hudInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 320, alignment: .leading)
            Button(action: onUndo) {
                Text("Undo")
                    .font(.uv(.ui, .semibold))
                    .foregroundStyle(Theme.hudInk)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .accessibilityLabel("Undo")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Theme.hudSurface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .themeShadow(.pop)
    }
}
