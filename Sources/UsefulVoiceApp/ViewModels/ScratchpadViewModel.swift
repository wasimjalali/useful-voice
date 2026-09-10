import Foundation
import SwiftUI
import UsefulVoiceCore

@MainActor
final class ScratchpadViewModel: ObservableObject {
    /// Whether the last persist actually reached disk. The editor only claims
    /// "Saved" in the `.saved` case.
    enum SaveState: Equatable {
        case saved
        case failed
    }

    /// A just-deleted note plus its index in the ordered list, kept so the page
    /// can offer an undo that restores it in place.
    struct DeletedNote: Equatable {
        let note: ScratchpadNote
        let index: Int
    }

    @Published var notes: [ScratchpadNote] = []
    @Published var query = ""
    @Published var selectedID: UUID?
    @Published var draftTitle = ""
    @Published var draftBody = ""
    @Published var draftTags = ""
    @Published private(set) var saveState: SaveState = .saved
    @Published private(set) var saveError = ""
    @Published private(set) var undoableDeletion: DeletedNote?

    private let store: ScratchpadStore
    private var pendingSave: DispatchWorkItem?
    private var pendingUndoDismissal: DispatchWorkItem?

    /// How long the undo affordance stays available after a delete.
    static let undoWindow: TimeInterval = 8

    init(store: ScratchpadStore) {
        self.store = store
        // React to every failed persist, including ones the view model cannot
        // observe directly (e.g. write() failing after a synchronous mutation).
        store.onSaveFailure = { [weak self] error in
            guard let self else { return }
            self.saveState = .failed
            self.saveError = Self.message(for: error)
        }
        refresh()
        selectedID = notes.first?.id
        loadSelectedDraft()
        syncSaveState()
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
        syncSaveState()
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
        syncSaveState()
        refresh()
    }

    /// Deletes the selected note and returns what was removed so the page can
    /// offer an undo. Nothing is deleted when there is no selection.
    @discardableResult
    func deleteSelected() -> DeletedNote? {
        guard let selectedID else { return nil }
        guard let removed = store.delete(id: selectedID) else { return nil }
        syncSaveState()
        refresh()
        self.selectedID = notes.first?.id
        loadSelectedDraft()

        let deletion = DeletedNote(note: removed.note, index: removed.index)
        undoableDeletion = deletion
        scheduleUndoDismissal()
        return deletion
    }

    /// Puts the just-deleted note back where it was and re-selects it.
    func undoDelete() {
        guard let deletion = undoableDeletion else { return }
        pendingUndoDismissal?.cancel()
        store.restore(deletion.note, at: deletion.index)
        undoableDeletion = nil
        syncSaveState()
        refresh()
        selectedID = deletion.note.id
        loadSelectedDraft()
    }

    /// Dismisses the undo affordance without restoring (the delete stands).
    func dismissUndo() {
        pendingUndoDismissal?.cancel()
        undoableDeletion = nil
    }

    func duplicateSelected() {
        guard let selectedID else { return }
        let copy = store.duplicate(id: selectedID, now: Date())
        syncSaveState()
        refresh()
        self.selectedID = copy?.id ?? notes.first?.id
        loadSelectedDraft()
    }

    func setPinned(_ pinned: Bool) {
        guard let selectedID else { return }
        store.setPinned(id: selectedID, isPinned: pinned)
        syncSaveState()
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
        syncSaveState()
        refresh()
        selectedID = notes.first?.id
        loadSelectedDraft()
        return result
    }

    /// Reconciles the published save state with the store's last write result.
    /// A successful persist clears the error; a failed one keeps it visible
    /// instead of letting the UI claim the note was saved.
    private func syncSaveState() {
        if let error = store.lastSaveError {
            saveState = .failed
            saveError = Self.message(for: error)
        } else {
            saveState = .saved
            saveError = ""
        }
    }

    private static func message(for error: Error) -> String {
        "Couldn't save this note to disk. Free up space or check permissions. (\(error.localizedDescription))"
    }

    private func scheduleUndoDismissal() {
        pendingUndoDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.undoableDeletion = nil }
        }
        pendingUndoDismissal = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.undoWindow,
            execute: work
        )
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
