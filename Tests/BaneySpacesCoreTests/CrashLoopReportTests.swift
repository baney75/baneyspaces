import XCTest
@testable import BaneySpacesCore

/// The crash-loop lines in `trace.log` and the unified log are how a crash loop is read back after
/// the fact (`AGENTS.md`, Run and check), so their text is pinned here.
final class CrashLoopReportTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_793_500_000)
    private let dead: (Int32) -> Bool = { _ in false }

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("bs-crashreport-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    func testTheLaunchLineNamesTheBuildTheModeAndThePid() {
        XCTAssertEqual(CrashLoopReport.launch(build: "0.2.1 (abc1234)", mode: .normal, pid: 412),
                       "launch: BaneySpaces 0.2.1 (abc1234), normal, pid 412")
        XCTAssertEqual(CrashLoopReport.launch(build: "0.2.1", mode: .render, pid: 9),
                       "launch: BaneySpaces 0.2.1, render, pid 9")
        XCTAssertEqual(CrashLoopReport.launch(build: "0.2.1", mode: .setup, pid: 9),
                       "launch: BaneySpaces 0.2.1, setup, pid 9")
    }

    func testTheDecisionLines() {
        let policy = CrashLoopGuard()
        let ledger = "~/Library/Application Support/BaneySpaces/crash-ledger.json"
        XCTAssertEqual(CrashLoopReport.decision(.start, recent: 1, policy: policy, mode: .normal, ledger: ledger),
                       "crash loop: start (normal), 1 of 3 crashes in 5 minutes, ledger \(ledger)")
        XCTAssertEqual(CrashLoopReport.decision(.stop(crashes: 3), recent: 3, policy: policy, mode: .normal, ledger: ledger),
                       "crash loop: stop (normal), 3 crashes in 5 minutes (limit 3), not starting, ledger \(ledger)")
        XCTAssertEqual(CrashLoopReport.decision(.start, recent: 7, policy: CrashLoopGuard(limit: 0, window: 60),
                                                mode: .render, ledger: "x"),
                       "crash loop: start (render), 7 crashes in 1 minute, guard off (limit 0), ledger x")
        XCTAssertEqual(CrashLoopReport.minutes(CrashLoopGuard(limit: 3, window: 150)), "2.5 minutes")
    }

    func testTheRestoreForgiveQuitAndEndLines() {
        XCTAssertEqual(CrashLoopReport.restored(missionControl: true),
                       "crash loop: Dock and drag to the top restored, Mission Control saved settings restored")
        XCTAssertEqual(CrashLoopReport.restored(missionControl: false),
                       "crash loop: Dock and drag to the top restored, Mission Control no saved settings changed")
        XCTAssertEqual(CrashLoopReport.quit, "crash loop: Quit, staying stopped")
        XCTAssertEqual(CrashLoopReport.forgave(3), "crash loop: Start Anyway, 3 crashes forgiven")
        XCTAssertEqual(CrashLoopReport.ended(pid: 412, mode: .normal, recorded: true),
                       "crash loop: clean quit (normal), pid 412 cleared from the ledger")
        XCTAssertEqual(CrashLoopReport.ended(pid: 412, mode: .render, recorded: false),
                       "crash loop: clean quit (render), pid 412 was not in the ledger")
    }

    /// Every line starts with `crash loop: `, which is what the AGENTS.md grep looks for.
    func testEveryGuardLineSharesThePrefix() {
        let lines = [
            CrashLoopReport.decision(.start, recent: 0, policy: CrashLoopGuard(), mode: .normal, ledger: "x"),
            CrashLoopReport.decision(.stop(crashes: 3), recent: 3, policy: CrashLoopGuard(), mode: .normal, ledger: "x"),
            CrashLoopReport.restored(missionControl: true),
            CrashLoopReport.quit,
            CrashLoopReport.forgave(1),
            CrashLoopReport.ended(pid: 1, mode: .normal, recorded: true),
        ]
        for line in lines { XCTAssertTrue(line.hasPrefix("crash loop: "), line) }
    }

    func testTheLedgerPathHidesTheHomeFolder() {
        let home = "/Users/someone"
        XCTAssertEqual(CrashLoopReport.path("/Users/someone/Library/Application Support/BaneySpaces/crash-ledger.json", home: home),
                       "~/Library/Application Support/BaneySpaces/crash-ledger.json")
        XCTAssertEqual(CrashLoopReport.path("/Users/someone/x", home: home + "/"), "~/x")
        XCTAssertEqual(CrashLoopReport.path("/Users/someoneelse/x", home: home), "/Users/someoneelse/x", "only the home folder itself")
        XCTAssertEqual(CrashLoopReport.path("/tmp/x", home: ""), "/tmp/x")
    }

    /// The path the app takes on a stop, end to end through a real ledger: the lines it would log
    /// come out of the ledger's own return values.
    func testAStopThenStartAnywayThenACleanQuitReadsBackFromTheLedger() {
        let file = CrashLedgerFile(url: dir.appendingPathComponent(CrashLedgerFile.fileName), policy: CrashLoopGuard())
        for (i, pid) in [100, 101, 102].enumerated() {
            XCTAssertEqual(file.begin(pid: Int32(pid), now: t0.addingTimeInterval(Double(i) * 13), isAlive: dead), .start)
        }
        let stop = file.begin(pid: 103, now: t0.addingTimeInterval(39), isAlive: dead)
        XCTAssertEqual(CrashLoopReport.decision(stop, recent: file.read().crashes.count, policy: file.policy,
                                                mode: .normal, ledger: "L"),
                       "crash loop: stop (normal), 3 crashes in 5 minutes (limit 3), not starting, ledger L")
        XCTAssertEqual(CrashLoopReport.forgave(file.forgive()), "crash loop: Start Anyway, 3 crashes forgiven")
        let again = file.begin(pid: 103, now: t0.addingTimeInterval(40), isAlive: dead)
        XCTAssertEqual(CrashLoopReport.decision(again, recent: file.read().crashes.count, policy: file.policy,
                                                mode: .normal, ledger: "L"),
                       "crash loop: start (normal), 0 of 3 crashes in 5 minutes, ledger L")
        XCTAssertTrue(file.end(pid: 103))
        XCTAssertFalse(file.end(pid: 103), "a second end finds nothing to clear")
    }
}
