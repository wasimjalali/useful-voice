import Foundation
import SwiftUI
import UsefulVoiceCore

@MainActor
final class ScratchpadViewModel: ObservableObject {
    @Published var notes: [ScratchpadNote] = []
    @Published var query = ""
    @Published var selectedID: UUID?
    @Published var draftTitle = ""
    @Published var draftBody = ""
    @Published var draftTags = ""
    @Published var saveError = ""

    private let store: ScratchpadStore
    private var pendingSave: DispatchWorkItem?

    init(store: ScratchpadStore) {
        self.store = store
        refresh()
        selectedID = notes.first?.id
        loadSelectedDraft()
    }

    var filteredNotes: [ScratchpadNote] {
        store.search(query)
    }

    var selected: ScratchpadNote? {
        guard let selectedID else { return nil }
        return notes.first { $0.id == selectedID }
    }

    func refresh() {
        notes = store.all()
        if let selectedID, !notes.contains(where: { $0.id == selectedID }) {
            self.selectedID = notes.first?.id
        }
    }

    func select(_ id: UUID) {
        commitDraft()
        selectedID = id
        store.markOpened(id: id)
        refresh()
        loadSelectedDraft()
    }

    @discardableResult
    func createNote(title: String = "Untitled", body: String = "", tags: [String] = []) -> ScratchpadNote? {
        let note = store.add(title: title, body: body, tags: tags, createdAt: Date())
        refresh()
        if let note {
            selectedID = note.id
            loadSelectedDraft()
        }
        return note
    }

    func updateDraftTitle(_ title: String) {
        draftTitle = title
        scheduleSave()
    }

    func updateDraftBody(_ body: String) {
        draftBody = body
        scheduleSave()
    }

    func updateDraftTags(_ tags: String) {
        draftTags = tags
        scheduleSave()
    }

    func commitDraft() {
        pendingSave?.cancel()
        guard var note = selected else { return }
        note.title = draftTitle
        note.body = draftBody
        note.tags = tagsFromDraft()
        note.updatedAt = Date()
        store.update(note)
        saveError = ""
        refresh()
    }

    func deleteSelected() {
        guard let selectedID else { return }
        store.delete(id: selectedID)
        refresh()
        self.selectedID = notes.first?.id
        loadSelectedDraft()
    }

    func duplicateSelected() {
        guard let selectedID else { return }
        let copy = store.duplicate(id: selectedID, now: Date())
        refresh()
        self.selectedID = copy?.id ?? notes.first?.id
        loadSelectedDraft()
    }

    func setPinned(_ pinned: Bool) {
        guard let selectedID else { return }
        store.setPinned(id: selectedID, isPinned: pinned)
        refresh()
    }

    func appendTextToSelectedOrCreate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if selected == nil {
            _ = createNote(title: "Dictation", body: trimmed)
            return
        }
        draftBody = [draftBody, trimmed]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        commitDraft()
        loadSelectedDraft()
    }

    @discardableResult
    func createDictationNote(_ text: String) -> ScratchpadNote? {
        guard let note = store.captureDictation(text) else { return nil }
        refresh()
        selectedID = note.id
        loadSelectedDraft()
        return note
    }

    func exportMarkdownForSelected() -> String? {
        guard let selectedID else { return nil }
        return store.exportMarkdown(id: selectedID)
    }

    func exportAllMarkdown() -> String {
        store.exportAllMarkdown()
    }

    func exportAllJSON() -> String {
        store.exportAllJSON()
    }

    func importJSON(_ json: String) -> ScratchpadImportResult? {
        guard let result = store.importJSON(json) else { return nil }
        refresh()
        selectedID = notes.first?.id
        loadSelectedDraft()
        return result
    }

    private func loadSelectedDraft() {
        guard let selected else {
            draftTitle = ""
            draftBody = ""
            draftTags = ""
            return
        }
        draftTitle = selected.title
        draftBody = selected.body
        draftTags = selected.tags.joined(separator: ", ")
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.commitDraft() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func tagsFromDraft() -> [String] {
        draftTags
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
