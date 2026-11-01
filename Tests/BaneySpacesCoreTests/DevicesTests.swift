import XCTest
@testable import BaneySpacesCore

/// Simulators, emulators and VMs (spec/devices.md). The spec's own cases are replayed here, the
/// same files the Rust core replays, plus the macOS window model's side of R-D2 to R-D5.
final class DevicesTests: XCTestCase {
    private func cases(_ file: String) throws -> [[String: Any]] {
        let data = try Repo.text("spec/conformance/devices/\(file)").data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }
    private func rect(_ a: Any?) -> CGRect? {
        guard let v = (a as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    func testTheEmbeddedTableIsTheSpecFile() throws {
        XCTAssertEqual(DeviceData.devicesJSON + "\n", try Repo.text("spec/devices.json"),
                       "run scripts/gen-device-data.sh")
        XCTAssertGreaterThanOrEqual(DeviceTable.builtin.apps.count, 10)
    }

    func testEveryClassificationCaseInTheSpec() throws {
        let list = try cases("classify.json")
        XCTAssertGreaterThanOrEqual(list.count, 12)
        for c in list {
            let f = c["facts"] as! [String: Any]
            let facts = DeviceFacts(platform: f["platform"] as! String, bundle: f["bundle"] as? String ?? "",
                                    process: f["process"] as? String ?? "", windowClass: f["class"] as? String ?? "",
                                    exe: f["exe"] as? String ?? "", title: f["title"] as? String ?? "",
                                    standard: f["standard"] as? Bool ?? true)
            let d = DeviceTable.classify(facts)
            let e = c["expect"] as! [String: Any]
            let name = c["name"] as! String
            if let want = e["role"] as? String { XCTAssertEqual(d.role.rawValue, want, name) }
            if e.keys.contains("app") { XCTAssertEqual(d.app, e["app"] as? String, name) }
            if let w = e["agent_home"] as? Bool { XCTAssertEqual(d.agentHome, w, name) }
            if let w = e["resizes_itself"] as? Bool { XCTAssertEqual(d.resizesItself, w, name) }
            if let w = e["float"] as? Bool { XCTAssertEqual(d.float, w, name) }
        }
    }

    func testEveryGeometryCaseInTheSpec() throws {
        for c in try cases("geometry.json") {
            let name = c["name"] as! String
            let size = (c["current"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
            let screens = (c["screens"] as! [Any]).compactMap(rect)
            let got = DeviceGeometry.restoreFrame(saved: rect(c["saved"]), size: CGSize(width: size[0], height: size[1]),
                                                  screens: screens, resizesItself: c["resizes_itself"] as! Bool)
            XCTAssertEqual(got, rect(c["expect"]), name)
        }
    }

    func testEveryKeyCaseInTheSpec() throws {
        for c in try cases("keys.json") {
            let ch = c["chord"] as! [String: Any]
            let chord = ChordSpec(mods: Set(ch["mods"] as! [String]), key: ch["key"] as! String)
            let got = DeviceKeys.action(frontApp: c["front"] as? String, platform: c["platform"] as! String, mod: c["mod"] as! String,
                                        bridge: c["bridge"] as! Bool, chord: chord)
            XCTAssertEqual(got, c["expect"] as? String, c["name"] as! String)
        }
    }

    func testEveryProcessTreeCaseInTheSpec() throws {
        func table(_ v: Any?) -> [Int32: Double] {
            Dictionary(uniqueKeysWithValues: (v as! [String: NSNumber]).map { (Int32($0.key)!, $0.value.doubleValue) })
        }
        for c in try cases("placement.json") {
            let roots = table(c["roots"]), starts = table(c["starts"]), parents = table(c["parents"])
            let got = ProcessTree.descends(pid: Int32(truncating: c["pid"] as! NSNumber), roots: roots,
                                           startOf: { starts[$0] }, parentOf: { parents[$0].map { Int32($0) } })
            XCTAssertEqual(got, c["expect"] as? Bool, c["name"] as! String)
        }
    }

    func testTheSpecNamesEveryDeviceRuleInACase() throws {
        let md = try Repo.text("spec/devices.md")
        let ids = md.split(separator: "\n").compactMap { $0.hasPrefix("### R-D") ? String($0.dropFirst(4).split(separator: " ")[0]) : nil }
        XCTAssertEqual(ids.count, 10)
        var all = try Repo.text("spec/conformance/devices.json")
        for f in ["classify", "geometry", "keys", "placement"] { all += try Repo.text("spec/conformance/devices/\(f).json") }
        for id in ids { XCTAssertTrue(all.contains("\"\(id)\""), "no case names \(id)") }
    }

    // MARK: the macOS window model: R-D2 to R-D5

    private func model(_ main: WindowID, companions: [WindowID], on n: Int = 1) -> Workspaces {
        var m = Workspaces()
        m.displays(["A"])
        m.sync(seen: [main] + companions, alive: Set([main] + companions))
        for c in companions { m.attach(c, to: main) }
        if n != 1 { m.assign(main, to: n) }
        return m
    }

    func testACompanionJoinsTheWorkspaceOfItsWindowAndIsNotCounted() {
        var m = Workspaces()
        m.displays(["A"])
        _ = m.switchTo(3)
        m.sync(seen: [10], alive: [10, 11])
        _ = m.switchTo(5)
        m.sync(seen: [10, 11], alive: [10, 11])   // 11 appeared on 5, 10 is on 3
        m.attach(11, to: 10)
        XCTAssertEqual(m.workspace(of: 11), 3)
        XCTAssertEqual(m.windows(on: 3), [10], "the toolbar is not a window")
        XCTAssertTrue(m.isCompanion(11))
    }

    func testMovingTheWindowMovesItsCompanionsAndMovingACompanionMovesTheWindow() {
        var m = model(10, companions: [11, 12])
        m.assign(10, to: 4, focus: false)
        XCTAssertEqual([m.workspace(of: 11), m.workspace(of: 12)], [4, 4])
        m.assign(12, to: 7, focus: false)
        XCTAssertEqual([m.workspace(of: 10), m.workspace(of: 11), m.workspace(of: 12)], [7, 7, 7])
        XCTAssertEqual(m.windows(on: 7), [10])
        XCTAssertEqual(m.lastFocused[7], 10, "focus is remembered for the window, not the toolbar")
    }

    func testASwitchHidesAndShowsCompanionsWithTheirWindow() {
        var m = model(10, companions: [11], on: 2)
        let plan = m.switchTo(1)
        XCTAssertEqual(Set(plan.hide), [10, 11])
        let back = m.switchTo(2)
        XCTAssertEqual(Set(back.show), [10, 11])
        XCTAssertEqual(back.focus, 10, "the workspace focuses its window, never the toolbar")
    }

    func testAWorkspaceWithOnlyACompanionIsEmpty() {
        var m = Workspaces()
        m.displays(["A"])
        m.sync(seen: [10, 11], alive: [10, 11])
        m.attach(11, to: 10)
        m.assign(10, to: 6, focus: false)
        _ = m.switchTo(2)
        XCTAssertTrue(m.windows(on: 1).isEmpty)
        // if the window goes, its toolbar goes from the model: alone it would count as a window
        m.sync(seen: [11], alive: [11])
        XCTAssertTrue(m.windows(on: 6).isEmpty)
        XCTAssertNil(m.workspace(of: 11))
    }

    func testCompanionLinksDieWithEitherWindowAndAreNotSaved() throws {
        var m = model(10, companions: [11])
        m.sync(seen: [], alive: [10])
        XCTAssertFalse(m.isCompanion(11))
        m = model(10, companions: [11])
        let data = try JSONEncoder().encode(m)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("companionOf"))
    }

    func testAnAttachToAWindowThatIsItselfACompanionIsRefused() {
        var m = model(10, companions: [11])
        m.sync(seen: [10, 11, 12], alive: [10, 11, 12])
        m.attach(12, to: 11)
        XCTAssertFalse(m.isCompanion(12))
    }

    // MARK: R-D7 and the tap list

    func testOurTapIsRearmedWhenAnotherKeyTapIsAheadOfIt() {
        XCTAssertTrue(DeviceKeys.shouldRearm(taps: [(owner: 900, takesKeys: true), (owner: 100, takesKeys: true)], ours: 100))
        XCTAssertFalse(DeviceKeys.shouldRearm(taps: [(owner: 100, takesKeys: true), (owner: 900, takesKeys: true)], ours: 100))
        XCTAssertFalse(DeviceKeys.shouldRearm(taps: [(owner: 900, takesKeys: false), (owner: 100, takesKeys: true)], ours: 100),
                       "a listen-only tap swallows nothing")
        XCTAssertFalse(DeviceKeys.shouldRearm(taps: [], ours: 100))
    }
}
