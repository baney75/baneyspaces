import XCTest
@testable import BaneySpacesCore

/// 2026-11-01, `trace.log`: `files q=2ch places=31 kept=1000 shown=5 ms=1299`, then `ms=3103`: the
/// launcher's file search took 1.3–3.1 s for two letters (4.0 and 6.9 s for earlier ones). Targets:
/// apps shown in under 16 ms, files streamed in under 100 ms (p90), a query stopped by the next keystroke.
final class FileSearchFlowTests: XCTestCase {
    private let home = "/Users/donovan"

    // MARK: Fakes

    /// Runs scheduled work only when told to, and counts what was stopped.
    private final class Clock {
        var pending: [(id: Int, work: () -> Void)] = []
        var stopped = 0
        private var next = 0
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> FileSearchFlow.Cancel {
            next += 1
            let id = next
            pending.append((id, work))
            return { [self] in
                if pending.contains(where: { $0.id == id }) { stopped += 1 }
                pending.removeAll { $0.id == id }
            }
        }
        func fire() {
            let due = pending
            pending = []
            due.forEach { $0.work() }
        }
    }

    /// A Spotlight that answers when told to.
    private final class Spotlight {
        var started: [String] = []
        var stopped: [String] = []
        var answers: [String: ([FileSearch.Hit]?) -> Void] = [:]
        func start(_ text: String, _ done: @escaping ([FileSearch.Hit]?) -> Void) -> FileSearchFlow.Cancel {
            started.append(text)
            answers[text] = done
            return { [self] in stopped.append(text) }
        }
    }

    private func hit(_ name: String, in folder: String = "Documents", used: Date? = nil) -> FileSearch.Hit {
        FileSearch.Hit(name: name, path: "\(home)/\(folder)/\(name)", lastUsed: used)
    }

    private func flow(_ clock: Clock, _ spotlight: Spotlight, warm: [FileSearch.Hit] = []) -> FileSearchFlow {
        let index = FileWarmIndex(warm, home: home)
        return FileSearchFlow(home: home, warm: { index }, schedule: clock.schedule, query: spotlight.start)
    }

    // MARK: Order

