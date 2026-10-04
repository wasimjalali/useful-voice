import Testing

@testable import UsefulVoiceCore

/// Failure modes the gate must stop: an older save finishing after a newer one,
/// a removal being undone by a slow save, and a keychain read that began before a
/// write publishing its stale answer afterwards.
@Suite("Deepgram key publish gate")
struct KeyPublishGateTests {
    @Test("the newest write publishes")
    func newestWrites() {
        var gate = KeyPublishGate()
        let first = gate.beginWrite()
        #expect(gate.accepts(first))
    }

    @Test("an older save cannot publish over a newer save")
    func olderSaveDropped() {
        var gate = KeyPublishGate()
        let older = gate.beginWrite()
        let newer = gate.beginWrite()
        #expect(!gate.accepts(older))
        #expect(gate.accepts(newer))
    }

    @Test("a save cannot undo a removal requested after it")
    func removalWins() {
        var gate = KeyPublishGate()
        let save = gate.beginWrite()
        let removal = gate.beginWrite()
        #expect(!gate.accepts(save))
        #expect(gate.accepts(removal))
    }

    @Test("a read that started before a write is dropped")
    func staleReadDropped() {
        var gate = KeyPublishGate()
        let read = gate.latest
        _ = gate.beginWrite()
        #expect(!gate.accepts(read))
    }

    @Test("a read with no write since it started publishes")
    func freshReadAccepted() {
        var gate = KeyPublishGate()
        _ = gate.beginWrite()
        let read = gate.latest
        #expect(gate.accepts(read))
    }
}
