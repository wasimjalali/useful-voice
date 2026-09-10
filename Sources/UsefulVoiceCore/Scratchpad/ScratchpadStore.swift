import Foundation

/// Local note capture store for dictated thinking. Used by the app on the main
/// actor; persistence is best-effort and corruption-tolerant.
public final class ScratchpadStore {
    private let fileURL: URL
    private var notes: [ScratchpadNote]

    /// The error from the most recent failed persist, or `nil` when the last
    /// write succeeded. `save()` never discards its error: a full disk or an
    /// unwritable directory must be reportable to the user instead of leaving
    /// the UI claiming the note was saved.
    public private(set) var lastSaveError: Error?

    /// Called synchronously on the saving thread whenever a persist fails.
    /// The app layer uses this to surface the failure.
    public var onSaveFailure: ((Error) -> Void)?

    public func clearSaveError() {
        lastSaveError = nil
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            notes = []
            return
        }

        if let persisted = try? Self.decoder.decode(ScratchpadPersisted.self, from: data) {
            notes = Self.sorted(persisted.notes)
        } else if let legacy = try? Self.decoder.decode([ScratchpadNote].self, from: data) {
            notes = Self.sorted(legacy)
        } else {
            Self.backUpCorruptFile(fileURL)
            notes = []
        }
    }

    public func all() -> [ScratchpadNote] {
        Self.sorted(notes)
    }

    public func search(_ query: String) -> [ScratchpadNote] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all() }
        return all().filter { note in
            note.title.range(of: trimmed, options: .caseInsensitive) != nil ||
            note.body.range(of: trimmed, options: .caseInsensitive) != nil ||
            note.tags.contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
        }
    }

    @discardableResult
    public func captureDictation(_ text: String, createdAt: Date = Date()) -> ScratchpadNote? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return add(title: "Dictation", body: body, tags: [], createdAt: createdAt)
    }

    @discardableResult
    public func add(title: String, body: String, tags: [String], createdAt: Date) -> ScratchpadNote? {
        let normalized = Self.normalize(title: title, body: body, tags: tags)
        guard !normalized.title.isEmpty || !normalized.body.isEmpty else { return nil }
        let note = ScratchpadNote(
            title: normalized.title.isEmpty ? Self.titleFromBody(normalized.body) : normalized.title,
            body: normalized.body,
            tags: normalized.tags,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        notes.insert(note, at: 0)
        save()
        return note
    }

    public func update(_ note: ScratchpadNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let normalized = Self.normalize(title: note.title, body: note.body, tags: note.tags)
        guard !normalized.title.isEmpty || !normalized.body.isEmpty else { return }
        var copy = note
        copy.title = normalized.title.isEmpty ? Self.titleFromBody(normalized.body) : normalized.title
        copy.body = normalized.body
        copy.tags = normalized.tags
        notes[index] = copy
        save()
    }

    /// Removes a note and returns the removed note together with its index in
    /// the visible (ordered) list, so the caller can offer an undo that puts it
    /// back exactly where it was.
    @discardableResult
    public func delete(id: UUID) -> (note: ScratchpadNote, index: Int)? {
        let ordered = all()
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let note = ordered[index]
        notes.removeAll { $0.id == id }
        save()
        return (note, index)
    }

    /// Puts a deleted note back at `index` in the ordered list. Restoring an id
    /// that is already present is a no-op and returns `false`.
    @discardableResult
    public func restore(_ note: ScratchpadNote, at index: Int) -> Bool {
        guard !notes.contains(where: { $0.id == note.id }) else { return false }
        notes.insert(note, at: min(max(index, 0), notes.count))
        save()
        return true
    }

    @discardableResult
    public func duplicate(id: UUID, now: Date) -> ScratchpadNote? {
        guard let original = notes.first(where: { $0.id == id }) else { return nil }
        let copy = ScratchpadNote(
            title: "\(original.title) copy",
            body: original.body,
            tags: original.tags,
            isPinned: false,
            createdAt: now,
            updatedAt: now
        )
        notes.insert(copy, at: 0)
        save()
        return copy
    }

    public func setPinned(id: UUID, isPinned: Bool) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned = isPinned
        notes[index].updatedAt = Date()
        save()
    }

    public func markOpened(id: UUID, at date: Date = Date()) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].lastOpenedAt = date
        save()
    }

    public func exportMarkdown(id: UUID) -> String? {
        guard let note = notes.first(where: { $0.id == id }) else { return nil }
        return markdown(for: note)
    }

    public func exportAllMarkdown() -> String {
        all().map(markdown(for:)).joined(separator: "\n\n---\n\n")
    }

    public func exportAllJSON() -> String {
        let persisted = ScratchpadPersisted(
            version: ScratchpadPersisted.currentVersion,
            notes: all()
        )
        guard let data = try? Self.exportEncoder.encode(persisted) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public func importJSON(_ json: String) -> ScratchpadImportResult? {
        guard let data = json.data(using: .utf8),
              let imported = Self.decodeImportedNotes(from: data)
        else { return nil }

        let outcome = Self.merge(existing: notes, incoming: imported)
        notes = outcome.notes
        save()
        return outcome.result
    }

    /// Pure merge of an imported backup into the local notes, extracted from
    /// the import path so the non-destructive rule is directly testable.
    ///
    /// A record whose id already exists locally is only adopted when it is
    /// strictly newer by `updatedAt`; otherwise the newer local edit is kept
    /// and counted in `keptLocal`. Records with unknown ids are inserted, and
    /// records that fail validation are reported in `invalid`.
    public static func merge(existing: [ScratchpadNote],
                             incoming: [ScratchpadNote]) -> ScratchpadMergeOutcome {
        var merged = existing
        var inserted = 0
        var updated = 0
        var keptLocal = 0
        var invalid: [String] = []

        for note in incoming {
            guard let normalized = Self.normalized(note) else {
                invalid.append(note.id.uuidString)
                continue
            }
            if let index = merged.firstIndex(where: { $0.id == normalized.id }) {
                if normalized.updatedAt > merged[index].updatedAt {
                    merged[index] = normalized
                    updated += 1
                } else {
                    keptLocal += 1
                }
            } else {
                merged.append(normalized)
                inserted += 1
            }
        }

        return ScratchpadMergeOutcome(
            notes: Self.sorted(merged),
            result: ScratchpadImportResult(
                inserted: inserted,
                updated: updated,
                keptLocal: keptLocal,
                invalid: invalid
            )
        )
    }

    private func markdown(for note: ScratchpadNote) -> String {
        var lines: [String] = []
        if !note.title.isEmpty {
            lines.append("# \(note.title)")
            lines.append("")
        }
        lines.append(note.body)
        if !note.tags.isEmpty {
            lines.append("")
            lines.append(note.tags.map { "#\($0)" }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private func save() {
        let persisted = ScratchpadPersisted(
            version: ScratchpadPersisted.currentVersion,
            notes: notes
        )
        do {
            let data = try Self.encoder.encode(persisted)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error
            onSaveFailure?(error)
        }
    }

    private static func normalize(title: String, body: String, tags: [String])
        -> (title: String, body: String, tags: [String]) {
        var seen = Set<String>()
        let normalizedTags = tags.compactMap { tag -> String? in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }

        return (
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: normalizedTags
        )
    }

    private static func normalized(_ note: ScratchpadNote) -> ScratchpadNote? {
        let normalized = Self.normalize(title: note.title, body: note.body, tags: note.tags)
        guard !normalized.title.isEmpty || !normalized.body.isEmpty else { return nil }
        var copy = note
        copy.title = normalized.title.isEmpty ? Self.titleFromBody(normalized.body) : normalized.title
        copy.body = normalized.body
        copy.tags = normalized.tags
        return copy
    }

    private static func titleFromBody(_ body: String) -> String {
        let firstLine = body.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }
        return String(trimmed.prefix(64))
    }

    private static func sorted(_ notes: [ScratchpadNote]) -> [ScratchpadNote] {
        notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let exportEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func decodeImportedNotes(from data: Data) -> [ScratchpadNote]? {
        if let persisted = try? decoder.decode(ScratchpadPersisted.self, from: data) {
            return persisted.notes
        }
        return try? decoder.decode([ScratchpadNote].self, from: data)
    }

    private static func backUpCorruptFile(_ url: URL) {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