    func testTheWarmAnswerComesBeforeTheKeystrokeReturnsAndSpotlightsComesLater() {
        let clock = Clock(), spotlight = Spotlight()
        let f = flow(clock, spotlight, warm: [hit("Photos Notes.txt")])
        var seen: [(FileSearchFlow.Stage, [String])] = []
        f.typed("ph", limit: 5) { seen.append(($0, $1.map(\.name))) }
        XCTAssertEqual(seen.count, 1, "warm answer is synchronous")
        XCTAssertEqual(seen[0].0, .warm)
        XCTAssertEqual(seen[0].1, ["Photos Notes.txt"])
        XCTAssertTrue(spotlight.started.isEmpty, "Spotlight waits out the debounce")
        clock.fire()
        XCTAssertEqual(spotlight.started.count, 1)
        spotlight.answers[spotlight.started[0]]?([hit("Phone Bill.pdf")])
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[1].0, .spotlight)
        XCTAssertEqual(Set(seen[1].1), ["Photos Notes.txt", "Phone Bill.pdf"], "Spotlight's hits and the warm ones, ranked as one list")
    }

    /// The same file from the warm list and from Spotlight is one row.
    func testAFileInBothListsAppearsOnce() {
        let clock = Clock(), spotlight = Spotlight()
        let both = hit("Photos Notes.txt", used: Date())
        let f = flow(clock, spotlight, warm: [both])
        var last: [FileSearch.Hit] = []
        f.typed("ph", limit: 5) { s, hits in if s == .spotlight { last = hits } }
        clock.fire()
        spotlight.answers[spotlight.started[0]]?([both, hit("Phone Bill.pdf")])
        XCTAssertEqual(last.map(\.path).sorted(), [both.path, hit("Phone Bill.pdf").path].sorted())
        XCTAssertEqual(last.filter { $0.path == both.path }.count, 1)
    }

    func testTextTooShortToSearchAnswersEmptyAndStartsNothing() {
        let clock = Clock(), spotlight = Spotlight()
        let f = flow(clock, spotlight, warm: [hit("a.txt")])
        var seen: [[FileSearch.Hit]] = []
        f.typed("a", limit: 5) { seen.append($1) }
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen[0].isEmpty)
        XCTAssertTrue(clock.pending.isEmpty)
        XCTAssertTrue(spotlight.started.isEmpty)
    }

    // MARK: A query per keystroke, cancellable

    func testTheNextKeystrokeStopsTheDebounceThatHasNotRun() {
        let clock = Clock(), spotlight = Spotlight()
        let f = flow(clock, spotlight)
        f.typed("ph", limit: 5) { _, _ in }
        f.typed("pho", limit: 5) { _, _ in }
        XCTAssertEqual(clock.stopped, 1, "the first keystroke's pause was stopped")
        clock.fire()
        XCTAssertEqual(spotlight.started, ["pho"], "only the last keystroke asked Spotlight")
    }

    func testTheNextKeystrokeStopsTheQueryThatIsRunning() {
        let clock = Clock(), spotlight = Spotlight()
        let f = flow(clock, spotlight)
        f.typed("ph", limit: 5) { _, _ in }
        clock.fire()
        XCTAssertEqual(spotlight.started.count, 1)
        f.typed("pho", limit: 5) { _, _ in }
        XCTAssertEqual(spotlight.stopped, [spotlight.started[0]], "MDQueryStop on the old query, not a wait behind it")
    }

    func testAnOldQueryThatAnswersAnywayIsIgnored() {
        let clock = Clock(), spotlight = Spotlight()
        let f = flow(clock, spotlight)
        var stages: [FileSearchFlow.Stage] = []
        f.typed("ph", limit: 5) { s, _ in if s == .spotlight { stages.append(s) } }
        clock.fire()
        let old = spotlight.answers[spotlight.started[0]]
        f.typed("pho", limit: 5) { s, _ in if s == .spotlight { stages.append(s) } }
        old?([hit("Phone.txt")])
        XCTAssertTrue(stages.isEmpty, "the answer to ph arrived after pho was typed")
    }

    func testAStoppedQueryThatCallsBackWithNilEmitsNothing() {
        let clock = Clock(), spotlight = Spotlight()
        let f = flow(clock, spotlight)
        var emitted = 0
        f.typed("ph", limit: 5) { s, _ in if s == .spotlight { emitted += 1 } }
        clock.fire()
        spotlight.answers[spotlight.started[0]]?(nil)
        XCTAssertEqual(emitted, 0)
    }

    func testCancelStopsEverything() {
        let clock = Clock(), spotlight = Spotlight()
        let f = flow(clock, spotlight)
        f.typed("ph", limit: 5) { _, _ in }
        clock.fire()
        f.typed("pho", limit: 5) { _, _ in }
        f.cancel()
        XCTAssertEqual(clock.stopped, 1)
        XCTAssertEqual(spotlight.stopped.count, 1)
        clock.fire()
        XCTAssertEqual(spotlight.started.count, 1, "nothing starts after cancel")
    }

    func testTheDebounceIsShort() {
        XCTAssertLessThanOrEqual(FileSearchFlow.debounce, 0.1, "the warm answer is already up; the pause only spares Spotlight")
    }

    // MARK: Timing (the 2026-11-01 numbers were 1,299 and 3,103 ms for two letters)

    private func p90(_ samples: [Double]) -> Double { samples.sorted()[Int(Double(samples.count) * 0.9)] }

    private func timeEach(_ runs: Int = 30, _ body: () -> Void) -> [Double] {
        (0..<runs).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
    }

    func testAppsAreMatchedInUnder16MsAtP90() {
        let names = (0..<600).map { i in ["Photos", "Preview", "Pages", "Calculator", "Safari", "Ghostty", "Helium"][i % 7] + (i < 7 ? "" : " \(i)") }
        let index = AppNameIndex(names: names)
        let boost: (Int) -> Int = { $0 % 5 }
        var shown = 0
        let ms = timeEach { for q in ["ph", "p", "ma", "co"] { shown += index.rank(q, boost: boost, limit: 8).count } }
        XCTAssertGreaterThan(shown, 0)
        // The budget is a keystroke's: each of the four queries fits the frame. (A shared CI runner can be
        // slow for a moment, so the four together get four frames.)
        XCTAssertLessThan(p90(ms) / 4, 16, "p90 \(p90(ms) / 4) ms a keystroke on 600 apps")
        XCTAssertLessThan(p90(ms), 64, "p90 \(p90(ms)) ms for four keystrokes of 600 apps")
        print("apps, 600 names, four keystrokes at once: p90 \(String(format: "%.2f", p90(ms))) ms (one keystroke \(String(format: "%.2f", p90(ms) / 4)))")
    }

    func testTheNameIndexRanksLikeFuzzy() {
        let names = ["Visual Studio Code", "Code", "Safari", "Calculator", "Photos", "Pages"]
        let index = AppNameIndex(names: names)
        for q in ["co", "vsc", "sfr", "pa", "zzz"] {
            let direct = names.enumerated().compactMap { i, n in Fuzzy.score(q, n).map { (i, $0) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
            XCTAssertEqual(index.rank(q, limit: 10), direct, q)
        }
    }

    /// 6,000 recently used files (the size of the warm list), the two-letter queries that took seconds.
    func testWarmFilesAreFoundInUnder100MsAtP90() {
        let stems = ["Photos", "Project Plan", "Math Notes", "Thesis Draft", "Invoice", "Budget", "Readme", "Recipe", "Map", "Chapter"]
        let hits = (0..<6_000).map { i in
            hit("\(stems[i % stems.count]) \(i).\(["txt", "pdf", "md", "docx"][i % 4])", in: "Projects/p\(i % 40)",
                used: Date(timeIntervalSinceNow: -Double(i) * 600))
        }
        let index = FileWarmIndex(hits, home: home)
        XCTAssertEqual(index.count, 6_000)
        var found = 0
        let ms = timeEach { for q in ["ph", "ma", "pr", "re"] { found += index.lookup(q, home: home, limit: 5).count } }
        XCTAssertGreaterThan(found, 0)
        // One keystroke is one of the four lookups.
        XCTAssertLessThan(p90(ms) / 4, 100, "p90 \(p90(ms) / 4) ms a keystroke on 6,000 warm files")
        print("warm lookup, 6000 files, two letters: p90 \(String(format: "%.2f", p90(ms) / 4)) ms")
    }

    func testWarmLookupAppliesTheSpotlightRule() {
        let index = FileWarmIndex([hit("2025 Tax Return.pdf"), hit("Taxes.txt"), hit("notes.md")], home: home)
        XCTAssertEqual(Set(index.lookup("tax 2025", home: home, limit: 5).map(\.name)), ["2025 Tax Return.pdf"])
        XCTAssertEqual(Set(index.lookup("ta", home: home, limit: 5).map(\.name)), ["2025 Tax Return.pdf", "Taxes.txt"])
        XCTAssertTrue(index.lookup("t", home: home, limit: 5).isEmpty, "one letter says nothing")
    }

    func testWarmIndexDropsNoiseAndRepeats() {
        let index = FileWarmIndex([hit("a.txt"), hit("a.txt"),
                                   FileSearch.Hit(name: "x.js", path: "\(home)/Projects/node_modules/x.js"),
                                   FileSearch.Hit(name: "c.db", path: "\(home)/Library/Caches/c.db")], home: home)
        XCTAssertEqual(index.count, 1)
    }

    // MARK: The app side uses it (source check: the app target can't be imported)

    func testTheLauncherStopsQueriesAndMatchesAppsOnFoldedNames() throws {
        let launcher = try Repo.code("Sources/BaneySpaces/Launcher.swift")
        XCTAssertTrue(launcher.contains("MDQueryStop(q)"), "a stale Spotlight query is stopped, not waited behind")
        XCTAssertFalse(launcher.contains("DispatchQueue(label: \"BaneySpaces file search\""), "no serial queue to wait behind")
        XCTAssertTrue(launcher.contains("fileFlow.typed("), "files go through the flow")
        XCTAssertTrue(launcher.contains("appIndex.rank("), "apps match on the folded index, with no menu reads")
        // (The menu read itself is pinned in OpenHereTests: one place, off the main thread.)
    }
}
