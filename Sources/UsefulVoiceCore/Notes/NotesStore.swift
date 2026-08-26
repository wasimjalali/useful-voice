import Foundation

/// Dictated notes, persisted as JSON. Same best-effort, corruption-tolerant
/// approach as the other stores. Used on the main actor.
public final class NotesStore {
    private let fileURL: URL
    private var notes: [Note]   // newest first

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            notes = []
            return
        }
        if let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
        } else {
            try? FileManager.default.moveItem(
                at: fileURL, to: fileURL.appendingPathExtension("bak"))
            notes = []
        }
    }

    public func all() -> [Note] { notes }

    @discardableResult
    public func add(text: String, createdAt: Date) -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = Note(text: trimmed, createdAt: createdAt)
        notes.insert(note, at: 0)
        save()
        return note
    }

    public func remove(id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    /// Replaces a note's text in place, keeping its id, createdAt and position.
    /// Blank text is rejected (same rule as `add`) so an edit can't empty a note.
    public func update(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].text = trimmed
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
