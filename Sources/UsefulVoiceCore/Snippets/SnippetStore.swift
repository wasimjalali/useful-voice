import Foundation

/// Spoken-trigger expansions, persisted as JSON. Used on the main actor.
///
/// Reads and writes are both checked. The previous `try?`-on-both approach meant a
/// file that failed to READ was treated as an empty list, and the next save wrote
/// that emptiness over the intact file — so a transient read error silently
/// destroyed the user's snippets. Saving is now refused unless the file was
/// genuinely absent or read successfully.
public final class SnippetStore {
    private let fileURL: URL
    private var snippets: [Snippet]   // newest first
    private let failures = StoreFailureReporter(label: "Snippets")
    private let outcome: StoreLoadOutcome
    private var isWritable: Bool

    public init(fileURL: URL, diagnostics: Diagnostics = .shared) {
        self.fileURL = fileURL
        let loaded = StoreFileReader.load(from: fileURL, diagnostics: diagnostics) { data in
            try JSONDecoder().decode([Snippet].self, from: data)
        }
        self.outcome = loaded.outcome
        self.snippets = loaded.value ?? []
        self.isWritable = loaded.outcome.allowsWriting
    }

    /// Whether the file could be read at launch, and why not if it could not.
    public var loadOutcome: StoreLoadOutcome { outcome }

    /// The last write failure, or nil. Drives the UI's save indicator.
    public var lastSaveError: String? { failures.lastSaveError }

    /// Called on every write failure.
    public func onSaveFailure(_ handler: @escaping (String) -> Void) {
        failures.onSaveFailure(handler)
    }

    public func clearSaveError() {
        failures.clearSaveError()
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

    /// Persist the current state, reporting rather than swallowing any failure.
    @discardableResult
    public func save() -> Bool {
        guard isWritable else {
            // The file exists but was never read. Writing now would replace data we
            // do not have, so refuse and keep the problem visible instead.
            failures.reportSaveFailure(
                "not saving: \(loadOutcome.userFacingMessage ?? "the existing file could not be read")")
            return false
        }
        do {
            let data = try JSONEncoder().encode(snippets)
            try data.write(to: fileURL, options: .atomic)
            failures.reportSaveSuccess()
            return true
        } catch {
            failures.reportSaveFailure(error)
            return false
        }
    }

    /// Allow writing again, after the user has resolved a launch-time read problem.
    public func allowWritingAgain() {
        isWritable = true
        failures.clearSaveError()
    }
}
