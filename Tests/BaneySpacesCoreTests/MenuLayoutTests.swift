import BaneySpacesCore
import XCTest

/// Donovan, 2026-10-14: the menu bar menu and the dock's right-click menus were "way too
/// cluttered". These hold the trimmed shape.
final class MenuLayoutTests: XCTestCase {
    func testListsOnlyWorkspacesInUseThenOneEmpty() {
        let rows = MenuLayout.rows(current: 1, apps: [1: ["Helium", "Ghostty"], 2: ["Grok Bot"]])
        XCTAssertEqual(rows.map(\.workspace), [1, 2, 3])
        XCTAssertEqual(rows.map(\.title), ["Workspace 1  ·  Helium, Ghostty", "Workspace 2  ·  Grok Bot", "Empty Workspace 3"])
        XCTAssertEqual(rows.map(\.isCurrent), [true, false, false])
    }

    func testCurrentWorkspaceShowsEvenWhenEmpty() {
        let rows = MenuLayout.rows(current: 5, apps: [1: ["Helium"]])
        XCTAssertEqual(rows.map(\.workspace), [1, 5, 2])
        XCTAssertEqual(rows[1].title, "Workspace 5")
        XCTAssertTrue(rows[1].isCurrent)
        // The empty row is another workspace than the one you're on.
        XCTAssertEqual(rows[2].title, "Empty Workspace 2")
    }

    func testLongAppListShortensAndKeepsTheFullListForTheTooltip() {
        let names = ["Helium", "Ghostty", "Obsidian", "T3 Code (Nightly)", "iPhone Mirroring"]
        let row = MenuLayout.rows(current: 1, apps: [1: names])[0]
        XCTAssertEqual(row.title, "Workspace 1  ·  Helium, Ghostty, Obsidian +2")
        XCTAssertEqual(row.fullList, names.joined(separator: ", "))
        XCTAssertNil(MenuLayout.rows(current: 1, apps: [1: ["A", "B", "C"]])[0].fullList)
    }

    func testEveryWorkspaceInUseLeavesNoEmptyRow() {
        var apps: [Int: [String]] = [:]
        for n in 1...9 { apps[n] = ["App \(n)"] }
        let rows = MenuLayout.rows(current: 4, apps: apps)
        XCTAssertEqual(rows.count, 9)
        XCTAssertFalse(rows.contains { $0.title.hasPrefix("Empty") })
    }

    /// The app target can't be imported by tests, so these read its source (code only, comments stripped).
    private func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    func testMenuBarMenuDropsTheHintRowAndMovesTheSwitchesToSettings() throws {
        let text = try code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertFalse(text.contains("\"Add ⇧ to send the front window there\""), "the ⇧ hint row is gone; setup teaches it")
        XCTAssertTrue(text.contains("MenuLayout.rows("), "the workspace rows come from MenuLayout")
        for gone in ["optionsItem()", "channelItem()", "updateItem()", "parkedAppsItem()", "\"About BaneySpaces\"", "session.menuItems()", "toolTip = updater"] {
            XCTAssertFalse(text.contains(gone), "\(gone) moved into Settings (Donovan, 2026-10-31)")
        }
    }

    /// Donovan, 2026-10-31: the menu keeps the workspace rows, Show All Workspaces, Find or Install
    /// an App, Settings and Quit. Finished agents and a waiting update get a row only while there is
    /// something to act on (review of #100: a tooltip and a Settings tab are not a notice).
    func testMenuIsFiveKindsOfRowsWhenNothingIsPending() {
        let rows = MenuLayout.rows(current: 1, apps: [1: ["Ghostty"]])
        let e = MenuLayout.entries(rows: rows, finished: 0, update: nil)
        XCTAssertEqual(e, rows.map(MenuEntry.workspace) + [.separator, .showAll, .find, .separator, .settings, .quit])
    }

