import XCTest
@testable import BaneySpacesCore

/// macOS's Mission Control stays off while BaneySpaces' overview is in use, and every setting goes
/// back exactly as it was. Regression ledger row "macOS Mission Control still opens from the
/// trackpad/hot corner" (10-31).
final class MissionControlTakeoverTests: XCTestCase {
    final class FakePrefs: PreferenceStore {
        var values: [String: NSNumber] = [:]
        var writes: [String] = []
        func value(_ domain: String, _ key: String) -> NSNumber? { values[domain + "/" + key] }
        func set(_ domain: String, _ key: String, _ value: NSNumber?) {
            values[domain + "/" + key] = value
            writes.append(key)
        }
    }
    final class FakeRecord: SavedRecord { var saved: [String: NSNumber]? }

    let prefs = FakePrefs(), record = FakeRecord()
    var takeover: MissionControlTakeover { MissionControlTakeover(prefs: prefs, record: record) }
    let flag = MissionControlTakeover.id("mcx-expose-disabled")

    func testASettingThatWasNotThereGoesAwayAgain() {
        XCTAssertTrue(takeover.takeOver())
        XCTAssertEqual(prefs.values[flag], true)
        XCTAssertNotNil(record.saved, "the record is what says Mission Control is ours to give back")
        XCTAssertTrue(takeover.restore())
        XCTAssertNil(prefs.values[flag], "absent before, absent after")
        XCTAssertNil(record.saved)
    }

    func testAnExistingValueComesBackExactly() {
        prefs.values[flag] = false
        takeover.takeOver()
        XCTAssertEqual(prefs.values[flag], true)
        takeover.restore()
        XCTAssertEqual(prefs.values[flag], false)
    }

    func testHotCornersSetToMissionControlAreSavedRemappedAndPutBack() {
        let tl = MissionControlTakeover.id("wvous-tl-corner"), tr = MissionControlTakeover.id("wvous-tr-corner")
        let br = MissionControlTakeover.id("wvous-br-corner")
        prefs.values[tl] = 2
        prefs.values[MissionControlTakeover.id("wvous-tl-modifier")] = 1048576
        prefs.values[tr] = 5   // screen saver: not ours
        prefs.values[br] = 0
        takeover.takeOver()
        XCTAssertEqual(prefs.values[tl], 1, "no action from macOS")
        XCTAssertEqual(prefs.values[tr], 5)
        XCTAssertEqual(prefs.values[br], 0)
        XCTAssertNil(prefs.values[MissionControlTakeover.id("wvous-bl-corner")], "an unset corner stays unset")
        let answered = takeover.answeredCorners()
        XCTAssertEqual(answered.map(\.corner), [.topLeft], "only the corner that was Mission Control")
        XCTAssertEqual(answered.first?.modifiers, 1048576, "with the key macOS wanted held")
        takeover.restore()
        XCTAssertEqual(prefs.values[tl], 2)
        XCTAssertEqual(prefs.values[tr], 5)
        XCTAssertEqual(prefs.values[br], 0)
        XCTAssertTrue(takeover.answeredCorners().isEmpty)
    }

    func testRestoringPutsEverythingBackByteForByte() {
        var before = prefs.values
        before[MissionControlTakeover.id("autohide")] = 1
        before[MissionControlTakeover.id("wvous-bl-corner")] = 2
        before[MissionControlTakeover.id("wvous-bl-modifier")] = 0
        before[MissionControlTakeover.id("wvous-tr-corner")] = 5
        prefs.values = before
        takeover.takeOver()
        XCTAssertNotEqual(prefs.values, before)
        takeover.restore()
        XCTAssertEqual(prefs.values, before)
    }

    func testTakingOverTwiceKeepsTheFirstRecord() {
        prefs.values[flag] = false
        takeover.takeOver()
        let first = record.saved
        XCTAssertFalse(takeover.takeOver(), "nothing left to change")
        XCTAssertEqual(record.saved, first, "the second launch must not save BaneySpaces' own values as the person's")
        takeover.restore()
        XCTAssertEqual(prefs.values[flag], false)
    }

    func testASettingTheyChangedSinceIsTheirNewChoice() {
        prefs.values[flag] = false
        takeover.takeOver()
        // They switched Mission Control back on in the Dock's own way while BaneySpaces ran.
        prefs.values[flag] = false
        takeover.restore()
        XCTAssertEqual(prefs.values[flag], false)
        XCTAssertNil(record.saved)

        prefs.values[flag] = nil
        takeover.takeOver()
        prefs.values[flag] = 0   // off by their hand: removed, set to 0
        let writes = prefs.writes.count
        takeover.restore()
        XCTAssertEqual(prefs.values[flag], 0)
        XCTAssertEqual(prefs.writes.count, writes, "nothing written over their newer value")
    }

    func testACornerTheyChangedSinceStaysAndIsNotAnswered() {
        let tl = MissionControlTakeover.id("wvous-tl-corner")
        prefs.values[tl] = 2
        takeover.takeOver()
        prefs.values[tl] = 5
        XCTAssertTrue(takeover.answeredCorners().isEmpty, "BaneySpaces doesn't answer a corner that's now the screen saver")
        takeover.restore()
        XCTAssertEqual(prefs.values[tl], 5)
    }

