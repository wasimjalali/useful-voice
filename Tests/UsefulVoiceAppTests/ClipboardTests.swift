import AppKit
import Testing
@testable import UsefulVoiceApp

/// What the clipboard snapshot may copy, and when a restore is refused. Each test
/// uses its own named pasteboard, never the user's real one.
@MainActor
@Suite("Clipboard snapshot")
struct ClipboardTests {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("ai.useful.voice.test.\(UUID().uuidString)"))
    }

    /// Counts how often the owner is asked for data, to prove nothing was read.
    private final class CountingProvider: NSObject, NSPasteboardItemDataProvider {
        var requests = 0
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            requests += 1
            item.setString("secret", forType: type)
        }
    }

    @Test func plainTextIsCopiedAndRestorable() {
        let pb = scratchPasteboard()
        pb.clearContents()
        pb.setString("hello", forType: .string)
        guard case .complete(let items) = Clipboard.snapshot(pb) else {
            Issue.record("expected a complete snapshot"); return
        }
        #expect(items.count == 1)
        #expect(items[0].string(forType: .string) == "hello")
    }

    @Test func concealedItemIsNeitherReadNorRestorable() {
        let pb = scratchPasteboard()
        pb.clearContents()
        let provider = CountingProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: Self.concealed)
        #expect(pb.writeObjects([item]))

        let result = Clipboard.snapshot(pb)
        guard case .incomplete = result else {
            Issue.record("expected an incomplete snapshot, got \(result)"); return
        }
        #expect(provider.requests == 0, "the concealed item's data must never be read")
        #expect(Clipboard.restorableItems(from: result) == nil)
    }

    @Test func transientItemIsNeitherReadNorRestorable() {
        let pb = scratchPasteboard()
        pb.clearContents()
        let provider = CountingProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: Self.transient)
        #expect(pb.writeObjects([item]))

        guard case .incomplete = Clipboard.snapshot(pb) else {
            Issue.record("expected an incomplete snapshot"); return
        }
        #expect(provider.requests == 0)
    }

    @Test func aConcealedItemAmongOthersTaintsTheWholeSnapshot() {
        let pb = scratchPasteboard()
        pb.clearContents()
        let plain = NSPasteboardItem()
        plain.setString("ordinary", forType: .string)
        let secret = NSPasteboardItem()
        secret.setString("hunter2", forType: .string)
        secret.setData(Data(), forType: Self.concealed)
        #expect(pb.writeObjects([plain, secret]))

        guard case .incomplete = Clipboard.snapshot(pb) else {
            Issue.record("expected an incomplete snapshot"); return
        }
    }

    @Test func aListedTypeThatCannotBeReadMakesTheSnapshotIncomplete() {
        let pb = scratchPasteboard()
        pb.clearContents()
        // A promise whose owner hands back nothing: the type is listed but has no data.
        final class EmptyProvider: NSObject, NSPasteboardItemDataProvider {
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                            provideDataForType type: NSPasteboard.PasteboardType) {}
        }
        let provider = EmptyProvider()
        let item = NSPasteboardItem()
        item.setString("kept", forType: .string)
        item.setDataProvider(provider, forTypes: [.png])
        #expect(pb.writeObjects([item]))

        let result = withExtendedLifetime(provider) { Clipboard.snapshot(pb) }
        guard case .incomplete = result else {
            Issue.record("expected an incomplete snapshot, got \(result)"); return
        }
    }

    /// End to end through delivery: a landed paste over a password-manager entry leaves
    /// the dictation on the clipboard instead of putting the secret back.
    @Test func deliveryNeverRestoresAConcealedItem() {
        let pb = scratchPasteboard()
        pb.clearContents()
        let secret = NSPasteboardItem()
        secret.setString("hunter2", forType: .string)
        secret.setData(Data(), forType: Self.concealed)
        #expect(pb.writeObjects([secret]))

        var restoreCalls = 0
        var counts = [10, 15]   // before, after the paste: grew by the 5-character payload
        let inserter = TextInserter(
            pasteboard: { pb },
            isSecureInput: { false },
            synthesizePaste: { true },
            axInsert: { _ in false },
            focusedProbe: { ("field", counts.removeFirst()) },
            restoreClipboard: { _, _, _ in restoreCalls += 1; return true },
            schedule: { _, work in work() })
        var outcome: DeliveryOutcome?
        inserter.deliver("hello") { outcome = $0 }

        #expect(outcome == .pasted)
        #expect(restoreCalls == 0)
        #expect(pb.string(forType: .string) == "hello")
    }

    @Test func emptyClipboardIsEmptyNotIncomplete() {
        let pb = scratchPasteboard()
        pb.clearContents()
        guard case .empty = Clipboard.snapshot(pb) else {
            Issue.record("expected an empty snapshot"); return
        }
    }
}