    func testFinishedAgentsAndAWaitingUpdateAddOneRowEachAndOnlyWhileTheyAreThere() {
        let rows = MenuLayout.rows(current: 1, apps: [:])
        let notice = UpdateNotice(name: "BaneySpaces 0.3.1", isNightly: false, installing: false)
        let tail: ([MenuEntry]) -> [MenuEntry] = { Array($0.dropFirst(rows.count)) }
        XCTAssertEqual(tail(MenuLayout.entries(rows: rows, finished: 2, update: nil)),
                       [.separator, .showAll, .find, .separator, .finished(count: 2), .separator, .settings, .quit])
        XCTAssertEqual(tail(MenuLayout.entries(rows: rows, finished: 0, update: notice)),
                       [.separator, .showAll, .find, .separator, .update(notice), .separator, .settings, .quit])
        XCTAssertEqual(tail(MenuLayout.entries(rows: rows, finished: 1, update: notice)),
                       [.separator, .showAll, .find, .separator, .finished(count: 1), .update(notice), .separator, .settings, .quit])
    }

    func testUpdateWordingIsCapitalizedWhereASentenceStarts() {
        let stable = UpdateNotice(name: "BaneySpaces 0.3.1", isNightly: false, installing: false)
        let nightly = UpdateNotice(name: "nightly-2026-10-31", isNightly: true, installing: false)
        XCTAssertEqual(stable.menuTitle, "Update to BaneySpaces 0.3.1…")
        XCTAssertEqual(stable.sentence, "BaneySpaces 0.3.1 is available.")
        XCTAssertEqual(nightly.menuTitle, "Update to the Nightly Build…")
        XCTAssertEqual(nightly.sentence, "The nightly build is available.")
        XCTAssertEqual(UpdateNotice(name: "x", isNightly: true, installing: true).menuTitle, "Updating to the Nightly Build…")
        XCTAssertEqual(MenuLayout.finishedTitle(1), "1 Agent Finished While You Were Away")
        XCTAssertEqual(MenuLayout.finishedTitle(3), "3 Agents Finished While You Were Away")
    }

    /// The status item's count of finished agents and the way to reach them travel together, so
    /// the number never counts something the menu won't show.
    func testTheCountBesideTheIconComesWithARowForThoseAgents() throws {
        let text = try code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(text.contains("session.unseenCount"))
        XCTAssertTrue(text.contains("finished: session.started ? session.unseenCount : 0"), "the menu row counts the same agents as the badge")
        XCTAssertTrue(text.contains("session.finishedMenuItem(title:"))
        XCTAssertFalse(text.contains("toolTip = updater"), "a tooltip is no notice of an update")
    }

