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
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .sheet(isPresented: $showImport) { importSheet }
        .onDisappear { scratchpad.commitDraft() }
    }

    // MARK: - Header

    private var header: some View {
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
                .clickableCursor()
            }
        }
    }

    // MARK: - Workspace

    private var workspace: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 16) {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PremiumSearchField(placeholder: "Search notes", text: $scratchpad.query)
                Text("\(scratchpad.filteredNotes.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
            }

            if scratchpad.filteredNotes.isEmpty {
                CommandEmptyState(
                    icon: scratchpad.notes.isEmpty ? "note.text" : "magnifyingglass",
                    title: scratchpad.notes.isEmpty ? "No notes yet" : "No matching notes",
                    detail: scratchpad.notes.isEmpty
                        ? "Create a note or send a transcript from Library."
                        : "Try a shorter search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(scratchpad.filteredNotes) { note in
                            ScratchpadNoteRow(
                                note: note,
                                isSelected: scratchpad.selectedID == note.id,
                                onSelect: { scratchpad.select(note.id) }
                            )
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxHeight: .infinity)
    }

    private var editor: some View {
        Group {
            if let selected = scratchpad.selected {
                VStack(alignment: .leading, spacing: 0) {
                    editorToolbar(selected)
                        .padding(.bottom, 14)

                    TextField(
                        "Note title",
                        text: Binding(
                            get: { scratchpad.draftTitle },
                            set: { scratchpad.updateDraftTitle($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 10)

                    TextEditor(
                        text: Binding(
                            get: { scratchpad.draftBody },
                            set: { scratchpad.updateDraftBody($0) }
                        )
                    )
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(2)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .layoutPriority(1)

                    Divider().overlay(Theme.line).padding(.vertical, 12)

                    HStack(spacing: 12) {
                        TextField(
                            "Tags, comma separated",
                            text: Binding(
                                get: { scratchpad.draftTags },
                                set: { scratchpad.updateDraftTags($0) }
                            )
                        )
                        .premiumInputChrome()

                        Text("\(ScratchpadNote.wordCount(in: scratchpad.draftBody)) words")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                        Text("Saved")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.success)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    if !scratchpad.saveError.isEmpty {
                        Text(scratchpad.saveError)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.danger)
                            .padding(.top, 8)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                CommandEmptyState(
                    icon: "note.text",
                    title: "Select or create a note",
                    detail: "Choose a note from the list, or create one."
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
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
                Button("Delete note", role: .destructive) {
                    scratchpad.deleteSelected()
                    toasts.show("Note deleted", kind: .info)
                }
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
                    importMessage = "Imported \(result.inserted) new and updated \(result.updated)."
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
}
