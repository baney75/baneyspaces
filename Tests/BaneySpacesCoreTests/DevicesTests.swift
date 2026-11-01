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
                                    exe: f["exe"] as? String ?? "", args: f["args"] as? [String] ?? [], title: f["title"] as? String ?? "",
                                    standard: f["standard"] as? Bool ?? true)
            let d = DeviceTable.classify(facts)
            let e = c["expect"] as! [String: Any]
            let name = c["name"] as! String
            if let want = e["role"] as? String { XCTAssertEqual(d.role.rawValue, want, name) }
            if e.keys.contains("app") { XCTAssertEqual(d.app, e["app"] as? String, name) }
            if let w = e["agent_home"] as? Bool { XCTAssertEqual(d.agentHome, w, name) }
            if let w = e["resizes_itself"] as? Bool { XCTAssertEqual(d.resizesItself, w, name) }
            if let w = e["float"] as? Bool { XCTAssertEqual(d.float, w, name) }
            if let w = e["sandbox_only"] as? Bool { XCTAssertEqual(d.sandboxOnly, w, name) }
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
            let roots = table(c["roots"]).merging(table(c["recorded"] ?? [:])) { a, _ in a }, starts = table(c["starts"]), parents = table(c["parents"])
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
        m.sync(seen: [], alive: [11])
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

    func testOurTapIsRemadeOnlyWhenAnotherKeyTakingTapAppears() {
        let ours: Int32 = 100
        let known: Set<UInt32> = [1, 2]
        XCTAssertTrue(DeviceKeys.shouldRearm(taps: [(id: 1, owner: 900, takesKeys: true), (id: 3, owner: 900, takesKeys: true)], known: known, ours: ours), "a new one")
        XCTAssertFalse(DeviceKeys.shouldRearm(taps: [(id: 3, owner: ours, takesKeys: true)], known: known, ours: ours), "our own is not another's")
        XCTAssertFalse(DeviceKeys.shouldRearm(taps: [(id: 3, owner: 900, takesKeys: false)], known: known, ours: ours), "a listen-only tap swallows nothing")
        XCTAssertFalse(DeviceKeys.shouldRearm(taps: [(id: 1, owner: 900, takesKeys: true), (id: 2, owner: 901, takesKeys: true)], known: known, ours: ours), "the ones seen when ours was made, in any order")
        XCTAssertFalse(DeviceKeys.shouldRearm(taps: [], known: known, ours: ours))
    }

    // MARK: the key bridge's shared state (R-D7)

    func testTheKeyBridgeStateDecidesLikeTheSpec() {
        let st = KeyBridgeState()
        st.setFront("utm", mod: "cmd")
        XCTAssertEqual(st.keyDown(code: 20, workspaceKey: 3, mods: ["cmd"], repeating: false), .pass, "not armed: nothing is taken")
        st.arm()
        XCTAssertEqual(st.keyDown(code: 20, workspaceKey: 3, mods: ["cmd"], repeating: false), .run("switch 3"))
        XCTAssertEqual(st.keyDown(code: 20, workspaceKey: 3, mods: ["cmd"], repeating: true), .swallow, "auto-repeat of a taken key")
        XCTAssertEqual(st.keyUp(code: 20), .swallow)
        XCTAssertEqual(st.keyUp(code: 20), .pass, "the up of a key that was not taken")
        XCTAssertEqual(st.keyDown(code: 8, workspaceKey: nil, mods: ["cmd"], repeating: false), .pass, "cmd-c is the guest's")
        st.keyDown(code: 21, workspaceKey: 4, mods: ["cmd"], repeating: false).run()
        st.disarm()
        XCTAssertEqual(st.keyUp(code: 21), .pass, "disarm forgets what it took; the up goes to the app")
    }

    func testTheKeyBridgeStateSurvivesArmingAndDisarmingWhileKeysArrive() {
        let st = KeyBridgeState()
        st.setFront("utm", mod: "cmd")
        let group = DispatchGroup()
        var swallowedUnpaired = 0
        let counter = NSLock()
        for t in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<20_000 {
                    let code = Int64(18 + (i + t) % 9)
                    if case .run = st.keyDown(code: code, workspaceKey: Int(code - 17), mods: ["cmd"], repeating: false) {
                        _ = st.keyUp(code: code)
                    }
                    if i % 97 == 0 { st.setFront(i % 2 == 0 ? "utm" : "parallels", mod: i % 3 == 0 ? "cmd" : "ctrl") }
                }
                counter.lock(); swallowedUnpaired += 1; counter.unlock()
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global().async {
            for i in 0..<20_000 { if i % 2 == 0 { st.arm() } else { st.disarm() } }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "no deadlock")
        XCTAssertEqual(swallowedUnpaired, 4)
        st.disarm()
        XCTAssertFalse(st.isArmed)
        XCTAssertEqual(st.keyUp(code: 18), .pass)
    }

    // MARK: R-D9, through the placement the scan runs

    func testASandboxViewGoesToTheAgentWorkspaceOnlyWhenTheSandboxOwnsItsProcess() {
        var m = Workspaces()
        m.displays(["A"])
        m.sync(seen: [10, 11, 12], alive: [10, 11, 12])
        let pinned: Set<WindowID> = [10, 11]
        let owned: Set<WindowID> = [10]
        let moved = DevicePlacement.placePinned(windows: [10, 11, 12], pinned: pinned, ownedBySandbox: { owned.contains($0) }, agent: 9, model: &m)
        XCTAssertEqual(moved, [10])
        XCTAssertEqual(m.workspace(of: 10), 9, "the sandbox's own view is on the agent workspace")
        XCTAssertEqual(m.workspace(of: 11), 1, "a stranger's window titled like it is left alone")
        XCTAssertEqual(m.workspace(of: 12), 1)
        XCTAssertTrue(m.windows(on: 1).contains(11))
        XCTAssertTrue(DevicePlacement.placePinned(windows: [10], pinned: pinned, ownedBySandbox: { _ in true }, agent: 9, model: &m).isEmpty, "already there")
        XCTAssertTrue(DevicePlacement.placePinned(windows: [11], pinned: pinned, ownedBySandbox: { _ in true }, agent: nil, model: &m).isEmpty, "no agent workspace, no pin")
    }

    func testTheScanUsesWhatThePlacementDecidesAndTheSandboxRegistry() throws {
        let spaces = try Repo.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertTrue(spaces.contains("DevicePlacement.placePinned("), "the scan places pinned windows")
        XCTAssertTrue(spaces.contains("sandboxOwns($0.pid)"), "and asks the sandbox which processes are its own")
        let windows = try Repo.code("Sources/BaneySpaces/Windows.swift")
        XCTAssertTrue(windows.contains("decision.agentHome"), "Windows.all hands the table's pin to the scan")
        let app = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("spaces.sandboxOwns = "), "and the app wires the sandbox's registry in")
    }

    // MARK: R-D8, recorded descendants

    func testNewDescendantsAreFoundByTheirParentAndOnlyOnce() {
        let table: [(pid: Int32, ppid: Int32)] = [(100, 1), (200, 100), (300, 200), (400, 1), (500, 400)]
        XCTAssertEqual(ProcessTree.newDescendants(roots: [100], known: [], table: table).sorted(), [200, 300])
        XCTAssertEqual(ProcessTree.newDescendants(roots: [100], known: [200, 300], table: table), [])
        XCTAssertEqual(ProcessTree.newDescendants(roots: [100], known: [300], table: [(200, 1), (300, 200)]), [], "200 already left and is nobody's")
        XCTAssertTrue(ProcessTree.newDescendants(roots: [], known: [], table: table).isEmpty)
    }

    func testAWindowThatWasATitlelessCompanionIsCountedOnceItIsDetached() {
        var m = model(10, companions: [11])
        XCTAssertTrue(m.windows(on: 1) == [10])
        m.detach(11)
        XCTAssertEqual(m.windows(on: 1), [10, 11], "its title arrived and it is a window of its own")
    }
}

private extension KeyBridgeState.Verdict {
    @discardableResult func run() -> String? { if case .run(let a) = self { return a }; return nil }
}
