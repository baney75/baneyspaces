import XCTest
@testable import BaneySpacesCore

/// 11-01: `BaneySpaces --render` crashed and was started again 12 times, about 13 s apart. After
/// `limit` crashes within `window` the next start stops instead.
final class CrashLoopGuardTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_793_500_000)
    private var url: URL { dir.appendingPathComponent(CrashLedgerFile.fileName) }

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("bs-crashloop-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    private func file(_ policy: CrashLoopGuard = CrashLoopGuard()) -> CrashLedgerFile { CrashLedgerFile(url: url, policy: policy) }
    private let dead: (Int32) -> Bool = { _ in false }

    /// Starts `pid` at `t0 + at` seconds after the last run died without a clean quit.
    private func crashThenStart(_ f: CrashLedgerFile, pid: Int32, at: TimeInterval) -> CrashLoopGuard.Decision {
        f.begin(pid: pid, now: t0.addingTimeInterval(at), isAlive: dead)
    }

    func testTheDefaultsAreThreeCrashesInFiveMinutes() {
        XCTAssertEqual(CrashLoopGuard(), CrashLoopGuard(limit: 3, window: 300))
        XCTAssertEqual(CrashLoopGuard(limit: nil, windowMinutes: nil), CrashLoopGuard())
        XCTAssertEqual(CrashLoopGuard(limit: 5, windowMinutes: 2), CrashLoopGuard(limit: 5, window: 120))
        XCTAssertEqual(CrashLoopGuard(limit: nil, windowMinutes: -1).window, 300, "a nonsensical window keeps the default")
    }

    func testUnderTheLimitItStarts() {
        let policy = CrashLoopGuard()
        XCTAssertEqual(policy.decide([], now: t0), .start)
        XCTAssertEqual(policy.decide([t0, t0.addingTimeInterval(13)], now: t0.addingTimeInterval(26)), .start)
    }

    func testAtTheLimitItStops() {
        let crashes = [t0, t0.addingTimeInterval(13), t0.addingTimeInterval(26)]
        XCTAssertEqual(CrashLoopGuard().decide(crashes, now: t0.addingTimeInterval(39)), .stop(crashes: 3))
    }

    func testCrashesOlderThanTheWindowFreeTheBudget() {
        let crashes = [t0, t0.addingTimeInterval(13), t0.addingTimeInterval(26)]
        let policy = CrashLoopGuard()
        XCTAssertEqual(policy.decide(crashes, now: t0.addingTimeInterval(299)), .stop(crashes: 3))
        // The first is 300 s old: two left.
        XCTAssertEqual(policy.decide(crashes, now: t0.addingTimeInterval(300)), .start)
    }

    func testALimitOfZeroNeverStops() {
        XCTAssertEqual(CrashLoopGuard(limit: 0, window: 300).decide(Array(repeating: t0, count: 50), now: t0), .start)
    }

    func testACrashDatedInTheFutureDoesNotCount() {
        XCTAssertEqual(CrashLoopGuard(limit: 1, window: 300).decide([t0.addingTimeInterval(60)], now: t0), .start)
    }

    /// The 11-01 loop, start by start: three crashes go by, the fourth start stops.
    func testTheReportedLoopStopsAtTheFourthStart() {
        let f = file()
        XCTAssertEqual(crashThenStart(f, pid: 100, at: 0), .start, "first start, nothing to count")
        XCTAssertEqual(crashThenStart(f, pid: 101, at: 13), .start, "1 crash")
        XCTAssertEqual(crashThenStart(f, pid: 102, at: 26), .start, "2 crashes")
        XCTAssertEqual(crashThenStart(f, pid: 103, at: 39), .stop(crashes: 3))
        XCTAssertNil(f.read().running, "a stopped start isn't a run")
        // Still stopped while a relauncher keeps trying: a stopped start doesn't crash.
        XCTAssertEqual(crashThenStart(f, pid: 104, at: 52), .stop(crashes: 3))
        // Five minutes after the first crash the budget frees up.
        XCTAssertEqual(crashThenStart(f, pid: 105, at: 13 + 300), .start)
    }

    func testACleanQuitIsNotACrash() {
        let f = file()
        for (i, pid) in (200...210).enumerated() {
            XCTAssertEqual(f.begin(pid: Int32(pid), now: t0.addingTimeInterval(Double(i)), isAlive: dead), .start)
            f.end(pid: Int32(pid))
        }
        XCTAssertEqual(f.read(), CrashLedger())
    }

    func testARunStillAliveIsNotACrash() {
        let f = file(CrashLoopGuard(limit: 1, window: 300))
        XCTAssertEqual(f.begin(pid: 300, now: t0, isAlive: dead), .start)
        XCTAssertEqual(f.begin(pid: 301, now: t0.addingTimeInterval(1), isAlive: { $0 == 300 }), .start)
        XCTAssertEqual(f.read().crashes, [])
    }

    func testStartAnywayForgivesTheCrashes() {
        let f = file(CrashLoopGuard(limit: 1, window: 300))
        _ = crashThenStart(f, pid: 400, at: 0)
        XCTAssertEqual(crashThenStart(f, pid: 401, at: 1), .stop(crashes: 1))
        f.forgive()
        XCTAssertEqual(crashThenStart(f, pid: 401, at: 2), .start)
    }

    func testTheLedgerRoundTrips() {
        let f = file()
        let ledger = CrashLedger(crashes: [t0, t0.addingTimeInterval(13)], running: .init(pid: 42, started: t0.addingTimeInterval(20)))
        XCTAssertTrue(f.write(ledger))
        XCTAssertEqual(f.read(), ledger)
        // Another process (the next launch) reads the same file.
        XCTAssertEqual(CrashLedgerFile(url: url, policy: CrashLoopGuard(limit: 9, window: 1)).read(), ledger)
    }

    func testTheLedgerKeepsOnlyCrashesThatCanStillCount() {
        let f = file()
        XCTAssertTrue(f.write(CrashLedger(crashes: [t0, t0.addingTimeInterval(1)], running: .init(pid: 1, started: t0))))
        XCTAssertEqual(f.begin(pid: 2, now: t0.addingTimeInterval(1000), isAlive: dead), .start)
        XCTAssertEqual(f.read().crashes, [t0.addingTimeInterval(1000)])
    }

    func testAMissingOrDamagedLedgerStarts() throws {
        XCTAssertEqual(file().read(), CrashLedger())
        for junk in ["", "not json", "{\"crashes\": \"x\"}", "[1,2,3]", String(repeating: "\u{0}", count: 64)] {
            try Data(junk.utf8).write(to: url)
            XCTAssertEqual(file().read(), CrashLedger(), junk)
            XCTAssertEqual(file().begin(pid: 7, now: t0, isAlive: dead), .start, junk)
            XCTAssertEqual(file().read().running?.pid, 7, "a damaged ledger is replaced by a good one")
        }
    }

    func testAnUnwritableLedgerStillStarts() {
        let f = CrashLedgerFile(url: URL(fileURLWithPath: "/dev/null/no/\(CrashLedgerFile.fileName)"), policy: CrashLoopGuard())
        XCTAssertEqual(f.begin(pid: 1, now: t0, isAlive: dead), .start)
    }
}