    /// Every item the menu builds: a literal title in `item(`, `NSMenuItem(title:` or `addItem(withTitle:`,
    /// and one `NSMenuItem(` call in the helper that every other item goes through. A row added any
    /// other way fails here, and a new title has to be added to this list on purpose.
    func testNoMenuItemIsBuiltOutsideTheKnownOnes() throws {
        let text = try code("Sources/BaneySpaces/AppDelegate.swift")
        let titlePatterns = [#"item\("([^"]+)""#, #"NSMenuItem\(title: "([^"]+)""#, #"addItem\(withTitle: "([^"]+)""#]
        var titles = Set<String>()
        for pattern in titlePatterns {
            let re = try NSRegularExpression(pattern: pattern)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                titles.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        // `item(` also matches "menuItem(for:" and "updateItem(": only quoted titles are captured.
        XCTAssertEqual(titles, ["Show All Workspaces", "Find or Install an App…", "Settings…", "Quit BaneySpaces",
                                "Waiting for AeroSpace to quit", "BaneySpaces needs permission to arrange windows", "Allow BaneySpaces…"])
        XCTAssertEqual(text.components(separatedBy: "NSMenuItem(").count - 1, 1, "only the item(_:_:key:) helper builds one")
        XCTAssertEqual(text.components(separatedBy: ".addItem(withTitle:").count - 1, 2, "only the not-started notices")
        XCTAssertEqual(text.components(separatedBy: "NSMenu()").count - 1, 1, "only the status item's own menu; no submenu built here")
        // The one other place a menu row is built, the finished-agents submenu, is the session engine's.
        let session = try code("Sources/BaneySpaces/Session/SessionController.swift")
        XCTAssertEqual(session.components(separatedBy: "NSMenuItem(").count - 1, 2, "the finished row and one item for each agent")
    }

    /// Review of #100: Settings' lists were read only on a tab change, a clicked row stayed, the
    /// command line tools were asked once, and Automation worked before BaneySpaces had started.
    func testSettingsListsRefreshAndAutomationWaitsForAccessibility() throws {
        let setup = try code("Sources/BaneySpaces/Setup.swift")
        let app = try code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(setup.contains("if tab == .automation { reloadParked() }\n            if tab == .updates"), "the parked list reads when the tab appears")
        // ...and not on every reload: the bodies of reload() and reloadOptional() never read it.
        for name in ["func reload() {", "private func reloadOptional() {"] {
            let from = try XCTUnwrap(setup.range(of: name))
            let rest = setup[from.upperBound...]
            let body = rest[..<(rest.range(of: "\n    func ")?.lowerBound ?? rest.range(of: "\n    private func ")!.lowerBound)]
            XCTAssertFalse(body.contains("reloadParked()"), "\(name) runs every few ticks")
        }
        XCTAssertTrue(setup.contains("NSWindow.didBecomeKeyNotification, object: window"), "the lists read again when the window takes the keyboard")
        XCTAssertTrue(setup.contains("onFocusFinished?(id)\n        finished = finishedRows()"), "a clicked row leaves the list at once")
        XCTAssertTrue(setup.contains("model.focusFinished(row.id)"))
        XCTAssertTrue(setup.contains("if tab == .updates { onUpdatesShown?() }"), "the command line tools are looked for when Updates comes up")
        XCTAssertTrue(app.contains("let found = Updater.hasCommandLineTools"))
        XCTAssertFalse(app.contains("lazy var commandLineTools"), "asked once at first use goes stale when the tools are installed")
        XCTAssertEqual(setup.components(separatedBy: ".disabled(model.automationReason != nil)").count - 1, 2, "the app list and Bring Every Window Back wait for BaneySpaces to start")
        for name in ["private func bringBack() {", "private func toggleParked(_ id: String) {"] {
            let start = try XCTUnwrap(app.range(of: name))
            XCTAssertTrue(app[start.upperBound...].prefix(60).contains("guard started else { return }"), "\(name) acts only once started")
        }
    }

    func testEveryActionTheMenuHadIsInSettings() throws {
        let setup = try code("Sources/BaneySpaces/Setup.swift")
        let wired = try code("Sources/BaneySpaces/AppDelegate.swift")
        // Each used to be a menu item; each is now a control in Settings, wired in the app delegate.
        for control in ["Workspace Dock in place of the macOS Dock", "Position on screen",
                        "Show what coding agents are doing on their app icons",
                        "⌘Space opens the BaneySpaces launcher instead of Spotlight",
                        "Keep usable by automation", "Bring Every Window Back", "Uninstall BaneySpaces…",
                        "Stable: tested releases", "Check for updates daily", "Check for Updates Now…",
                        "Button(notice.menuTitle)", "About BaneySpaces…", "Finished while you were away"] {
            XCTAssertTrue(setup.contains(control), "Settings lacks \"\(control)\"")
        }
        for wire in ["onBringBack", "onAbout", "onToggleParked", "onCheckForUpdates", "onOfferUpdate",
                     "onSetUpdateChannel", "onSetCheckDaily", "onFocusFinished", "onUninstall", "onUpdatesShown"] {
            XCTAssertTrue(wired.contains("c.model.\(wire) ="), "\(wire) isn't wired")
        }
    }

    func testDockMenusAreShortAndForceQuitHidesBehindOption() throws {
        let text = try code("Sources/BaneySpaces/WorkspaceDock.swift")
        XCTAssertTrue(text.contains("quit.modifierKeyAlternate(.option) { force }"), "Force Quit shows only while ⌥ is held")
        XCTAssertTrue(text.contains(".contextMenu { appMenu(app, in: tile) }"))
        // The dock's own buttons do these; the menus don't repeat them.
        let start = try XCTUnwrap(text.range(of: "private func tileMenu("))
        let end = try XCTUnwrap(text.range(of: "private func icons("))
        let menus = text[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(menus.contains("Find or Install an App"))
        XCTAssertFalse(menus.contains("Show All Workspaces"))
        XCTAssertFalse(menus.contains("Send Front Window"))
    }
}

/// Review of #100 round 2 (first-F1, first-F3, first-F4), read from the source: the app target
/// can't be imported.
final class SettingsFollowUpTests: XCTestCase {
    private func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    func testTheBadgeAndTheMenuCountOnlyAgentsTheListCanShow() throws {
        let session = try code("Sources/BaneySpaces/Session/SessionController.swift")
        XCTAssertTrue(session.contains("var unseenCount: Int { finishedRows().count }"), "one count for the badge and the menu row")
        XCTAssertTrue(session.contains("engine.attention.unseen.compactMap { engine.item($0) }"), "an unseen agent with no row isn't listed")
    }

    func testTheKeyObserverIsKeptAndRemoved() throws {
        let setup = try code("Sources/BaneySpaces/Setup.swift")
        XCTAssertTrue(setup.contains("observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(\n            forName: NSWindow.didBecomeKeyNotification"))
        XCTAssertTrue(setup.contains("deinit {"))
        XCTAssertTrue(setup.contains("for o in observers { o.center.removeObserver(o.token) }"))
        XCTAssertTrue(setup.contains("if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }"))
    }

    func testTheParkedListReadsOnEventsNotEveryTick() throws {
        let setup = try code("Sources/BaneySpaces/Setup.swift")
        let start = try XCTUnwrap(setup.range(of: "private func reloadOptional()"))
        let end = try XCTUnwrap(setup.range(of: "func reloadParked()"))
        XCTAssertFalse(setup[start.lowerBound..<end.lowerBound].contains("reloadParked()"), "reloadOptional runs every few ticks")
        XCTAssertTrue(setup.contains("NSWorkspace.didLaunchApplicationNotification"))
        XCTAssertTrue(setup.contains("NSWorkspace.didTerminateApplicationNotification"))
        XCTAssertTrue(setup.contains("self.model.tab == .automation"), "only while that tab is up")
    }

    func testSettingsReadsTheListWhenStartedFlipsAndWhileTheTabIsUp() throws {
        let setup = try code("Sources/BaneySpaces/Setup.swift")
        // F4: nothing is live until the gate has read the state.
        XCTAssertTrue(setup.contains("@Published var started = false {"))
        XCTAssertTrue(setup.contains("var isStarted: () -> Bool = { false } {\n        didSet { started = isStarted() }"))
        // F2: the list read empty while waiting; it reads the moment BaneySpaces is up.
        XCTAssertTrue(setup.contains("guard started, !oldValue, tab == .automation, windowVisible() else { return }\n            reloadParked()"))
        // F6: a late first window shows without any notification.
        XCTAssertTrue(setup.contains("if ticks % 12 == 0, tab == .automation, windowVisible() { reloadParked() }"), "a closed window isn't scanned for")
        XCTAssertTrue(setup.contains("guard started, !oldValue, tab == .automation, windowVisible() else { return }"))
        XCTAssertTrue(setup.contains("self?.windowVisible() == true { self?.reloadParked() }"))
        XCTAssertTrue(setup.contains("model.windowVisible = { [weak window] in window?.isVisible == true }"))
        let app = try code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("if started { spaces.refresh() }"), "the list is the window list as it is now")
    }
}
