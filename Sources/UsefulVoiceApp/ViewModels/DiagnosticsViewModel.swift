import Foundation
import UsefulVoiceCore

/// Backs the Diagnostics section in Settings.
///
/// The core `Diagnostics` type is a plain thread-safe recorder; this adapts it to
/// SwiftUI. It keeps a published snapshot rather than reading the live buffer
/// during `body`, for two reasons: the buffer is mutated from other threads, and
/// reading it on every render would re-sort the whole ring on every keystroke
/// elsewhere in Settings.
@MainActor
final class DiagnosticsViewModel: ObservableObject {
    /// Newest first, which is the order a person actually reads a log in.
    @Published private(set) var entries: [Diagnostics.Entry] = []
    @Published private(set) var copyConfirmation: String?

    /// How many entries the section shows. The log keeps more; this is a display
    /// limit so the Settings page stays scannable.
    static let displayLimit = 30

    private let diagnostics: Diagnostics

    init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
        reload()
    }

    var hasEntries: Bool { !entries.isEmpty }

    /// Number of recorded errors, which is what decides whether the section
    /// looks alarming or calm.
    var errorCount: Int {
        entries.filter { $0.level == .error }.count
    }

    func reload() {
        let all = diagnostics.entries()
        // Newest first, capped for display.
        entries = Array(all.suffix(Self.displayLimit).reversed())
    }

    /// Copies the full report (not just the displayed slice) to the clipboard.
    func copyReport() {
        let report = diagnostics.report()
        guard !report.isEmpty else {
            copyConfirmation = "Nothing to copy"
            return
        }
        // `marker: false` on purpose: the delivery marker means "this clipboard
        // content is our dictation", and a diagnostics report is not one. Marking
        // it would let the paste-verification path treat it as a pending delivery.
        let wrote = Clipboard.writeString(report, marker: false)
        copyConfirmation = wrote
            ? "Copied \(entries.count) of \(diagnostics.entries().count) entries"
            : "Could not copy to the clipboard"
    }

    func clear() {
        diagnostics.clear()
        reload()
        copyConfirmation = "Cleared"
    }

    func dismissConfirmation() {
        copyConfirmation = nil
    }
}
