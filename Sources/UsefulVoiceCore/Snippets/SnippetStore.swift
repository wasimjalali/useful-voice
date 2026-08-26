import Foundation

/// Spoken-trigger expansions, persisted as JSON. Same best-effort, corruption
/// tolerant approach as DictationHistory/DictionaryStore. Used on the main actor.
public final class SnippetStore {
    private let fileURL: URL
    private var snippets: [Snippet]   // newest first

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            snippets = []
            return
        }
        if let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        } else {
            try? FileManager.default.moveItem(
                at: fileURL, to: fileURL.appendingPathExtension("bak"))
            snippets = []
        }
    }

    public func all() -> [Snippet] { snippets }

    public func add(trigger: String, expansion: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !e.isEmpty else { return }
        snippets.removeAll { $0.trigger.caseInsensitiveCompare(t) == .orderedSame }
        snippets.insert(Snippet(trigger: t, expansion: e), at: 0)
        save()
    }

    public func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
