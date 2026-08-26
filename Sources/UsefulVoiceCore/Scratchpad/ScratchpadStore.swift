import Foundation

/// Local note capture store for dictated thinking. Used by the app on the main
/// actor; persistence is best-effort and corruption-tolerant.
public final class ScratchpadStore {
    private let fileURL: URL
    private var notes: [ScratchpadNote]

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
        let normalized = normalize(title: title, body: body, tags: tags)
        guard !normalized.title.isEmpty || !normalized.body.isEmpty else { return nil }
        let note = ScratchpadNote(
            title: normalized.title.isEmpty ? titleFromBody(normalized.body) : normalized.title,
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
        let normalized = normalize(title: note.title, body: note.body, tags: note.tags)
        guard !normalized.title.isEmpty || !normalized.body.isEmpty else { return }
        var copy = note
        copy.title = normalized.title.isEmpty ? titleFromBody(normalized.body) : normalized.title
        copy.body = normalized.body
        copy.tags = normalized.tags
        notes[index] = copy
        save()
    }

    public func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        save()
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

        var inserted = 0
        var updated = 0
        var invalid: [String] = []

        for note in imported {
            guard let normalized = normalized(note) else {
                invalid.append(note.id.uuidString)
                continue
            }
            if let index = notes.firstIndex(where: { $0.id == normalized.id }) {
                notes[index] = normalized
                updated += 1
            } else {
                notes.append(normalized)
                inserted += 1
            }
        }

        notes = Self.sorted(notes)
        save()
        return ScratchpadImportResult(inserted: inserted, updated: updated, invalid: invalid)
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
        guard let data = try? Self.encoder.encode(persisted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private func normalize(title: String, body: String, tags: [String])
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

    private func normalized(_ note: ScratchpadNote) -> ScratchpadNote? {
        let normalized = normalize(title: note.title, body: note.body, tags: note.tags)
        guard !normalized.title.isEmpty || !normalized.body.isEmpty else { return nil }
        var copy = note
        copy.title = normalized.title.isEmpty ? titleFromBody(normalized.body) : normalized.title
        copy.body = normalized.body
        copy.tags = normalized.tags
        return copy
    }

    private func titleFromBody(_ body: String) -> String {
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
