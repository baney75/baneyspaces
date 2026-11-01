import XCTest
@testable import BaneySpacesCore

/// What spec/overview.md promises about the layout: nothing clipped, no two cards overlapping, every
/// window shown, every workspace reachable, the room shared by window count.
enum OverviewFixture {
    static let metrics = OverviewMetrics.make(spec: ThemeCatalog.shared.spec(.baneyspaces))

    /// Donovan's screenshot (2026-11-01 10:36): workspace 1 holds Word, Helium, Obsidian, T3 Code, Excel,
    /// Grok Bot and Terminal; the rest are empty. The windows are stacked the way they were on his screen.
    static let reportedNames = ["Microsoft Word", "Helium", "Obsidian", "T3 Code (Nightly)", "Microsoft Excel", "Grok Bot", "Terminal"]
    static func reported(on screen: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 945)) -> [OverviewWindow] {
        let frames = [CGRect(x: 40, y: 60, width: 1100, height: 760), CGRect(x: 0, y: 38, width: 1512, height: 907),
                      CGRect(x: 120, y: 90, width: 1180, height: 800), CGRect(x: 60, y: 60, width: 1300, height: 840),
                      CGRect(x: 200, y: 120, width: 1100, height: 700), CGRect(x: 300, y: 150, width: 900, height: 640),
                      CGRect(x: 520, y: 380, width: 760, height: 480)]
        return frames.enumerated().map { OverviewWindow(id: WindowID(100 + $0.offset), workspace: 1, frame: frames[$0.offset].offsetBy(dx: screen.minX, dy: screen.minY)) }
    }

    /// `count(n)` windows on workspace `n`, with frames of every kind: stacked, tall, wide, small.
    static func windows(on screen: CGRect, count: (Int) -> Int) -> [OverviewWindow] {
        var out: [OverviewWindow] = []
        var id: WindowID = 1000
        var seed: UInt64 = 7
        func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 1000) / 1000 }
        for n in Workspaces.range {
            for _ in 0..<count(n) {
                id += 1
                let w = screen.width * (0.15 + 0.7 * next()), h = screen.height * (0.15 + 0.75 * next())
                let f = CGRect(x: screen.minX + (screen.width - w) * next(), y: screen.minY + (screen.height - h) * next(), width: w, height: h)
                out.append(OverviewWindow(id: id, workspace: n, frame: f))
            }
        }
        return out
    }

    static func input(_ windows: [OverviewWindow], size: CGSize = CGSize(width: 1512, height: 945), current: Int = 1,
                      settings: OverviewSettings = OverviewSettings(), safeTop: CGFloat = 0, dragging: Bool = false,
                      expanded: Set<Int> = [], help: Bool = true, openSlot: Int? = nil) -> OverviewInput {
        OverviewInput(size: size, safeTop: safeTop, windows: windows, current: current, settings: settings, metrics: metrics,
                      dragging: dragging, expanded: expanded, help: help, openSlot: openSlot)
    }

    /// The displays a Mac might have: the laptop (with its notch), a monitor, a portrait one.
    static let displays: [[(size: CGSize, safeTop: CGFloat)]] = [
        [(CGSize(width: 1512, height: 982), 32)],
        [(CGSize(width: 1512, height: 982), 32), (CGSize(width: 1920, height: 1080), 0)],
        [(CGSize(width: 1512, height: 982), 32), (CGSize(width: 2560, height: 1440), 0), (CGSize(width: 900, height: 1600), 0)],
    ]
}

final class OverviewLayoutTests: XCTestCase {
    typealias F = OverviewFixture

    // MARK: Donovan's load

