import SwiftUI
import AppKit
import UsefulVoiceCore

struct ScratchpadPage: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    @ObservedObject var scratchpad: ScratchpadViewModel
    @EnvironmentObject private var toasts: AppToastCenter

    @State private var showImport = false
    @State private var importText = ""
    @State private var importMessage = ""
    @State private var showDeleteConfirm = false

    init(viewModel: UsefulVoiceViewModel) {
        self.viewModel = viewModel
        self.scratchpad = viewModel.scratchpad
    }

    var body: some View {
        FillRemainingHeightLayout(spacing: 20) {
            header
            workspace
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 32)
        .pageColumn(maxWidth: 1200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .sheet(isPresented: $showImport) { importSheet }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This note will be removed. You can undo this right after.")
        }
        .onDisappear { scratchpad.commitDraft() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommandPageHeader(
                title: "Notes"
            ) {
                HStack(spacing: 8) {
                    BrandedMenuButton(help: "Import and export") {
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
                    Button("New note") {
                        scratchpad.createNote()
                        toasts.show("Note created")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .controlSize(.large)
                    .keyboardShortcut("n", modifiers: .command)
                    .clickableCursor()
                }
            }

            if let deletion = scratchpad.undoableDeletion {
                undoBar(deletion)
            }
        }
    }

    /// Inline, self-dismissing undo affordance shown right after a delete.
    /// Surface/border tokens only — undo is not a status colour.
    private func undoBar(_ deletion: ScratchpadViewModel.DeletedNote) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)

            Text(deletedLabel(deletion))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Button("Undo") {
                scratchpad.undoDelete()
                toasts.show("Note restored")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .clickableCursor()

            Button {
                scratchpad.dismissUndo()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .help("Dismiss")
            .accessibilityLabel("Dismiss undo")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.lineStrong, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(deletedLabel(deletion)). Undo available.")
    }

    private func confirmDelete() {
        guard scratchpad.deleteSelected() != nil else { return }
        toasts.show("Note deleted", kind: .info)
    }

    /// The undo bar names the note it can bring back.
    private func deletedLabel(_ deletion: ScratchpadViewModel.DeletedNote) -> String {
        let title = deletion.note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Note deleted" : "Deleted \"\(title)\""
    }

    // MARK: - Workspace

    private var workspace: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 20) {
                noteList
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 320)
                    .frame(height: geometry.size.height)
                editor
                    .frame(minWidth: 300, maxWidth: .infinity)
                    .frame(height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
    }

    private var noteList: some View {
        let filtered = scratchpad.filteredNotes
        let pinned = filtered.filter(\.isPinned)
        let others = filtered.filter { !$0.isPinned }
        return VStack(alignment: .leading, spacing: 12) {
            PremiumSearchField(placeholder: "Search notes", text: $scratchpad.query)

            if filtered.isEmpty {
                Spacer(minLength: 0)
                Text(scratchpad.notes.isEmpty ? "No notes yet" : "No matching notes")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !pinned.isEmpty {
                            listHeader("Pinned")
                            ForEach(pinned) { noteRow($0) }
                            if !others.isEmpty { listHeader("Notes") }
                        }
                        ForEach(others) { noteRow($0) }
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxHeight: .infinity)
    }

    private func noteRow(_ note: ScratchpadNote) -> some View {
        ScratchpadNoteRow(
            note: note,
            isSelected: scratchpad.selectedID == note.id,
            onSelect: { scratchpad.select(note.id) }
        )
    }

    private func listHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var editor: some View {
        Group {
            if let selected = scratchpad.selected {
                VStack(alignment: .leading, spacing: 0) {
                    editorToolbar(selected)
                        .padding(.bottom, 18)

                    TextField(
                        "Title",
                        text: Binding(
                            get: { scratchpad.draftTitle },
                            set: { scratchpad.updateDraftTitle($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 6)

                    metaLine(selected)
                        .padding(.bottom, 12)

                    TextEditor(
                        text: Binding(
                            get: { scratchpad.draftBody },
                            set: { scratchpad.updateDraftBody($0) }
                        )
                    )
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .layoutPriority(1)

                    Divider().overlay(Theme.line).padding(.vertical, 12)

                    HStack(spacing: 8) {
                        Image(systemName: "number")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.inkFaint)
                        TextField(
                            "Tags, comma separated",
                            text: Binding(
                                get: { scratchpad.draftTags },
                                set: { scratchpad.updateDraftTags($0) }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    }

                    if !scratchpad.saveError.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.danger)
                            Text(scratchpad.saveError)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                startState
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    /// Word count, last edit and save state as one quiet line under the title.
    private func metaLine(_ selected: ScratchpadNote) -> some View {
        let words = ScratchpadNote.wordCount(in: scratchpad.draftBody)
        return HStack(spacing: 6) {
            Text("\(words) \(words == 1 ? "word" : "words")")
            Text("\u{00B7}")
            Text("Edited \(PageFormat.relativeTime(selected.updatedAt))")
            if scratchpad.saveState == .saved {
                Text("\u{00B7}")
                Text("Saved")
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.inkMuted)
        .lineLimit(1)
    }

    /// Shown when no note is open. With no notes at all it says how to begin.
    private var startState: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.inkFaint)
            Text(scratchpad.notes.isEmpty ? "Write your first note" : "Pick a note")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if scratchpad.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Press Command N to start writing", systemImage: "square.and.pencil")
                    Label("Send a dictation here from Library", systemImage: "waveform")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
                Button("New note") {
                    scratchpad.createNote()
                    toasts.show("Note created")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .controlSize(.large)
                .clickableCursor()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editorToolbar(_ selected: ScratchpadNote) -> some View {
        HStack(spacing: 8) {
            toolbarChip(
                title: selected.isPinned ? "Unpin" : "Pin",
                systemImage: selected.isPinned ? "pin.slash" : "pin",
                active: selected.isPinned
            ) {
                scratchpad.setPinned(!selected.isPinned)
                toasts.show(selected.isPinned ? "Note unpinned" : "Note pinned", kind: .info)
            }

            toolbarChip(
                title: "Append latest",
                systemImage: "text.append"
            ) {
                if let latest = viewModel.recent.first?.text {
                    scratchpad.appendTextToSelectedOrCreate(latest)
                    toasts.show("Latest dictation appended")
                }
            }
            .disabled(viewModel.recent.isEmpty)
            .opacity(viewModel.recent.isEmpty ? 0.45 : 1)

            Spacer()

            toolbarChip(title: "Copy", systemImage: "doc.on.doc") {
                if let value = scratchpad.exportMarkdownForSelected() {
                    copy(value, toast: "Note copied")
                }
            }

            BrandedMenuButton(help: "More note actions") {
                Button("Duplicate note") {
                    scratchpad.duplicateSelected()
                    toasts.show("Note duplicated")
                }
                Button("Copy as Markdown") {
                    if let value = scratchpad.exportMarkdownForSelected() {
                        copy(value, toast: "Note copied")
                    }
                }
                Divider()
                Button("Delete note", role: .destructive) { showDeleteConfirm = true }
            }
        }
    }

    private func toolbarChip(
        title: String,
        systemImage: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.ink : Theme.inkMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? Theme.sunken : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.lineStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(title)
        .clickableCursor()
    }

    // MARK: - Import

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import notes")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(Theme.ink)

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
                Button("Import") {
                    guard let result = scratchpad.importJSON(importText) else {
                        importMessage = "The JSON backup could not be read."
                        return
                    }
                    importMessage = importSummary(result)
                    toasts.show("Notes imported")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .clickableCursor()
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
