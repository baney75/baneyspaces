import XCTest
@testable import BaneySpacesCore

/// What was there is on disk before any Dock setting changes, so a crash between the two still
/// leaves the way back (series 2, round 1).
final class MissionControlDurabilityTests: XCTestCase {
    final class Prefs: PreferenceStore {
        var values: [String: NSNumber] = [:]
        var sets = 0
        /// Runs before the first write, and `dead` stops every write after it: a crash there.
        var beforeFirstSet: (() -> Void)?
        var dead = false
        func value(_ domain: String, _ key: String) -> NSNumber? { values[domain + "/" + key] }
        func set(_ domain: String, _ key: String, _ value: NSNumber?) {
            if sets == 0 { beforeFirstSet?() }
            sets += 1
            if !dead { values[domain + "/" + key] = value }
        }
    }

    /// `flushed` is what is on disk; `saved` is only in memory until `flush()`.
    final class Record: SavedRecord {
        var saved: [String: NSNumber]?
        var flushed: [String: NSNumber]?
        var flushWorks = true
        func flush() -> Bool {
            guard flushWorks else { return false }
            flushed = saved
            return true
        }
    }

    private let prefs = Prefs(), record = Record()
    private var takeover: MissionControlTakeover { MissionControlTakeover(prefs: prefs, record: record) }
    private let flag = MissionControlTakeover.id("mcx-expose-disabled")
    private let tl = MissionControlTakeover.id("wvous-tl-corner")

    func testTheRecordIsOnDiskBeforeTheFirstDockSettingChanges() {
        prefs.values[tl] = 2
        var onDiskAtFirstWrite: [String: NSNumber]?
        prefs.beforeFirstSet = { onDiskAtFirstWrite = self.record.flushed }
        XCTAssertEqual(takeover.takeOverDurably(), .done(changed: true))
        XCTAssertNotNil(onDiskAtFirstWrite, "flushed before the first write, not after")
        XCTAssertEqual(onDiskAtFirstWrite?[tl], 2)
    }

    /// The app dies after the record is flushed and before (or part way through) the Dock
    /// settings: what is on disk is enough to put everything back.
    func testACrashBetweenTheRecordAndTheDockSettingsStillLeavesTheWayBack() {
        prefs.values[tl] = 2
        prefs.values[MissionControlTakeover.id("autohide")] = 1
        let before = prefs.values
        prefs.beforeFirstSet = { self.prefs.dead = true }   // no Dock setting is ever written
        takeover.takeOver()
        XCTAssertEqual(prefs.values, before, "the crash came before anything changed")
        // Next launch (or the launch agent): only what reached the disk is left.
        let after = Record()
        after.saved = record.flushed
        XCTAssertNotNil(after.saved)
        let restart = MissionControlTakeover(prefs: prefs, record: after)
        restart.restore()
        XCTAssertEqual(prefs.values, before)

        // The same, but the first setting did land before the crash.
        let live = Prefs(), liveRecord = Record()
        live.values = before
        var landed = 0
        live.beforeFirstSet = {}
        let t = MissionControlTakeover(prefs: live, record: liveRecord)
        t.takeOver()
        landed = live.sets
        XCTAssertGreaterThan(landed, 0)
        live.values[tl] = 2   // the corner's remap never happened
        let again = Record()
        again.saved = liveRecord.flushed
        MissionControlTakeover(prefs: live, record: again).restore()
        XCTAssertNil(live.values[flag], "the switch is gone again")
        XCTAssertEqual(live.values[tl], 2)
    }

    func testNothingIsTouchedWhenTheRecordCannotBeSaved() {
        prefs.values[tl] = 2
        record.flushWorks = false
        XCTAssertEqual(takeover.takeOverDurably(), .recordNotSaved)
        XCTAssertEqual(prefs.sets, 0, "no Dock setting written")
        XCTAssertNil(record.saved, "and no record claiming otherwise")
        XCTAssertFalse(takeover.takeOver())
        guard case .notArmed = MissionControlSetup.takeOver(takeover, arm: { nil }) else { return XCTFail("a failed save is a failed takeover") }
        XCTAssertEqual(prefs.sets, 0)
    }

    func testAnEarlierRecordSurvivesAFailedSave() {
        takeover.takeOver()
        let kept = record.saved
        prefs.values[flag] = false   // changed since: a new record would be made
        record.flushWorks = false
        XCTAssertEqual(takeover.takeOverDurably(), .recordNotSaved)
        XCTAssertEqual(record.saved, kept)
    }

    func testTheDockSwitchCanBeReadBack() {
        XCTAssertFalse(takeover.isOffAtDock)
        takeover.takeOver()
        XCTAssertTrue(takeover.isOffAtDock)
        prefs.values[flag] = nil   // `defaults delete`, a profile
        XCTAssertFalse(takeover.isOffAtDock)
    }

    // MARK: The file

    private var dir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("bs-record-\(UUID().uuidString)") }

    func testTheRecordFileRoundTripsAndReplacesTheOldOne() throws {
        let url = dir.appendingPathComponent(DurableRecord.fileName)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(DurableRecord.write([flag: true, tl: 2], to: url))
        XCTAssertEqual(DurableRecord.read(from: url), [flag: true, tl: 2])
        XCTAssertTrue(DurableRecord.write([tl: 2], to: url))
        XCTAssertEqual(DurableRecord.read(from: url), [tl: 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path), "no temporary file left")
        DurableRecord.remove(url)
        XCTAssertNil(DurableRecord.read(from: url))
    }

    func testAHalfWrittenFileIsNeverTheRecord() throws {
        let url = dir.appendingPathComponent(DurableRecord.fileName)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(DurableRecord.write([flag: true], to: url))
        // A crash during the next write leaves a partial temporary file; the record is still whole.
        try Data("<?xml version=\"1.0\"?><plist><dict><key>".utf8).write(to: url.appendingPathExtension("tmp"))
        XCTAssertEqual(DurableRecord.read(from: url), [flag: true])
        try Data("not a plist".utf8).write(to: url)
        XCTAssertNil(DurableRecord.read(from: url))
    }

    func testTheFileIsAPlistTheShellCanRead() throws {
        let url = dir.appendingPathComponent(DurableRecord.fileName)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(DurableRecord.write([tl: 2], to: url))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["read", url.deletingPathExtension().path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"com.apple.dock/wvous-tl-corner\" = 2;"), text)
    }
}