    func testDonovansSevenWindowsAreAllShownUnclippedAndTheEmptyWorkspacesAreAStrip() {
        let windows = F.reported()
        let layout = OverviewLayout.make(F.input(windows))
        XCTAssertEqual(layout.violations(windows: windows), [])
        XCTAssertEqual(layout.tiles.map(\.n), [1], "only workspace 1 has windows")
        let tile = layout.tiles[0]
        XCTAssertEqual(tile.cards.count, 7)
        XCTAssertNil(tile.more)
        XCTAssertEqual(Set(tile.cards.map(\.id)), Set(windows.map(\.id)))
        // The empty workspaces are a row of numbered slots plus the "+", each the size of a dock tile.
        XCTAssertEqual(layout.slots.compactMap(\.n), Array(2...9))
        XCTAssertEqual(layout.slots.count, 9)
        XCTAssertEqual(layout.plusTarget, 2)
        for s in layout.slots { XCTAssertLessThanOrEqual(s.frame.width, F.metrics.slot + 0.001) }
        XCTAssertEqual(Set(layout.slots.map { $0.frame.minY }).count, 1, "one row")
        // The cards are big enough to read, and workspace 1's tile takes the room the empty ones gave up.
        for c in tile.cards { XCTAssertGreaterThanOrEqual(c.frame.height, F.metrics.minCardHeight, "card \(c.id)") }
        XCTAssertGreaterThan(tile.frame.width * tile.frame.height, 1512 * 945 * 0.55)
        XCTAssertEqual(layout.reachable, Set(Workspaces.range))
    }

    func testTheWorkspaceYouAreOnIsMarkedWhetherItHasWindowsOrIsInTheStrip() {
        let windows = F.reported()
        XCTAssertTrue(OverviewLayout.make(F.input(windows, current: 1)).tiles[0].isCurrent)
        let away = OverviewLayout.make(F.input(windows, current: 4))
        XCTAssertFalse(away.tiles[0].isCurrent)
        XCTAssertEqual(away.slots.filter(\.isCurrent).compactMap(\.n), [4])
    }

    // MARK: Sharing the room

    func testWorkspacesShareTheScreenByWindowCountAndOneWindowGetsAtLeastAQuarterOfSeven() {
        let windows = F.windows(on: CGRect(x: 0, y: 0, width: 1512, height: 945)) { [1: 7, 2: 3, 3: 1][$0] ?? 0 }
        let layout = OverviewLayout.make(F.input(windows))
        XCTAssertEqual(layout.violations(windows: windows), [])
        let area = { (n: Int) in layout.tile(n)!.frame.width * layout.tile(n)!.frame.height }
        XCTAssertGreaterThan(area(1), area(2))
        XCTAssertGreaterThan(area(2), area(3))
        XCTAssertGreaterThanOrEqual(area(3) / area(1), 0.25 * 0.97, "one window gets at least a quarter of seven's share")
    }

    func testGridKeepsNineEqualTiles() {
        let windows = F.windows(on: CGRect(x: 0, y: 0, width: 1512, height: 945)) { [1: 7, 2: 1][$0] ?? 0 }
        let layout = OverviewLayout.make(F.input(windows, settings: OverviewSettings(layout: .grid)))
        XCTAssertEqual(layout.violations(windows: windows), [])
        XCTAssertEqual(layout.tiles.count, 9)
        XCTAssertTrue(layout.slots.isEmpty)
        let sizes = Set(layout.tiles.map { "\(Int($0.frame.width.rounded()))x\(Int($0.frame.height.rounded()))" })
        XCTAssertEqual(sizes.count, 1, "every tile is the same size")
    }

    func testEmptyWorkspacesFullHiddenAndWhileDragging() {
        let windows = F.reported()
        let full = OverviewLayout.make(F.input(windows, settings: OverviewSettings(empty: .full)))
        XCTAssertEqual(full.tiles.count, 9)
        XCTAssertTrue(full.slots.isEmpty)
        XCTAssertEqual(full.violations(windows: windows), [])
        let hidden = OverviewLayout.make(F.input(windows, settings: OverviewSettings(empty: .hidden)))
        XCTAssertEqual(hidden.tiles.map(\.n), [1])
        XCTAssertTrue(hidden.slots.isEmpty, "hidden leaves the empty workspaces out")
        let dragging = OverviewLayout.make(F.input(windows, settings: OverviewSettings(empty: .hidden), dragging: true))
        XCTAssertEqual(dragging.slots.compactMap(\.n), Array(2...9), "…except while a window is dragged")
        XCTAssertEqual(dragging.violations(windows: windows), [])
    }

    func testNoWindowsAnywhereShowsTheCurrentWorkspaceAndTheStrip() {
        let layout = OverviewLayout.make(F.input([], current: 3))
        XCTAssertEqual(layout.tiles.map(\.n), [3])
        XCTAssertEqual(layout.violations(windows: []), [])
        XCTAssertEqual(layout.reachable, Set(Workspaces.range))
    }