    func testACornerSetToMissionControlLaterIsSavedOnTheNextLaunch() {
        let bl = MissionControlTakeover.id("wvous-bl-corner")
        takeover.takeOver()
        prefs.values[bl] = 2
        XCTAssertTrue(takeover.takeOver())
        XCTAssertEqual(prefs.values[bl], 1)
        takeover.restore()
        XCTAssertEqual(prefs.values[bl], 2)
        XCTAssertNil(prefs.values[flag])
    }

    func testRestoringWithoutARecordChangesNothing() {
        prefs.values[flag] = true   // somebody else's (a managed Mac)
        XCTAssertFalse(takeover.restore())
        XCTAssertEqual(prefs.values[flag], true)
        XCTAssertTrue(prefs.writes.isEmpty)
    }

    func testAManagedMacsOwnSwitchIsGivenBackAsItWas() {
        prefs.values[flag] = true
        takeover.takeOver()
        XCTAssertNotNil(record.saved, "recorded even when already on")
        takeover.restore()
        XCTAssertEqual(prefs.values[flag], true, "never removes a setting that was the person's or their admin's")
    }

    // MARK: Keys

    func testTheKeysThatOpenTheOverview() {
        func m(_ code: Int64, control: Bool = false, command: Bool = false, option: Bool = false, shift: Bool = false, up: Bool = true) -> Bool {
            MissionControlKey.matches(code: code, control: control, command: command, option: option, shift: shift, controlUpIsMissionControl: up)
        }
        XCTAssertTrue(m(160), "the Mission Control key (F3)")
        XCTAssertTrue(m(160, control: true), "with a modifier too")
        XCTAssertTrue(m(126, control: true), "⌃↑")
        XCTAssertFalse(m(126, control: true, up: false), "⌃↑ the person moved or turned off stays theirs")
        XCTAssertFalse(m(126), "↑ alone")
        XCTAssertFalse(m(126, control: true, shift: true), "⌃⇧↑ selects text in apps")
        XCTAssertFalse(m(126, control: true, command: true))
        XCTAssertFalse(m(125, control: true), "⌃↓ is App Exposé; the Dock switch turns it off")
    }

    // MARK: Hot corners

    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let monitor = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    func testACornerIsWhereThePointerIsPushedIntoIt() {
        XCTAssertEqual(HotCorners.corner(at: CGPoint(x: 0, y: 982), screens: [laptop]), .topLeft)
        XCTAssertEqual(HotCorners.corner(at: CGPoint(x: 1511, y: 981), screens: [laptop]), .topRight)
        XCTAssertEqual(HotCorners.corner(at: CGPoint(x: 2, y: 1), screens: [laptop]), .bottomLeft)
        XCTAssertEqual(HotCorners.corner(at: CGPoint(x: 1512, y: 0), screens: [laptop]), .bottomRight)
        XCTAssertNil(HotCorners.corner(at: CGPoint(x: 40, y: 940), screens: [laptop]))
        XCTAssertNil(HotCorners.corner(at: CGPoint(x: 700, y: 982), screens: [laptop]), "an edge isn't a corner")
    }

    func testTheSeamBetweenTwoScreensIsNotACorner() {
        let screens = [laptop, monitor]
        XCTAssertNil(HotCorners.corner(at: CGPoint(x: 1512, y: 0), screens: screens), "bottom seam")
        XCTAssertNil(HotCorners.corner(at: CGPoint(x: 1511, y: 981), screens: screens), "top seam")
        XCTAssertEqual(HotCorners.corner(at: CGPoint(x: 0, y: 982), screens: screens), .topLeft)
        XCTAssertEqual(HotCorners.corner(at: CGPoint(x: 3431, y: 1079), screens: screens), .topRight, "the far screen's own corner")
    }

    func testTheModifierMacOSWantedHeld() {
        let command = 1 << 20, shift = 1 << 17
        XCTAssertTrue(HotCorners.modifiersHeld(required: 0, held: 0))
        XCTAssertTrue(HotCorners.modifiersHeld(required: command, held: command | shift))
        XCTAssertFalse(HotCorners.modifiersHeld(required: command, held: shift))
        XCTAssertFalse(HotCorners.modifiersHeld(required: command, held: 0))
    }

    func testRestingInACornerOpensOnceUntilThePointerLeaves() {
        var d = HotCornerDwell()
        XCTAssertFalse(d.update(.topLeft, now: 0))
        XCTAssertFalse(d.update(.topLeft, now: HotCorners.dwell - 0.01))
        XCTAssertTrue(d.update(.topLeft, now: HotCorners.dwell))
        XCTAssertFalse(d.update(.topLeft, now: 2), "once")
        XCTAssertFalse(d.update(nil, now: 3))
        XCTAssertFalse(d.update(.topLeft, now: 4))
        XCTAssertTrue(d.update(.topLeft, now: 4 + HotCorners.dwell), "again after leaving")
    }

    func testPassingThroughACornerDoesNotOpen() {
        var d = HotCornerDwell()
        XCTAssertFalse(d.update(.bottomRight, now: 0))
        XCTAssertFalse(d.update(nil, now: 0.05))
        XCTAssertFalse(d.update(.bottomRight, now: 0.1))
        XCTAssertFalse(d.update(.bottomRight, now: 0.1 + HotCorners.dwell - 0.01))
    }
}
