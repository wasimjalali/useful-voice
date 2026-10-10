import SwiftUI
import AppKit
import UsefulVoiceCore

/// Notes: a 260 pt list on the left, the open document on the right. Notes are plain
/// text, so Markdown shows as typed. Direction is automatic per paragraph, so a
/// Persian note reads right to left while the list and toolbar stay left to right.
struct NotesPage: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    @ObservedObject var scratchpad: ScratchpadViewModel
    @EnvironmentObject private var toasts: AppToastCenter

    @State private var showImport = false
    @State private var importText = ""
    @State private var importMessage = ""

    /// How long "Note deleted. Undo" stays up.
    private static let undoSeconds: Double = 5
    /// 68 characters of 15 pt text.
    private static let measure: CGFloat = 612

    init(viewModel: UsefulVoiceViewModel) {
        self.viewModel = viewModel
        self.scratchpad = viewModel.scratchpad
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if scratchpad.notes.isEmpty {
                emptyState
            } else {
                Rectangle().fill(Theme.line).frame(height: 1)
                workspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .keepsFirstFieldUnfocused()
        .overlay(alignment: .bottomTrailing) {
            if let deletion = scratchpad.undoableDeletion {
                NotesUndoToast(message: Self.deletedMessage(deletion.note)) {
                    scratchpad.undoDelete()
                }
                .padding(20)
                .transition(.brandRise())
            }
        }
        .brandAnimation(BrandMotion.hudEnter, value: scratchpad.undoableDeletion?.note.id)
        .task(id: scratchpad.undoableDeletion?.note.id) {
            guard let id = scratchpad.undoableDeletion?.note.id else { return }
            AccessibilityNotification.Announcement("Note deleted. Undo available.").post()
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled, scratchpad.undoableDeletion?.note.id == id else { return }
            scratchpad.dismissUndo()
        }
        .sheet(isPresented: $showImport) { importSheet }
        .onDisappear { scratchpad.commitDraft() }
    }

    /// Undo covers the latest delete only (the view model keeps one), so the toast
    /// names the note it will bring back.
    private static func deletedMessage(_ note: ScratchpadNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Note deleted." : "Deleted \u{201C}\(title)\u{201D}."
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Notes")
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            PageMoreMenu(help: "Import and export") {
                Button("Copy all as Markdown") {
                    copy(scratchpad.exportAllMarkdown(), toast: "All notes copied")
                }
                Button("Copy JSON backup") {
                    copy(scratchpad.exportAllJSON(), toast: "Backup copied")
                }
                Button("Import JSON backup") {
                    importText = ""
                    importMessage = ""
                    showImport = true
                }
            }
            newNoteButton
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var newNoteButton: some View {
        Button {
            // A search that hides the new note would leave it open but unlisted.
            scratchpad.query = ""
            scratchpad.createNote()
        } label: {
            Label("New note", systemImage: "plus")
        }
        .buttonStyle(.brandPrimary)
        .keyboardShortcut("n", modifiers: .command)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No notes yet")
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
            Text("Notes keep what you want to reuse. Add the latest dictation to a note from the Stream, or start a blank one.")
                .font(.uv(.body))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("New note") {
                scratchpad.query = ""
                scratchpad.createNote()
            }
            .buttonStyle(.brandPrimary)
            .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Workspace

    private var workspace: some View {
        HStack(spacing: 0) {
            noteList
                .frame(width: 260)
            Rectangle().fill(Theme.line).frame(width: 1)
            if let selected = scratchpad.selected {
                document(selected)
            } else {
                Text("Pick a note")
                    .font(.uv(.body))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var noteList: some View {
        let filtered = scratchpad.filteredNotes
        let pinned = filtered.filter(\.isPinned)
        let others = filtered.filter { !$0.isPinned }
        return VStack(alignment: .leading, spacing: 8) {
            PremiumSearchField(placeholder: "Search notes", text: $scratchpad.query)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if filtered.isEmpty {
                Text("No matching notes")
                    .font(.uv(.ui))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !pinned.isEmpty {
                            listHeader("Pinned")
                            ForEach(pinned) { noteRow($0) }
                            if !others.isEmpty { listHeader("Notes") }
                        }
                        ForEach(others) { noteRow($0) }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func noteRow(_ note: ScratchpadNote) -> some View {
        NotesListRow(
            note: note,
            isSelected: scratchpad.selectedID == note.id,
            onSelect: { scratchpad.select(note.id) }
        )
    }

    private func listHeader(_ title: String) -> some View {
        Text(title)
            .font(.uv(.meta, .semibold))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Document

    private func document(_ selected: ScratchpadNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar(selected)
                .padding(.horizontal, 24)
                .padding(.top, 14)

            VStack(alignment: .leading, spacing: 0) {
                TextField(
                    "Title",
                    text: Binding(
                        get: { scratchpad.draftTitle },
                        set: { scratchpad.updateDraftTitle($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.48)
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 6)

                metaLine(selected)
                    .padding(.bottom, 16)

                // The editor's own text inset is 5 pt; pull it back so the text
                // lines up with the title.
                TextEditor(
                    text: Binding(
                        get: { scratchpad.draftBody },
                        set: { scratchpad.updateDraftBody($0) }
                    )
                )
                .font(.uv(.title))
                .foregroundStyle(Theme.ink)
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .padding(.leading, -5)
                .frame(minHeight: 120, maxHeight: .infinity)
                .layoutPriority(1)
            }
            .frame(maxWidth: Self.measure, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !scratchpad.saveError.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.uv(.label, .semibold))
                        .foregroundStyle(Theme.danger)
                    Text(scratchpad.saveError)
                        .font(.uv(.meta))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
            }

            Rectangle().fill(Theme.line).frame(height: 1)
            NotesTagBar(tags: draftTags) { tags in
                scratchpad.updateDraftTags(tags.joined(separator: ", "))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var draftTags: [String] {
        var seen = Set<String>()
        return scratchpad.draftTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Word count and last edit as one quiet line under the title.
    private func metaLine(_ selected: ScratchpadNote) -> some View {
        let words = ScratchpadNote.wordCount(in: scratchpad.draftBody)
        return Text("\(NotesFormat.words(words)) \u{00B7} Edited \(NotesFormat.relative(selected.updatedAt))")
            .font(.uv(.ui).monospacedDigit())
            .foregroundStyle(Theme.inkMuted)
            .lineLimit(1)
    }

    private func toolbar(_ selected: ScratchpadNote) -> some View {
        HStack(spacing: 4) {
            Button {
                scratchpad.setPinned(!selected.isPinned)
            } label: {
                Label(selected.isPinned ? "Unpin" : "Pin",
                      systemImage: selected.isPinned ? "pin.slash" : "pin")
            }

            Button {
                if let latest = viewModel.recent.first?.text {
                    scratchpad.appendTextToSelectedOrCreate(latest)
                    toasts.show("Latest dictation appended")
                }
            } label: {
                Label("Append latest dictation", systemImage: "text.append")
            }
            .disabled(viewModel.recent.isEmpty)

            Button {
                if let value = scratchpad.exportMarkdownForSelected() {
                    copy(value, toast: "Note copied")
                }
            } label: {
                Label("Copy as Markdown", systemImage: "doc.on.doc")
            }

            Spacer(minLength: 8)

            PageMoreMenu(help: "More") {
                Button("Duplicate") {
                    scratchpad.duplicateSelected()
                    toasts.show("Note duplicated")
                }
                Divider()
                Button("Delete", role: .destructive) {
                    _ = scratchpad.deleteSelected()
                }
            }
        }
        .buttonStyle(.brandGhost)
    }

    // MARK: - Import

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import notes")
                .font(.uv(.figure, .semibold))
                .foregroundStyle(Theme.ink)

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
                Button("Import") {
                    guard let result = scratchpad.importJSON(importText) else {
                        importMessage = "The JSON backup could not be read."
                        return
                    }
                    importMessage = importSummary(result)
                    toasts.show("Notes imported")
                }
                .buttonStyle(.brandPrimary)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 430)
        .background(Theme.surface)
    }

    private func copy(_ value: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        toasts.show(toast)
    }

    /// Reports what the merge actually did, including local notes that were
    /// kept because they were newer than the record in the backup.
    private func importSummary(_ result: ScratchpadImportResult) -> String {
        var parts = ["Imported \(result.inserted) new", "updated \(result.updated)"]
        if result.keptLocal > 0 {
            parts.append("kept \(result.keptLocal) newer local")
        }
        return parts.joined(separator: ", ") + "."
    }
}