    func testThePlusMovesToTheFirstEmptyWorkspaceAndIsGoneWhenNoneIsEmpty() {
        let some = F.windows(on: CGRect(x: 0, y: 0, width: 1512, height: 945)) { [1: 1, 2: 1, 4: 1][$0] ?? 0 }
        XCTAssertEqual(OverviewLayout.make(F.input(some)).plusTarget, 3)
        let all = F.windows(on: CGRect(x: 0, y: 0, width: 1512, height: 945)) { _ in 1 }
        let full = OverviewLayout.make(F.input(all))
        XCTAssertNil(full.plusTarget)
        XCTAssertTrue(full.slots.isEmpty, "every workspace has a tile, so there is no strip and no +")
    }

    // MARK: "+N"

    func testMoreThanTwentyFourWindowsInATileCollapseTheSmallestIntoAPlusN() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let exactly = F.windows(on: screen) { $0 == 1 ? 24 : 0 }
        let l24 = OverviewLayout.make(F.input(exactly))
        XCTAssertEqual(l24.tiles[0].cards.count, 24)
        XCTAssertNil(l24.tiles[0].more, "24 is not past 24")
        XCTAssertEqual(l24.violations(windows: exactly), [])

        let past = F.windows(on: screen) { $0 == 1 ? 25 : 0 }
        let l25 = OverviewLayout.make(F.input(past))
        XCTAssertEqual(l25.tiles[0].cards.count, 23)
        XCTAssertEqual(l25.tiles[0].more?.count, 2)
        XCTAssertEqual(l25.violations(windows: past), [])
        // The ones that collapsed are the smallest.
        let area = { (id: WindowID) in past.first { $0.id == id }!.frame!.width * past.first { $0.id == id }!.frame!.height }
        let kept = l25.tiles[0].cards.map { area($0.id) }.min()!
        for id in l25.tiles[0].collapsed { XCTAssertLessThanOrEqual(area(id), kept) }
    }

    func testThePlusNExpandsInPlaceToEveryCard() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let windows = F.windows(on: screen) { $0 == 1 ? 60 : 0 }
        let l = OverviewLayout.make(F.input(windows, expanded: [1]))
        XCTAssertEqual(l.tiles[0].cards.count, 60)
        XCTAssertTrue(l.tiles[0].more?.expanded == true, "a card to close it again")
        XCTAssertEqual(l.violations(windows: windows), [])
    }

    // MARK: Where cards go

    func testTwoSideBySideWindowsStaySideBySide() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let windows = [OverviewWindow(id: 1, workspace: 1, frame: CGRect(x: 0, y: 40, width: 756, height: 905)),
                       OverviewWindow(id: 2, workspace: 1, frame: CGRect(x: 756, y: 40, width: 756, height: 905))]
        let l = OverviewLayout.make(F.input(windows))
        XCTAssertEqual(l.violations(windows: windows), [])
        let a = l.card(1)!.card, b = l.card(2)!.card
        XCTAssertTrue(a.relative && b.relative, "their places read, so cards keep them")
        XCTAssertLessThan(a.frame.maxX, b.frame.minX)
        XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 0.5)
        _ = screen
    }

    func testHeavilyOverlappingWindowsFallBackToATidyGrid() {
        let windows = F.reported()
        let l = OverviewLayout.make(F.input(windows))
        XCTAssertTrue(l.cards.allSatisfy { !$0.relative })
        // Tidy: rows of cards at one height.
        XCTAssertEqual(Set(l.cards.map { ($0.frame.height * 10).rounded() }).count, 1)
    }

    func testAWindowWithNoKnownFrameStillGetsACard() {
        let windows = [OverviewWindow(id: 1, workspace: 1), OverviewWindow(id: 2, workspace: 1, frame: CGRect(x: 0, y: 0, width: 300, height: 200))]
        let l = OverviewLayout.make(F.input(windows))
        XCTAssertEqual(l.violations(windows: windows), [])
        XCTAssertEqual(l.cards.count, 2)
    }

    // MARK: The matrix

    func testNoClippingNoOverlapEveryWindowShownEveryWorkspaceReachableAcrossTheMatrix() {
        let settings: [OverviewSettings] = [OverviewSettings(), OverviewSettings(layout: .grid), OverviewSettings(empty: .full),
                                            OverviewSettings(empty: .hidden)]
        var checked = 0
        for perWorkspace in [0, 1, 7, 24, 60] {
            for displays in F.displays {
                for (d, display) in displays.enumerated() {
                    let screen = CGRect(origin: .zero, size: display.size)
                    let shapes: [(String, (Int) -> Int)] = [
                        ("every workspace", { _ in perWorkspace }),
                        ("workspace 1 only", { $0 == 1 ? perWorkspace : 0 }),
                        ("mixed", { [1: perWorkspace, 2: 1, 5: 7, 9: 24][$0] ?? 0 }),
                    ]
                    for (shape, count) in shapes {
                        let windows = F.windows(on: screen, count: count)
                        for s in settings {
                            for dragging in [false, true] {
                                for current in [1, 5] {
                                    let l = OverviewLayout.make(F.input(windows, size: display.size, current: current, settings: s,
                                                                         safeTop: display.safeTop, dragging: dragging))
                                    let what = "\(perWorkspace)/\(shape) display \(d + 1) of \(displays.count) \(s) dragging=\(dragging) current=\(current)"
                                    XCTAssertEqual(l.violations(windows: windows), [], what)
                                    if s.empty != .hidden || dragging {
                                        XCTAssertEqual(l.reachable, Set(Workspaces.range), what)
                                    } else {
                                        XCTAssertFalse(l.tiles.isEmpty, what)
                                    }
                                    // The notch: nothing above it.
                                    for t in l.tiles { XCTAssertGreaterThanOrEqual(t.frame.minY, display.safeTop, what) }
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    func testEveryCardOfEveryCountAndExpandedTileIsInsideItsTileAtTheSmallestScreens() {
        for size in [CGSize(width: 800, height: 500), CGSize(width: 640, height: 480), CGSize(width: 1280, height: 720)] {
            for n in [1, 7, 24, 60, 200] {
                let screen = CGRect(origin: .zero, size: size)
                let windows = F.windows(on: screen) { $0 == 1 ? n : ($0 == 2 ? 3 : 0) }
                for expanded in [Set<Int>(), [1]] {
                    let l = OverviewLayout.make(F.input(windows, size: size, expanded: expanded))
                    XCTAssertEqual(l.violations(windows: windows), [], "\(size) \(n) \(expanded)")
                }
            }
        }
    }

    func testATileThatNeedsRoomTakesItFromTheOthers() {
        // 24 windows next to one: the one shrinks so the 24 stay readable, never the other way round.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let windows = F.windows(on: screen) { [1: 24, 2: 1, 3: 1][$0] ?? 0 }
        let l = OverviewLayout.make(F.input(windows))
        XCTAssertEqual(l.violations(windows: windows), [])
        XCTAssertGreaterThan(l.tile(1)!.frame.width * l.tile(1)!.frame.height, 3 * l.tile(2)!.frame.width * l.tile(2)!.frame.height)
    }

    func testTheHelpLineTakesItsRowOnlyWhileItIsShown() {
        let windows = F.reported()
        let with = OverviewLayout.make(F.input(windows, help: true))
        let without = OverviewLayout.make(F.input(windows, help: false))
        XCTAssertNotNil(with.help)
        XCTAssertNil(without.help)
        XCTAssertGreaterThan(without.tiles[0].frame.height, with.tiles[0].frame.height)
    }

    // MARK: Slots, drops and keys

    func testAStripSlotUnderThePointerOpensToAFullTileAboveTheStrip() {
        let windows = F.reported()
        let plain = OverviewLayout.make(F.input(windows))
        let slot4 = plain.slot(4)!
        let opened = OverviewLayout.make(F.input(windows, openSlot: 4))
        let o = opened.slot(4)!.opened!
        XCTAssertGreaterThan(o.width, slot4.frame.width * 2)
        XCTAssertGreaterThan(o.height, slot4.frame.height * 1.5)
        XCTAssertEqual(o.maxY, slot4.frame.maxY, accuracy: 0.01)
        XCTAssertTrue(CGRect(origin: .zero, size: opened.size).contains(o))
        XCTAssertEqual(opened.slotNumber(at: CGPoint(x: o.midX, y: o.minY + 2)), 4, "the tile it opened to still counts as that slot")
        XCTAssertEqual(opened.dropTarget(at: CGPoint(x: o.midX, y: o.minY + 2), from: 1), 4)
    }

    func testDroppingOnATileASlotOrThePlus() {
        let windows = F.windows(on: CGRect(x: 0, y: 0, width: 1512, height: 945)) { [1: 3, 2: 3][$0] ?? 0 }
        let l = OverviewLayout.make(F.input(windows))
        let t2 = l.tile(2)!.frame
        XCTAssertEqual(l.dropTarget(at: CGPoint(x: t2.midX, y: t2.midY), from: 1), 2)
        XCTAssertNil(l.dropTarget(at: CGPoint(x: t2.midX, y: t2.midY), from: 2), "not onto where it came from")
        XCTAssertEqual(l.dropTarget(at: CGPoint(x: l.slot(7)!.frame.midX, y: l.slot(7)!.frame.midY), from: 1), 7)
        let plus = l.slots.first { $0.n == nil }!.frame
        XCTAssertEqual(l.dropTarget(at: CGPoint(x: plus.midX, y: plus.midY), from: 1), 3, "the first empty workspace")
        XCTAssertNil(l.dropTarget(at: CGPoint(x: -5, y: -5), from: 1))
    }

    func testTheArrowKeysReachEveryCardTileAndSlot() {
        let windows = F.windows(on: CGRect(x: 0, y: 0, width: 1512, height: 945)) { [1: 7, 2: 3, 3: 1][$0] ?? 0 }
        let l = OverviewLayout.make(F.input(windows))
        let all = l.targets.map(\.target)
        // From any target some chain of arrows reaches every other: nothing is out of the keyboard's reach.
        var seen: Set<OverviewTarget> = [all[0]]
        var queue = [all[0]]
        while let t = queue.popLast() {
            for d in [OverviewDirection.left, .right, .up, .down] {
                if let n = OverviewNav.move(from: t, d, in: l, current: 1), !seen.contains(n) { seen.insert(n); queue.append(n) }
            }
        }
        XCTAssertEqual(seen, Set(all))
        // Right from the first card goes right; down from the bottom-most card goes lower still.
        let first = l.tiles[0].cards[0]
        let right = OverviewNav.move(from: .card(first.id), .right, in: l, current: 1)
        XCTAssertNotEqual(right, .card(first.id))
        XCTAssertGreaterThan(l.frame(of: right!)!.midX, first.frame.midX)
        let lowest = l.cards.max { $0.frame.maxY < $1.frame.maxY }!
        let down = OverviewNav.move(from: .card(lowest.id), .down, in: l, current: 1)!
        XCTAssertGreaterThan(l.frame(of: down)!.midY, lowest.frame.midY, "down from the lowest card reaches the strip")
        // Along the strip the arrows step one slot; at the far edge they stay.
        XCTAssertEqual(OverviewNav.move(from: .slot(4), .right, in: l, current: 1), .slot(5))
        XCTAssertEqual(OverviewNav.move(from: .slot(5), .left, in: l, current: 1), .slot(4))
        XCTAssertEqual(OverviewNav.move(from: .slot(9), .right, in: l, current: 1), .plus)
        let rightmost = l.targets.max { $0.frame.midX < $1.frame.midX }!.target
        XCTAssertEqual(OverviewNav.move(from: rightmost, .right, in: l, current: 1), rightmost)
    }

    /// The checker the matrix leans on must see what it is there to see.
    func testTheCheckSeesAClippedCardAnOverlapAMissingWindowAndAnUnreachableWorkspace() {
        let windows = F.reported()
        var l = OverviewLayout.make(F.input(windows))
        XCTAssertEqual(l.violations(windows: windows), [])
        // Cut off, the way today's list was: a card hanging out of its tile.
        var clipped = l
        clipped.tiles[0].cards[6].frame.origin.y = clipped.tiles[0].body.maxY - 10
        XCTAssertTrue(clipped.violations(windows: windows).contains { $0.contains("is outside") })
        // Two cards on top of each other.
        var stacked = l
        stacked.tiles[0].cards[1].frame = stacked.tiles[0].cards[0].frame
        XCTAssertTrue(stacked.violations(windows: windows).contains { $0.contains("overlap") })
        // A card gone, with no "+N" for it.
        var missing = l
        missing.tiles[0].cards.removeLast()
        XCTAssertTrue(missing.violations(windows: windows).contains { $0.contains("isn't shown") })
        // A workspace with neither a tile nor a slot.
        l.slots.removeAll { $0.n == 6 }
        XCTAssertFalse(l.reachable.contains(6))
    }
}
