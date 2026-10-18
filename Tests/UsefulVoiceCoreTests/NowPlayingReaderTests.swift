import Testing
import Foundation
@testable import UsefulVoiceCore

/// A stand-in for the perl helper: a perl script that speaks the same protocol and misbehaves
/// the way the test asks, through a `mode` file next to it. `started` gets a line per launch.
private struct FakeHelper {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-nowplaying-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.script.write(to: directory.appendingPathComponent("uv-nowplaying.pl"), atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("libuvnowplaying.dylib"))   // never loaded by the fake
        try mode("ok")
    }

    func mode(_ value: String) throws {
        try value.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    var launches: Int {
        let text = (try? String(contentsOf: directory.appendingPathComponent("started"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static let script = """
    use strict; use warnings;
    $| = 1;
    my $dir = $0; $dir =~ s{/[^/]*$}{};
    open(my $m, '<', "$dir/mode") or die "no mode"; my $mode = <$m>; chomp $mode; close $m;
    open(my $s, '>>', "$dir/started"); print $s "x\\n"; close $s;
    exit 3 if $mode eq 'exit-before-ready';
    if ($mode eq 'never-ready') { select(undef, undef, undef, 60); exit 0; }
    print "{\\"ready\\":1}\\n";
    my $count = 0;
    while (my $line = <STDIN>) {
        $line =~ s/\\s+$//;
        if ($line =~ /^get (\\d+)$/) {
            my $id = $1; $count++;
            next if $mode eq 'never-answer';
            if ($mode eq 'slow-first' && $count == 1) {
                select(undef, undef, undef, 0.5);
                print "seq=$id {\\"playing\\":1,\\"pid\\":111,\\"bundleIdentifier\\":\\"stale\\"}\\n";
                next;
            }
            my $pid = $mode eq 'slow-first' ? 222 : 4242;
            print "seq=$id {\\"playing\\":1,\\"pid\\":$pid,\\"bundleIdentifier\\":\\"fake.app\\"}\\n";
            exit 0 if $mode eq 'die-after-1' && $count == 1;
        } elsif ($line eq 'quit') { last }
    }
    """
}

/// The date the reader's backoff looks at, moved by the test: no backoff test waits for real time.
private final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

private func makeReader(_ helper: FakeHelper,
                        verify: @escaping (URL) -> String? = { _ in nil },
                        backoff: [TimeInterval] = [30, 120],
                        readTimeout: TimeInterval = 5,
                        startTimeout: TimeInterval = 5,
                        clock: HandClock = HandClock()) -> (NowPlayingReader, Diagnostics) {
    let diagnostics = Diagnostics(directory: nil)
    let reader = NowPlayingReader(directory: helper.directory, diagnostics: diagnostics, verify: verify,
                                  backoff: backoff, readTimeout: readTimeout, startTimeout: startTimeout,
                                  clock: { clock.now() })
    return (reader, diagnostics)
}

@Suite(.serialized) struct NowPlayingReaderTests {
    @Test func aHealthyHelperAnswersWithTheStateAndBundle() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        let (reader, diagnostics) = makeReader(helper)
        let state = reader.read()
        #expect(state == NowPlayingState(isPlaying: true, pid: 4242, bundleID: "fake.app"))
        #expect(reader.read() == state)
        #expect(helper.launches == 1)   // one long-lived process serves every read
        #expect(diagnostics.entries().isEmpty)
    }

    // 1. SIGPIPE: a helper that is already gone must never be written to in a way that kills the app.

    @Test func aHelperThatExitsBeforeItIsReadyFallsBackWithoutCrashing() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        try helper.mode("exit-before-ready")
        let (reader, diagnostics) = makeReader(helper, startTimeout: 60)   // the exit has to be noticed, not waited out
        let began = Date()
        #expect(reader.read() == nil)           // stop() writes "quit" to a perl that already died: no SIGPIPE
        #expect(Date().timeIntervalSince(began) < 30)
        #expect(reader.read() == nil)           // a failed start backs off at once: no second launch
        #expect(helper.launches == 1)
        #expect(diagnostics.entries().contains { $0.category == "media" && $0.level == .warning })
    }

    // 2. A failed start backs off at once, and a start never holds the caller long.

    @Test func aHelperThatNeverBecomesReadyBacksOffAtOnceAndRetriesAfterTheFirstStep() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        try helper.mode("never-ready")
        let clock = HandClock()
        let (reader, diagnostics) = makeReader(helper, backoff: [30, 120], startTimeout: 0.3, clock: clock)
        let began = Date()
        #expect(reader.read() == nil)           // the start gives up after its timeout, not after 5 s or 30 s
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(helper.launches == 1)
        #expect(diagnostics.entries().contains { $0.message.contains("trying again in 30 s") })
        #expect(reader.read() == nil)           // backing off: nothing started
        #expect(helper.launches == 1)

        clock.advance(31)
        #expect(reader.read() == nil)           // the retry fails the same way, now for the longer step
        #expect(helper.launches == 2)
        #expect(diagnostics.entries().last?.message.contains("trying again in 120 s") == true)

        try helper.mode("ok")
        clock.advance(121)
        #expect(reader.read() != nil)           // and recovers when it can start
    }

    @Test func aReadDoesNotWaitForAWarmUpThatIsStillStartingTheHelper() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        try helper.mode("never-ready")
        let (reader, _) = makeReader(helper, startTimeout: 3)
        reader.warmUp()                          // holds the start for up to 3 s
        let deadline = Date().addingTimeInterval(20)
        while helper.launches == 0, Date() < deadline { usleep(2000) }
        let began = Date()
        #expect(reader.read() == nil)            // not ready yet: answered at once
        #expect(Date().timeIntervalSince(began) < 1.5)
    }

    @Test func warmingUpAHelperThatCannotLoadDoesNotCrashTheApp() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        try helper.mode("exit-before-ready")
        let (reader, _) = makeReader(helper)
        reader.warmUp()                          // launch, die, stop(), all in the background
        let deadline = Date().addingTimeInterval(20)
        while helper.launches == 0, Date() < deadline { usleep(5000) }
        #expect(helper.launches >= 1)
        #expect(reader.read() == nil)            // waits for the warm-up to finish: it holds the same lock
    }

    @Test func aHelperKilledBetweenReadsFailsTheNextReadAndRecovers() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        let (reader, _) = makeReader(helper)
        #expect(reader.read() != nil)
        let pid = try #require(reader.helperProcessIDForTesting)
        kill(pid, SIGKILL)
        // Reads right after the kill write to a dead pipe: with SIGPIPE this process would die here.
        for _ in 0..<10 { _ = reader.read(timeout: 0.1) }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(reader.read() != nil || reader.read() != nil)   // a new helper took over (or the third failure backed off)
    }

    @Test func aHelperThatExitsAfterOneAnswerIsReplacedByTheNextRead() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        try helper.mode("die-after-1")
        let (reader, diagnostics) = makeReader(helper)
        #expect(reader.read() != nil)
        let deadline = Date().addingTimeInterval(20)
        while let pid = reader.helperProcessIDForTesting, kill(pid, 0) == 0, Date() < deadline { usleep(5000) }
        // The dead helper is not written to, and the read starts a new one rather than failing.
        #expect(reader.read() != nil)
        #expect(helper.launches == 2)
        #expect(diagnostics.entries().isEmpty)
    }

    // A helper that never answers

    @Test func aHelperThatNeverAnswersTimesOutAndBacksOff() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        try helper.mode("never-answer")
        let clock = HandClock()
        let (reader, diagnostics) = makeReader(helper, backoff: [30], readTimeout: 0.2, clock: clock)
        for _ in 0..<3 { #expect(reader.read() == nil) }
        let launchesAfterThree = helper.launches
        #expect(reader.read() == nil)           // backing off: starts nothing
        #expect(helper.launches == launchesAfterThree)
        #expect(diagnostics.entries().contains { $0.message.contains("trying again in 30 s") })

        try helper.mode("ok")
        clock.advance(31)                       // the backoff is over: it tries again, and recovers
        #expect(reader.read() != nil)
    }

    @Test func theBackoffGrowsAndStaysAtItsLastStep() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        try helper.mode("never-answer")
        let clock = HandClock()
        let (reader, diagnostics) = makeReader(helper, backoff: [30, 120], readTimeout: 0.2, clock: clock)
        func failThreeTimes() { for _ in 0..<3 { _ = reader.read() } }
        func steps() -> [String] { diagnostics.entries().map(\.message).filter { $0.contains("trying again in") } }
        failThreeTimes()
        #expect(steps().last?.contains("in 30 s") == true)
        clock.advance(29)
        let launches = helper.launches
        #expect(reader.read() == nil)           // 29 s into 30: still waiting, nothing started
        #expect(helper.launches == launches)
        clock.advance(2)
        failThreeTimes()
        #expect(steps().last?.contains("in 120 s") == true)
        clock.advance(121)
        failThreeTimes()
        #expect(steps().last?.contains("in 120 s") == true)   // the last step repeats
        #expect(steps().count == 3)
    }

    // 3. A timed-out read's answer in flight must not be taken by the next read.

    @Test func aLateAnswerToATimedOutReadIsNotTakenForTheNextOne() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        try helper.mode("slow-first")
        let (reader, _) = makeReader(helper)
        // The first answer (pid 111) comes after 0.5 s: usually after this read gave up at 0.2 s.
        // Whether it did or not, the second read must get its own answer (pid 222), never the stale one.
        let first = reader.read(timeout: 0.2)
        let second = reader.read(timeout: 10)              // sent while the first may still be in flight
        if let first { #expect(first.pid == 111) }
        #expect(second?.pid == 222)
        #expect(second?.bundleID == "fake.app")
    }

    // 7. A helper that is not the app's own is never started.

    @Test func aHelperWhoseSignatureIsRejectedIsNeverStarted() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        let (reader, diagnostics) = makeReader(helper, verify: { _ in "signed by someone else" })
        #expect(reader.read() == nil)
        #expect(reader.read() == nil)
        reader.warmUp()
        Thread.sleep(forTimeInterval: 0.3)      // the warm-up is asynchronous: give it every chance to start something
        #expect(reader.read() == nil)
        #expect(helper.launches == 0)
        let entries = diagnostics.entries()
        #expect(entries.count == 1)                        // logged once
        #expect(entries.first?.message.contains("signed by someone else") == true)
    }

    @Test func missingHelperFilesTurnItOffWithOneLogLine() {
        let diagnostics = Diagnostics(directory: nil)
        let reader = NowPlayingReader(directory: nil, diagnostics: diagnostics)
        #expect(reader.read() == nil)
        #expect(reader.read() == nil)
        #expect(diagnostics.entries().count == 1)
    }

    @Test func aMissingPerlTurnsItOff() throws {
        let helper = try FakeHelper(); defer { helper.remove() }
        let diagnostics = Diagnostics(directory: nil)
        let reader = NowPlayingReader(directory: helper.directory, executable: URL(fileURLWithPath: "/nonexistent/perl"),
                                      diagnostics: diagnostics, verify: { _ in nil })
        #expect(reader.read() == nil)
        #expect(diagnostics.entries().count == 1)
    }

    @Test func theRealSignatureCheckRefusesAMissingFileAndANonLibrary() throws {
        #expect(HelperSignature.problem(with: URL(fileURLWithPath: "/nonexistent/libuvnowplaying.dylib")) != nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uv-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("libuvnowplaying.dylib")
        try Data("not a library".utf8).write(to: fake)
        #expect(HelperSignature.problem(with: fake) != nil)
    }
}
