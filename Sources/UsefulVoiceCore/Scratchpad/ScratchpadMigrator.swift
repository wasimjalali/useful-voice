import Foundation

public enum ScratchpadMigrator {
    public static func migrateIfNeeded(scratchpadURL: URL,
                                       notesURL: URL) -> ScratchpadStore {
        let scratchpad = ScratchpadStore(fileURL: scratchpadURL)
        guard !FileManager.default.fileExists(atPath: scratchpadURL.path),
              FileManager.default.fileExists(atPath: notesURL.path)
        else { return scratchpad }

        let notesStore = NotesStore(fileURL: notesURL)
        for note in notesStore.all().reversed() {
            _ = scratchpad.add(
                title: title(from: note.text),
                body: note.text,
                tags: [],
                createdAt: note.createdAt
            )
        }
        return scratchpad
    }

    private static func title(from text: String) -> String {
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }
        return String(trimmed.prefix(64))
    }
}
