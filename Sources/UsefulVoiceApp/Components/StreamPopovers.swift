import AppKit
import SwiftUI
import UsefulVoiceCore

// MARK: - Action menu

struct StreamMenuItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    var destructive = false
    let action: () -> Void
}

/// The board's menu: 32 pt rows, 10 pt radius highlight, muted icons, a danger row at
/// the end behind a hairline. Up and Down move, Return runs the row, Esc closes.
struct StreamMenuList: View {
    let items: [StreamMenuItem]
    let close: () -> Void

    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.destructive, index > 0 {
                    Divider().overlay(Theme.line).padding(.horizontal, 6).padding(.vertical, 3)
                }
                Button {
                    run(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.uv(.ui))
                            .foregroundStyle(item.destructive ? Theme.danger : Theme.inkMuted)
                            .frame(width: 16)
                        Text(item.title)
                            .font(.uv(.ui))
                            .foregroundStyle(item.destructive ? Theme.danger : Theme.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(highlighted == index ? Theme.sunken : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
                .clickableCursor()
                .accessibilityLabel(item.title)
            }
        }
        .padding(6)
        .frame(minWidth: 196)
        .background(Theme.surface)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { highlighted = (highlighted - 1 + items.count) % items.count; return .handled }
        .onKeyPress(.downArrow) { highlighted = (highlighted + 1) % items.count; return .handled }
        .onKeyPress(.return) {
            guard items.indices.contains(highlighted) else { return .ignored }
            run(items[highlighted])
            return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func run(_ item: StreamMenuItem) {
        close()
        item.action()
    }
}

// MARK: - Add to note

/// Search, the three most recent notes, New note.
struct StreamNotePicker: View {
    @ObservedObject var scratchpad: ScratchpadViewModel
    let onPick: (ScratchpadNote) -> Void
    let onNew: () -> Void

    @State private var query = ""
    @State private var hoveredID: UUID?
    @State private var newHovered = false

    private var rows: [ScratchpadNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return scratchpad.recentNotes(limit: 3) }
        return Array(scratchpad.notes
            .filter {
                $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || $0.body.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PremiumSearchField(placeholder: "Find a note", text: $query)
                .padding(.bottom, 10)
            Text(query.isEmpty ? "Recent notes" : "Notes")
                .font(.uv(.label, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            if rows.isEmpty {
                Text("No notes match")
                    .font(.uv(.ui))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
            ForEach(rows) { note in
                Button { onPick(note) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: note.isPinned ? "pin" : "note.text")
                            .font(.uv(.ui))
                            .foregroundStyle(Theme.inkMuted)
                            .frame(width: 16)
                        Text(note.title)
                            .font(.uv(.ui))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(PageFormat.relativeTime(note.updatedAt))
                            .font(.uv(.meta))
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(hoveredID == note.id ? Theme.sunken : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredID = $0 ? note.id : nil }
                .clickableCursor()
            }
            Divider().overlay(Theme.line).padding(.vertical, 6)
            Button(action: onNew) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.uv(.ui))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 16)
                    Text("New note")
                        .font(.uv(.ui))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(newHovered ? Theme.sunken : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { newHovered = $0 }
            .clickableCursor()
        }
        .padding(10)
        .frame(width: 288)
        .background(Theme.surface)
    }
}

// MARK: - Teach a fix

/// Heard (read-only), Write as (focused), Save fix. "Correct this one" needs record
/// v2, so it is preview only.
struct StreamTeachPopover: View {
    let heard: String
    let onSave: (String) -> Void
    let onCorrectOne: (String) -> Void

    @State private var writeAs: String
    @FocusState private var focused: Bool

    init(heard: String, writeAs: String = "",
         onSave: @escaping (String) -> Void, onCorrectOne: @escaping (String) -> Void) {
        self.heard = heard
        self.onSave = onSave
        self.onCorrectOne = onCorrectOne
        _writeAs = State(initialValue: writeAs)
    }

    private var trimmed: String { writeAs.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && trimmed != heard }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Teach a fix")
                .font(.uv(.ui, .semibold))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text("Heard")
                    .font(.uv(.meta))
                    .foregroundStyle(Theme.inkMuted)
                Text(heard)
                    .font(.uv(.ui))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(Theme.controlEdge, lineWidth: 1))
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Write as")
                    .font(.uv(.meta))
                    .foregroundStyle(Theme.inkMuted)
                TextField("", text: $writeAs)
                    .premiumInputChrome()
                    .focused($focused)
                    .onSubmit { if canSave { onSave(trimmed) } }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if PreviewFeatures.enabled {
                    Button("Correct this one") { onCorrectOne(trimmed) }
                        .buttonStyle(.brandSecondary)
                        .disabled(!canSave)
                }
                Button("Save fix") { onSave(trimmed) }
                    .buttonStyle(.brandPrimary)
                    .disabled(!canSave)
            }
        }
        .padding(14)
        .frame(width: 308)
        .background(Theme.surface)
        .onAppear { focused = true }
    }
}

// MARK: - Date jump

/// Days with counts and a Choose a date row.
struct StreamDateJump: View {
    let days: [StreamDay]
    let onPick: (Date) -> Void

    @State private var hoveredDay: Date?
    @State private var choosing = false
    @State private var chosen = Date()

    private var recent: [StreamDay] { Array(days.reversed().prefix(5)) }

    var body: some View {
        if choosing, let first = days.first?.day, let last = days.last?.day {
            VStack(alignment: .leading, spacing: 8) {
                Button { choosing = false } label: {
                    Label("Days", systemImage: "chevron.left")
                        .font(.uv(.ui, .medium))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .clickableCursor()
                DatePicker("Choose a date", selection: $chosen, in: first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .onChange(of: chosen) { _, date in onPick(nearest(to: date)) }
            }
            .padding(12)
            .frame(width: 252)
            .background(Theme.surface)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, day in
                    Button { onPick(day.day) } label: {
                        HStack(spacing: 10) {
                            Text(StreamFormat.dayTitle(day.day))
                                .font(.uv(.ui, hoveredDay == day.day ? .semibold : .regular))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 24)
                            Text(index == 0 ? StreamFormat.dictations(day.records.count)
                                 : StreamFormat.count(day.records.count))
                                .font(.uv(.ui))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                .fill(hoveredDay == day.day ? Theme.sunken : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredDay = $0 ? day.day : nil }
                    .clickableCursor()
                }
                Divider().overlay(Theme.line).padding(.horizontal, 6).padding(.vertical, 4)
                Button { choosing = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar")
                            .font(.uv(.ui))
                            .foregroundStyle(Theme.inkMuted)
                        Text("Choose a date")
                            .font(.uv(.ui))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
            }
            .padding(6)
            .frame(width: 228)
            .background(Theme.surface)
        }
    }

    /// The day with dictations closest to the chosen one.
    private func nearest(to date: Date) -> Date {
        let target = Calendar.current.startOfDay(for: date)
        return days.map(\.day).min { abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target)) } ?? target
    }
}

// MARK: - Toast

/// The board's toast: an always-dark capsule with the message and, when the action can be
/// taken back, Undo.
struct StreamToastView: View {
    let toast: StreamStore.Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.uv(.ui, .semibold))
                .foregroundStyle(tint)
            Text(toast.message)
                .font(.uv(.ui, .medium))
                .foregroundStyle(Theme.hudInk)
                .lineLimit(1)
            if let undo = toast.undo {
                Button {
                    dismiss()
                    undo()
                } label: {
                    Text("Undo")
                        .font(.uv(.ui, .semibold))
                        .foregroundStyle(Theme.hudInk)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, toast.undo == nil ? 18 : 8)
        .frame(minHeight: 44)
        .background(Theme.hudSurface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .themeShadow(.pop)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
    }

    private var icon: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .danger: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .success: return Theme.rgb(0x4C, 0xC3, 0x9B)
        case .info: return Theme.hudInk
        case .danger: return Theme.hudDanger
        }
    }
}

// MARK: - Delete confirmation

private struct StreamDangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uv(.ui, .semibold))
            .foregroundStyle(Theme.brandInk)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Theme.danger.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}

/// Destructive confirmation: a solid scrim, a 22 pt dialog, Cancel holding the focus
/// ring, and a danger button that names what goes.
struct StreamConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var cancelFocused: Bool

    var body: some View {
        ZStack {
            Theme.scrim
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.uv(.title, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.uv(.ui))
                    .foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.brandSecondary)
                        .controlSize(.large)
                        .focused($cancelFocused)
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(StreamDangerButtonStyle())
                        .clickableCursor()
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(width: 420)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .themeShadow(.pop)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { cancelFocused = true }
        .transition(.opacity)
    }
}

// MARK: - Multi-select bar

/// Takes the dock's place while dictations are selected.
struct StreamSelectionBar: View {
    @ObservedObject var store: StreamStore
    @State private var pickerOpen = false

    var body: some View {
        HStack(spacing: 14) {
            Text("\(store.selection.count) selected")
                .font(.uv(.body, .semibold))
                .foregroundStyle(Theme.hudInk)
            Text("Shift-click to extend, Esc to clear")
                .font(.uv(.body))
                .foregroundStyle(Theme.hudInk.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("Cancel") { store.clearSelection() }
                .buttonStyle(.plain)
                .font(.uv(.body, .semibold))
                .foregroundStyle(Theme.hudInk)
                .padding(.horizontal, 10)
                .clickableCursor()
            Button { pickerOpen = true } label: {
                Text("Add \(store.selection.count) to note")
                    .font(.uv(.body, .semibold))
                    .foregroundStyle(Color(red: 0.09, green: 0.09, blue: 0.09))
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(Theme.hudInk, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                StreamNotePicker(scratchpad: store.viewModel.scratchpad, onPick: { note in
                    pickerOpen = false
                    store.addToNote(store.selectedRecords, note: note)
                }, onNew: {
                    pickerOpen = false
                    store.addToNewNote(store.selectedRecords)
                })
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 10)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(Theme.hudSurface, in: Capsule())
        .themeShadow(.raise)
    }
}
